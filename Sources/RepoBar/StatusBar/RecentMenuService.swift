import Foundation
import RepoBarCore

@MainActor
final class RecentMenuService {
    let listLimit: Int
    let previewLimit: Int
    let cacheTTL: TimeInterval
    let loadTimeout: TimeInterval

    private let github: @MainActor () -> GitHubClient
    private let cacheNamespace: @MainActor () -> String
    private let recentIssuesCache = RecentListCache<[RepoIssueSummary]>()
    private let recentPullRequestsCache = RecentListCache<[RepoPullRequestSummary]>()
    private let recentReleasesCache = RecentListCache<[RepoReleaseSummary]>()
    private let recentWorkflowRunsCache = RecentListCache<[RepoWorkflowRunSummary]>()
    private let recentCommitsCache = RecentListCache<RepoCommitList>()
    private let recentDiscussionsCache = RecentListCache<[RepoDiscussionSummary]>()
    private let recentTagsCache = RecentListCache<[RepoTagSummary]>()
    private let recentBranchesCache = RecentListCache<[RepoBranchSummary]>()
    private let recentContributorsCache = RecentListCache<[RepoContributorSummary]>()

    init(
        github: @escaping @MainActor () -> GitHubClient,
        cacheNamespace: @escaping @MainActor () -> String,
        listLimit: Int = AppLimits.RecentLists.limit,
        previewLimit: Int = AppLimits.RecentLists.previewLimit,
        cacheTTL: TimeInterval = AppLimits.RecentLists.cacheTTL,
        loadTimeout: TimeInterval = AppLimits.RecentLists.loadTimeout
    ) {
        self.github = github
        self.cacheNamespace = cacheNamespace
        self.listLimit = listLimit
        self.previewLimit = previewLimit
        self.cacheTTL = cacheTTL
        self.loadTimeout = loadTimeout
    }

    convenience init(appState: AppState) {
        self.init(
            github: { [appState] in appState.github },
            cacheNamespace: { [appState] in appState.session.settings.resolvedActiveAccount()?.id ?? "legacy" }
        )
    }

    func cacheKey(fullName: String) -> String {
        "\(self.cacheNamespace())|\(fullName)"
    }

    func cacheContext(fullName: String) -> (key: String, github: GitHubClient) {
        (self.cacheKey(fullName: fullName), self.github())
    }

    func descriptor(for kind: RepoRecentMenuKind) -> RecentMenuDescriptor? {
        self.descriptors()[kind]
    }

