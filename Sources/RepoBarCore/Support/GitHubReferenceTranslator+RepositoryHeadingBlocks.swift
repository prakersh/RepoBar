import Foundation

struct RepositoryHeadingListBlockParse {
    let entries: [RepositoryHeadingListBlockEntry]
    let consumedLineIndexes: Set<Int>
    let remainingText: String
    let repositoryFullNames: [String]

    var queries: [GitHubReferenceQuery] {
        self.entries.flatMap(\.queries)
    }
}

struct RepositoryHeadingListBlockEntry {
    let lineIndex: Int
    let queries: [GitHubReferenceQuery]
}

extension GitHubReferenceTranslator {
    static func repositoryHeadingListBlockParse(
        in text: String,
        minimumBareDigits: Int
    ) -> RepositoryHeadingListBlockParse {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [RepositoryHeadingListBlockEntry] = []
        var consumedLineIndexes: Set<Int> = []
        var repositoryFullNames: [String] = []
        var currentRepositoryFullName: String?
        var currentHeadingIndent: Int?
        var currentChildHadIssueReferenceContext = false
        var currentChildHadCommitContext = false
        var pendingRepositoryFullName: String?
        var pendingHeadingIndent: Int?
        var pendingLineIndex: Int?

        for (lineIndex, line) in lines.enumerated() {
            let indent = self.leadingWhitespaceCount(in: line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let listItemBody = self.listItemBody(in: line)
            if let repositoryFullName = self.repositoryHeading(in: listItemBody ?? trimmed) {
                pendingRepositoryFullName = nil
                pendingHeadingIndent = nil
                pendingLineIndex = nil
                currentRepositoryFullName = repositoryFullName
                currentHeadingIndent = indent
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                consumedLineIndexes.insert(lineIndex)
                repositoryFullNames.append(repositoryFullName)
                continue
            }

            if let pendingFullName = pendingRepositoryFullName {
                let pendingIndent = pendingHeadingIndent ?? indent
                let pendingIndex = pendingLineIndex ?? lineIndex
                if trimmed.isEmpty || indent <= pendingIndent {
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                } else if self.isRepositoryHeadingSummary(listItemBody ?? trimmed) {
                    currentRepositoryFullName = pendingFullName
                    currentHeadingIndent = pendingIndent
                    currentChildHadIssueReferenceContext = false
                    currentChildHadCommitContext = false
                    consumedLineIndexes.insert(pendingIndex)
                    consumedLineIndexes.insert(lineIndex)
                    repositoryFullNames.append(pendingFullName)
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                    continue
                } else {
                    pendingRepositoryFullName = nil
                    pendingHeadingIndent = nil
                    pendingLineIndex = nil
                }
            }

            let canStartRepositoryOnlyHeading = currentHeadingIndent.map { indent <= $0 } ?? true
            let repositoryOnlyHeading = self.repositoryOnlyHeading(in: listItemBody ?? trimmed)
            if canStartRepositoryOnlyHeading, let repositoryFullName = repositoryOnlyHeading {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                pendingRepositoryFullName = repositoryFullName
                pendingHeadingIndent = indent
                pendingLineIndex = lineIndex
                continue
            }

            if let body = listItemBody {
                if let repositoryFullName = currentRepositoryFullName {
                    if let headingIndent = currentHeadingIndent, indent > headingIndent {
                        let lineQueries = self.leadingRepositoryHeadingQueries(
                            in: body,
                            repositoryFullName: repositoryFullName,
                            minimumBareDigits: minimumBareDigits,
                            previousHadCommitContext: currentChildHadCommitContext,
                            previousHadIssueReferenceContext: currentChildHadIssueReferenceContext
                        )
                        currentChildHadIssueReferenceContext = self.headingChildHasIssueReferenceContext(body)
                        currentChildHadCommitContext = self.headingChildHasCommitContext(body)
                        consumedLineIndexes.insert(lineIndex)
                        if lineQueries.isEmpty == false {
                            entries.append(RepositoryHeadingListBlockEntry(
                                lineIndex: lineIndex,
                                queries: lineQueries
                            ))
                        }
                        continue
                    }
                }

                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }

            guard let repositoryFullName = currentRepositoryFullName,
                  let headingIndent = currentHeadingIndent
            else { continue }

            if trimmed.isEmpty {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }
            guard indent > headingIndent else {
                currentRepositoryFullName = nil
                currentHeadingIndent = nil
                currentChildHadIssueReferenceContext = false
                currentChildHadCommitContext = false
                continue
            }

            let lineQueries = self.leadingRepositoryHeadingQueries(
                in: trimmed,
                repositoryFullName: repositoryFullName,
                minimumBareDigits: minimumBareDigits,
                previousHadCommitContext: currentChildHadCommitContext,
                previousHadIssueReferenceContext: currentChildHadIssueReferenceContext
            )
            currentChildHadIssueReferenceContext = self.headingChildHasIssueReferenceContext(trimmed)
            currentChildHadCommitContext = self.headingChildHasCommitContext(trimmed)
            consumedLineIndexes.insert(lineIndex)
            if lineQueries.isEmpty == false {
                entries.append(RepositoryHeadingListBlockEntry(
                    lineIndex: lineIndex,
                    queries: lineQueries
                ))
            }
        }

        let remainingText = lines.enumerated()
            .map { consumedLineIndexes.contains($0.offset) ? "" : $0.element }
            .joined(separator: "\n")
        return RepositoryHeadingListBlockParse(
            entries: entries,
            consumedLineIndexes: consumedLineIndexes,
            remainingText: remainingText,
            repositoryFullNames: repositoryFullNames
        )
    }

    static func queriesMergingRepositoryHeadingListBlocks(
        in text: String,
        minimumBareDigits: Int,
        repositoryContextOverride: String?,
        repositoryHeadingListBlockParse: RepositoryHeadingListBlockParse
    ) -> [GitHubReferenceQuery] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let entriesByLine = Dictionary(grouping: repositoryHeadingListBlockParse.entries, by: \.lineIndex)
        let allowedNormalDedupeKeys = self.primaryURLShortcutDedupeKeys(
            in: repositoryHeadingListBlockParse.remainingText,
            repositoryContextOverride: repositoryContextOverride
        )
        let normalRepositoryContext = self.normalRepositoryContext(
            in: repositoryHeadingListBlockParse.remainingText,
            repositoryContextOverride: repositoryContextOverride,
            consumedRepositoryFullNames: repositoryHeadingListBlockParse.repositoryFullNames
        )
        var normalLines: [String] = []
        var queries: [GitHubReferenceQuery] = []
        var seen: Set<String> = []

        func append(_ query: GitHubReferenceQuery) {
            guard seen.insert(self.dedupeKey(for: query)).inserted else { return }

            queries.append(query)
        }

        func flushNormalLines() {
            guard normalLines.isEmpty == false else { return }

            let chunkText = normalLines.joined(separator: "\n")
            let localQueries = self.normalQueries(
                from: chunkText,
                minimumBareDigits: minimumBareDigits,
                repositoryContextOverride: normalRepositoryContext
            ) + self.chunkPrimaryCompoundListQueries(
                in: chunkText,
                repositoryContext: normalRepositoryContext
            )
            let localScopedIssueNumbers = Set<Int>(localQueries.compactMap { query in
                guard case let .repositoryIssueNumber(_, number) = query else { return nil }

                return number
            })
            let localPrimaryURLShortcutScopedKeys = self.localPrimaryURLShortcutScopedKeys(
                in: chunkText,
                allowedNormalDedupeKeys: allowedNormalDedupeKeys
            )
            for query in localQueries {
                let queryIsAllowed = self.normalQueryIsAllowedByPrimaryURLShortcut(
                    query,
                    allowedNormalDedupeKeys: allowedNormalDedupeKeys,
                    localPrimaryURLShortcutScopedKeys: localPrimaryURLShortcutScopedKeys,
                    localScopedIssueNumbers: localScopedIssueNumbers
                )
                if queryIsAllowed == false {
                    continue
                }
                append(query)
            }
            normalLines.removeAll(keepingCapacity: true)
        }

        for lineIndex in lines.indices {
            if repositoryHeadingListBlockParse.consumedLineIndexes.contains(lineIndex) {
                flushNormalLines()
                for entry in entriesByLine[lineIndex] ?? [] {
                    for query in entry.queries {
                        append(query)
                    }
                }
                continue
            }

            normalLines.append(lines[lineIndex])
        }
        flushNormalLines()

        return queries
    }

