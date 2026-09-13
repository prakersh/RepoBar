@testable import RepoBar
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RecentListCacheTests {
    @Test(arguments: [true, false])
    func `one caller leaving does not cancel a shared request`(cancelCaller: Bool) async throws {
        let clock = ControlledClock()
        let cache = RecentListCache<[Int]>(clock: clock)
        let probe = FetchProbe()
        let first = Task { try await cache.load(for: "repo", timeout: 1) { await probe.fetch() } }
        let second = Task { try await cache.load(for: "repo", timeout: 10) { await probe.fetch() } }
        try await clock.waitUntilSleeping(count: 2)

        if cancelCaller {
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
        } else {
            clock.advance(by: .seconds(1))
            await #expect(throws: AsyncTimeoutError.self) { try await first.value }
        }
        await probe.release()

        #expect(try await second.value == [42])
        #expect(await probe.calls == 1)
        #expect(await probe.wasCancelled == false)
    }

    @Test
    func `cancelled request suppresses duplicates until completion`() async throws {
        let clock = ControlledClock()
        let cache = RecentListCache<[Int]>(clock: clock)
        let probe = FetchProbe()
        let first = Task { try await cache.load(for: "repo", timeout: 1) { await probe.fetch() } }
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(1))
        await #expect(throws: AsyncTimeoutError.self) { try await first.value }
        await #expect(throws: AsyncTimeoutError.self) {
            try await cache.load(for: "repo", timeout: 1) { await probe.duplicateFetch() }
        }
        await probe.release()
        #expect(try await Self.retryAfterCleanup(cache) { await probe.duplicateFetch() } == [99])
        #expect(await probe.calls == 2)
        #expect(await probe.wasCancelled)
    }

    @Test
    func `uncooperative cancelled request retires after bounded cleanup`() async throws {
        let clock = ControlledClock()
        let cache = RecentListCache<[Int]>(clock: clock, cancellationGrace: .seconds(5))
        let probe = FetchProbe()
        let first = Task { try await cache.load(for: "repo", timeout: 1) { await probe.fetch() } }
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(1))
        await #expect(throws: AsyncTimeoutError.self) { try await first.value }
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(5))

        #expect(try await Self.retryAfterCleanup(cache) { await probe.duplicateFetch() } == [99])
        await probe.release()
        #expect(await probe.calls == 2)
    }

    @Test
    func `completed requests permit a new fetch`() async throws {
        let cache = RecentListCache<[Int]>(clock: ControlledClock())
        #expect(try await cache.load(for: "repo", timeout: 1) { [1] } == [1])
        #expect(try await cache.load(for: "repo", timeout: 1) { [2] } == [2])
    }

    private static func retryAfterCleanup(
        _ cache: RecentListCache<[Int]>,
        factory: @escaping @Sendable () async throws -> [Int]
    ) async throws -> [Int] {
        while true {
            try Task.checkCancellation()
            do {
                return try await cache.load(for: "repo", timeout: 1, factory: factory)
            } catch is AsyncTimeoutError {
                await Task.yield()
            }
        }
    }
}

private actor FetchProbe {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var wasCancelled = false

    func fetch() async -> [Int] {
        self.calls += 1
        if !self.released {
            await withCheckedContinuation { self.continuations.append($0) }
        }
        self.wasCancelled = Task.isCancelled
        return [42]
    }

    func duplicateFetch() -> [Int] {
        self.calls += 1
        return [99]
    }

    func release() {
        self.released = true
        for continuation in self.continuations {
            continuation.resume()
        }
        self.continuations = []
    }
}
