import Algorithms
import Foundation
import RepoBarCore

extension AppState {
    func updateGitHubReferenceMonitor() {
        guard self.isStarted else {
            self.gitHubReferenceMonitor?.stop()
            self.gitHubReferenceMonitor = nil
            return
        }
        guard self.session.settings.gitHubReferenceMonitor.enabled else {
            Task { await DiagnosticsLogger.shared.message("GitHub reference monitor disabled") }
            self.gitHubReferenceMonitor?.stop()
            self.gitHubReferenceMonitor = nil
            self.setGitHubReferenceMatch(nil)
            return
        }

        if self.gitHubReferenceMonitor == nil {
            Task { await DiagnosticsLogger.shared.message("GitHub reference monitor created") }
            self.gitHubReferenceMonitor = GitHubReferenceMonitor(
                onPasteboardWithoutReference: { [weak self] in
                    await self?.clearGitHubReference()
                },
                onReferences: { [weak self] queries, text in
                    await self?.resolveGitHubReferences(queries, sourceText: text)
                }
            )
        }
        Task { await DiagnosticsLogger.shared.message("GitHub reference monitor started mode=clipboard-only") }
        self.gitHubReferenceMonitor?.start()
    }

    private func clearGitHubReference() async {
        guard self.session.settings.gitHubReferenceMonitor.enabled else { return }

        self.gitHubReferenceResolutionID = UUID()
        self.setGitHubReferenceMatches([])
    }

    private func resolveGitHubReferences(_ queries: [GitHubReferenceQuery], sourceText: String) async {
        guard self.session.settings.gitHubReferenceMonitor.enabled else { return }

        let resolutionID = UUID()
        self.gitHubReferenceResolutionID = resolutionID
        let scopedQueries = await self.queries(queries, applyingLocalRepositoryContextFrom: sourceText)
        guard self.gitHubReferenceResolutionID == resolutionID else { return }

        let provisionalMatches = self.provisionalReferenceMatches(from: sourceText)
        let matches = await self.referenceMatches(
            for: scopedQueries,
            resolutionID: resolutionID,
            provisionalMatches: provisionalMatches
        ) { matches in
            self.setGitHubReferenceMatches(matches)
        }
        guard self.gitHubReferenceResolutionID == resolutionID else { return }

        self.setGitHubReferenceMatches(matches)
    }

    func resolveGitHubReferenceQueries(_ queries: [GitHubReferenceQuery], sourceText: String) async -> [GitHubReferenceMatch] {
        let scopedQueries = await self.queries(queries, applyingLocalRepositoryContextFrom: sourceText)
        return await self.referenceMatches(for: scopedQueries, resolutionID: nil)
    }

    private func referenceMatches(
        for queries: [GitHubReferenceQuery],
        resolutionID: UUID?,
        provisionalMatches: [GitHubReferenceQuery: GitHubReferenceMatch] = [:],
        onProgress: (([GitHubReferenceMatch]) -> Void)? = nil
    ) async -> [GitHubReferenceMatch] {
        let limitedQueries = Array(queries.prefix(AppLimits.GitHubReferenceMonitor.queryLimit))
        let repositories = self.githubReferenceCandidateRepositories()
        let github = self.github
        var matchesByIndex: [Int: GitHubReferenceMatch] = [:]

        let indexedQueries = Array(limitedQueries.enumerated())
        for (index, query) in indexedQueries {
            if let provisionalMatch = provisionalMatches[query] {
                matchesByIndex[index] = provisionalMatch
            }
        }
        if matchesByIndex.isEmpty == false {
            onProgress?(Self.orderedReferenceMatches(matchesByIndex))
        }

        for chunk in indexedQueries.chunks(ofCount: AppLimits.GitHubReferenceMonitor.resolutionConcurrencyLimit) {
            await withTaskGroup(of: (Int, GitHubReferenceMatch?).self) { group in
                for (index, query) in chunk {
                    group.addTask {
                        let match = await Self.resolveGitHubReferenceMatch(
                            query: query,
                            repositories: repositories,
                            github: github
                        )
                        return (index, match)
                    }
                }

                for await (index, match) in group {
                    if let resolutionID, self.gitHubReferenceResolutionID != resolutionID {
                        group.cancelAll()
                        return
                    }
                    if let match {
                        matchesByIndex[index] = match
                    } else if let provisionalMatch = matchesByIndex[index], provisionalMatch.isResolved == false {
                        matchesByIndex[index] = GitHubReferenceMatch.unresolved(from: provisionalMatch)
                    } else {
                        continue
                    }
                    onProgress?(Self.orderedReferenceMatches(matchesByIndex))
                }
            }

            if let resolutionID, self.gitHubReferenceResolutionID != resolutionID {
                return []
            }
        }

        return Self.orderedReferenceMatches(matchesByIndex)
    }

