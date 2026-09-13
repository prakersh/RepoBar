import Foundation

extension GitHubReferenceTranslator {
    private static let maxIssueSeriesCount = 100

    static func tokenQuery(
        from rawToken: String,
        minimumBareDigits: Int,
        allowBareIssueNumber: Bool,
        allowNumericCommitHash: Bool
    ) -> GitHubReferenceQuery? {
        let token = self.normalizedToken(from: rawToken)
        guard token.isEmpty == false else { return nil }

        if let scopedIssue = self.repositoryIssueNumber(from: token) {
            return scopedIssue
        }
        if let namedIssue = self.repositoryNameIssueNumber(from: token) {
            return namedIssue
        }
        if self.isCommitHash(token, allowNumericOnly: allowNumericCommitHash) {
            return .commitHash(token.lowercased())
        }
        if let number = self.issueNumber(from: token, minimumBareDigits: minimumBareDigits, allowBareNumber: allowBareIssueNumber) {
            return .issueNumber(number)
        }
        return nil
    }

    static func issueNumber(from token: String, minimumBareDigits: Int, allowBareNumber: Bool) -> Int? {
        if token.hasPrefix("#") {
            return Int(token.dropFirst())
        }
        if token.lowercased().hasPrefix("gh-") {
            return Int(token.dropFirst(3))
        }
        guard allowBareNumber else { return nil }
        guard token.count >= minimumBareDigits,
              token.allSatisfy(\.isNumber)
        else { return nil }

        return Int(token)
    }

    static func repositoryIssueNumber(from token: String) -> GitHubReferenceQuery? {
        let parts = token.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let number = Int(parts[1]),
              self.isRepositoryFullName(parts[0])
        else { return nil }

        return .repositoryIssueNumber(repositoryFullName: parts[0], number: number)
    }

    static func repositoryNameIssueNumber(from token: String) -> GitHubReferenceQuery? {
        let parts = token.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let number = Int(parts[1]),
              self.isRepositoryName(parts[0])
        else { return nil }

        return .repositoryNameIssueNumber(repositoryName: parts[0], number: number)
    }

    static func compoundRepositoryIssueQueries(from token: String) -> [GitHubReferenceQuery] {
        let parts = token.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              self.isRepositoryFullName(parts[0]),
              parts[1].contains("/") || parts[1].contains("-")
        else { return [] }

        let numberParts = parts[1]
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard numberParts.isEmpty == false else { return [] }

        var numbers: [Int] = []
        for numberPart in numberParts {
            guard let parsedNumbers = self.issueNumbers(fromSeriesPart: numberPart)
            else { return [] }

            numbers.append(contentsOf: parsedNumbers)
        }
        guard (1 ... Self.maxIssueSeriesCount).contains(numbers.count) else { return [] }

        return numbers.map { .repositoryIssueNumber(repositoryFullName: parts[0], number: $0) }
    }

    private static func issueNumbers(fromSeriesPart rawPart: String) -> [Int]? {
        let part = rawPart.hasPrefix("#") ? String(rawPart.dropFirst()) : rawPart
        guard part.isEmpty == false else { return nil }

        let rangeParts = part
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        if rangeParts.count == 2 {
            guard let start = self.issueSeriesNumber(from: rangeParts[0]),
                  let end = self.issueSeriesNumber(from: rangeParts[1]),
                  start <= end
            else { return nil }

            return Array(start ... end)
        }

        guard let number = self.issueSeriesNumber(from: part) else { return nil }

        return [number]
    }

    static func compoundBareIssueQueries(from token: String) -> [GitHubReferenceQuery] {
        guard token.hasPrefix("#"),
              token.contains("/") || token.contains("-")
        else { return [] }

        let numberParts = token
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard numberParts.isEmpty == false else { return [] }

        var numbers: [Int] = []
        for numberPart in numberParts {
            guard let parsedNumbers = self.issueNumbers(fromSeriesPart: numberPart)
            else { return [] }

            numbers.append(contentsOf: parsedNumbers)
        }
        guard (1 ... Self.maxIssueSeriesCount).contains(numbers.count) else { return [] }

        return numbers.map { .issueNumber($0) }
    }

    private static func issueSeriesNumber(from rawNumber: String) -> Int? {
        let normalized = rawNumber.hasPrefix("#") ? String(rawNumber.dropFirst()) : rawNumber
        guard normalized.isEmpty == false,
              normalized.allSatisfy(\.isNumber)
        else { return nil }

        return Int(normalized)
    }

    static func isRepositoryFullName(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }

        return parts.allSatisfy { part in
            part.isEmpty == false && part.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            }
        }
    }

    private static func isRepositoryName(_ value: String) -> Bool {
        value.isEmpty == false && value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
    }

    private static func normalizedToken(from rawToken: String) -> String {
        rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}<>\"'`"))
    }

    static func referenceTokens(in text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map(self.normalizedToken)
            .filter { $0.isEmpty == false }
    }

    static func dedupeKey(for query: GitHubReferenceQuery) -> String {
        switch query {
        case let .issueNumber(number):
            "issue:\(number)"
        case let .repositoryNameIssueNumber(repositoryName, number):
            "repo-name:\(repositoryName.lowercased())#\(number)"
        case let .repositoryIssueNumber(repositoryFullName, number):
            "repo:\(repositoryFullName.lowercased())#\(number)"
        case let .commitHash(hash):
            "commit:\(hash.lowercased())"
        case let .repositoryCommitHash(repositoryFullName, hash):
            "repo:\(repositoryFullName.lowercased())@\(hash.lowercased())"
        case let .repositoryWorkflowRun(repositoryFullName, runID):
            "repo:\(repositoryFullName.lowercased())/run/\(runID)"
        }
    }

    static func dedupedQueries(_ queries: [GitHubReferenceQuery]) -> [GitHubReferenceQuery] {
        var seen: Set<String> = []
        return queries.filter { seen.insert(self.dedupeKey(for: $0)).inserted }
    }

    static func isCommitHash(_ token: String, allowNumericOnly: Bool) -> Bool {
        guard (7 ... 40).contains(token.count) else { return false }
        guard token.allSatisfy(\.isHexDigit) else { return false }
        guard allowNumericOnly || token.contains(where: \.isLetter) else { return false }

        return true
    }
}
