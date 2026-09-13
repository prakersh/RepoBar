import Foundation

extension GitHubReferenceTranslator {
    static func leadingRepositoryHeadingQueries(
        in line: String,
        repositoryFullName: String,
        minimumBareDigits: Int,
        previousHadCommitContext: Bool,
        previousHadIssueReferenceContext: Bool
    ) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: line)
        let allowsCommitHash = previousHadCommitContext || self.headingChildHasCommitContext(line)
        let allowsContextualBareIssueNumber = self.isIssueCountSummary(line) == false
        let explicitLineQueries = self.explicitRepositoryHeadingLineQueries(
            in: line,
            minimumBareDigits: minimumBareDigits
        )
        let explicitLineNumbers = Set(explicitLineQueries.compactMap(\.repositoryIssueNumber))
        let tokenOptions = RepositoryHeadingTokenOptions(
            repositoryFullName: repositoryFullName,
            allowsCommitHash: allowsCommitHash,
            allowsContextualBareIssueNumber: allowsContextualBareIssueNumber,
            explicitLineNumbers: explicitLineNumbers,
            firstExplicitRepositoryIndex: tokens.firstIndex(where: self.isExplicitRepositoryToken),
            minimumBareDigits: minimumBareDigits
        )
        let tokenQueries = tokens.indices.flatMap { index in
            self.repositoryHeadingTokenQueries(
                tokens: tokens,
                index: index,
                options: tokenOptions
            )
        }
        let explicitTokenNumbers = Set<Int>(tokenQueries.compactMap { query in
            guard case let .repositoryIssueNumber(tokenRepositoryFullName, number) = query,
                  tokenRepositoryFullName != repositoryFullName
            else { return nil }

            return number
        })
        let headingTokenNumbers = Set<Int>(tokenQueries.compactMap { query in
            guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                  parentRepositoryFullName == repositoryFullName
            else { return nil }

            return number
        })
        let suppression = RepositoryHeadingSuppression(
            explicitLineNumbers: explicitLineNumbers.union(explicitTokenNumbers),
            headingTokenNumbers: headingTokenNumbers
        )
        let contextualQueries = self.contextualBareIssueQueries(
            in: line,
            minimumBareDigits: minimumBareDigits
        )
        .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
        .filter { query in
            guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                  parentRepositoryFullName == repositoryFullName
            else { return true }

            return suppression.allowsHeadingRepositoryIssueNumber(number)
        }
        let backReferenceQueries = self.repositoryHeadingBackReferenceQueries(
            in: line,
            repositoryFullName: repositoryFullName,
            minimumBareDigits: minimumBareDigits,
            previousHadIssueReferenceContext: previousHadIssueReferenceContext,
            suppression: suppression
        )
        return self.dedupedQueries(tokenQueries + explicitLineQueries + contextualQueries + backReferenceQueries)
    }

    private static func repositoryHeadingTokenQueries(
        tokens: [String],
        index: Array<String>.Index,
        options: RepositoryHeadingTokenOptions
    ) -> [GitHubReferenceQuery] {
        let token = tokens[index]
        let hasPreviousIssueContext = self.previousTokenHasIssueReferenceContext(tokens: tokens, index: index)
        if let explicitRepositoryFullName = self.explicitRepositoryFullName(beforeIssueTokenAt: index, in: tokens) {
            if let number = self.issueNumber(
                from: token,
                minimumBareDigits: options.minimumBareDigits,
                allowBareNumber: hasPreviousIssueContext
            ) {
                return [.repositoryIssueNumber(repositoryFullName: explicitRepositoryFullName, number: number)]
            }
        }
        if options.allowsContextualBareIssueNumber, hasPreviousIssueContext {
            if let number = self.issueNumber(
                from: token,
                minimumBareDigits: options.minimumBareDigits,
                allowBareNumber: true
            ) {
                return [.repositoryIssueNumber(repositoryFullName: options.repositoryFullName, number: number)]
            }
        }
        let isAfterExplicitRepository = options.firstExplicitRepositoryIndex.map { index > $0 } ?? false
        if isAfterExplicitRepository, hasPreviousIssueContext == false {
            let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false)
            if let number, options.explicitLineNumbers.contains(number) {
                return []
            }
        }

        return self.repositoryHeadingTokenQueries(
            token,
            repositoryFullName: options.repositoryFullName,
            allowsCommitHash: options.allowsCommitHash
        )
    }

    private static func explicitRepositoryFullName(
        beforeIssueTokenAt index: Array<String>.Index,
        in tokens: [String]
    ) -> String? {
        guard index > tokens.startIndex else { return nil }

        let previousIndex = tokens.index(before: index)
        if self.isRepositoryFullName(tokens[previousIndex]) {
            return tokens[previousIndex]
        }
        if let repositoryFullName = self.explicitRepositoryFullNameBeforePullRequestPhrase(
            previousIndex: previousIndex,
            in: tokens
        ) {
            return repositoryFullName
        }

        guard index > tokens.index(after: tokens.startIndex),
              ["pr", "prs", "issue", "issues"].contains(tokens[previousIndex].lowercased())
        else { return nil }

        let repositoryIndex = tokens.index(before: previousIndex)
        guard self.isRepositoryFullName(tokens[repositoryIndex]) else { return nil }

        return tokens[repositoryIndex]
    }

    private static func isExplicitRepositoryToken(_ token: String) -> Bool {
        self.isRepositoryFullName(token) || self.repositoryIssueQuery(from: token) != nil
    }

    private static func explicitRepositoryFullNameBeforePullRequestPhrase(
        previousIndex: Array<String>.Index,
        in tokens: [String]
    ) -> String? {
        let previousToken = tokens[previousIndex].lowercased()
        guard previousToken == "request" || previousToken == "requests",
              previousIndex > tokens.index(after: tokens.startIndex)
        else { return nil }

        let pullIndex = tokens.index(before: previousIndex)
        guard tokens[pullIndex].lowercased() == "pull",
              pullIndex > tokens.startIndex
        else { return nil }

        let repositoryIndex = tokens.index(before: pullIndex)
        guard self.isRepositoryFullName(tokens[repositoryIndex]) else { return nil }

        return tokens[repositoryIndex]
    }

    private static func previousTokenHasIssueReferenceContext(tokens: [String], index: Array<String>.Index) -> Bool {
        guard index > tokens.startIndex else { return false }

        let previousIndex = tokens.index(before: index)
        let previousToken = tokens[previousIndex].lowercased()
        if ["pr", "prs", "issue", "issues"].contains(previousToken) {
            return true
        }

        guard previousToken == "request" || previousToken == "requests",
              previousIndex > tokens.startIndex
        else { return false }

        return tokens[tokens.index(before: previousIndex)].lowercased() == "pull"
    }

    private static func repositoryHeadingTokenQueries(
        _ token: String,
        repositoryFullName: String,
        allowsCommitHash: Bool
    ) -> [GitHubReferenceQuery] {
        let bareSeriesQueries = self.compoundBareIssueQueries(from: token)
        if bareSeriesQueries.isEmpty == false {
            return bareSeriesQueries.map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
        }

        let compoundQueries = self.compoundRepositoryIssueQueries(from: token)
        if compoundQueries.isEmpty == false {
            return compoundQueries
        }

        if let query = self.urlQuery(from: token) {
            return [query]
        }
        if let query = self.tokenQuery(
            from: token,
            minimumBareDigits: 1,
            allowBareIssueNumber: false,
            allowNumericCommitHash: allowsCommitHash
        ) {
            if case .commitHash = query, allowsCommitHash == false {
                return []
            }
            return [self.applyingRepositoryContext(repositoryFullName, to: query)]
        }
        return []
    }

    private static func repositoryHeadingBackReferenceQueries(
        in line: String,
        repositoryFullName: String,
        minimumBareDigits: Int,
        previousHadIssueReferenceContext: Bool,
        suppression: RepositoryHeadingSuppression
    ) -> [GitHubReferenceQuery] {
        guard previousHadIssueReferenceContext else { return [] }

        return self.backReferenceBareIssueSeriesQueries(in: line, minimumBareDigits: minimumBareDigits)
            .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
            .filter { query in
                guard case let .repositoryIssueNumber(parentRepositoryFullName, number) = query,
                      parentRepositoryFullName == repositoryFullName
                else { return true }

                return suppression.allowsHeadingRepositoryIssueNumber(number)
            }
    }

    private static func explicitRepositoryHeadingLineQueries(
        in line: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceQuery] {
        self.dedupedQueries(
            self.groupedRepositoryHeadingLineQueries(in: line) +
                self.spacedRepositoryHeadingLineQueries(in: line) +
                self.compactRepositoryHeadingLineQueries(in: line) +
                self.contextualExplicitRepositoryHeadingLineQueries(
                    in: line,
                    minimumBareDigits: minimumBareDigits
                )
        )
    }

    private static func contextualExplicitRepositoryHeadingLineQueries(
        in line: String,
        minimumBareDigits: Int
    ) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: line)
        guard tokens.count >= 3 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        for index in tokens.indices.dropLast() {
            let repositoryFullName = tokens[index]
            guard self.isRepositoryFullName(repositoryFullName) else { continue }

            let firstReferenceIndex = tokens.index(after: index)
            guard self.tokenStartsIssueReferenceContext(tokens: tokens, index: firstReferenceIndex) else { continue }

            let segmentEnd = tokens[firstReferenceIndex...].firstIndex(where: self.isRepositoryFullName) ?? tokens.endIndex
            let rest = tokens[firstReferenceIndex ..< segmentEnd].joined(separator: " ")
            queries.append(
                contentsOf: self.contextualBareIssueQueries(in: rest, minimumBareDigits: minimumBareDigits)
                    .map { self.applyingRepositoryContext(repositoryFullName, to: $0) }
            )
        }
        return self.dedupedQueries(queries)
    }

    private static func tokenStartsIssueReferenceContext(tokens: [String], index: Array<String>.Index) -> Bool {
        guard tokens.indices.contains(index) else { return false }

        let token = tokens[index].lowercased()
        if ["pr", "prs", "issue", "issues"].contains(token) {
            return true
        }
        return self.startsPullRequestPhrase(tokens: tokens.map { $0.lowercased() }, index: index)
    }

    private static func groupedRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        guard let colon = line.firstIndex(of: ":") else { return [] }

        let prefixTokens = self.referenceTokens(in: String(line[..<colon]))
        guard let repositoryFullName = prefixTokens.last(where: self.isRepositoryFullName) else { return [] }

        return self.referenceTokens(in: String(line[line.index(after: colon)...]))
            .compactMap { token in
                guard let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false) else {
                    return nil
                }

                return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
            }
    }

    private static func spacedRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        self.dedupedQueries(self.repositoryHeadingSentenceFragments(in: line).flatMap {
            self.spacedRepositoryHeadingSentenceQueries(in: $0)
        })
    }

    private static func spacedRepositoryHeadingSentenceQueries(in sentence: String) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.count >= 2 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        for index in tokens.indices.dropLast() {
            let repositoryFullName = tokens[index]
            guard self.isRepositoryFullName(repositoryFullName) else { continue }

            var sawNumber = false
            for token in tokens[tokens.index(after: index)...] {
                if self.isRepositoryFullName(token) {
                    break
                }
                if sawNumber, self.tokenHasIssueReferenceContext(token) {
                    break
                }
                guard let number = self.issueNumber(
                    from: token,
                    minimumBareDigits: 1,
                    allowBareNumber: false
                ) else { continue }

                sawNumber = true
                queries.append(.repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number))
            }
        }
        return queries
    }

    private static func compactRepositoryHeadingLineQueries(in line: String) -> [GitHubReferenceQuery] {
        self.dedupedQueries(self.repositoryHeadingSentenceFragments(in: line).flatMap {
            self.compactRepositoryHeadingSentenceQueries(in: $0)
        })
    }

    private static func compactRepositoryHeadingSentenceQueries(in sentence: String) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: sentence)
        guard tokens.count >= 2 else { return [] }

        var queries: [GitHubReferenceQuery] = []
        var currentRepositoryFullName: String?
        var currentRepositorySawNumber = false
        for token in tokens {
            if let repositoryIssueQuery = self.repositoryIssueQuery(from: token) {
                if case let .repositoryIssueNumber(repositoryFullName, _) = repositoryIssueQuery {
                    currentRepositoryFullName = repositoryFullName
                    currentRepositorySawNumber = true
                    queries.append(repositoryIssueQuery)
                    continue
                }
            }
            if self.isRepositoryFullName(token) {
                currentRepositoryFullName = nil
                currentRepositorySawNumber = false
                continue
            }
            if currentRepositorySawNumber, self.tokenHasIssueReferenceContext(token) {
                currentRepositoryFullName = nil
                currentRepositorySawNumber = false
                continue
            }
            guard let currentRepositoryFullName,
                  let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false)
            else { continue }

            currentRepositorySawNumber = true
            queries.append(.repositoryIssueNumber(repositoryFullName: currentRepositoryFullName, number: number))
        }
        return queries
    }

    private static func repositoryHeadingSentenceFragments(in line: String) -> [String] {
        var fragments: [String] = []
        var fragmentStart = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let nextIndex = line.index(after: index)
            let character = line[index]
            let isSentencePunctuation = character == "." || character == "!" || character == "?" || character == ";"
            let isBoundary = nextIndex == line.endIndex || line[nextIndex].isWhitespace
            if isSentencePunctuation, isBoundary {
                fragments.append(String(line[fragmentStart ..< index]))
                fragmentStart = nextIndex
            }
            index = nextIndex
        }
        fragments.append(String(line[fragmentStart...]))
        return fragments
    }

    private static func tokenHasIssueReferenceContext(_ token: String) -> Bool {
        ["pr", "prs", "issue", "issues", "pull"].contains(token.lowercased())
    }

    private static func repositoryIssueQuery(from token: String) -> GitHubReferenceQuery? {
        guard let query = self.tokenQuery(
            from: token,
            minimumBareDigits: 1,
            allowBareIssueNumber: false,
            allowNumericCommitHash: false
        ),
            case .repositoryIssueNumber = query
        else { return nil }

        return query
    }

    static func headingChildHasIssueReferenceContext(_ line: String) -> Bool {
        let lastSentence = line
            .split { character in
                character == "." || character == "!" || character == "?"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.isEmpty == false }
        guard let lastSentence else { return false }

        return self.isIssueCountSummary(lastSentence) == false && self.hasIssueReferenceContext(lastSentence)
    }

    static func headingChildHasCommitContext(_ line: String) -> Bool {
        let normalized = line.lowercased()
        return normalized.contains("sha") || normalized.contains("commit") || normalized.contains("hash")
    }
}

private struct RepositoryHeadingSuppression {
    let explicitLineNumbers: Set<Int>
    let headingTokenNumbers: Set<Int>

    func allowsHeadingRepositoryIssueNumber(_ number: Int) -> Bool {
        self.explicitLineNumbers.contains(number) == false ||
            self.headingTokenNumbers.contains(number)
    }
}

private struct RepositoryHeadingTokenOptions {
    let repositoryFullName: String
    let allowsCommitHash: Bool
    let allowsContextualBareIssueNumber: Bool
    let explicitLineNumbers: Set<Int>
    let firstExplicitRepositoryIndex: Int?
    let minimumBareDigits: Int
}

extension GitHubReferenceQuery {
    var repositoryIssueNumber: Int? {
        guard case let .repositoryIssueNumber(_, number) = self else { return nil }

        return number
    }
}
