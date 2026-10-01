import Foundation
import XCTest
@testable import DicomCore

final class DicomLDAPWireTests: XCTestCase, @unchecked Sendable {
    private func hex(_ text: String) -> Data {
        let chars = Array(text)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }

    func test_rfcMessages_parseBindEntryAndDone() throws {
        XCTAssertEqual(try DicomLDAPWire.parse(hex("300c02010161070a010004000400"), expectedID: 1, maximum: 256), .bind)
        XCTAssertEqual(try DicomLDAPWire.parse(hex("300c02010265070a010004000400"), expectedID: 2, maximum: 256), .done)
        let entry = hex("301a020102641504057569643d61300c300a04037569643103040161")
        XCTAssertEqual(try DicomLDAPWire.parse(entry, expectedID: 2, maximum: 256),
            .entry(.init(dn: "uid=a", attributes: ["uid": ["a"]])))
    }

    func test_fragmentedAndCoalescedFrames_reportExactLength() throws {
        let frame = hex("300c02010161070a010004000400")
        for count in 0..<2 { XCTAssertNil(try DicomLDAPWire.frameLength(frame.prefix(count), maximum: 256)) }
        for count in 2...frame.count {
            XCTAssertEqual(try DicomLDAPWire.frameLength(frame.prefix(count), maximum: 256), frame.count)
        }
        XCTAssertEqual(try DicomLDAPWire.frameLength(frame + frame, maximum: 256), frame.count)
        for count in 0..<frame.count {
            XCTAssertThrowsError(try DicomLDAPWire.parse(frame.prefix(count), expectedID: 1, maximum: 256))
        }
    }

    func test_oversizedIndefiniteNegativeAndMismatchedMessages_refused() throws {
        for bytes in ["3080", "30850000000001", "30847fffffff", "3100", "300b02008061070a010004000400",
                      "300c02010261070a010004000400", "300c02010161070a018004000400"] {
            XCTAssertThrowsError(try DicomLDAPWire.parse(hex(bytes), expectedID: 1, maximum: 256), bytes)
        }
        XCTAssertThrowsError(try DicomLDAPWire.frameLength(hex("30847fffffff"), maximum: 256)) {
            XCTAssertEqual($0 as? DicomLDAPError, .responseLimit)
        }
    }

    func test_referralsControlsAndSASL_refused() throws {
        for bytes in ["30050201017300", "300e02010161070a010004000400a000", "300e02010161090a0100040004008700"] {
            XCTAssertThrowsError(try DicomLDAPWire.parse(hex(bytes), expectedID: 1, maximum: 256)) {
                XCTAssertEqual($0 as? DicomLDAPError, .unsupportedResponse)
            }
        }
    }

    func test_failureCode_discardsSensitiveServerDiagnostic() throws {
        let diagnostic = "password=synthetic-marker"
        let response = DicomLDAPWire.message(1, operation: DicomLDAPWire.field(0x61,
            DicomLDAPWire.integer(49, tag: 10) + DicomLDAPWire.text("") + DicomLDAPWire.text(diagnostic)))
        XCTAssertThrowsError(try DicomLDAPWire.parse(response, expectedID: 1, maximum: 256)) {
            XCTAssertEqual($0 as? DicomLDAPError, .invalidCredentials)
            XCTAssertFalse(String(describing: $0).contains("synthetic-marker"))
        }
    }

    func test_equalityFilter_escapesTextAndPreservesWireOctets() throws {
        let value = "a*)(uid=*)\\\u{0}é"
        let filter = try DicomLDAPEqualityFilter(attribute: "uid", value: value)
        XCTAssertEqual(filter.stringRepresentation, "(uid=a\\2a\\29\\28uid=\\2a\\29\\5c\\00\\c3\\a9)")
        let request = DicomLDAPWire.search(2, base: "dc=test", filter: filter, attributes: ["uid"], limit: 2, seconds: 1)
        XCTAssertNotNil(request.range(of: Data(DicomLDAPWire.field(0xa3,
            DicomLDAPWire.text("uid") + DicomLDAPWire.text(value)))))
        for attribute in ["", "uid)(objectClass", "uid;binary", "1.2.3"] {
            XCTAssertThrowsError(try DicomLDAPEqualityFilter(attribute: attribute, value: "a"))
        }
    }

    func test_configuration_plaintextIsNumericLoopbackOnly() throws {
        for host in ["127.0.0.1", "127.0.0.2", "::1"] {
            try DicomLDAPConfiguration(host: host, transport: .loopbackPlaintext,
                userBaseDN: "dc=test", groupBaseDN: "dc=test").validate()
        }
        for host in ["localhost", "directory.example", "192.168.1.2", "127.0.0.1.example", "user@host"] {
            XCTAssertThrowsError(try DicomLDAPConfiguration(host: host, transport: .loopbackPlaintext,
                userBaseDN: "dc=test", groupBaseDN: "dc=test").validate())
        }
        var config = DicomLDAPConfiguration(host: "127.0.0.1", transport: .loopbackPlaintext,
            userBaseDN: "dc=test", groupBaseDN: "dc=test")
        config.trustStorePath = "/unused"
        XCTAssertThrowsError(try config.validate())
        config.transport = .ldaps; config.timeout = .infinity
        XCTAssertThrowsError(try config.validate())
        config.timeout = 1; config.maximumGroups = 257
        XCTAssertThrowsError(try config.validate())
    }

    func test_groupPolicy_requiresMappingAndBoundedExpiry() throws {
        let now = Date()
        let identity = DicomLDAPIdentity(distinguishedName: "uid=a", username: "a", groups: ["cn=readers"])
        XCTAssertNil(DicomLDAPGroupPolicy(groups: [:], policyVersion: 1).principal(for: identity, at: now))
        for lifetime in [0, -1, .infinity, 3601] {
            XCTAssertNil(DicomLDAPGroupPolicy(groups: ["cn=readers": .init(scopes: ["export"])],
                policyVersion: 1, sessionLifetime: lifetime).principal(for: identity, at: now))
        }
        let policy = DicomLDAPGroupPolicy(groups: ["cn=readers": .init(scopes: ["export"], roles: ["operator"])],
            policyVersion: 4, sessionLifetime: 60)
        let principal = try XCTUnwrap(policy.principal(for: identity, at: now))
        XCTAssertEqual(principal.source, .ldap); XCTAssertEqual(principal.roles, ["operator"])
        XCTAssertEqual(principal.scopes, ["export"]); XCTAssertEqual(principal.expiresAt, now.addingTimeInterval(60))
        XCTAssertEqual(try JSONDecoder().decode(DicomPrincipal.self, from: JSONEncoder().encode(principal)), principal)
    }
}
