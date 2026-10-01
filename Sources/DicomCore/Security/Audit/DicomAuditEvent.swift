import Foundation
import CryptoKit

public struct DicomAuditCode: Codable, Equatable, Sendable {
    public var code: String
    public var codeSystem: String
    public var displayName: String
    public init(_ code: String, _ codeSystem: String, _ displayName: String) {
        self.code = code; self.codeSystem = codeSystem; self.displayName = displayName
    }
    public init(_ code: String, _ displayName: String) { self.init(code, "DCM", displayName) }
    public static let nodeAuthentication = Self("110126", "Node Authentication")
    public static let emergencyOverrideStarted = Self("110127", "Emergency Override Started")
    public static let objectSecurityAttributesChanged = Self("110135", "Object Security Attributes Changed")
    public static let patientSecurityAttributesChanged = Self("110136", "Patient Security Attributes Changed")
    public static let userSecurityAttributesChanged = Self("110137", "User Security Attributes Changed")
}

public struct DicomAuditEvent: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case create = "C", read = "R", update = "U", delete = "D", execute = "E" }
    public enum Outcome: Int, Codable, Sendable { case success = 0, minorFailure = 4, seriousFailure = 8, majorFailure = 12 }
    public struct EventIdentification: Codable, Equatable, Sendable {
        public var eventID: DicomAuditCode
        public var eventActionCode: Action
        public var eventDateTime: Date
        public var eventOutcomeIndicator: Outcome
        public var eventTypeCode: [DicomAuditCode]
        public init(eventID: DicomAuditCode, eventActionCode: Action, eventDateTime: Date,
                    eventOutcomeIndicator: Outcome, eventTypeCode: [DicomAuditCode] = []) {
            self.eventID = eventID; self.eventActionCode = eventActionCode; self.eventDateTime = eventDateTime
            self.eventOutcomeIndicator = eventOutcomeIndicator; self.eventTypeCode = eventTypeCode
        }
    }
    public struct ActiveParticipant: Codable, Equatable, Sendable {
        public var userID: String
        public var alternativeUserID: String?
        public var userIsRequestor: Bool
        public var roleIDCode: [DicomAuditCode]
        public var networkAccessPointID: String?
        public var networkAccessPointTypeCode: Int?
        public init(userID: String, alternativeUserID: String? = nil, userIsRequestor: Bool = true,
                    roleIDCode: [DicomAuditCode] = [], networkAccessPointID: String? = nil,
                    networkAccessPointTypeCode: Int? = nil) {
            self.userID = userID; self.alternativeUserID = alternativeUserID; self.userIsRequestor = userIsRequestor
            self.roleIDCode = roleIDCode; self.networkAccessPointID = networkAccessPointID
            self.networkAccessPointTypeCode = networkAccessPointTypeCode
        }
    }
    public struct AuditSourceIdentification: Codable, Equatable, Sendable {
        public var auditSourceID: String
        public var enterpriseSiteID: String?
        public var typeCode: [DicomAuditCode]
        public init(auditSourceID: String, enterpriseSiteID: String? = nil, typeCode: [DicomAuditCode] = []) {
            self.auditSourceID = auditSourceID; self.enterpriseSiteID = enterpriseSiteID; self.typeCode = typeCode
        }
    }
    public struct ObjectDetail: Codable, Equatable, Sendable {
        public var type: String
        public var value: Data
        public init(type: String, value: Data) { self.type = type; self.value = value }
        public init(type: String, text: String) { self.init(type: type, value: Data(text.utf8)) }
    }
    public struct ParticipantObjectIdentification: Codable, Equatable, Sendable {
        public var objectID: String
        public var typeCode: Int
        public var typeCodeRole: Int
        public var idTypeCode: DicomAuditCode
        public var objectName: String?
        public var objectQuery: Data?
        public var objectDetail: [ObjectDetail]
        public init(objectID: String, typeCode: Int = 2, typeCodeRole: Int = 3, idTypeCode: DicomAuditCode,
                    objectName: String? = nil, objectQuery: Data? = nil, objectDetail: [ObjectDetail] = []) {
            self.objectID = objectID; self.typeCode = typeCode; self.typeCodeRole = typeCodeRole
            self.idTypeCode = idTypeCode; self.objectName = objectName; self.objectQuery = objectQuery
            self.objectDetail = objectDetail
        }
    }
    public var eventIdentification: EventIdentification
    public var activeParticipants: [ActiveParticipant]
    public var auditSource: AuditSourceIdentification
    public var participantObjects: [ParticipantObjectIdentification]
    /// Explicit caller policy for retaining patient numbers, never patient names.
    public var includePatientID: Bool
    public init(eventIdentification: EventIdentification, activeParticipants: [ActiveParticipant],
                auditSource: AuditSourceIdentification, participantObjects: [ParticipantObjectIdentification] = [],
                includePatientID: Bool = false) {
        self.eventIdentification = eventIdentification; self.activeParticipants = activeParticipants
        self.auditSource = auditSource; self.participantObjects = participantObjects; self.includePatientID = includePatientID
    }
}

