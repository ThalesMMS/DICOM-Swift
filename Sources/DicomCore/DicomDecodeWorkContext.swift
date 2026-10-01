import Synchronization

/// Keeps a source job admitted until synchronous fallback work actually exits.
/// Cancelling the consumer may return earlier; it does not release physical work.
final class DicomDecodeWorkContext: Sendable {
    @TaskLocal static var current: DicomDecodeWorkContext?

    private struct State {
        var workers = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var outputOwner: (any DicomFrameMemoryOwner)?
    }

    private let state = Mutex(State())
    private let memory: (any DicomFrameMemoryReservation)?
    let shadowSession: DicomShadowSession?

    init(memory: (any DicomFrameMemoryReservation)?, shadowSession: DicomShadowSession? = nil) {
        self.memory = memory
        self.shadowSession = shadowSession
    }

    func retainOutput(_ owner: any DicomFrameMemoryOwner) {
        state.withLock { $0.outputOwner = owner }
    }

    var activeWorkerCount: Int { state.withLock { $0.workers } }

    func workerStarted() {
        state.withLock { $0.workers += 1 }
    }

    func workerFinished() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            precondition(state.workers > 0)
            state.workers -= 1
            guard state.workers == 0 else { return [] }
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Intentionally drains even in a cancelled task. Consumers have independent waiters.
    func waitForWorkers() async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state in
                guard state.workers > 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}
