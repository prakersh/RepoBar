import Commander
import Foundation
import RepoBarCore

@MainActor
struct ReposCommand: CommanderRunnableCommand {
    nonisolated static let commandName = "repos"

    @Option(name: .customLong("limit"), help: "Max repositories to fetch (default: all accessible)")
    var limit: Int?

    @Option(name: .customLong("age"), help: "Max age in days for repo activity (default: 365)")
    var age: Int = RepositoryQueryDefaults.defaultAgeDays

    @Flag(names: [.customLong("release")], help: "Include latest release tag and date")
    var includeRelease: Bool = false

    @Flag(names: [.customLong("event")], help: "Show activity event column (hidden by default)")
    var includeEvent: Bool = false

    @Flag(names: [.customLong("forks"), .customLong("include-forks")], help: "Include forked repositories (hidden by default)")
    var includeForks: Bool = false

    @Flag(names: [.customLong("archived"), .customLong("include-archived")], help: "Include archived repositories (hidden by default)")
    var includeArchived: Bool = false

    @Option(name: .customLong("scope"), help: "Repository scope (values: all, pinned, hidden)")
    var scope: RepoScopeSelection?

    @Option(name: .customLong("filter"), help: "Filter repositories (values: all, work, issues, prs)")
    var filter: RepoFilterSelection?

    @Flag(names: [.customLong("pinned-only")], help: "Only list pinned repositories from settings")
    var pinnedOnly: Bool = false

    @Option(name: .customLong("only-with"), help: "Only show repos that have issues and/or PRs (values: work, issues, prs)")
    var onlyWith: OnlyWithSelection?

    @Option(name: .customLong("owner"), help: "Only show repositories owned by this login (repeatable, comma-separated)")
    var owner: String?

    @Flag(names: [.customLong("mine")], help: "Only show repositories owned by the authenticated user")
    var mine: Bool = false

    @Option(name: .customLong("sort"), help: "Sort by activity, issues, prs, stars, repo, or event")
    var sort: RepositorySortKey = .activity

    @OptionGroup
    var output: OutputOptions

    private var ownerFilter: RepoOwnerFilter?