    func descriptors() -> [RepoRecentMenuKind: RecentMenuDescriptor] {
        let commitDescriptor = self.commitDescriptor()

        let descriptors: [RecentMenuDescriptor] = [
            commitDescriptor,
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .issues,
                headerTitle: "Open Issues",
                headerIcon: "exclamationmark.circle",
                emptyTitle: "No open issues",
                cache: self.recentIssuesCache,
                wrap: RecentMenuItems.issues,
                unwrap: { boxed in
                    if case let .issues(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentIssues(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .pullRequests,
                headerTitle: "Open Pull Requests",
                headerIcon: "arrow.triangle.branch",
                emptyTitle: "No open pull requests",
                cache: self.recentPullRequestsCache,
                wrap: RecentMenuItems.pullRequests,
                unwrap: { boxed in
                    if case let .pullRequests(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentPullRequests(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .releases,
                headerTitle: "Open Releases",
                headerIcon: "tag",
                emptyTitle: "No releases",
                cache: self.recentReleasesCache,
                wrap: RecentMenuItems.releases,
                unwrap: { boxed in
                    if case let .releases(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentReleases(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .ciRuns,
                headerTitle: "Open Actions",
                headerIcon: "bolt",
                emptyTitle: "No CI runs",
                cache: self.recentWorkflowRunsCache,
                wrap: RecentMenuItems.workflowRuns,
                unwrap: { boxed in
                    if case let .workflowRuns(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentWorkflowRuns(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .discussions,
                headerTitle: "Open Discussions",
                headerIcon: "bubble.left.and.bubble.right",
                emptyTitle: "No discussions",
                cache: self.recentDiscussionsCache,
                wrap: RecentMenuItems.discussions,
                unwrap: { boxed in
                    if case let .discussions(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentDiscussions(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .tags,
                headerTitle: "Open Tags",
                headerIcon: "tag",
                emptyTitle: "No tags",
                cache: self.recentTagsCache,
                wrap: RecentMenuItems.tags,
                unwrap: { boxed in
                    if case let .tags(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentTags(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .branches,
                headerTitle: "Open Branches",
                headerIcon: "point.topleft.down.curvedto.point.bottomright.up",
                emptyTitle: "No branches",
                cache: self.recentBranchesCache,
                wrap: RecentMenuItems.branches,
                unwrap: { boxed in
                    if case let .branches(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.recentBranches(owner: owner, name: name, limit: limit)
                }
            )),
            self.makeDescriptor(RecentMenuDescriptorConfig(
                kind: .contributors,
                headerTitle: "Open Contributors",
                headerIcon: "person.2",
                emptyTitle: "No contributors",
                cache: self.recentContributorsCache,
                wrap: RecentMenuItems.contributors,
                unwrap: { boxed in
                    if case let .contributors(items) = boxed {
                        return items
                    }
                    return nil
                },
                fetch: { github, owner, name, limit in
                    try await github.topContributors(owner: owner, name: name, limit: limit)
                }
            ))
        ]

        return Dictionary(uniqueKeysWithValues: descriptors.map { ($0.kind, $0) })
    }

    func cachedRecentCommitCount(fullName: String) -> Int? {
        let key = self.cacheKey(fullName: fullName)
        return self.recentCommitsCache.stale(for: key).map { $0.totalCount ?? $0.items.count }
    }

    func cachedCommits(fullName: String, now: Date = Date()) -> [RepoCommitSummary]? {
        let key = self.cacheKey(fullName: fullName)
        return self.recentCommitsCache.cached(for: key, now: now, maxAge: self.cacheTTL)?.items
            ?? self.recentCommitsCache.stale(for: key)?.items
    }

    func cachedCommitDigest(fullName: String) -> Int? {
        let now = Date()
        guard let commits = self.cachedCommits(fullName: fullName, now: now), commits.isEmpty == false else { return nil }

        var hasher = Hasher()
        for commit in commits {
            hasher.combine(commit.sha)
            hasher.combine(commit.authoredAt.timeIntervalSinceReferenceDate)
        }
        return hasher.finalize()
    }

    private func commitDescriptor() -> RecentMenuDescriptor {
        RecentMenuDescriptor(
            kind: .commits,
            headerTitle: "Open Commits",
            headerIcon: "arrow.turn.down.right",
            emptyTitle: "No commits",
            cached: { key, now, ttl in
                self.recentCommitsCache.cached(for: key, now: now, maxAge: ttl).map { RecentMenuItems.commits($0.items) }
            },
            stale: { key in
                self.recentCommitsCache.stale(for: key).map { RecentMenuItems.commits($0.items) }
            },
            needsRefresh: { key, now, ttl in
                self.recentCommitsCache.needsRefresh(for: key, now: now, maxAge: ttl)
            },
            load: { key, owner, name, limit, github in
                let list = try await self.recentCommitsCache.load(for: key, timeout: self.loadTimeout) {
                    try await github.recentCommits(owner: owner, name: name, limit: limit)
                }
                self.recentCommitsCache.store(list, for: key, fetchedAt: Date())
                return RecentMenuItems.commits(list.items)
            }
        )
    }

    private func makeDescriptor(
        _ config: RecentMenuDescriptorConfig<some Sendable>
    ) -> RecentMenuDescriptor {
        let fetch = config.fetch

        return RecentMenuDescriptor(
            kind: config.kind,
            headerTitle: config.headerTitle,
            headerIcon: config.headerIcon,
            emptyTitle: config.emptyTitle,
            cached: { key, now, ttl in
                config.cache.cached(for: key, now: now, maxAge: ttl).map(config.wrap)
            },
            stale: { key in
                config.cache.stale(for: key).map(config.wrap)
            },
            needsRefresh: { key, now, ttl in
                config.cache.needsRefresh(for: key, now: now, maxAge: ttl)
            },
            load: { key, owner, name, limit, github in
                let items = try await config.cache.load(for: key, timeout: self.loadTimeout) {
                    try await fetch(github, owner, name, limit)
                }
                _ = config.cache.store(items, for: key, fetchedAt: Date())
                return config.wrap(items)
            }
        )
    }
}

struct RecentMenuDescriptorConfig<Item: Sendable> {
    let kind: RepoRecentMenuKind
    let headerTitle: String
    let headerIcon: String?
    let emptyTitle: String
    let cache: RecentListCache<[Item]>
    let wrap: ([Item]) -> RecentMenuItems
    let unwrap: (RecentMenuItems) -> [Item]?
    let fetch: @Sendable (GitHubClient, String, String, Int) async throws -> [Item]
}

struct RecentMenuDescriptor {
    let kind: RepoRecentMenuKind
    let headerTitle: String
    let headerIcon: String?
    let emptyTitle: String
    let cached: (String, Date, TimeInterval) -> RecentMenuItems?
    let stale: (String) -> RecentMenuItems?
    let needsRefresh: (String, Date, TimeInterval) -> Bool
    let load: @MainActor (String, String, String, Int, GitHubClient) async throws -> RecentMenuItems
}

enum RecentMenuItems {
    case commits([RepoCommitSummary])
    case issues([RepoIssueSummary])
    case pullRequests([RepoPullRequestSummary])
    case releases([RepoReleaseSummary])
    case workflowRuns([RepoWorkflowRunSummary])
    case discussions([RepoDiscussionSummary])
    case tags([RepoTagSummary])
    case branches([RepoBranchSummary])
    case contributors([RepoContributorSummary])

    var isEmpty: Bool {
        switch self {
        case let .commits(items): items.isEmpty
        case let .issues(items): items.isEmpty
        case let .pullRequests(items): items.isEmpty
        case let .releases(items): items.isEmpty
        case let .workflowRuns(items): items.isEmpty
        case let .discussions(items): items.isEmpty
        case let .tags(items): items.isEmpty
        case let .branches(items): items.isEmpty
        case let .contributors(items): items.isEmpty
        }
    }

    var count: Int {
        switch self {
        case let .commits(items): items.count
        case let .issues(items): items.count
        case let .pullRequests(items): items.count
        case let .releases(items): items.count
        case let .workflowRuns(items): items.count
        case let .discussions(items): items.count
        case let .tags(items): items.count
        case let .branches(items): items.count
        case let .contributors(items): items.count
        }
    }
}
