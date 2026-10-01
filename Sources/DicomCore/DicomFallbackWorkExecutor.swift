import Foundation

/// Bounds synchronous codec work, including standalone readers outside a source session.
/// A cancelled running caller retains its slot until the physical worker returns.
actor DicomFallbackWorkExecutor {
    static let shared = DicomFallbackWorkExecutor()

    enum Failure: Error { case queueFull }

    struct Snapshot: Sendable {
        let running: Int
        let queued: Int
    }

    private struct Pending {
        let id: UUID
        let priority: TaskPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumRunning: Int
    private let maximumQueued: Int
    private var admitted: Set<UUID> = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var queue: [Pending] = []
    private var dispatches = 0

    init(maximumRunning: Int = 4, maximumQueued: Int = 128) {
        self.maximumRunning = max(1, maximumRunning)
        self.maximumQueued = max(0, maximumQueued)
    }

    var snapshot: Snapshot { Snapshot(running: admitted.count, queued: queue.count) }

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if admitted.count < maximumRunning {
            admitted.insert(id)
            return id
        }
        guard queue.count < maximumQueued else { throw Failure.queueFull }
        let priority = Task.currentPriority
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Pending(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        return id
    }

    func start(
        _ id: UUID,
        priority: TaskPriority,
        operation: @escaping @Sendable () -> Void,
        finished: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        precondition(admitted.contains(id) && workers[id] == nil)
        let worker = Task.detached(priority: priority) {
            operation()
            await self.release(id)
            finished()
        }
        workers[id] = worker
        return worker
    }

    func release(_ id: UUID) {
        precondition(admitted.remove(id) != nil)
        workers[id] = nil
        guard !queue.isEmpty else { return }
        // Every fourth admission serves the oldest request, bounding speculation starvation.
        dispatches = (dispatches + 1) % 4
        var selected = 0
        if dispatches != 0 {
            for index in queue.indices where queue[index].priority > queue[selected].priority {
                selected = index
            }
        }
        let next = queue.remove(at: selected)
        admitted.insert(next.id)
        next.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
