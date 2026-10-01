import Foundation
import CryptoKit
import HL7v2
import DicomCore

public struct MLLPPeer: Sendable, Equatable {
    public let address: String
    public let port: UInt16
    public init(address: String, port: UInt16) { self.address = address; self.port = port }
}

public struct MLLPInboundContext: Sendable {
    public let peer: MLLPPeer
    public let transportSecured: Bool
    public let principal: DicomPrincipal?
    public let receivedAt: Date
    public let sequence: Int
    public init(peer: MLLPPeer, transportSecured: Bool, principal: DicomPrincipal?,
                receivedAt: Date = Date(), sequence: Int) {
        self.peer = peer; self.transportSecured = transportSecured; self.principal = principal
        self.receivedAt = receivedAt; self.sequence = sequence
    }
    public var accessContext: DicomAccessContext {
        .init(peerAddress: peer.address, peerPort: peer.port, transportSecured: transportSecured,
              protocol: .mllp, at: receivedAt)
    }
}

public protocol MLLPMessageProcessing: Sendable {
    func process(_ message: HL7Message, raw: Data, context: MLLPInboundContext) async -> MLLPProcessingOutcome
}

/// The host authenticates peers. MSH application/facility fields are never an identity assertion.
/// tlsPeerIdentity is the SHA-256 fingerprint of the verified peer leaf certificate, when available.
public protocol MLLPPrincipalResolving: Sendable {
    func principal(peer: MLLPPeer, tlsPeerIdentity: String?) async -> DicomPrincipal?
}

public struct MLLPAuthorizationBridge: Sendable {
    public let authorizer: any DicomAuthorizing
    public let listenerID: String
    public init(authorizer: any DicomAuthorizing, listenerID: String) {
        self.authorizer = authorizer; self.listenerID = listenerID
    }
    /// Inbound HL7 uses receiveMessage on the listener configuration, not DICOM instance store.
    /// sendMessage is reserved for host outbound policy; a protocol ACK is part of receiveMessage.
    public func decide(context: MLLPInboundContext) async -> DicomAuthorizationDecision {
        await authorizer.decide(principal: context.principal, operation: .receiveMessage,
            resource: .init(kind: .configuration, id: "mllp:" + listenerID), context: context.accessContext)
    }
}

public struct MLLPAuditing: Sendable {
    public enum Activity: String, Sendable { case start, stop, accept, refuse, deny, processed, exposure }
    public let recorder: DicomAuditRecorder
    public init(recorder: DicomAuditRecorder) { self.recorder = recorder }

    public func record(_ activity: Activity, context: DicomAccessContext = .init(protocol: .mllp),
                       message: HL7Message? = nil, outcome: MLLPProcessingOutcome? = nil,
                       findings: [DicomExposureFinding] = []) async throws {
        // Never pass caller principals, listener IDs, provider text, or message header values to audit builders.
        var event = DicomAuditMessages.securityAlert(typeCode: .init("MLLP", "99MLLP", activity.rawValue),
            principal: nil, context: context,
            outcome: activity == .deny || activity == .refuse || findings.contains(where: \.isError)
                ? .seriousFailure : .success)
        if activity == .start || activity == .stop {
            event = DicomAuditMessages.applicationActivity(activity == .start ? .start : .stop,
                principal: nil, context: context)
        } else if activity == .processed {
            event = DicomAuditMessages.dataImport(principal: nil, context: context,
                outcome: outcome?.description == "accepted" ? .success : .minorFailure)
        }
        let type = message?.messageType.code ?? ""
        let safeType = ["ADT", "ORM", "ORU", "QRY", "QBP", "RSP", "ACK"].contains(type) ? type : "other"
        let hash = message?.controlID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        let detail = "activity=\(activity.rawValue);type=\(safeType);controlHash=\(hash ?? "none");outcome=\(outcome?.description ?? "none");findings=\(findings.map { $0.code.rawValue }.joined(separator: ","))"
        event.participantObjects = [.init(objectID: "mllp", typeCodeRole: 24,
            idTypeCode: .init("MLLP", "99MLLP", "Transport"), objectDetail: [.init(type: "mllp", text: detail)])]
        try await recorder.record(event)
    }
}
