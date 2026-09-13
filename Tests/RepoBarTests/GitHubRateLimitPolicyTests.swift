import Foundation
@testable import RepoBarCore
import Testing

struct GitHubRateLimitPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `secondary limit without retry header ignores the primary window`() throws {
        let response = try self.response(403, ["X-RateLimit-Remaining": "42", "X-RateLimit-Reset": "1700003600"])
        let data = Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)
        #expect(GitHubRateLimitPolicy.retryDate(response: response, data: data, now: self.now) == self.now.addingTimeInterval(60))
    }

    @Test
    func `primary exhaustion waits for both reset and retry after`() throws {
        let response = try self.response(429, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700003600", "Retry-After": "120"])
        #expect(GitHubRateLimitPolicy.retryDate(response: response, data: Data(), now: self.now) == self.now.addingTimeInterval(3600))
    }

    @Test
    func `HTTP date Retry After is honored`() throws {
        let response = try self.response(429, ["Retry-After": "Tue, 14 Nov 2023 22:15:20 GMT"])
        #expect(GitHubRateLimitPolicy.retryDate(response: response, data: Data(), now: self.now) == self.now.addingTimeInterval(120))
    }

    @Test
    func `ordinary permission failure is not a rate limit`() throws {
        let response = try self.response(403, ["X-RateLimit-Remaining": "42", "Retry-After": "invalid"])
        let data = Data(#"{"message":"Resource not accessible by integration"}"#.utf8)
        #expect(GitHubRateLimitPolicy.retryDate(response: response, data: data, now: self.now) == nil)
    }

    private func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://api.github.com/graphql"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
    }
}
