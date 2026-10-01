import Foundation

/// Lifecycle facts only; delivery acknowledgements and commitment are independent facts.
public struct DicomLifecycleEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case received, complete, available, archived, error }
    public typealias Subject = DicomWebhookEvent.Subject
    public struct ErrorInfo: Codable, Equatable, Sendable {
        public let `class`: String
        /// Host-supplied diagnostic: must not contain PHI, paths, or dataset values.
        public let message: String
        public init(class classification: String, message: String) {
            self.class = classification
            self.message = message
        }
    }
    public enum ValidationError: Error { case invalidAttributes, invalidIdentity }
    public var eventID: String {
        String(DicomStudyPackageManifest.digest(Data("\(sourceKind)|\(sourceRef)|\(kind.rawValue)".utf8)).prefix(32))
    }
    public let kind: Kind
    public let subject: Subject
    public let sourceKind: String
    public let sourceRef: String
    public let occurredAt: Date
    public let durability: DicomDurabilityLevel?
    public let error: ErrorInfo?
    public let attributes: [String: String]
    /// Routing audit persisted by the same sink, including dry-run decisions. No dataset values.
    public internal(set) var routingDecisions: [DicomRoutingDecision] = []

    public init(kind: Kind, subject: Subject = .init(), sourceKind: String, sourceRef: String,
                occurredAt: Date = Date(), durability: DicomDurabilityLevel? = nil,
                error: ErrorInfo? = nil, attributes: [String: String] = [:]) throws {
        guard !sourceKind.isEmpty, !sourceRef.isEmpty, occurredAt.timeIntervalSince1970.isFinite else {
            throw ValidationError.invalidIdentity
        }
        guard attributes.count <= 16, attributes.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 256 }) else {
            throw ValidationError.invalidAttributes
        }
        self.kind = kind
        self.subject = subject
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
        self.occurredAt = occurredAt
        self.durability = durability
        self.error = error
        self.attributes = attributes
    }

    public func webhookEvent(sequence: Int64? = nil, source: String,
                             phi: DicomWebhookEvent.PHI? = nil,
                             authorization: DicomWebhookPHIAuthorization? = nil) throws -> DicomWebhookEvent {
        try .init(eventID: eventID, kind: kind.rawValue, occurredAt: occurredAt, subject: subject,
                  phi: phi, authorization: authorization, source: source, sequence: sequence)
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, kind, subject, sourceKind, sourceRef, occurredAt, durability, error, attributes, routingDecisions
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(Kind.self, forKey: .kind), subject: c.decode(Subject.self, forKey: .subject),
                      sourceKind: c.decode(String.self, forKey: .sourceKind), sourceRef: c.decode(String.self, forKey: .sourceRef),
                      occurredAt: c.decode(Date.self, forKey: .occurredAt),
                      durability: c.decodeIfPresent(DicomDurabilityLevel.self, forKey: .durability),
                      error: c.decodeIfPresent(ErrorInfo.self, forKey: .error),
                      attributes: c.decode([String: String].self, forKey: .attributes))
        guard try c.decode(String.self, forKey: .eventID) == eventID else { throw ValidationError.invalidIdentity }
        routingDecisions = try c.decodeIfPresent([DicomRoutingDecision].self, forKey: .routingDecisions) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(kind, forKey: .kind)
        try c.encode(subject, forKey: .subject)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encode(sourceRef, forKey: .sourceRef)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encodeIfPresent(durability, forKey: .durability)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(attributes, forKey: .attributes)
        try c.encode(routingDecisions, forKey: .routingDecisions)
    }
}
