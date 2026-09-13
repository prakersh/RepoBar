import Foundation

public enum GitHubReferenceTranslator {
    public static let defaultMinimumBareDigits = 1
    static let maxScannedTextLength = 8000

    public static func query(
        from rawText: String,
        minimumBareDigits: Int = Self.defaultMinimumBareDigits
    ) -> GitHubReferenceQuery? {
        self.queries(from: rawText, minimumBareDigits: minimumBareDigits).first
    }

    public static func queries(
        from rawText: String,
        minimumBareDigits: Int = Self.defaultMinimumBareDigits,
        repositoryContextOverride: String? = nil
    ) -> [GitHubReferenceQuery] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query = self.urlQuery(from: text) {
            return [query]
        }

        if let query = self.tokenQuery(
            from: text,
            minimumBareDigits: minimumBareDigits,
            allowBareIssueNumber: true,
            allowNumericCommitHash: true
        ) {
            return [self.applyingRepositoryContext(repositoryContextOverride, to: query)]
        }

        let scannedText = rawText.trimmingCharacters(in: .newlines)
        guard scannedText.count <= Self.maxScannedTextLength else { return [] }

        let repositoryHeadingListBlockParse = self.repositoryHeadingListBlockParse(
            in: scannedText,
            minimumBareDigits: minimumBareDigits
        )
        if repositoryHeadingListBlockParse.consumedLineIndexes.isEmpty == false {
            return self.queriesMergingRepositoryHeadingListBlocks(
                in: scannedText,
                minimumBareDigits: minimumBareDigits,
                repositoryContextOverride: repositoryContextOverride,
                repositoryHeadingListBlockParse: repositoryHeadingListBlockParse
            )
        }

