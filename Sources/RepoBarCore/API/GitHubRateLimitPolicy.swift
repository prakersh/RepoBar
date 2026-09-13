import Foundation

struct GitHubHTTPResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
    let retryAt: Date?
}

enum GitHubRateLimitPolicy {
    static func retryDate(response: HTTPURLResponse, data: Data, now: Date = Date()) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }

        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let retryAfter = self.retryAfterDate(response: response, now: now)
        let error = try? GitHubDecoding.decode(GitHubErrorResponse.self, from: data)
        let hasRateLimitMessage = error?.message?.localizedCaseInsensitiveContains("rate limit") == true
            || error?.errors?.contains(where: self.isRateLimitError) == true
        guard response.statusCode == 429 || remaining == 0 || retryAfter != nil || hasRateLimitMessage else { return nil }

        return self.deadline(response: response, now: now)
    }

    static func graphQLRetryDate(response: HTTPURLResponse, data: Data, now: Date = Date()) -> Date? {
        guard response.statusCode == 200 else { return self.retryDate(response: response, data: data, now: now) }

        let error = try? GitHubDecoding.decode(GitHubErrorResponse.self, from: data)
        guard error?.errors?.contains(where: self.isRateLimitError) == true else { return nil }

        return self.deadline(response: response, now: now)
    }

    private static func isRateLimitError(_ error: GitHubErrorDetail) -> Bool {
        error.type == "RATE_LIMITED" || error.message?.localizedCaseInsensitiveContains("rate limit") == true
    }

    private static func deadline(response: HTTPURLResponse, now: Date) -> Date {
        let retryAfter = self.retryAfterDate(response: response, now: now)
        let primaryReset = self.primaryResetDate(response: response)
        return [retryAfter, primaryReset].compactMap(\.self).max() ?? now.addingTimeInterval(60)
    }

    static func primaryResetDate(response: HTTPURLResponse) -> Date? {
        guard response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) == 0,
              let rawReset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let epoch = TimeInterval(rawReset), epoch.isFinite else { return nil }

        return Date(timeIntervalSince1970: epoch)
    }

    static func retryAfterDate(response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header)
    }
}
