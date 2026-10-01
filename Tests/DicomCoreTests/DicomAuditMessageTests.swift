import Foundation
import XCTest
@testable import DicomCore
#if canImport(FoundationXML)
import FoundationXML
#endif

final class DicomAuditMessageTests: XCTestCase {
    static let context = DicomAccessContext(protocol: .local, requestID: "request", at: Date(timeIntervalSince1970: 0))
    static let resources = [DicomResourceRef(kind: .study, id: "1.2.3")]
    static func events() -> [(String, DicomAuditEvent)] {
        let c = context; let r = resources
        return [
            ("application-start", DicomAuditMessages.applicationActivity(.start, principal: nil, context: c, resources: r)),
            ("application-stop", DicomAuditMessages.applicationActivity(.stop, principal: nil, context: c, resources: r)),
            ("login", DicomAuditMessages.userAuthentication(.login, principal: nil, context: c, resources: r)),
            ("logout", DicomAuditMessages.userAuthentication(.logout, principal: nil, context: c, resources: r)),
            ("authentication-failure", DicomAuditMessages.userAuthentication(.failure, principal: nil, context: c, resources: r)),
            ("query", DicomAuditMessages.queryPerformed(principal: nil, context: c, resources: r)),
            ("access", DicomAuditMessages.dicomInstancesAccessed(principal: nil, context: c, resources: r)),
            ("begin-transfer", DicomAuditMessages.beginTransferringInstances(principal: nil, context: c, resources: r)),
            ("transfer", DicomAuditMessages.instancesTransferred(principal: nil, context: c, resources: r)),
            ("export", DicomAuditMessages.dataExport(principal: nil, context: c, resources: r)),
            ("import", DicomAuditMessages.dataImport(principal: nil, context: c, resources: r)),
            ("security-alert", DicomAuditMessages.securityAlert(typeCode: .nodeAuthentication, principal: nil, context: c, resources: r)),
            ("patient-record", DicomAuditMessages.patientRecord(action: .read, principal: nil, context: c, resources: r)),
            ("configuration", DicomAuditMessages.configurationChanged(principal: nil, context: c, resources: r)),
            ("authorization-deny", DicomAuditMessages.authorizationDecision(.init(outcome: .deny, reason: .scopeMissing,
                policyVersion: 1, evaluatedAt: c.at), principal: nil, operation: .export, context: c, resources: r))
        ]
    }
    func test_eachBuilder_matchesGoldenXMLAndRoundTrips() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Audit")
        for (name, event) in Self.events() {
            let xml = DicomAuditMessageXML.serialize(event)
            let golden = try String(contentsOf: directory.appendingPathComponent(name + ".xml"), encoding: .utf8)
            XCTAssertEqual(xml, golden, name)
            XCTAssertTrue(XMLParser(data: Data(xml.utf8)).parse(), name)
            XCTAssertEqual(try DicomAuditMessageXML.parse(Data(xml.utf8)), event, name)
            XCTAssertEqual(try DicomAuditMessageJSON.decode(DicomAuditMessageJSON.encode(event)), event)
        }
    }
    func test_authorizationDecision_alwaysIncludesOperationAndPolicyVersion() {
        for resources in [[], Self.resources] {
            let event = DicomAuditMessages.authorizationDecision(
                .init(outcome: .allow, reason: .allowed, policyVersion: 17, evaluatedAt: Self.context.at),
                principal: .anonymous, operation: .query, context: Self.context, resources: resources)
            XCTAssertFalse(event.participantObjects.isEmpty)
            for object in event.participantObjects {
                let details = Dictionary(uniqueKeysWithValues: object.objectDetail.map {
                    ($0.type, String(decoding: $0.value, as: UTF8.self))
                })
                XCTAssertEqual(details["operation"], "query")
                XCTAssertEqual(details["policyVersion"], "17")
                XCTAssertEqual(details["decision"], "decision=allow;reason=allowed")
            }
        }
    }

    func test_minimization_removesNamesSecretsQueriesAndHashesPatientID() throws {
        let principal = DicomPrincipal(id: "opaque-user", kind: .localUser, source: .oidc, displayHint: "Patient Name",
            sessionID: "session", authenticatedAt: Self.context.at, policyVersion: 1)
        var event = DicomAuditMessages.patientRecord(action: .read, principal: principal, context: Self.context,
            resources: [.init(kind: .patient, id: "patient-123")])
        event.participantObjects[0].objectName = "Patient Name"
        event.participantObjects[0].objectQuery = Data("https://user:secret@example.org/query?PatientName=Smith#private".utf8)
        event.participantObjects[0].objectDetail = [.init(type: "error", text: "error token=super-secret password=other"),
            .init(type: "error2", text: "Authorization: Bearer super-secret"), .init(type: "patientName", text: "Patient Name")]
        let xml = DicomAuditMessageXML.serialize(event)
        let json = String(decoding: try DicomAuditMessageJSON.encode(event), as: UTF8.self)
        for value in ["Patient Name", "patient-123", "super-secret", "password=other"] {
            XCTAssertFalse(xml.contains(value)); XCTAssertFalse(json.contains(value))
        }
        let parsed = try DicomAuditMessageXML.parse(Data(xml.utf8))
        XCTAssertTrue(parsed.participantObjects[0].objectID.hasPrefix("sha256:"))
        XCTAssertEqual(String(data: try XCTUnwrap(parsed.participantObjects[0].objectQuery), encoding: .utf8), "https://example.org")
        XCTAssertEqual(String(decoding: parsed.participantObjects[0].objectDetail[0].value, as: UTF8.self), "error [redacted]")
        XCTAssertEqual(parsed.activeParticipants[0].userID, "opaque-user")
        XCTAssertEqual(DicomAuditPHIMinimizer.error(String(repeating: "a", count: 300)).count, 200)
        XCTAssertEqual(DicomAuditPHIMinimizer.patientID("abc"), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let explicit = DicomAuditMessages.patientRecord(action: .read, principal: nil, context: Self.context,
            resources: [.init(kind: .patient, id: "patient-123")], includePatientID: true)
        XCTAssertTrue(DicomAuditMessageXML.serialize(explicit).contains("patient-123"))
    }
    func test_minimization_removesSensitiveURLPathsFromSerializedQueriesAndDetails() throws {
        let origin = "https://example.org:8443"
        let expected = Data(origin.utf8)
        for path in ["/patients/synthetic-patient/session/synthetic-secret", "/patients/%73ynthetic-patient;key=%73ynthetic-secret"] {
            let url = "https://caller:secret@example.org:8443\(path)?patient=synthetic-patient#synthetic-secret"
            var event = DicomAuditMessages.queryPerformed(principal: nil, context: Self.context, resources: Self.resources)
            event.participantObjects[0].objectQuery = Data(url.utf8)
            event.participantObjects[0].objectDetail = [.init(type: "endpoint", text: url)]
            let xml = DicomAuditMessageXML.serialize(event)
            XCTAssertTrue(xml.contains("<ParticipantObjectQuery>\(expected.base64EncodedString())</ParticipantObjectQuery>"))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(DicomAuditEvent.self, from: DicomAuditMessageJSON.encode(event))
            XCTAssertEqual(decoded.participantObjects[0].objectQuery, expected)
            XCTAssertEqual(decoded.participantObjects[0].objectDetail[0].value, expected)
            XCTAssertEqual(DicomAuditPHIMinimizer.text("request \(url)"), "request \(origin)")
        }
    }
    func test_xmlEscapingAndStructuralRejection() throws {
        var event = Self.events()[0].1
        event.auditSource.auditSourceID = "a<&\"'\nΩ"
        let xml = DicomAuditMessageXML.serialize(event)
        XCTAssertEqual(try DicomAuditMessageXML.parse(Data(xml.utf8)), event)
        for bad in ["<AuditMessage/>", "<!DOCTYPE AuditMessage [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><AuditMessage>&e;</AuditMessage>",
                    xml.replacingOccurrences(of: "EventOutcomeIndicator=\"0\"", with: "EventOutcomeIndicator=\"7\""),
                    xml.replacingOccurrences(of: "UserIsRequestor=\"true\"", with: "UserIsRequestor=\"yes\""),
                    xml.replacingOccurrences(of: "<EventID ", with: "<Unknown ")] {
            XCTAssertThrowsError(try DicomAuditMessageXML.validate(Data(bad.utf8)))
        }
    }
    func test_denialUsesAccessEvent_notUnrelatedSecurityAlertCode() {
        let event = Self.events().last!.1
        XCTAssertEqual(event.eventIdentification.eventID.code, "110103")
        XCTAssertEqual(event.eventIdentification.eventOutcomeIndicator, .seriousFailure)
        XCTAssertEqual(String(decoding: event.participantObjects[0].objectDetail[0].value, as: UTF8.self), "decision=deny;reason=scopeMissing")
    }
    func test_exposureFindings_buildSecurityConfigurationFailure() {
        let event = DicomAuditMessages.exposureFindings([.init(code: .tlsRequired)], principal: nil, context: Self.context)
        XCTAssertEqual(event.eventIdentification.eventID.code, "110113")
        XCTAssertEqual(event.eventIdentification.eventTypeCode.first?.code, "110129")
        XCTAssertEqual(event.eventIdentification.eventOutcomeIndicator, .seriousFailure)
        XCTAssertEqual(String(decoding: event.participantObjects[0].objectDetail[0].value, as: UTF8.self), "tlsRequired")
    }

}