public enum DicomAuditPHIMinimizer {
    public static func patientID(_ value: String, includePatientID: Bool = false) -> String {
        if includePatientID { return text(value) }
        if value.hasPrefix("sha256:"), value.count == 71,
           value.dropFirst(7).allSatisfy({ $0.isHexDigit }) { return value }
        return "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func url(_ value: String) -> String {
        guard var parts = URLComponents(string: value), parts.scheme != nil, parts.host != nil else { return "[redacted-url]" }
        parts.user = nil; parts.password = nil; parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string ?? "[redacted-url]"
    }
    public static func error(_ value: String) -> String { String(text(value).prefix(200)) }
    public static func text(_ value: String) -> String {
        // Drop the entire sensitive suffix, including spaced/quoted/multiline credentials and PEM material.
        let pattern = #"(?is)(token\s*=|password\s*=|authorization|-----BEGIN .*PRIVATE KEY-----).*"#
        var result = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>\"']+"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: url(String(result[range]))) }
            }
        }
        return result
    }
    public static func minimize(_ input: DicomAuditEvent) -> DicomAuditEvent {
        var event = input
        func code(_ input: DicomAuditCode) -> DicomAuditCode {
            .init(text(input.code), text(input.codeSystem), text(input.displayName))
        }
        event.eventIdentification.eventID = code(event.eventIdentification.eventID)
        event.eventIdentification.eventTypeCode = event.eventIdentification.eventTypeCode.map(code)
        event.auditSource.auditSourceID = text(event.auditSource.auditSourceID)
        event.auditSource.enterpriseSiteID = event.auditSource.enterpriseSiteID.map(text)
        event.auditSource.typeCode = event.auditSource.typeCode.map(code)
        event.activeParticipants = event.activeParticipants.map {
            var p = $0; p.userID = text(p.userID); p.alternativeUserID = p.alternativeUserID.map(text)
            p.networkAccessPointID = p.networkAccessPointID.map(text); p.roleIDCode = p.roleIDCode.map(code); return p
        }
        event.participantObjects = event.participantObjects.map {
            var object = $0
            object.objectName = nil
            object.objectID = object.typeCode == 1 && object.typeCodeRole == 1
                ? patientID(object.objectID, includePatientID: event.includePatientID) : text(object.objectID)
            object.idTypeCode = code(object.idTypeCode)
            // Raw query datasets and URL paths can contain PHI and credentials. Keep only the URL origin.
            if let query = object.objectQuery, let string = String(data: query, encoding: .utf8),
               URLComponents(string: string)?.host != nil {
                object.objectQuery = Data(text(url(string)).utf8)
            } else { object.objectQuery = nil }
            object.objectDetail = object.objectDetail.compactMap { detail in
                // Names and arbitrary binary payloads do not belong in the minimized audit trail.
                if detail.type.lowercased().contains("name") || detail.type.lowercased().contains("patient") { return nil }
                guard let string = String(data: detail.value, encoding: .utf8) else { return nil }
                return .init(type: text(detail.type), text: error(string))
            }
            return object
        }
        return event
    }
}