    static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: commandName,
            abstract: "List repositories by activity, issues, PRs, and stars"
        )
    }

    mutating func bind(_ values: ParsedValues) throws {
        self.output.bind(values)
        self.limit = try values.decodeOption("limit")
        self.age = try values.decodeOption("age") ?? 365
        self.sort = try values.decodeOption("sort") ?? .activity
        self.includeRelease = values.flag("includeRelease")
        self.includeEvent = values.flag("includeEvent")
        self.includeForks = values.flag("includeForks")
        self.includeArchived = values.flag("includeArchived")
        self.scope = try values.decodeOption("scope")
        self.filter = try values.decodeOption("filter")
        self.pinnedOnly = values.flag("pinnedOnly")
        self.onlyWith = try values.decodeOption("onlyWith")
        let rawOwners = values.optionValues("owner")
        self.ownerFilter = RepoOwnerFilter.parse(rawOwners)
        self.mine = values.flag("mine")
        if self.ownerFilter == nil, rawOwners.isEmpty == false {
            throw ValidationError("--owner must include at least one login")
        }
    }

    mutating func run() async throws {
        if let limit, limit <= 0 {
            throw ValidationError("--limit must be greater than 0")
        }
        if self.age <= 0 {
            throw ValidationError("--age must be greater than 0")
        }
        if self.pinnedOnly, let scope, scope != .pinned {
            throw ValidationError("--pinned-only cannot be combined with --scope \(scope.rawValue)")
        }
        if self.filter != nil, self.onlyWith != nil {
            throw ValidationError("--filter cannot be combined with --only-with")
        }

        if self.output.jsonOutput == false, self.output.useColor {
            print("RepoBar CLI")
        }

        let context = try await makeAuthenticatedClient()
        let settings = context.settings
        let client = context.client

        var ownerFilter = self.ownerFilter
        if self.mine {
            let identity = try await client.currentUser()
            ownerFilter = (ownerFilter ?? RepoOwnerFilter(owners: []))
                .inserting(owner: identity.username)
        }

        let now = Date()
        let baseHost = context.host
        let effectiveScope = self.scope ?? (self.pinnedOnly ? .pinned : .all)
        let effectiveOnlyWith = self.filter?.onlyWith ?? self.onlyWith?.filter ?? .none
        let hidden = Set(settings.repoList.hiddenRepositories)
        let pinned = settings.repoList.pinnedRepositories.filter { !hidden.contains($0) }
        let ageCutoff = RepositoryQueryDefaults.ageCutoff(
            now: now,
            scope: effectiveScope.repositoryScope,
            ageDays: self.age
        )
        let query = RepositoryQuery(
            scope: effectiveScope.repositoryScope,
            onlyWith: effectiveOnlyWith,
            includeForks: self.includeForks,
            includeArchived: self.includeArchived,
            sortKey: self.sort,
            limit: self.limit,
            ageCutoff: ageCutoff,
            pinned: pinned,
            hidden: hidden,
            pinPriority: false
        )

        switch effectiveScope {
        case .pinned:
            guard pinned.isEmpty == false else {
                if self.output.jsonOutput {
                    try renderJSON([], baseHost: baseHost)
                } else {
                    print("No pinned repositories to show.")
                }
                return
            }

            let repos = try await self.fetchNamedRepositories(pinned, client: client)
            let ownerFiltered = ownerFilter?.applying(to: repos) ?? repos
            let filtered = RepositoryPipeline.apply(ownerFiltered, query: query)
            try await self.renderResults(
                repos: filtered,
                baseHost: baseHost,
                now: now,
                client: client
            )
            return
        case .hidden:
            let hiddenList = settings.repoList.hiddenRepositories
            guard hiddenList.isEmpty == false else {
                if self.output.jsonOutput {
                    try renderJSON([], baseHost: baseHost)
                } else {
                    print("No hidden repositories to show.")
                }
                return
            }

            let repos = try await self.fetchNamedRepositories(hiddenList, client: client)
            let ownerFiltered = ownerFilter?.applying(to: repos) ?? repos
            let filtered = RepositoryPipeline.apply(ownerFiltered, query: query)
            try await self.renderResults(
                repos: filtered,
                baseHost: baseHost,
                now: now,
                client: client
            )
            return
        case .all:
            break
        }

        let fetchLimit = Self.activityFetchLimit(requestedLimit: limit, ownerFilter: ownerFilter)
        let repos = try await client.activityRepositories(limit: fetchLimit)
        let ownerFiltered = ownerFilter?.applying(to: repos) ?? repos
        let filteredRepos = RepositoryPipeline.apply(ownerFiltered, query: query)
        try await self.renderResults(
            repos: filteredRepos,
            baseHost: baseHost,
            now: now,
            client: client
        )
    }

    private func renderResults(
        repos: [Repository],
        baseHost: URL,
        now: Date,
        client: GitHubClient
    ) async throws {
        var output = repos
        if self.includeRelease {
            output = try await self.attachLatestReleases(to: output, client: client)
        }
        let rows = prepareRows(repos: output, now: now)

        if self.output.jsonOutput {
            try renderJSON(rows, baseHost: baseHost)
        } else {
            let context = RepoTableContext(
                useColor: self.output.useColor,
                includeURL: self.output.plain == false,
                includeRelease: self.includeRelease,
                includeEvent: self.includeEvent,
                baseHost: baseHost,
                now: now
            )
            renderTable(rows, context: context)
        }
    }

    private func attachLatestReleases(to repos: [Repository], client: GitHubClient) async throws -> [Repository] {
        try await withThrowingTaskGroup(of: (Int, Repository).self) { group in
            for (index, repo) in repos.enumerated() {
                group.addTask {
                    var updated = repo
                    do {
                        updated.latestRelease = try await client.latestRelease(owner: repo.owner, name: repo.name)
                    } catch {
                        if updated.error == nil {
                            updated.error = "Release: \(error.userFacingMessage)"
                        }
                        if let gh = error as? GitHubAPIError {
                            updated.rateLimitedUntil = maxDate(updated.rateLimitedUntil, gh.rateLimitedUntil ?? gh.retryAfter)
                        }
                    }
                    return (index, updated)
                }
            }

            var results: [Repository?] = Array(repeating: nil, count: repos.count)
            for try await (index, repo) in group {
                results[index] = repo
            }
            return results.compactMap(\.self)
        }
    }

    private struct RepoLookup {
        let index: Int
        let repo: RepoIdentifier
    }

    private func fetchNamedRepositories(_ names: [String], client: GitHubClient) async throws -> [Repository] {
        let targets: [RepoLookup] = names.enumerated().compactMap { index, name in
            guard let repo = try? parseRepoName(name) else { return nil }

            return RepoLookup(index: index, repo: repo)
        }
        return try await withThrowingTaskGroup(of: (Int, Repository).self) { group in
            for target in targets {
                group.addTask {
                    let repo = try await client.fullRepository(owner: target.repo.owner, name: target.repo.name)
                    return (target.index, repo.withOrder(target.index))
                }
            }

            var results: [Repository?] = Array(repeating: nil, count: names.count)
            for try await (index, repo) in group {
                results[index] = repo
            }
            return results.compactMap(\.self)
        }
    }

    nonisolated static func activityFetchLimit(requestedLimit: Int?, ownerFilter: RepoOwnerFilter?) -> Int? {
        ownerFilter == nil ? requestedLimit : nil
    }
}

private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case (nil, nil):
        nil
    case (nil, let rhs?):
        rhs
    case (let lhs?, nil):
        lhs
    case let (lhs?, rhs?):
        max(lhs, rhs)
    }
}
