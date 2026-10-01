import Foundation

public enum DicomWebhookEventError: Error, Equatable {
    case phiNotAuthorized
    case invalidEvent
}

public struct DicomWebhookPHIAuthorization: Sendable {
    public let token: String
    public let reason: String

    public init(token: String, reason: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomWebhookEventError.phiNotAuthorized
        }
        self.token = token
        self.reason = reason
    }
}

public struct DicomWebhookEvent: Codable, Equatable, Sendable {
    public struct Subject: Codable, Equatable, Sendable {
        public var studyInstanceUID: String?
        public var seriesInstanceUID: String?
        public var sopInstanceUID: String?
        public var objectCount: Int?

        public init(studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                    sopInstanceUID: String? = nil, objectCount: Int? = nil) {
            self.studyInstanceUID = studyInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.sopInstanceUID = sopInstanceUID
            self.objectCount = objectCount
        }
    }

    public struct PHI: Codable, Equatable, Sendable {
        public var patientID: String?
        public var patientName: String?
        public var accessionNumber: String?

        public init(patientID: String? = nil, patientName: String? = nil, accessionNumber: String? = nil) {
            self.patientID = patientID
            self.patientName = patientName
            self.accessionNumber = accessionNumber
        }
    }

    public let eventID: String
    public let kind: String
    public let occurredAt: Date
    public let subject: Subject
    public let phi: PHI?
    public let source: String
    public let sequence: Int64?
    public var phiIncluded: Bool { phi != nil }

    public init(eventID: String, kind: String, occurredAt: Date, subject: Subject, phi: PHI? = nil,
                authorization: DicomWebhookPHIAuthorization? = nil, source: String, sequence: Int64? = nil) throws {
        guard phi == nil || authorization != nil else { throw DicomWebhookEventError.phiNotAuthorized }
        guard !eventID.isEmpty, !source.isEmpty,
              ["received", "complete", "available", "archived", "error"].contains(kind),
              occurredAt.timeIntervalSince1970.isFinite else { throw DicomWebhookEventError.invalidEvent }
        self.eventID = eventID
        self.kind = kind
        self.occurredAt = Date(timeIntervalSince1970: floor(occurredAt.timeIntervalSince1970))
        self.subject = subject
        self.phi = phi
        self.source = source
        self.sequence = sequence
    }

    public init(eventID: String, kind: String, occurredAt: Date, subject: Subject, phi: PHI? = nil,
                authorization: DicomWebhookPHIAuthorization? = nil, source: String, sequence: Int64? = nil,
                authorizer: (any DicomAuthorizing)?, principal: DicomPrincipal? = nil) async throws {
        if phi != nil, let authorizer {
            guard authorization != nil, let study = subject.studyInstanceUID, !study.isEmpty else {
                throw DicomWebhookEventError.phiNotAuthorized
            }
            let resource = subject.sopInstanceUID.map {
                DicomResourceRef.instance(study: study, series: subject.seriesInstanceUID ?? "", instance: $0)
            } ?? .init(kind: .study, id: study)
            let decision = await authorizer.decide(principal: principal, operation: .readMetadata,
                resource: resource, context: .init(protocol: .webhook))
            guard decision.outcome == .allow, decision.obligations.isEmpty else {
                throw DicomWebhookEventError.phiNotAuthorized
            }
        }
        try self.init(eventID: eventID, kind: kind, occurredAt: occurredAt, subject: subject, phi: phi,
                      authorization: authorization, source: source, sequence: sequence)
    }

    private enum CodingKeys: String, CodingKey { case eventID, kind, occurredAt, subject, phi, source, sequence }

    /// Set this decoder userInfo entry to an explicit authorization to decode PHI-bearing events.
    public static let phiAuthorizationUserInfoKey = CodingUserInfoKey(rawValue: "DicomWebhookPHIAuthorization")!

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let date = try values.decode(String.self, forKey: .occurredAt)
        guard let parsed = ISO8601DateFormatter().date(from: date) else {
            throw DecodingError.dataCorruptedError(forKey: .occurredAt, in: values, debugDescription: "Invalid UTC date")
        }
        try self.init(eventID: values.decode(String.self, forKey: .eventID),
            kind: values.decode(String.self, forKey: .kind), occurredAt: parsed,
            subject: values.decode(Subject.self, forKey: .subject), phi: values.decodeIfPresent(PHI.self, forKey: .phi),
            authorization: decoder.userInfo[Self.phiAuthorizationUserInfoKey] as? DicomWebhookPHIAuthorization,
            source: values.decode(String.self, forKey: .source), sequence: values.decodeIfPresent(Int64.self, forKey: .sequence))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(kind, forKey: .kind)
        try values.encode(ISO8601DateFormatter().string(from: occurredAt), forKey: .occurredAt)
        try values.encode(subject, forKey: .subject)
        try values.encodeIfPresent(phi, forKey: .phi)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(sequence, forKey: .sequence)
    }
}