        return self.normalQueries(
            from: repositoryHeadingListBlockParse.remainingText,
            minimumBareDigits: minimumBareDigits,
            repositoryContextOverride: repositoryContextOverride
        )
    }

    static func normalQueries(
        from parseText: String,
        minimumBareDigits: Int,
        repositoryContextOverride: String?
    ) -> [GitHubReferenceQuery] {
        let tokens = self.referenceTokens(in: parseText)
        let groupedQueries = self.groupedRepositoryIssueQueries(in: parseText)
        let lineScopedQueries = self.lineScopedRepositoryIssueQueries(in: parseText, minimumBareDigits: minimumBareDigits)
        let repositoryContext = repositoryContextOverride
            ?? self.repositoryContext(in: parseText)
            ?? self.listItemRepositoryContext(in: parseText)
        let primaryListQueries = self.primaryListItemQueries(
            in: parseText,
            repositoryContext: repositoryContext
        )
        if let shortcutQueries = self.primaryURLShortcutQueries(
            tokens: tokens,
            primaryListQueries: primaryListQueries
        ) {
            return shortcutQueries
        }

        var queries: [GitHubReferenceQuery] = []
        var seen: Set<String> = []
        func append(_ query: GitHubReferenceQuery) {
            guard seen.insert(self.dedupeKey(for: query)).inserted else { return }

            queries.append(query)
        }

        if primaryListQueries.count >= 2 {
            for query in primaryListQueries {
                append(query)
            }
        }

        for token in tokens {
            if let query = self.urlQuery(from: token) {
                append(query)
            }
            for query in self.compoundRepositoryIssueQueries(from: token) {
                append(query)
            }
        }

        for query in groupedQueries {
            append(query)
        }
        for query in lineScopedQueries {
            append(query)
        }
        for query in self.contextualBareIssueQueries(
            in: parseText,
            minimumBareDigits: minimumBareDigits,
            suppressLineScopedDuplicates: true
        ) {
            append(self.applyingRepositoryContext(repositoryContext, to: query))
        }

        let allowsNumericCommitHash = self.hasCommitContext(parseText)
        for line in parseText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            for sentence in self.lineScopedSentenceFragments(in: line) {
                let lineScopedIssueTokens = self.scopedIssueNumberTokens(
                    inLine: sentence,
                    minimumBareDigits: minimumBareDigits
                )
                for (index, token) in self.referenceTokens(in: sentence).enumerated() {
                    if let query = self.tokenQuery(
                        from: token,
                        minimumBareDigits: minimumBareDigits,
                        allowBareIssueNumber: false,
                        allowNumericCommitHash: allowsNumericCommitHash
                    ) {
                        let isLineScopedIssueToken = query.issueNumber.map {
                            lineScopedIssueTokens.contains(.init(number: $0, tokenIndex: index))
                        } ?? false
                        if isLineScopedIssueToken {
                            continue
                        }
                        append(self.applyingRepositoryContext(repositoryContext, to: query))
                    }
                }
            }
        }

        return queries
    }

    private static func primaryListItemQueries(
        in text: String,
        repositoryContext: String?
    ) -> [GitHubReferenceQuery] {
        let allowsNumericCommitHash = self.hasCommitContext(text)
        var queries: [GitHubReferenceQuery] = []
        var seen: Set<String> = []

        func append(_ query: GitHubReferenceQuery) {
            guard seen.insert(self.dedupeKey(for: query)).inserted else { return }

            queries.append(query)
        }

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let body = self.listItemBody(in: line),
                  let firstToken = self.referenceTokens(in: body).first
            else { continue }

            if let query = self.urlQuery(from: firstToken) {
                append(query)
                continue
            }

            let bareSeriesQueries = self.compoundBareIssueQueries(from: firstToken)
            if bareSeriesQueries.isEmpty == false {
                bareSeriesQueries
                    .map { self.applyingRepositoryContext(repositoryContext, to: $0) }
                    .forEach(append)
                continue
            }

            let compoundQueries = self.compoundRepositoryIssueQueries(from: firstToken)
            if compoundQueries.isEmpty == false {
                compoundQueries.forEach(append)
                continue
            }

            guard let query = self.tokenQuery(
                from: firstToken,
                minimumBareDigits: 1,
                allowBareIssueNumber: false,
                allowNumericCommitHash: allowsNumericCommitHash
            ) else { continue }

            append(self.applyingRepositoryContext(repositoryContext, to: query))
        }

        return queries
    }

    private static func primaryURLShortcutQueries(
        tokens: [String],
        primaryListQueries: [GitHubReferenceQuery]
    ) -> [GitHubReferenceQuery]? {
        guard primaryListQueries.count >= 2,
              tokens.contains(where: { self.urlQuery(from: $0) != nil })
        else { return nil }

        return primaryListQueries
    }

    static func primaryURLShortcutDedupeKeys(
        in parseText: String,
        repositoryContextOverride: String?
    ) -> Set<String>? {
        let tokens = self.referenceTokens(in: parseText)
        let repositoryContext = repositoryContextOverride
            ?? self.repositoryContext(in: parseText)
            ?? self.listItemRepositoryContext(in: parseText)
        let primaryListQueries = self.primaryListItemQueries(
            in: parseText,
            repositoryContext: repositoryContext
        )
        guard let shortcutQueries = self.primaryURLShortcutQueries(
            tokens: tokens,
            primaryListQueries: primaryListQueries
        ) else { return nil }

        return Set(shortcutQueries.map(self.dedupeKey(for:)))
    }

    static func listItemBody(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var digitEnd = trimmed.startIndex
        while digitEnd < trimmed.endIndex, trimmed[digitEnd].isNumber {
            digitEnd = trimmed.index(after: digitEnd)
        }
        guard digitEnd > trimmed.startIndex,
              digitEnd < trimmed.endIndex,
              trimmed[digitEnd] == "." || trimmed[digitEnd] == ")"
        else { return nil }

        let markerEnd = trimmed.index(after: digitEnd)
        guard markerEnd == trimmed.endIndex || trimmed[markerEnd].isWhitespace else { return nil }

        return String(trimmed[markerEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func groupedRepositoryIssueQueries(in text: String) -> [GitHubReferenceQuery] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { self.groupedRepositoryIssueQueries(inLine: String($0)) }
    }

    private static func groupedRepositoryIssueQueries(inLine line: String) -> [GitHubReferenceQuery] {
        self.lineScopedSentenceFragments(in: line).flatMap(self.groupedRepositoryIssueQueries(inSegment:))
    }

    private static func groupedRepositoryIssueQueries(inSegment segment: String) -> [GitHubReferenceQuery] {
        guard let colon = segment.firstIndex(of: ":") else { return [] }

        let prefixTokens = self.referenceTokens(in: String(segment[..<colon]))
        guard let repositoryFullName = prefixTokens.last(where: self.isRepositoryFullName) else { return [] }

        return self.referenceTokens(in: String(segment[segment.index(after: colon)...]))
            .compactMap { token in
                guard let number = self.issueNumber(from: token, minimumBareDigits: 1, allowBareNumber: false) else {
                    return nil
                }

                return .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number)
            }
    }
}
