import Foundation
import HL7v2

public enum HL7AckMode: String, Sendable, CaseIterable {
    case original, always = "AL", never = "NE", errors = "ER", successful = "SU"

    public init(message: HL7Message, commitAck: Bool) {
        let accept = message["MSH"]?[15][1][1][1].text ?? ""
        let application = message["MSH"]?[16][1][1][1].text ?? ""
        if accept.isEmpty && application.isEmpty { self = .original }
        else { self = Self(rawValue: commitAck ? accept : application) ?? .never }
    }
}

public enum HL7AckCode: String, Sendable, CaseIterable {
    case AA, AE, AR, CA, CE, CR
    public var isSuccess: Bool { self == .AA || self == .CA }
    public var isCommit: Bool { self == .CA || self == .CE || self == .CR }
}

/// Provider text is wire response data, never diagnostic or audit content.
/// Receipt ACK is not evidence of durable processing. Only the processing provider can assert acceptance.
public enum MLLPProcessingOutcome: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case accepted
    case rejectedStructure([HL7ValidationFinding])
    case rejectedApplication(code: String, text: String)
    case error(text: String)
    /// Processing happened, but durable confirmation is unavailable. Never produces AA/CA.
    case uncertain(reason: String)

    public var description: String {
        switch self {
        case .accepted: "accepted"
        case .rejectedStructure: "rejectedStructure"
        case .rejectedApplication: "rejectedApplication"
        case .error: "error"
        case .uncertain: "uncertain"
        }
    }
    public var debugDescription: String { description }
}

public struct MLLPAckPolicy: Sendable {
    public var mode: HL7AckMode
    public var commitAck: Bool
    public init(mode: HL7AckMode = .original, commitAck: Bool = false) {
        self.mode = mode; self.commitAck = commitAck
    }

    public func shouldAcknowledge(outcome: MLLPProcessingOutcome) -> HL7AckCode? {
        let code: HL7AckCode
        let commit = commitAck && mode != .original
        switch outcome {
        case .accepted: code = commit ? .CA : .AA
        case .rejectedStructure: code = commit ? .CR : .AR
        case .rejectedApplication, .error, .uncertain: code = commit ? .CE : .AE
        }
        switch mode {
        case .never: return nil
        case .errors: return code.isSuccess ? nil : code
        case .successful: return code.isSuccess ? code : nil
        case .always, .original: return code
        }
    }

    /// Original mode follows MSH-15/16; an explicit local mode overrides the requested frequency.
    public func resolved(for message: HL7Message) -> Self {
        mode == .original ? .init(mode: .init(message: message, commitAck: commitAck), commitAck: commitAck) : self
    }
}

public enum MLLPAckBuilder {
    public static func ack(for message: HL7Message, outcome: MLLPProcessingOutcome,
                           policy: MLLPAckPolicy, version: HL7Version? = nil) throws -> HL7Message? {
        guard let code = policy.shouldAcknowledge(outcome: outcome) else { return nil }
        guard let version = version ?? message.version else { throw MLLPError.invalidMessage }
        var builder = HL7MessageBuilder(version: version)
        var findings: [HL7ValidationFinding] = []
        let text: String?
        switch outcome {
        case .accepted: text = nil
        case .rejectedStructure(let errors): findings = errors; text = "Structure rejected"
        case .rejectedApplication(_, let value), .error(let value): text = value
        case .uncertain: text = "Processing not durably confirmed"
        }
        builder.ack(for: message, code: code.isSuccess ? .AA : (code == .AR || code == .CR ? .AR : .AE),
                    text: text, errors: findings)
        var ack = builder.message
        ack["MSA"]?[1] = HL7Field(.text(code.rawValue))
        return ack
    }
}

public enum MLLPError: Error, Sendable {
    case invalidConfiguration, invalidMessage, connectionClosed, connectionFailed, cancelled, duplicateControlID
}
