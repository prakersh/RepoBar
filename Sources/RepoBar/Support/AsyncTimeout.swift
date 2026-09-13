import Foundation

struct AsyncTimeoutError: Error {}

enum AsyncTimeout {
    static func value<T>(
        within seconds: TimeInterval,
        task: Task<T, Error>,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> T {
        // A task group would keep waiting for task.value even after its deadline won.
        let (results, continuation) = AsyncStream<Result<T, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let completion = Task {
            await continuation.yield(task.result)
        }
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(max(0, seconds)))
            } catch {
                return
            }
            continuation.yield(.failure(AsyncTimeoutError()))
        }
        defer {
            completion.cancel()
            deadline.cancel()
            continuation.finish()
        }

        var iterator = results.makeAsyncIterator()
        guard let result = await iterator.next() else {
            task.cancel()
            throw CancellationError()
        }

        do {
            try Task.checkCancellation()
            return try result.get()
        } catch {
            task.cancel()
            throw error
        }
    }
}
