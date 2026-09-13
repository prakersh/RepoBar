import Foundation

extension GitHubReferenceTranslator {
    static func contextualBareIssueQueries(
        in text: String,
        minimumBareDigits: Int,
        suppressLineScopedDuplicates: Bool = true
    ) -> [GitHubReferenceQuery] {
        var previousHadReferenceContext = false
        var queries: [GitHubReferenceQuery] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                previousHadReferenceContext = false
                continue
            }

            for sentence in self.lineScopedSentenceFragments(in: line) {
                if self.isIssueCountSummary(sentence) {
                    previousHadReferenceContext = false
                    continue
                }

                let lineScopedIssueTokens = suppressLineScopedDuplicates
                    ? self.scopedIssueNumberTokens(inLine: sentence, minimumBareDigits: minimumBareDigits)
                    : []
                let hasContext = self.hasIssueReferenceContext(sentence)
                defer { previousHadReferenceContext = hasContext }

                if hasContext {
                    queries.append(contentsOf: self.suppressLineScopedIssueDuplicates(
                        in: self.contextualBareIssueSeriesMatches(
                            in: sentence,
                            minimumBareDigits: minimumBareDigits
                        ),
                        lineScopedIssueTokens: lineScopedIssueTokens
                    ).map(\.query))
                }

                if previousHadReferenceContext, self.startsWithBackReference(sentence) {
                    queries.append(contentsOf: self.suppressLineScopedIssueDuplicates(
                        in: self.backReferenceBareIssueSeriesMatches(
                            in: sentence,
                            minimumBareDigits: minimumBareDigits
                        ),
                        lineScopedIssueTokens: lineScopedIssueTokens
                    ).map(\.query))
                }
            }
        }

        return queries
    }

    private static func suppressLineScopedIssueDuplicates(
        in matches: [GitHubReferenceIssueNumberTokenMatch],
        lineScopedIssueTokens: Set<IssueNumberToken>
    ) -> [GitHubReferenceIssueNumberTokenMatch] {
        matches.filter { match in
            guard case let .issueNumber(number) = match.query else { return true }

            return lineScopedIssueTokens.contains(.init(number: number, tokenIndex: match.tokenIndex)) == false
        }
    }

    static func scopedIssueNumberTokens(inLine line: String, minimumBareDigits: Int) -> Set<IssueNumberToken> {
        Set(
            self.lineScopedRepositoryIssueNumberTokenMatches(
                inLine: line,
                minimumBareDigits: minimumBareDigits
            )
            .compactMap { match in
                guard let number = match.query.issueNumber else { return nil }

                return IssueNumberToken(number: number, tokenIndex: match.tokenIndex)
            }
        )
    }

    private static func contextualBareIssueSeriesMatches(
        in sentence: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceIssueNumberTokenMatch] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.isEmpty == false else { return [] }

        var matches: [GitHubReferenceIssueNumberTokenMatch] = []
        for index in tokens.indices {
            let token = tokens[index].lowercased()
            if index > tokens.startIndex, self.isRepositoryFullName(tokens[tokens.index(before: index)]) {
                continue
            }
            let nextToken = tokens.indices.contains(index + 1) ? tokens[index + 1].lowercased() : nil
            let startIndex: Int? = if ["pr", "prs", "issue", "issues"].contains(token) {
                index + 1
            } else if token == "pull", nextToken == "request" || nextToken == "requests" {
                index + 2
            } else {
                nil
            }
            guard let startIndex else { continue }

            matches.append(contentsOf: self.bareIssueSeriesMatches(
                in: Array(tokens.dropFirst(startIndex)),
                minimumBareDigits: minimumBareDigits,
                tokenOffset: startIndex
            ))
        }

        return matches
    }

    static func backReferenceBareIssueSeriesQueries(in sentence: String, minimumBareDigits: Int) -> [GitHubReferenceQuery] {
        self.backReferenceBareIssueSeriesMatches(in: sentence, minimumBareDigits: minimumBareDigits).map(\.query)
    }

    private static func backReferenceBareIssueSeriesMatches(
        in sentence: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceIssueNumberTokenMatch] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.count >= 2 else { return [] }

        let firstToken = tokens[0].lowercased()
        guard ["that", "this", "it", "they", "these", "those"].contains(firstToken) else { return [] }

        let firstSeriesIndex = ["is", "are", "was", "were"].contains(tokens[1].lowercased()) ? 2 : 1
        guard tokens.indices.contains(firstSeriesIndex) else { return [] }

        return self.bareIssueSeriesMatches(
            in: Array(tokens.dropFirst(firstSeriesIndex)),
            minimumBareDigits: minimumBareDigits,
            tokenOffset: firstSeriesIndex
        )
    }

    static func bareIssueSeriesQueries(in tokens: [String], minimumBareDigits: Int) -> [GitHubReferenceQuery] {
        self.bareIssueSeriesMatches(in: tokens, minimumBareDigits: minimumBareDigits).map(\.query)
    }

    static func bareIssueSeriesMatches(
        in tokens: [String],
        minimumBareDigits: Int,
        tokenOffset: Int = 0
    ) -> [GitHubReferenceIssueNumberTokenMatch] {
        var matches: [GitHubReferenceIssueNumberTokenMatch] = []

        for index in tokens.indices {
            let token = tokens[index]
            let normalized = token.lowercased()
            if let number = self.bareIssueSeriesNumber(from: token, minimumBareDigits: minimumBareDigits) {
                let startsDiffStat = token.hasPrefix("#") == false && self.startsDiffStat(in: tokens, at: index)
                if startsDiffStat, matches.isEmpty == false {
                    break
                }
                matches.append(.init(query: .issueNumber(number), tokenIndex: tokenOffset + index))
                if startsDiffStat {
                    break
                }
                continue
            }

            if ["and", "or", "maybe"].contains(normalized) {
                continue
            }

            break
        }

        return matches
    }

    private static func startsDiffStat(in tokens: [String], at index: Array<String>.Index) -> Bool {
        let nounIndex = index + 1
        guard tokens.indices.contains(nounIndex),
              self.isDiffStatNoun(tokens[nounIndex].lowercased())
        else { return false }

        let nextIndex = nounIndex + 1
        let noun = tokens[nounIndex].lowercased()
        guard tokens.indices.contains(nextIndex) else {
            return self.isStrongDiffStatNoun(noun)
        }

        let nextToken = tokens[nextIndex].lowercased()
        if nextToken == "/" {
            let countIndex = nextIndex + 1
            return tokens.indices.contains(countIndex) && Int(tokens[countIndex]) != nil
        }
        if nextToken == "changed" {
            return self.isStrongDiffStatNoun(noun)
        }
        if ["and", "or"].contains(nextToken) {
            let countIndex = nextIndex + 1
            return self.isStrongDiffStatNoun(noun) &&
                tokens.indices.contains(countIndex) &&
                Int(tokens[countIndex]) != nil
        }

        return Int(nextToken) != nil && self.isStrongDiffStatNoun(noun)
    }

    private static func isDiffStatNoun(_ token: String) -> Bool {
        [
            "add",
            "adds",
            "addition",
            "additions",
            "del",
            "dels",
            "delete",
            "deletes",
            "deletion",
            "deletions",
            "file",
            "files"
        ].contains(token)
    }

    private static func isStrongDiffStatNoun(_ token: String) -> Bool {
        [
            "addition",
            "additions",
            "deletion",
            "deletions",
            "file",
            "files"
        ].contains(token)
    }

    private static func bareIssueSeriesNumber(from token: String, minimumBareDigits: Int) -> Int? {
        if token.hasPrefix("#") {
            return self.issueNumber(from: token, minimumBareDigits: minimumBareDigits, allowBareNumber: false)
        }
        if token.lowercased().hasPrefix("gh-") {
            return self.issueNumber(from: token, minimumBareDigits: minimumBareDigits, allowBareNumber: false)
        }

        guard token.allSatisfy(\.isNumber),
              let number = self.issueNumber(
                  from: token,
                  minimumBareDigits: minimumBareDigits,
                  allowBareNumber: true
              )
        else { return nil }

        return number
    }

    static func repositoryContext(in text: String) -> String? {
        var repositoryFullNames: [String] = []
        var seen: Set<String> = []

        func append(_ repositoryFullName: String) {
            guard seen.insert(repositoryFullName.lowercased()).inserted else { return }

            repositoryFullNames.append(repositoryFullName)
        }

        var sawPrimaryListReference = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let lineHasPrimaryListReference = self.startsWithPrimaryListReference(in: line)
            let lineScopedRepositories = Set(
                self.lineScopedRepositoryIssueQueries(inLine: line, minimumBareDigits: 1)
                    .compactMap(\.repositoryFullName)
                    .map { $0.lowercased() }
            )
            let tokens = self.referenceTokens(in: line)
            for (index, token) in tokens.enumerated() {
                let isProseRepositoryContext = token.contains("#") == false
                    && sawPrimaryListReference == false
                    && lineHasPrimaryListReference == false
                    && self.isRepositoryFullName(token)
                    && lineScopedRepositories.contains(token.lowercased()) == false
                    && self.isLikelyRepositoryContextToken(at: index, in: tokens)
                if isProseRepositoryContext {
                    append(token)
                    continue
                }
                if let repositoryFullName = self.urlQuery(from: token)?.repositoryFullName {
                    append(repositoryFullName)
                    continue
                }
                if let repositoryFullName = self.repositoryIssueNumber(from: token)?.repositoryFullName {
                    append(repositoryFullName)
                }
            }
            if lineHasPrimaryListReference {
                sawPrimaryListReference = true
            }
        }

        return repositoryFullNames.count == 1 ? repositoryFullNames[0] : nil
    }

    private static func startsWithPrimaryListReference(in line: String) -> Bool {
        guard let body = self.listItemBody(in: line),
              let firstToken = self.referenceTokens(in: body).first
        else { return false }

        if self.urlQuery(from: firstToken) != nil {
            return true
        }
        if self.compoundBareIssueQueries(from: firstToken).isEmpty == false {
            return true
        }
        if self.compoundRepositoryIssueQueries(from: firstToken).isEmpty == false {
            return true
        }
        return self.tokenQuery(
            from: firstToken,
            minimumBareDigits: 1,
            allowBareIssueNumber: false,
            allowNumericCommitHash: self.hasCommitContext(line)
        ) != nil
    }

    static func listItemRepositoryContext(in text: String) -> String? {
        let repositories = text
            .split(whereSeparator: \.isNewline)
            .compactMap { self.listItemBody(in: String($0)) }
            .compactMap { body -> String? in
                let tokens = self.referenceTokens(in: body)
                guard tokens.count == 1,
                      let repositoryFullName = tokens.first,
                      self.isRepositoryFullName(repositoryFullName)
                else { return nil }

                return repositoryFullName
            }

        var uniqueRepositories: [String] = []
        var seen: Set<String> = []
        for repository in repositories {
            guard seen.insert(repository.lowercased()).inserted else { continue }

            uniqueRepositories.append(repository)
        }

        return uniqueRepositories.count == 1 ? uniqueRepositories[0] : nil
    }

    private static func isLikelyRepositoryContextToken(at index: Int, in tokens: [String]) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        guard index > 0 else { return true }

        let previous = tokens[index - 1].lowercased()
        return ["in", "repo", "repository", "from", "for", "on", "inside"].contains(previous)
    }

    static func hasIssueReferenceContext(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let tokens = self.referenceTokens(in: normalized)
        if tokens.contains(where: { ["pr", "prs", "issue", "issues"].contains($0) }) {
            return true
        }

        return normalized.contains("pull request")
            || normalized.contains("security fix")
            || normalized.contains("fix/enhancement")
    }

    static func isIssueCountSummary(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains(":") else { return false }

        let tokens = self.referenceTokens(in: normalized)
        guard tokens.count >= 2,
              ["open", "closed"].contains(tokens[0]),
              ["prs", "issues"].contains(tokens[1])
        else { return false }

        if tokens.dropFirst(2).contains(where: { token in
            self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false) != nil
        }) {
            return false
        }

        let bareNumbers = tokens.dropFirst(2).compactMap { token in
            self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: true)
        }
        return bareNumbers.count <= 1
    }

    private static func startsWithBackReference(_ text: String) -> Bool {
        guard let firstToken = self.referenceTokens(in: text).first?.lowercased() else { return false }

        return ["that", "this", "it", "they", "these", "those"].contains(firstToken)
    }

    static func applyingRepositoryContext(_ repositoryFullName: String?, to query: GitHubReferenceQuery) -> GitHubReferenceQuery {
        guard let repositoryFullName else { return query }

        switch query {
        case let .issueNumber(number):
            return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
        case let .repositoryNameIssueNumber(repositoryName, number):
            guard repositoryFullName.split(separator: "/").last?.caseInsensitiveCompare(repositoryName) == .orderedSame else {
                return query
            }

            return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
        case let .commitHash(hash):
            return .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash)
        case .repositoryIssueNumber, .repositoryCommitHash, .repositoryWorkflowRun:
            return query
        }
    }

    static func hasCommitContext(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("sha") || normalized.contains("commit") || normalized.contains("hash")
    }
}
