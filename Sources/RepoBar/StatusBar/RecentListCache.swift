import Foundation

@MainActor
final class RecentListCache<Value: Sendable> {
    struct Entry {
        var fetchedAt: Date
        var value: Value
    }

    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []
    private struct Inflight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: AsyncStream<Result<Value, Error>>.Continuation] = [:]
        var retirement: Task<Void, Never>?
    }

    private var inflight: [String: Inflight] = [:]
    private let clock: any Clock<Duration>
    private let cancellationGrace: Duration

    init(
        maxEntries: Int = AppLimits.RecentLists.cacheEntries,
        clock: any Clock<Duration> = ContinuousClock(),
        cancellationGrace: Duration = .seconds(AppLimits.RecentLists.loadTimeout)
    ) {
        self.maxEntries = max(0, maxEntries)
        self.clock = clock
        self.cancellationGrace = cancellationGrace
    }

    func cached(for key: String, now: Date, maxAge: TimeInterval) -> Value? {
        guard let entry = self.entries[key] else { return nil }
        guard now.timeIntervalSince(entry.fetchedAt) <= maxAge else { return nil }

        self.touch(key)
        return entry.value
    }

    func stale(for key: String) -> Value? {
        guard let entry = self.entries[key] else { return nil }

        self.touch(key)
        return entry.value
    }

    func needsRefresh(for key: String, now: Date, maxAge: TimeInterval) -> Bool {
        guard let entry = self.entries[key] else { return true }

        return now.timeIntervalSince(entry.fetchedAt) > maxAge
    }

    func load(
        for key: String,
        timeout: TimeInterval,
        factory: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if self.inflight[key]?.retirement != nil {
            throw AsyncTimeoutError()
        }
        let request = self.inflight[key] ?? self.startRequest(for: key, factory: factory)
        let waiterID = UUID()
        let (results, continuation) = AsyncStream<Result<Value, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.inflight[key]?.waiters[waiterID] = continuation
        defer { self.releaseWaiter(for: key, requestID: request.id, waiterID: waiterID) }

        // A cancelled subscriber stops immediately without cancelling another caller's request.
        let waiter = Task {
            var iterator = results.makeAsyncIterator()
            guard let result = await iterator.next() else { throw CancellationError() }

            return try result.get()
        }
        return try await AsyncTimeout.value(within: timeout, task: waiter, clock: self.clock)
    }

    private func startRequest(
        for key: String,
        factory: @escaping @Sendable () async throws -> Value
    ) -> Inflight {
        let id = UUID()
        let task = Task { [weak self] in
            let result: Result<Value, Error>
            do {
                result = try await .success(factory())
            } catch {
                result = .failure(error)
            }
            self?.finishRequest(for: key, requestID: id, result: result)
        }
        let request = Inflight(id: id, task: task)
        self.inflight[key] = request
        return request
    }

    private func releaseWaiter(for key: String, requestID: UUID, waiterID: UUID) {
        guard var request = self.inflight[key], request.id == requestID else { return }

        request.waiters.removeValue(forKey: waiterID)?.finish()
        if request.waiters.isEmpty, request.retirement == nil {
            request.task.cancel()
            let clock = self.clock
            let grace = self.cancellationGrace
            request.retirement = Task { [weak self] in
                do {
                    try await clock.sleep(for: grace)
                } catch {
                    return
                }
                self?.finishRequest(for: key, requestID: requestID, result: .failure(AsyncTimeoutError()))
            }
        }
        self.inflight[key] = request
    }

    private func finishRequest(for key: String, requestID: UUID, result: Result<Value, Error>) {
        guard let request = self.inflight[key], request.id == requestID else { return }

        self.inflight[key] = nil
        request.retirement?.cancel()
        for continuation in request.waiters.values {
            continuation.yield(result)
            continuation.finish()
        }
    }

    @discardableResult
    func store(_ value: Value, for key: String, fetchedAt: Date) -> [String] {
        guard self.maxEntries > 0 else { return [] }

        self.entries[key] = Entry(fetchedAt: fetchedAt, value: value)
        self.touch(key)
        return self.evictIfNeeded()
    }

    func count() -> Int {
        self.entries.count
    }

    private func touch(_ key: String) {
        self.entryOrder.removeAll { $0 == key }
        self.entryOrder.append(key)
    }

    private func evictIfNeeded() -> [String] {
        var evicted: [String] = []
        while self.entries.count > self.maxEntries, let oldest = self.entryOrder.first {
            self.entryOrder.removeFirst()
            if self.entries.removeValue(forKey: oldest) != nil {
                evicted.append(oldest)
            }
        }
        return evicted
    }
}
