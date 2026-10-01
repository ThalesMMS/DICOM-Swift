import DicomCore
import Foundation
import XCTest

final class DicomWebhookCanonicalJSONTests: XCTestCase {
    func test_sortedKeys_fixedVector() throws {
        struct Value: Encodable { let b = 1; let a = "x" }
        XCTAssertEqual(try string(Value()), #"{"a":"x","b":1}"#)
    }
    func test_unicodeAndEscapes_stableBytes() throws {
        XCTAssertEqual(try string(["text": "ação/雪\n\"\\"]), #"{"text":"ação/雪\n\"\\"}"#)
    }
    func test_date_wholeSecondsUTC() throws {
        XCTAssertEqual(try string(["date": Date(timeIntervalSince1970: 1_700_000_000.99)]),
                       #"{"date":"2023-11-14T22:13:20Z"}"#)
    }
    func test_nestedArraysAndObjectNulls_preserveArrayPositions() throws {
        struct Value: Encodable {
            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(["z": [nil, 1], "a": nil] as [String: [Int?]?])
            }
        }
        XCTAssertEqual(try string(Value()), #"{"z":[null,1]}"#)
        XCTAssertEqual(try string([["b": 2, "a": 1]]), #"[{"a":1,"b":2}]"#)
    }
    func test_exponents_plainDecimals() throws {
        XCTAssertEqual(try string([1e-7, 1e20]), "[0.0000001,100000000000000000000]")
    }
    func test_phi_requiresAuthorizationAndReportsInclusion() throws {
        XCTAssertThrowsError(try event(phi: .init(patientID: "synthetic"))) {
            XCTAssertEqual($0 as? DicomWebhookEventError, .phiNotAuthorized)
        }
        XCTAssertThrowsError(try DicomWebhookPHIAuthorization(token: " ", reason: "test"))
        XCTAssertThrowsError(try DicomWebhookPHIAuthorization(token: "test", reason: ""))
        let allowed = try event(phi: .init(patientID: "synthetic"),
                                authorization: .init(token: "explicit", reason: "test"))
        let decoder = JSONDecoder()
        let authorizedBytes = try DicomWebhookCanonicalJSON.encode(allowed)
        XCTAssertThrowsError(try decoder.decode(DicomWebhookEvent.self, from: authorizedBytes))
        decoder.userInfo[DicomWebhookEvent.phiAuthorizationUserInfoKey] =
            try DicomWebhookPHIAuthorization(token: "explicit", reason: "test")
        XCTAssertEqual(try decoder.decode(DicomWebhookEvent.self, from: authorizedBytes), allowed)
        XCTAssertTrue(allowed.phiIncluded)
        XCTAssertTrue(try string(allowed).contains(#""phi":{"patientID":"synthetic"}"#))
        let minimal = try event()
        XCTAssertFalse(minimal.phiIncluded)
        XCTAssertFalse(try string(minimal).contains("phi"))
        XCTAssertEqual(try JSONDecoder().decode(DicomWebhookEvent.self,
            from: DicomWebhookCanonicalJSON.encode(minimal)), minimal)
    }
    private func string(_ value: some Encodable) throws -> String {
        String(decoding: try DicomWebhookCanonicalJSON.encode(value), as: UTF8.self)
    }
    private func event(phi: DicomWebhookEvent.PHI? = nil,
                       authorization: DicomWebhookPHIAuthorization? = nil) throws -> DicomWebhookEvent {
        try .init(eventID: "stable", kind: "received", occurredAt: Date(timeIntervalSince1970: 0.8),
                  subject: .init(studyInstanceUID: "1.2.3"), phi: phi, authorization: authorization, source: "test")
    }
}
