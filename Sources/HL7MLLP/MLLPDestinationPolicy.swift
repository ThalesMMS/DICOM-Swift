import Foundation
import HL7v2

public struct MLLPDestinationPolicy: Sendable {
    public enum Idempotency: Sendable { case idempotent, nonIdempotent(orderTypes: Set<String>) }
    public enum Resend: Sendable { case never, onlyIfUnsent, idempotentOnly }
    public var idempotency: Idempotency
    public var resend: Resend
    public var maxAttempts: Int
    public var ackTimeout: TimeInterval
    public init(idempotency: Idempotency = .nonIdempotent(orderTypes: ["ORM", "ORU"]),
                resend: Resend = .never, maxAttempts: Int = 3, ackTimeout: TimeInterval = 30) {
        self.idempotency = idempotency; self.resend = resend
        self.maxAttempts = maxAttempts; self.ackTimeout = ackTimeout
    }
}

public enum MLLPOutboundDecision: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case resend, stop, requiresReconciliation(String)
    public var description: String {
        switch self {
        case .resend: "resend"
        case .stop: "stop"
        case .requiresReconciliation: "requiresReconciliation(redacted)"
        }
    }
    public var debugDescription: String { description }
}

public enum MLLPOutbound {
    /// `definitelyUnsent` requires positive transport evidence, not merely a missing ACK.
    public static func decision(for message: HL7Message, policy: MLLPDestinationPolicy,
                                attempts: Int, definitelyUnsent: Bool = false) -> MLLPOutboundDecision {
        let type = message.messageType.code ?? ""
        var nonIdempotent = ["ORM", "ORU"].contains(type)
        if case .nonIdempotent(let types) = policy.idempotency { nonIdempotent = nonIdempotent || types.contains(type) }
        if !definitelyUnsent && nonIdempotent { return .requiresReconciliation(message.controlID ?? "") }
        guard attempts < policy.maxAttempts else { return .stop }
        switch policy.resend {
        case .never: return .stop
        case .onlyIfUnsent: return definitelyUnsent ? .resend : .stop
        case .idempotentOnly:
            if definitelyUnsent { return .resend }
            if case .idempotent = policy.idempotency { return .resend }
            return ["ADT", "ACK", "QBP"].contains(type) ? .resend : .stop
        }
    }

    public static func send(_ message: HL7Message, client: MLLPClient,
                            policy: MLLPDestinationPolicy) async throws -> MLLPOutboundResult {
        guard policy.maxAttempts > 0, policy.ackTimeout.isFinite, policy.ackTimeout > 0 else {
            throw MLLPError.invalidConfiguration
        }
        let retry = decision(for: message, policy: policy, attempts: 1) == .resend
        let result = try await client.send(message, timeout: policy.ackTimeout,
            resendPolicy: retry ? .idempotent : .never, maxAttempts: policy.maxAttempts)
        switch result {
        case .ackTimeout, .ackMismatch:
            return .unknown(decision(for: message, policy: policy, attempts: policy.maxAttempts))
        default: return .completed(result)
        }
    }
}

public enum MLLPOutboundResult: Sendable {
    case completed(MLLPSendResult)
    case unknown(MLLPOutboundDecision)
}
