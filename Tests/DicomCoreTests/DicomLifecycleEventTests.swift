import XCTest
@testable import DicomCore

final class DicomLifecycleEventTests: XCTestCase {
    func test_sameTransition_hasDeterministicIDAndRoundTrips() throws {
        let a = try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "123")
        let b = try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "123", occurredAt: .distantPast)
        XCTAssertEqual(a.eventID, b.eventID)
        XCTAssertEqual(a.eventID, String(DicomStudyPackageManifest.digest(Data("ingest|123|received".utf8)).prefix(32)))
        XCTAssertEqual(a.eventID.count, 32)
        XCTAssertNotEqual(a.eventID, try DicomLifecycleEvent(kind: .available, sourceKind: "ingest", sourceRef: "123").eventID)
        XCTAssertEqual(a, try JSONDecoder().decode(DicomLifecycleEvent.self, from: JSONEncoder().encode(a)))
    }

    func test_attributeBounds_enforcedAtConstructionAndDecode() throws {
        let maximum = Dictionary(uniqueKeysWithValues: (0..<16).map { (String($0), String(repeating: "x", count: 256)) })
        let event = try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "id", attributes: maximum)
        XCTAssertThrowsError(try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "id",
            attributes: maximum.merging(["extra": "x"]) { $1 }))
        XCTAssertThrowsError(try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "id",
            attributes: ["key": String(repeating: "é", count: 129)]))
        XCTAssertThrowsError(try DicomLifecycleEvent(kind: .received, sourceKind: "ingest", sourceRef: "id",
            attributes: [String(repeating: "x", count: 257): "value"]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        json["attributes"] = ["x": String(repeating: "x", count: 257)]
        XCTAssertThrowsError(try JSONDecoder().decode(DicomLifecycleEvent.self, from: JSONSerialization.data(withJSONObject: json)))
        json["attributes"] = [:]
        json["eventID"] = "forged"
        XCTAssertThrowsError(try JSONDecoder().decode(DicomLifecycleEvent.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func test_webhookMapping_defaultsToNoPHIAndRequiresAuthorization() throws {
        for kind in [DicomLifecycleEvent.Kind.received, .complete, .available, .archived, .error] {
            let event = try DicomLifecycleEvent(kind: kind, subject: .init(studyInstanceUID: "1.2", objectCount: 3),
                sourceKind: "host", sourceRef: "id")
            let webhook = try event.webhookEvent(sequence: 7, source: "host")
            XCTAssertNil(webhook.phi)
            XCTAssertEqual(webhook.kind, kind.rawValue)
            XCTAssertEqual(webhook.subject, event.subject)
            XCTAssertEqual(webhook.eventID, event.eventID)
            XCTAssertEqual(webhook.sequence, 7)
            XCTAssertThrowsError(try event.webhookEvent(source: "host", phi: .init(patientID: "synthetic")))
            let authorized = try event.webhookEvent(source: "host", phi: .init(patientID: "synthetic"),
                authorization: .init(token: "test", reason: "test"))
            XCTAssertTrue(authorized.phiIncluded)
        }
    }
}