/// Builders use the PS3.15 A.5 event codes. Caller-supplied participants carry real process identities;
/// network addresses and AE titles never become authenticated user IDs.
public enum DicomAuditMessages {
    public enum ApplicationActivity: Sendable { case start, stop }
    public enum Authentication: Sendable { case login, logout, failure }
    private static func build(_ code: DicomAuditCode, action: DicomAuditEvent.Action,
                              types: [DicomAuditCode] = [], principal: DicomPrincipal?, context: DicomAccessContext,
                              resources: [DicomResourceRef], outcome: DicomAuditEvent.Outcome,
                              source: DicomAuditEvent.AuditSourceIdentification,
                              participants: [DicomAuditEvent.ActiveParticipant], includePatientID: Bool) -> DicomAuditEvent {
        let objects = resources.map { resource -> DicomAuditEvent.ParticipantObjectIdentification in
            let object = resource.sourceObject
            let study = ([object] + object.ancestry).first { $0.kind == .study }
            if object.kind == .patient {
                return .init(objectID: object.id, typeCode: 1, typeCodeRole: 1,
                             idTypeCode: .init("2", "RFC-3881", "Patient Number"))
            }
            if let study {
                return .init(objectID: study.id, idTypeCode: .init("110180", "Study Instance UID"),
                    objectDetail: object.kind == .instance ? [.init(type: "SOPInstanceUID", text: object.id)] : [])
            }
            // Never label a SOP Instance UID as a SOP Class UID (110181).
            return .init(objectID: object.id, typeCodeRole: object.kind == .workitem ? 20 : 4,
                         idTypeCode: .init("resource-key", "DICOM-Swift", "Resource Key"))
        }
        return DicomAuditPHIMinimizer.minimize(.init(eventIdentification: .init(eventID: code,
            eventActionCode: action, eventDateTime: context.at, eventOutcomeIndicator: outcome, eventTypeCode: types),
            activeParticipants: [.init(userID: principal?.id ?? "anonymous", networkAccessPointID: context.peerAddress,
                networkAccessPointTypeCode: context.peerAddress == nil ? nil : 2)] + participants,
            auditSource: source, participantObjects: objects, includePatientID: includePatientID))
    }
    public static func queryPerformed(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110112", "Query"), action: .execute, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func dicomInstancesAccessed(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110103", "DICOM Instances Accessed"), action: .read, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func beginTransferringInstances(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110102", "Begin Transferring DICOM Instances"), action: .execute, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func instancesTransferred(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110104", "DICOM Instances Transferred"), action: .read, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func dataExport(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110106", "Export"), action: .read, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func dataImport(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110107", "Import"), action: .create, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func applicationActivity(_ activity: ApplicationActivity, principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        var event = build(.init("110100", "Application Activity"), action: .execute,
            types: [activity == .start ? .init("110120", "Application Start") : .init("110121", "Application Stop")], principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
        event.activeParticipants.append(.init(userID: source.auditSourceID, userIsRequestor: false,
            roleIDCode: [.init("110150", "Application")]))
        event.activeParticipants[0].roleIDCode = [.init("110151", "Application Launcher")]
        return DicomAuditPHIMinimizer.minimize(event)
    }
    public static func userAuthentication(_ authentication: Authentication, principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110114", "User Authentication"), action: .execute,
            types: [authentication == .logout ? .init("110123", "Logout") : .init("110122", "Login")],
            principal: principal, context: context, resources: resources,
            outcome: authentication == .failure && outcome == .success ? .seriousFailure : outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func securityAlert(typeCode: DicomAuditCode, principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110113", "Security Alert"), action: .execute, types: [typeCode], principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func patientRecord(action: DicomAuditEvent.Action, principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        build(.init("110110", "Patient Record"), action: action, principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func configurationChanged(principal: DicomPrincipal?, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        securityAlert(typeCode: .init("110129", "Security Configuration"), principal: principal, context: context, resources: resources, outcome: outcome,
            source: source, participants: participants, includePatientID: includePatientID)
    }
    public static func authorizationDecision(_ decision: DicomAuthorizationDecision, principal: DicomPrincipal?,
        operation: DicomAccessOperation, context: DicomAccessContext,
        resources: [DicomResourceRef] = [], outcome: DicomAuditEvent.Outcome = .success,
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift"),
        participants: [DicomAuditEvent.ActiveParticipant] = [], includePatientID: Bool = false) -> DicomAuditEvent {
        var event = dicomInstancesAccessed(principal: principal, context: context, resources: resources,
            outcome: decision.outcome == .deny && outcome == .success ? .seriousFailure : outcome,
            source: source, participants: participants, includePatientID: includePatientID)
        let detail = DicomAuditEvent.ObjectDetail(type: "decision",
            text: "decision=\(decision.outcome.rawValue);reason=\(decision.reason.rawValue)")
        if event.participantObjects.isEmpty {
            event.participantObjects = [.init(objectID: context.requestID, typeCodeRole: 24,
                idTypeCode: .init("10", "RFC-3881", "Search Criteria"))]
        }
        for index in event.participantObjects.indices {
            event.participantObjects[index].objectDetail += [detail,
                .init(type: "operation", text: operation.rawValue),
                .init(type: "auditRequired", text: String(decision.obligations.contains(.auditRequired))),
                .init(type: "policyVersion", text: String(decision.policyVersion))]
        }
        return DicomAuditPHIMinimizer.minimize(event)
    }
    /// Records exposure configuration failures without substituting an authentication or override event type.
    public static func exposureFindings(_ findings: [DicomExposureFinding], principal: DicomPrincipal?,
        context: DicomAccessContext, resources: [DicomResourceRef] = [],
        source: DicomAuditEvent.AuditSourceIdentification = .init(auditSourceID: "DICOM-Swift")) -> DicomAuditEvent {
        var event = securityAlert(typeCode: .init("110129", "Security Configuration"), principal: principal,
            context: context, resources: resources,
            outcome: findings.contains(where: \.isError) ? .seriousFailure : .success, source: source)
        event.participantObjects.append(.init(objectID: context.requestID, typeCodeRole: 13,
            idTypeCode: .init("exposure-policy", "DICOM-Swift", "Exposure Policy"),
            objectDetail: findings.map { .init(type: "exposure", text: $0.code.rawValue) }))
        return DicomAuditPHIMinimizer.minimize(event)
    }

}
