import Foundation

public struct GitHubReferenceParsedURL: Sendable, Hashable {
    public let query: GitHubReferenceQuery
    public let url: URL
    public let kind: GitHubReferenceKind
}

struct GitHubReferenceIssueNumberTokenMatch {
    let query: GitHubReferenceQuery
    let tokenIndex: Int
}

struct IssueNumberToken: Hashable {
    let number: Int
    let tokenIndex: Int
}

extension GitHubReferenceTranslator {
    static func urlQuery(from rawText: String) -> GitHubReferenceQuery? {
        self.urlReference(from: rawText)?.query
    }

    public static func urlReferences(in rawText: String) -> [GitHubReferenceParsedURL] {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reference = self.urlReference(from: text) {
            return [reference]
        }
        guard text.count <= Self.maxScannedTextLength else { return [] }

        var references: [GitHubReferenceParsedURL] = []
        var seen: Set<String> = []
        for token in self.referenceTokens(in: text) {
            guard let reference = self.urlReference(from: token),
                  seen.insert(self.dedupeKey(for: reference.query)).inserted
            else { continue }

            references.append(reference)
        }
        return references
    }

    private static func urlReference(from rawText: String) -> GitHubReferenceParsedURL? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let host = components.host?.lowercased() ?? ""
        guard host == "github.com" || host.hasSuffix(".github.com") else { return nil }

        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        guard pathParts.count >= 4 else { return nil }

        let repositoryFullName = "\(pathParts[0])/\(pathParts[1])"
        switch pathParts[2].lowercased() {
        case "issues":
            guard let number = Int(pathParts[3]) else { return nil }

            return GitHubReferenceParsedURL(
                query: .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number),
                url: url,
                kind: .issue
            )
        case "pull":
            if let hash = self.commitHash(in: pathParts.dropFirst(4)) {
                return GitHubReferenceParsedURL(
                    query: .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash),
                    url: url,
                    kind: .commit
                )
            }
            guard let number = Int(pathParts[3]) else { return nil }

            return GitHubReferenceParsedURL(
                query: .repositoryIssueNumber(repositoryFullName: repositoryFullName, number: number),
                url: url,
                kind: .pullRequest
            )
        case "commit", "commits":
            let hash = pathParts[3].lowercased()
            guard self.isCommitHash(hash, allowNumericOnly: true) else { return nil }

            return GitHubReferenceParsedURL(
                query: .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash),
                url: url,
                kind: .commit
            )
        case "actions":
            guard pathParts.count >= 5,
                  pathParts[3].lowercased() == "runs",
                  let runID = Int64(pathParts[4])
            else { return nil }

            return GitHubReferenceParsedURL(
                query: .repositoryWorkflowRun(repositoryFullName: repositoryFullName, runID: runID),
                url: url,
                kind: .workflowRun
            )
        default:
            guard let hash = self.commitHash(in: pathParts.dropFirst(2)) else { return nil }

            return GitHubReferenceParsedURL(
                query: .repositoryCommitHash(repositoryFullName: repositoryFullName, hash: hash),
                url: url,
                kind: .commit
            )
        }
    }

    static func commitHash(in pathParts: some Sequence<String>) -> String? {
        pathParts
            .map { $0.lowercased() }
            .first { self.isCommitHash($0, allowNumericOnly: true) }
    }
}