    private nonisolated static func orderedReferenceMatches(_ matchesByIndex: [Int: GitHubReferenceMatch]) -> [GitHubReferenceMatch] {
        var seen: Set<URL> = []
        return matchesByIndex.keys.sorted().compactMap { matchesByIndex[$0] }.filter {
            seen.insert($0.url).inserted
        }
    }

    private nonisolated func provisionalReferenceMatches(from sourceText: String) -> [GitHubReferenceQuery: GitHubReferenceMatch] {
        let now = Date()
        var matches: [GitHubReferenceQuery: GitHubReferenceMatch] = [:]
        for reference in GitHubReferenceTranslator.urlReferences(in: sourceText) {
            guard let match = GitHubReferenceMatch.provisional(
                query: reference.query,
                url: reference.url,
                kind: reference.kind,
                now: now
            ) else { continue }

            matches[reference.query] = match
        }
        return matches
    }

    private func queries(
        _ queries: [GitHubReferenceQuery],
        applyingLocalRepositoryContextFrom text: String
    ) async -> [GitHubReferenceQuery] {
        guard queries.contains(where: { $0.repositoryFullName == nil }) else { return queries }

        let repositoryFullName = await GitHubReferenceLocalContext.repositoryFullName(
            in: text,
            localRepoIndex: self.session.localRepoIndex
        )
        guard let repositoryFullName else {
            return await GitHubReferenceLocalContext.queries(
                queries,
                applyingLocalRepositoryContextFrom: self.session.localRepoIndex
            )
        }

        return GitHubReferenceTranslator.queries(
            from: text,
            minimumBareDigits: AppLimits.GitHubReferenceMonitor.minimumBareDigits,
            repositoryContextOverride: repositoryFullName
        )
    }

    private nonisolated static func resolveGitHubReferenceMatch(
        query: GitHubReferenceQuery,
        repositories: [Repository],
        github: GitHubClient
    ) async -> GitHubReferenceMatch? {
        let candidateRepositories = if let repositoryFullName = query.repositoryFullName {
            repositories.filter { $0.fullName.caseInsensitiveCompare(repositoryFullName) == .orderedSame }
        } else if let repositoryName = query.repositoryName {
            repositories.filter { $0.name.caseInsensitiveCompare(repositoryName) == .orderedSame }
        } else {
            repositories
        }
        guard candidateRepositories.isEmpty == false else {
            return await github.liveReferenceMatch(query: query)
        }

        let cachedMatches = await github.cachedReferenceMatches(
            query: query,
            repositories: candidateRepositories,
            limit: AppLimits.GitHubReferenceMonitor.cacheLookupLimit
        )
        if let match = GitHubReferenceMatch.newestCreated(in: cachedMatches) {
            return match
        }

        let liveMatch = await github.liveReferenceMatch(
            query: query,
            repositories: Array(candidateRepositories.prefix(AppLimits.GitHubReferenceMonitor.liveLookupLimit))
        )
        if let liveMatch {
            return liveMatch
        }

        guard query.repositoryFullName == nil else { return nil }

        return await github.liveReferenceMatch(query: query)
    }

    func githubReferenceCandidateRepositories() -> [Repository] {
        let sources = [
            self.session.accessibleRepositories,
            self.session.repositories,
            self.session.menuSnapshot?.repositories ?? []
        ]
        let repositories = sources.first(where: { $0.isEmpty == false }) ?? []
        var seen: Set<String> = []
        return repositories.filter { repo in
            guard repo.viewerCanRead else { return false }

            return seen.insert(repo.fullName.lowercased()).inserted
        }
    }

    private func setGitHubReferenceMatch(_ match: GitHubReferenceMatch?) {
        self.setGitHubReferenceMatches(match.map { [$0] } ?? [])
    }

    private func setGitHubReferenceMatches(_ matches: [GitHubReferenceMatch]) {
        let primaryMatch = GitHubReferenceMatch.newestCreated(in: matches)
        guard self.session.gitHubReferenceMatches != matches || self.session.gitHubReferenceMatch != primaryMatch else { return }

        self.session.gitHubReferenceMatches = matches
        self.session.gitHubReferenceMatch = primaryMatch
        NotificationCenter.default.post(name: .gitHubReferenceMatchDidChange, object: nil)
    }
}
