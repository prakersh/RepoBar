import Algorithms
import Foundation
import RepoBarCore

extension AppState {
    func searchIssueReferences(
        matching text: String,
        repositoryFullName: String?,
        includeIssues: Bool,
        includePullRequests: Bool,
        limit: Int = AppLimits.IssueNavigator.searchLimit
    ) async throws -> [GitHubReferenceMatch] {
        if let repositoryFullName {
            return try await self.github.searchIssueReferences(
                matching: text,
                repositoryFullName: repositoryFullName,
                includeIssues: includeIssues,
                includePullRequests: includePullRequests,
                limit: limit
            )
        }

        let repositories = Self.issueNavigatorSearchRepositories(from: self.githubReferenceCandidateRepositories())
        guard repositories.isEmpty == false else {
            if self.session.hasLoadedRepositories {
                return []
            }

            throw IssueNavigatorSearchError.repositoryInventoryLoading
        }

        let github = self.github
        let perRepositoryLimit = AppLimits.IssueNavigator.perRepositorySearchLimit
        var matches: [GitHubReferenceMatch] = []
        var firstError: Error?
        var failedSearches = 0

        for chunk in repositories.chunks(ofCount: AppLimits.IssueNavigator.repositorySearchConcurrencyLimit) {
            await withTaskGroup(of: Result<[GitHubReferenceMatch], Error>.self) { group in
                for repo in chunk {
                    group.addTask {
                        do {
                            let matches = try await github.searchIssueReferences(
                                matching: text,
                                repositoryFullName: repo.fullName,
                                includeIssues: includeIssues,
                                includePullRequests: includePullRequests,
                                limit: perRepositoryLimit
                            )
                            return .success(matches)
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                for await result in group {
                    switch result {
                    case let .success(found):
                        matches.append(contentsOf: found)
                    case let .failure(error):
                        failedSearches += 1
                        firstError = firstError ?? error
                    }
                }
            }
        }

        if Self.shouldSurfaceIssueSearchFailure(
            searchedRepositories: repositories.count,
            failedSearches: failedSearches,
            matchCount: matches.count
        ), let firstError {
            throw firstError
        }

        return Array(Self.dedupedGitHubReferenceMatches(matches).prefix(limit))
    }

    static func shouldSurfaceIssueSearchFailure(
        searchedRepositories: Int,
        failedSearches: Int,
        matchCount: Int
    ) -> Bool {
        matchCount == 0 && searchedRepositories > 0 && failedSearches >= searchedRepositories
    }

    static func issueNavigatorSearchRepositories(from repositories: [Repository]) -> [Repository] {
        let sorted = repositories
            .filter { $0.viewerCanRead && !$0.isArchived }
            .sorted {
                let lhsDate = $0.latestActivity?.date ?? $0.pushedAt ?? .distantPast
                let rhsDate = $1.latestActivity?.date ?? $1.pushedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }

        return Array(sorted.prefix(AppLimits.IssueNavigator.maxRepositorySearchFanout))
    }

    func recentIssueReferences(
        repositoryFullName: String?,
        includeIssues: Bool,
        includePullRequests: Bool,
        limit: Int = AppLimits.IssueNavigator.searchLimit
    ) async throws -> [GitHubReferenceMatch] {
        if let repositoryFullName {
            let matches = try await self.recentRepositoryIssueReferences(
                repositoryFullName: repositoryFullName,
                includeIssues: includeIssues,
                includePullRequests: includePullRequests,
                limit: limit
            )
            return Array(Self.dedupedGitHubReferenceMatches(matches).prefix(limit))
        }

        async let allResult = Self.capture {
            try await self.github.recentIssueReferences(
                filter: "all",
                includeIssues: includeIssues,
                includePullRequests: includePullRequests,
                limit: limit
            )
        }
        async let subscribedResult = Self.capture {
            try await self.github.recentIssueReferences(
                filter: "subscribed",
                includeIssues: includeIssues,
                includePullRequests: includePullRequests,
                limit: limit
            )
        }
        async let repositoryMatches = self.recentAccessibleRepositoryIssueReferences(
            includeIssues: includeIssues,
            includePullRequests: includePullRequests
        )

        let (all, subscribed, accessible) = await (allResult, subscribedResult, repositoryMatches)
        var matches = accessible
        var firstError: Error?
        switch all {
        case let .success(found):
            matches.append(contentsOf: found)
        case let .failure(error):
            firstError = firstError ?? error
        }
        switch subscribed {
        case let .success(found):
            matches.append(contentsOf: found)
        case let .failure(error):
            firstError = firstError ?? error
        }

        if matches.isEmpty, let firstError {
            throw firstError
        }

        return Array(Self.dedupedGitHubReferenceMatches(matches).prefix(limit))
    }

    func gitHubReferenceRepositories() -> [Repository] {
        self.githubReferenceCandidateRepositories()
    }

    private nonisolated static func capture<T>(_ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do {
            return try await .success(operation())
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func dedupedGitHubReferenceMatches(_ matches: [GitHubReferenceMatch]) -> [GitHubReferenceMatch] {
        var seen: Set<URL> = []
        return matches
            .filter { seen.insert($0.url).inserted }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
    }

    static func issueNavigatorRecentRepositories(
        from repositories: [Repository],
        includeIssues: Bool,
        includePullRequests: Bool
    ) -> [Repository] {
        let sorted = repositories
            .filter { repo in
                guard repo.viewerCanRead, !repo.isArchived else { return false }

                return (includeIssues && repo.openIssues > 0) || (includePullRequests && repo.openPulls > 0)
            }
            .sorted {
                let lhs = $0.latestActivity?.date ?? $0.pushedAt ?? .distantPast
                let rhs = $1.latestActivity?.date ?? $1.pushedAt ?? .distantPast
                if lhs != rhs {
                    return lhs > rhs
                }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }

        return Array(sorted.prefix(AppLimits.IssueNavigator.recentRepositoryLimit))
    }

    private func recentAccessibleRepositoryIssueReferences(
        includeIssues: Bool,
        includePullRequests: Bool
    ) async -> [GitHubReferenceMatch] {
        let repositories = Self.issueNavigatorRecentRepositories(
            from: self.githubReferenceCandidateRepositories(),
            includeIssues: includeIssues,
            includePullRequests: includePullRequests
        )

        var matches: [GitHubReferenceMatch] = []
        let github = self.github

        for chunk in repositories.chunks(ofCount: AppLimits.IssueNavigator.repositorySearchConcurrencyLimit) {
            await withTaskGroup(of: [GitHubReferenceMatch].self) { group in
                for repo in chunk {
                    group.addTask {
                        do {
                            return try await Self.recentRepositoryIssueReferences(
                                github: github,
                                repositoryFullName: repo.fullName,
                                includeIssues: includeIssues,
                                includePullRequests: includePullRequests,
                                limit: AppLimits.IssueNavigator.perRepositoryRecentLimit
                            )
                        } catch {
                            return []
                        }
                    }
                }

                for await found in group {
                    matches.append(contentsOf: found)
                }
            }
        }

        return matches
    }

    private func recentRepositoryIssueReferences(
        repositoryFullName: String,
        includeIssues: Bool,
        includePullRequests: Bool,
        limit: Int
    ) async throws -> [GitHubReferenceMatch] {
        try await Self.recentRepositoryIssueReferences(
            github: self.github,
            repositoryFullName: repositoryFullName,
            includeIssues: includeIssues,
            includePullRequests: includePullRequests,
            limit: limit
        )
    }

    private nonisolated static func recentRepositoryIssueReferences(
        github: GitHubClient,
        repositoryFullName: String,
        includeIssues: Bool,
        includePullRequests: Bool,
        limit: Int
    ) async throws -> [GitHubReferenceMatch] {
        guard let parts = repositoryParts(from: repositoryFullName) else { return [] }

        async let issuesItems: [RepoIssueSummary] = includeIssues
            ? github.recentIssues(owner: parts.owner, name: parts.name, limit: limit)
            : []
        async let pullsItems: [RepoPullRequestSummary] = includePullRequests
            ? github.recentPullRequests(owner: parts.owner, name: parts.name, limit: limit)
            : []

        let (issues, pulls) = try await (issuesItems, pullsItems)
        var matches: [GitHubReferenceMatch] = []
        matches.append(contentsOf: issues.map {
            GitHubReferenceMatch(
                query: .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: $0.number),
                title: $0.title,
                url: $0.url,
                repositoryFullName: repositoryFullName,
                kind: .issue,
                state: .open,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                authorLogin: $0.authorLogin
            )
        })
        matches.append(contentsOf: pulls.map {
            GitHubReferenceMatch(
                query: .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: $0.number),
                title: $0.title,
                url: $0.url,
                repositoryFullName: repositoryFullName,
                kind: .pullRequest,
                state: .open,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                bodyPreview: $0.bodyPreview,
                authorLogin: $0.authorLogin
            )
        })

        return Self.dedupedGitHubReferenceMatches(matches)
    }

    private nonisolated static func repositoryParts(from fullName: String) -> (owner: String, name: String)? {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false else { return nil }

        return (parts[0], parts[1])
    }
}

private enum IssueNavigatorSearchError: LocalizedError {
    case repositoryInventoryLoading

    var errorDescription: String? {
        switch self {
        case .repositoryInventoryLoading:
            "Repository list is still loading. Try again in a moment."
        }
    }
}
