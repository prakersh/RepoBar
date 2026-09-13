@testable import RepoBar
import Testing

@Suite("AsyncTimeout")
struct AsyncTimeoutTests {
    @Test
    func `returns value before timeout`() async throws {
        let task = Task<Int, Error> {
            42
        }

        let value = try await AsyncTimeout.value(within: 2.0, task: task)
        #expect(value == 42)
    }

    @Test
    func `times out and cancels task`() async {
        let task = Task<Int, Error> {
            try await Task.sleep(for: .seconds(2))
            return 1
        }

        do {
            _ = try await AsyncTimeout.value(within: 0.05, task: task)
            #expect(Bool(false), "Expected timeout")
        } catch is AsyncTimeoutError {
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        #expect(task.isCancelled)
    }

    @Test
    func `timeout returns before work that ignores cancellation finishes`() async throws {
        let gate = CompletionGate()
        let work = Task<Bool, Error> {
            await gate.wait()
            return Task.isCancelled
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            await gate.release()
        }
        defer { watchdog.cancel() }

        await #expect(throws: AsyncTimeoutError.self) {
            try await AsyncTimeout.value(within: 0.05, task: work)
        }
        await gate.release()
        #expect(try await work.value)
    }

    @Test
    func `caller cancellation cancels pending work`() async throws {
        let gate = CompletionGate()
        let work = Task<Bool, Error> {
            await gate.wait()
            return Task.isCancelled
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            await gate.release()
        }
        defer { watchdog.cancel() }
        let caller = Task {
            try await AsyncTimeout.value(within: 30, task: work)
        }
        caller.cancel()

        await #expect(throws: CancellationError.self) { try await caller.value }
        await gate.release()
        #expect(try await work.value)
    }

    @Test
    func `operation errors are preserved`() async {
        let work = Task<Int, Error> { throw OperationFailure.expected }
        await #expect(throws: OperationFailure.self) {
            try await AsyncTimeout.value(within: 1, task: work)
        }
    }
}

private actor CompletionGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !self.isReleased else { return }

        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        self.isReleased = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

private enum OperationFailure: Error {
    case expected
}
