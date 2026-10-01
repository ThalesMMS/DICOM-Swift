import Foundation

public struct DicomDeliveryLimits: Sendable {
    public var globalMaxConcurrent: Int
    public var perDestinationMaxConcurrent: [String: Int]
    public var globalBytesPerSecond: Int64?
    public var perDestinationBytesPerSecond: [String: Int64]
    public var statShare: Int
    public var leaseSeconds: TimeInterval
    public init(globalMaxConcurrent: Int = 2, perDestinationMaxConcurrent: [String: Int] = [:],
                globalBytesPerSecond: Int64? = nil, perDestinationBytesPerSecond: [String: Int64] = [:],
                statShare: Int = 70, leaseSeconds: TimeInterval = 300) {
        self.globalMaxConcurrent = max(1, globalMaxConcurrent)
        self.perDestinationMaxConcurrent = perDestinationMaxConcurrent
        self.globalBytesPerSecond = globalBytesPerSecond
        self.perDestinationBytesPerSecond = perDestinationBytesPerSecond
        self.statShare = min(100, max(0, statShare))
        self.leaseSeconds = max(1, leaseSeconds)
    }
}

public enum DicomDeliveryAdmission: Sendable { case proceed, pause(retryAfter: TimeInterval) }
public protocol DicomDeliveryBackpressure: Sendable {
    func admission() async -> DicomDeliveryAdmission
}
public struct DicomDeliveryNoBackpressure: DicomDeliveryBackpressure {
    public init() {}
    public func admission() async -> DicomDeliveryAdmission { .proceed }
}

/// One second of burst capacity. Large objects are charged in chunks so they cannot wait forever
/// for more tokens than the bucket can hold. Clock and sleep must advance on the same time base.
public actor DicomBandwidthLimiter {
    private let rate: Double
    private var tokens: Double
    private var updated: Date
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(bytesPerSecond: Int64, clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        rate = Double(max(1, bytesPerSecond))
        tokens = Double(max(1, bytesPerSecond))
        self.clock = clock
        self.sleep = sleep
        updated = clock()
    }
    public func acquire(bytes: Int64) async throws {
        var remaining = Double(max(0, bytes))
        while remaining > 0 {
            try Task.checkCancellation()
            let now = clock()
            tokens = min(rate, tokens + max(0, now.timeIntervalSince(updated)) * rate)
            updated = now
            let consumed = min(tokens, remaining)
            tokens -= consumed
            remaining -= consumed
            if remaining > 0 { try await sleep(min(remaining, rate) / rate) }
        }
    }
}

final class DicomDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
