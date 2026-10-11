//
//  DicomBlockingAsyncOperation.swift
//  DicomCore
//
//  Synchronous entry to an async decode (issue #3050). The operation runs on a detached task while the caller waits,
//  as the Part 2 collection path already does; callers are synchronous loaders, never the cooperative pool's only thread.
//

import Foundation

enum DicomBlockingAsyncOperation {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        let box = ResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.store(.success(try await operation())) } catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.take().get()
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, any Error> = .failure(CancellationError())

        func store(_ value: Result<Value, any Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func take() -> Result<Value, any Error> {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }
}
