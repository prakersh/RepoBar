import RepoBarCore
@testable import RepoBariOS
import SwiftUI
import XCTest

final class IncomingReferenceURLTests: XCTestCase {
    func testLocalGitProbeIsUnavailableOnIOS() {
        XCTAssertNil(GitHubReferenceLocalContext.gitHubRepositoryFullName(at: "/tmp/synthetic-repository"))
    }

    func testWorkflowRunDisplay() throws {
        let match = try GitHubReferenceMatch(
            query: .repositoryWorkflowRun(repositoryFullName: "acme/widget", runID: 42),
            title: "Fixture workflow",
            url: XCTUnwrap(URL(string: "https://github.com/acme/widget/actions/runs/42")),
            repositoryFullName: "acme/widget",
            kind: .workflowRun,
            state: nil,
            createdAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(match.symbolName, "play.circle")
        XCTAssertEqual(match.tint, .secondary)
    }

    func testParsesResolveText() throws {
        let url = try XCTUnwrap(IncomingReferenceURL.makeURL(text: " openclaw/openclaw#123 "))

        XCTAssertEqual(IncomingReferenceURL.text(from: url), "openclaw/openclaw#123")
    }

    func testAcceptsURLQueryAlias() throws {
        let url = try XCTUnwrap(URL(string: "repobar://resolve?url=https%3A%2F%2Fgithub.com%2Fopenclaw%2Fopenclaw%2Fissues%2F76162"))

        XCTAssertEqual(
            IncomingReferenceURL.text(from: url),
            "https://github.com/openclaw/openclaw/issues/76162"
        )
    }

    func testRejectsNonResolveURLs() throws {
        XCTAssertNil(try IncomingReferenceURL.text(from: XCTUnwrap(URL(string: "https://github.com/openclaw/openclaw/issues/1"))))
        XCTAssertNil(try IncomingReferenceURL.text(from: XCTUnwrap(URL(string: "repobar://settings"))))
    }
}
