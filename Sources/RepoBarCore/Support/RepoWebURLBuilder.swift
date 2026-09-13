import Foundation

public struct RepoWebURLBuilder: Sendable {
    public let host: URL

    public init(host: URL) {
        self.host = host
    }

    public func repoURL(fullName: String) -> URL? {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }

        return self.repoPathURL(components: [String(parts[0]), String(parts[1])])
    }

    public func repoPathURL(fullName: String, path: String) -> URL? {
        let components = path.split(separator: "/").map(String.init)
        return self.repoPathURL(fullName: fullName, components: components)
    }

    public func issuesURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["issues"])
    }

    public func pullsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["pulls"])
    }

    public func actionsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["actions"])
    }

    public func discussionsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["discussions"])
    }

    public func tagsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["tags"])
    }

    public func branchesURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["branches"])
    }

    public func contributorsURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["graphs", "contributors"])
    }

    public func releasesURL(fullName: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["releases"])
    }

    public func tagURL(fullName: String, tag: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["tree"] + tag.split(separator: "/").map(String.init))
    }

    public func branchURL(fullName: String, branch: String) -> URL? {
        self.repoPathURL(fullName: fullName, components: ["tree"] + branch.split(separator: "/").map(String.init))
    }

    private func repoPathURL(fullName: String, components: [String]) -> URL? {
        guard var url = self.repoURL(fullName: fullName) else { return nil }

        for component in components where component.isEmpty == false {
            url.appendPathComponent(component)
        }
        return url
    }

    private func repoPathURL(components: [String]) -> URL {
        var url = self.host
        for component in components where component.isEmpty == false {
            url.appendPathComponent(component)
        }
        return url
    }
}
