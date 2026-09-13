import Foundation
import Synchronization

final class ControlledClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = ContinuousClock().now
        var sleepers: [UUID: Sleeper] = [:]
    }

    private let state = Mutex(State())

    var now: Instant {
        self.state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .nanoseconds(1)
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = self.state.withLock { state in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if deadline <= state.now {
                        return .success(())
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = self.state.withLock { state in
            state.now += duration
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys {
                state.sleepers[id] = nil
            }
            return Array(ready.values)
        }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    func waitUntilSleeping(count: Int) async throws {
        while self.state.withLock({ $0.sleepers.count }) < count {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}
