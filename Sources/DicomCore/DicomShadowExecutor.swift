import Foundation

/// Best-effort comparisons share a bounded queue; production pixels never depend on admission.
actor DicomShadowExecutor {
    static let shared = DicomShadowExecutor(limits: Limits(environment: ProcessInfo.processInfo.environment))

    /// Source sessions own background comparisons. Standalone callers drain their temporary session.
    static func schedule(bytes: Int, environment: [String: String],
                         operation: @escaping @Sendable () async -> Void) async -> Admission {
        let parent = DicomDecodeWorkContext.current
        let session = parent?.shadowSession ?? DicomShadowSession()
        let sampleEvery = max(1, Int(environment["DICOM_SHADOW_SAMPLE_EVERY"] ?? "16") ?? 16)
        return await withTaskCancellationHandler {
            let admission = await shared.submit(session: session, bytes: bytes, sampleEvery: sampleEvery) {
                defer { withExtendedLifetime(parent) {} }
                await operation()
            }
            if parent?.shadowSession == nil { await shared.drain(session: session) }
            return admission
        } onCancel: {
            // A temporary standalone session has exactly one consumer. A source session is shared.
            if parent?.shadowSession == nil {
                session.close()
                Task { await shared.cancel(session: session) }
            }
        }
    }

    struct Limits: Sendable {
        var maximumRunning = 1
        var maximumQueued = 4
        var maximumRetainedBytes = 128 * 1024 * 1024

        init(maximumRunning: Int = 1, maximumQueued: Int = 4,
             maximumRetainedBytes: Int = 128 * 1024 * 1024) {
            self.maximumRunning = maximumRunning
            self.maximumQueued = maximumQueued
            self.maximumRetainedBytes = maximumRetainedBytes
        }

        init(environment: [String: String]) {
            maximumRunning = min(4, max(1, Int(environment["DICOM_SHADOW_MAX_CONCURRENT"] ?? "1") ?? 1))
            maximumQueued = min(128, max(0, Int(environment["DICOM_SHADOW_MAX_QUEUED"] ?? "4") ?? 4))
            maximumRetainedBytes = min(1024 * 1024 * 1024, max(0,
                Int(environment["DICOM_SHADOW_MAX_RETAINED_BYTES"] ?? "134217728") ?? 134217728))
        }
    }

    enum Admission: String, Sendable {
        case admitted, sampledOut, queueFull, byteLimit, closed
    }

    enum Comparison: Sendable { case matched, mismatched, failed, cancelled }

    struct Snapshot: Sendable {
        let running: Int
        let queued: Int
        let retainedBytes: Int
        let completed: Int
        let dropped: Int
        let maximumQueueWaitNanoseconds: UInt64
        let matched: Int
        let mismatched: Int
        let failed: Int
        let cancelled: Int
    }

    private struct Job {
        let id: UUID
        let session: DicomShadowSession
        let bytes: Int
        let enqueuedAt: UInt64
        let operation: @Sendable () async -> Void
        var task: Task<Void, Never>?
    }

    private let limits: Limits
    private let now: @Sendable () -> UInt64
    private var jobs: [UUID: Job] = [:]
    private var queue: [UUID] = []
    private var running = 0
    private var retainedBytes = 0
    private var submissions: UInt64 = 0
    private var completed = 0
    private var dropped = 0
    private var maximumQueueWaitNanoseconds: UInt64 = 0
    private var matched = 0
    private var mismatched = 0
    private var failed = 0
    private var cancelled = 0
    private var drainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(limits: Limits = Limits(), now: @escaping @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }) {
        self.limits = Limits(maximumRunning: max(1, limits.maximumRunning),
                             maximumQueued: max(0, limits.maximumQueued),
                             maximumRetainedBytes: max(0, limits.maximumRetainedBytes))
        self.now = now
    }

    var snapshot: Snapshot {
        Snapshot(running: running, queued: queue.count, retainedBytes: retainedBytes,
                 completed: completed, dropped: dropped,
                 maximumQueueWaitNanoseconds: maximumQueueWaitNanoseconds,
                 matched: matched, mismatched: mismatched, failed: failed, cancelled: cancelled)
    }

    func record(_ comparison: Comparison) {
        switch comparison {
        case .matched: matched += 1
        case .mismatched: mismatched += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        }
    }

    func submit(session: DicomShadowSession, bytes: Int, sampleEvery: Int,
                operation: @escaping @Sendable () async -> Void) -> Admission {
        submissions &+= 1
        let outcome: Admission
        if session.isClosed { outcome = .closed }
        else if (submissions &- 1) % UInt64(max(1, sampleEvery)) != 0 { outcome = .sampledOut }
        else if bytes < 0 || bytes > limits.maximumRetainedBytes - retainedBytes { outcome = .byteLimit }
        else if running >= limits.maximumRunning && queue.count >= limits.maximumQueued { outcome = .queueFull }
        else { outcome = .admitted }
        guard outcome == .admitted else {
            dropped += 1
            return outcome
        }
        let id = UUID()
        jobs[id] = Job(id: id, session: session, bytes: bytes, enqueuedAt: now(), operation: operation)
        retainedBytes += bytes
        queue.append(id)
        startAvailable()
        return .admitted
    }

    func cancel(session: DicomShadowSession) {
        session.close()
        for job in jobs.values where job.session.id == session.id {
            if let task = job.task { task.cancel() }
            else {
                queue.removeAll { $0 == job.id }
                retainedBytes -= job.bytes
                jobs[job.id] = nil
                dropped += 1
            }
        }
        resumeDrained(session.id)
    }

    func drain(session: DicomShadowSession) async {
        guard jobs.values.contains(where: { $0.session.id == session.id }) else { return }
        await withCheckedContinuation { drainWaiters[session.id, default: []].append($0) }
    }

    private func startAvailable() {
        while running < limits.maximumRunning, !queue.isEmpty {
            let id = queue.removeFirst()
            guard var job = jobs[id] else { continue }
            let timestamp = now()
            maximumQueueWaitNanoseconds = max(maximumQueueWaitNanoseconds,
                                               timestamp >= job.enqueuedAt ? timestamp - job.enqueuedAt : 0)
            running += 1
            let operation = job.operation
            let session = job.session
            job.task = Task.detached(priority: .utility) {
                // Separate accounting prevents a late shadow fallback joining the production drain.
                let context = DicomDecodeWorkContext(memory: nil)
                await DicomDecodeWorkContext.$current.withValue(context) {
                    if !Task.isCancelled && !session.isClosed { await operation() }
                    await context.waitForWorkers()
                }
                await self.finished(id)
            }
            jobs[id] = job
        }
    }

    private func finished(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        running -= 1
        retainedBytes -= job.bytes
        completed += 1
        resumeDrained(job.session.id)
        startAvailable()
    }

    private func resumeDrained(_ session: UUID) {
        guard !jobs.values.contains(where: { $0.session.id == session }) else { return }
        for waiter in drainWaiters.removeValue(forKey: session) ?? [] { waiter.resume() }
    }
}
