/// Process-wide shadow queue counters, without source identifiers or patient information.
/// Retained bytes count compressed input plus production pixels, not codec scratch or process RSS.
public struct DicomShadowDecodeStatistics: Sendable {
    public let running: Int
    public let queued: Int
    public let retainedPayloadBytes: Int
    public let completed: Int
    public let dropped: Int
    public let maximumQueueWaitNanoseconds: UInt64
    public let matched: Int
    public let mismatched: Int
    public let failed: Int
    public let cancelled: Int

    public static func current() async -> Self {
        let snapshot = await DicomShadowExecutor.shared.snapshot
        return Self(running: snapshot.running, queued: snapshot.queued,
                    retainedPayloadBytes: snapshot.retainedBytes,
                    completed: snapshot.completed, dropped: snapshot.dropped,
                    maximumQueueWaitNanoseconds: snapshot.maximumQueueWaitNanoseconds,
                    matched: snapshot.matched, mismatched: snapshot.mismatched,
                    failed: snapshot.failed, cancelled: snapshot.cancelled)
    }
}