    private static func chunkPrimaryCompoundListQueries(
        in text: String,
        repositoryContext: String?
    ) -> [GitHubReferenceQuery] {
        var queries: [GitHubReferenceQuery] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let body = self.listItemBody(in: line),
                  let firstToken = self.referenceTokens(in: body).first
            else { continue }

            let bareSeriesQueries = self.compoundBareIssueQueries(from: firstToken)
            if bareSeriesQueries.isEmpty == false {
                queries.append(contentsOf: bareSeriesQueries.map {
                    self.applyingRepositoryContext(repositoryContext, to: $0)
                })
            }
        }
        return self.dedupedQueries(queries)
    }

    private static func normalRepositoryContext(
        in remainingText: String,
        repositoryContextOverride: String?,
        consumedRepositoryFullNames: [String]
    ) -> String? {
        guard repositoryContextOverride == nil else { return repositoryContextOverride }

        if let context = self.repositoryContext(in: self.droppingRepositoryOnlyListItems(from: remainingText)) {
            return context
        }

        guard let context = self.listItemRepositoryContext(in: remainingText) else { return nil }

        let loweredContext = context.lowercased()
        let hasDifferentConsumedRepository = consumedRepositoryFullNames.contains {
            $0.lowercased() != loweredContext
        }
        return hasDifferentConsumedRepository ? nil : context
    }

    private static func droppingRepositoryOnlyListItems(from text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let line = String(line)
                let listItemIsRepositoryOnly = self.listItemBody(in: line).map {
                    self.repositoryOnlyHeading(in: $0) != nil
                } ?? false
                if listItemIsRepositoryOnly {
                    return ""
                }
                if self.repositoryOnlyHeading(in: line) != nil {
                    return ""
                }

                return line
            }
            .joined(separator: "\n")
    }

    private static func normalQueryIsAllowedByPrimaryURLShortcut(
        _ query: GitHubReferenceQuery,
        allowedNormalDedupeKeys: Set<String>?,
        localPrimaryURLShortcutScopedKeys: Set<String>,
        localScopedIssueNumbers: Set<Int>
    ) -> Bool {
        guard let allowedNormalDedupeKeys else { return true }

        if case let .issueNumber(number) = query {
            if allowedNormalDedupeKeys.contains("issue:\(number)"), localScopedIssueNumbers.contains(number) {
                return false
            }
        }
        if allowedNormalDedupeKeys.contains(self.dedupeKey(for: query)) {
            return true
        }
        if case .repositoryIssueNumber = query {
            return localPrimaryURLShortcutScopedKeys.contains(self.dedupeKey(for: query))
        }
        return false
    }

    private static func localPrimaryURLShortcutScopedKeys(
        in text: String,
        allowedNormalDedupeKeys: Set<String>?
    ) -> Set<String> {
        guard let allowedNormalDedupeKeys else { return [] }

        var keys: Set<String> = []
        var currentPrimaryNumbers: Set<Int> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let body = self.listItemBody(in: line) {
                currentPrimaryNumbers = self.primaryListBodyShortcutIssueNumbers(
                    in: body,
                    allowedNormalDedupeKeys: allowedNormalDedupeKeys
                )
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentPrimaryNumbers = []
            }

            guard currentPrimaryNumbers.isEmpty == false else { continue }

            for token in self.referenceTokens(in: line) {
                guard let query = self.urlQuery(from: token),
                      case let .repositoryIssueNumber(_, number) = query,
                      currentPrimaryNumbers.contains(number)
                else { continue }

                keys.insert(self.dedupeKey(for: query))
            }
        }
        return keys
    }

    private static func primaryListBodyShortcutIssueNumbers(
        in body: String,
        allowedNormalDedupeKeys: Set<String>
    ) -> Set<Int> {
        guard let firstToken = self.referenceTokens(in: body).first else { return [] }

        let queries = self.compoundBareIssueQueries(from: firstToken) + [
            self.tokenQuery(
                from: firstToken,
                minimumBareDigits: 1,
                allowBareIssueNumber: false,
                allowNumericCommitHash: false
            )
        ].compactMap(\.self)
        return Set(queries.compactMap { query in
            guard case let .issueNumber(number) = query,
                  allowedNormalDedupeKeys.contains("issue:\(number)")
            else { return nil }

            return number
        })
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix(while: \.isWhitespace).count
    }

    private static func repositoryHeading(in listItemBody: String) -> String? {
        guard let colon = listItemBody.firstIndex(of: ":") else { return nil }

        let suffix = String(listItemBody[listItemBody.index(after: colon)...])
        guard self.isRepositoryHeadingSummary(suffix) else { return nil }

        let suffixTokens = self.referenceTokens(in: suffix)
        guard suffixTokens.contains(where: {
            self.issueNumber(from: $0, minimumBareDigits: 1, allowBareNumber: false) != nil
        }) == false else { return nil }

        let prefixTokens = self.referenceTokens(in: String(listItemBody[..<colon]))
        guard prefixTokens.count == 1,
              let repositoryFullName = prefixTokens.first,
              self.isRepositoryFullName(repositoryFullName)
        else { return nil }

        return repositoryFullName
    }

    private static func repositoryOnlyHeading(in listItemBody: String) -> String? {
        let trimmed = listItemBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(":") == false else { return nil }

        let tokens = self.referenceTokens(in: trimmed)
        guard tokens.count == 1,
              let repositoryFullName = tokens.first,
              self.isRepositoryFullName(repositoryFullName)
        else { return nil }

        return repositoryFullName
    }

    private static func isRepositoryHeadingSummary(_ text: String) -> Bool {
        let tokens = self.referenceTokens(in: text.lowercased())
        guard tokens.isEmpty == false else { return false }

        var hasIssueCount = false
        var hasPullRequestCount = false
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            if token == "/" {
                index = tokens.index(after: index)
                continue
            }

            guard Int(token) != nil else { return false }

            index = tokens.index(after: index)
            guard index < tokens.endIndex else { return false }

            let noun = tokens[index]
            if noun == "issue" || noun == "issues" {
                hasIssueCount = true
                index = tokens.index(after: index)
                continue
            }
            if noun == "pr" || noun == "prs" {
                hasPullRequestCount = true
                index = tokens.index(after: index)
                continue
            }
            if self.startsPullRequestPhrase(tokens: tokens, index: index) {
                hasPullRequestCount = true
                index = tokens.index(index, offsetBy: 2)
                continue
            }
            return false
        }

        return hasIssueCount && hasPullRequestCount
    }

    static func startsPullRequestPhrase(tokens: [String], index: Array<String>.Index) -> Bool {
        self.tokenIsPull(tokens: tokens, index: index) &&
            tokens.indices.contains(tokens.index(after: index)) &&
            ["request", "requests"].contains(tokens[tokens.index(after: index)])
    }

    private static func tokenIsPull(tokens: [String], index: Array<String>.Index) -> Bool {
        tokens[index] == "pull"
    }
}
