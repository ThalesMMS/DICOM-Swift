import Foundation

/// Only connection establishment is retried. An unknown ACK never implies permission to resend.
public struct MLLPRetryPolicy: Sendable {
    public let attempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitter: Double
    public init(attempts: Int = 3, baseDelay: TimeInterval = 0.1,
                maxDelay: TimeInterval = 2, jitter: Double = 0.2) {
        self.attempts = attempts; self.baseDelay = baseDelay; self.maxDelay = maxDelay; self.jitter = jitter
    }
    var isValid: Bool {
        attempts > 0 && baseDelay.isFinite && baseDelay >= 0 && maxDelay.isFinite
            && maxDelay >= baseDelay && jitter.isFinite && (0...1).contains(jitter)
    }
    func delay(at attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(min(attempt, 30)))) * Double.random(in: (1 - jitter)...1)
    }
}

public enum MLLPResendPolicy: Sendable { case never, idempotent }

func mllpSleep(_ seconds: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(max(0, seconds)))
}
