import Foundation

public struct DicomDeliveryRetryPolicy: Sendable {
    public var maxAttempts: [DicomDeliveryErrorClass: Int]
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    private let random: @Sendable () -> Double

    public init(maxAttempts: [DicomDeliveryErrorClass: Int] = [.transient: 8, .uncertain: 5,
                .rejectedByDestination: 0, .permanent: 0, .signatureRejected: 0, .cancelled: 0],
                baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 900,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.random = random
    }

    /// Attempts includes the attempt just finished. Retry-After is a lower bound, including beyond maxDelay.
    public func nextAttempt(after attempts: Int, class errorClass: DicomDeliveryErrorClass,
                            retryAfter: TimeInterval? = nil, now: Date) -> Date? {
        guard attempts < maxAttempts[errorClass, default: 0] else { return nil }
        let ceiling = min(max(0, maxDelay), max(0, baseDelay) * pow(2, Double(min(62, max(0, attempts - 1)))))
        let jitter = ceiling * min(1, max(0, random()))
        let requested = retryAfter.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return now.addingTimeInterval(max(jitter, requested))
    }
}
