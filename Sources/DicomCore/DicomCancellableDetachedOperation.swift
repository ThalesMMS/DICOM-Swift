import Foundation

enum DicomCancellableDetachedOperation {
    static func run<Value: Sendable>(
        executor: DicomFallbackWorkExecutor = .shared,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let admission = try await executor.acquire()
        do { try Task.checkCancellation() }
        catch {
            await executor.release(admission)
            throw error
        }
        let state = State<Value>()
        let context = DicomDecodeWorkContext.current
        context?.workerStarted()
        let worker = await executor.start(admission, priority: Task.currentPriority, operation: {
            do {
                try Task.checkCancellation()
                state.resolve(.success(try operation()))
            } catch {
                state.resolve(.failure(error))
            }
        }, finished: {
            context?.workerFinished()
        })
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
            }
        } onCancel: {
            worker.cancel()
            state.resolve(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return value
    }

    private final class State<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var result: Result<Value, any Error>?

        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ result: Result<Value, any Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
