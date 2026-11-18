//
//  DicomBlockingAsyncOperation.swift
//  DicomCore
//
//  Synchronous entry to an async decode (issue #3050). The operation runs on a detached task while
//  the caller waits, as the Part 2 collection path already does; callers are synchronous loaders,
//  never the cooperative pool's only thread.
//
//  Thales Matheus Mendonça Santos — October 2026
//

import Foundation

enum DicomBlockingAsyncOperation {
    /// Runs `operation` on a detached task and waits for it.
    ///
    /// - Parameter priority: the task's priority; nil takes the calling thread's QoS (Isis-DICOM-Viewer #3220), so a
    ///   volume build on a `.utility` thread decodes its JPEG 2000 slices at `.utility` and one on a user-initiated
    ///   thread at `.userInitiated`, instead of every decode competing with the viewer at `.userInitiated`.
    static func run<Value: Sendable>(
        priority: TaskPriority? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = ResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: priority ?? callingThreadPriority()) {
            do { box.store(.success(try await operation())) } catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.take().get()
    }

    /// The task priority of the calling thread's QoS class.
    static func callingThreadPriority() -> TaskPriority {
        taskPriority(for: qos_class_self())
    }

    /// User-interactive maps to `.userInitiated`, the highest priority a detached decode takes; a thread without a
    /// QoS class runs at `.medium`, as the default class does.
    static func taskPriority(for qosClass: qos_class_t) -> TaskPriority {
        switch qosClass {
        case QOS_CLASS_USER_INTERACTIVE, QOS_CLASS_USER_INITIATED:
            return .userInitiated
        case QOS_CLASS_UTILITY:
            return .utility
        case QOS_CLASS_BACKGROUND:
            return .background
        default:
            return .medium
        }
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
