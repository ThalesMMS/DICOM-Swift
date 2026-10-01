import CryptoKit
import Foundation
import HL7v3CDA
import XCTest
@testable import HL7v3Transport

final class SOAPEnvelopeTests: XCTestCase {
    private func payload() -> HL7v3CDA.XMLNode {
        HL7v3CDA.XMLNode("PRPA_IN201301UV02", namespaceURI: CDANamespace.hl7, children: [
            HL7v3CDA.XMLNode("id", attributes: ["root": "2.25.2362.1"]),
            HL7v3CDA.XMLNode("creationTime", attributes: ["value": "20260912"])
        ])
    }

    func test_roundTrip_bothVersionsPreserveHeaderAndPayload() throws {
        for version in SOAPVersion.allCases {
            let header = HL7v3CDA.XMLNode("Action", namespaceURI: "http://www.w3.org/2005/08/addressing", prefix: "wsa", text: "urn:hl7-org:v3:PRPA_IN201301UV02")
            let envelope = SOAPEnvelope(version: version, headerElements: [header], body: payload())
            let data = try envelope.serialize()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("xmlns:soap=\"\(version.namespace)\""), version.rawValue)
            let parsed = try SOAPEnvelope.parse(data)
            XCTAssertEqual(parsed.version, version)
            XCTAssertEqual(parsed.headerElements.count, 1)
            XCTAssertEqual(parsed.headerElements.first?.textContent, "urn:hl7-org:v3:PRPA_IN201301UV02")
            XCTAssertEqual(parsed.body.name.localName, "PRPA_IN201301UV02")
            XCTAssertEqual(parsed.body.first("id")?[attribute: "root"], "2.25.2362.1")
            XCTAssertNil(parsed.fault)
        }
    }

    func test_fault_serializesAndParsesInBothVersions() throws {
        for version in SOAPVersion.allCases {
            let fault = SOAPFault(code: version == .v1_1 ? "soap:Server" : "soap:Receiver", reason: "synthetic",
                                  detail: HL7v3CDA.XMLNode("detailCode", namespaceURI: "", text: "E1"))
            let envelope = SOAPEnvelope(version: version, body: fault.node(version: version))
            let parsed = try SOAPEnvelope.parse(try envelope.serialize())
            XCTAssertEqual(parsed.fault?.code, fault.code, version.rawValue)
            XCTAssertEqual(parsed.fault?.reason, "synthetic")
            XCTAssertEqual(parsed.fault?.detail?.textContent, "E1")
        }
    }

    func test_parse_rejectsNonEnvelopeMissingBodyAndMultiplePayloads() throws {
        let ns = SOAPVersion.v1_2.namespace
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data("<a/>".utf8))) { XCTAssertEqual($0 as? SOAPEnvelopeError, .notAnEnvelope) }
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data("<s:Envelope xmlns:s=\"\(ns)\"><s:Header/></s:Envelope>".utf8))) {
            XCTAssertEqual($0 as? SOAPEnvelopeError, .missingBody)
        }
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data("<s:Envelope xmlns:s=\"\(ns)\"><s:Body><a/><b/></s:Body></s:Envelope>".utf8))) {
            XCTAssertEqual($0 as? SOAPEnvelopeError, .bodyPayloadCount(2))
        }
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data("<s:Envelope xmlns:s=\"\(ns)\"><s:Body><s:Fault/></s:Body></s:Envelope>".utf8))) {
            XCTAssertEqual($0 as? SOAPEnvelopeError, .malformedFault)
        }
    }

    func test_parse_refusesDTDAndDepthBombs() {
        let ns = SOAPVersion.v1_1.namespace
        let dtd = "<!DOCTYPE x [<!ENTITY a \"aaaa\">]><s:Envelope xmlns:s=\"\(ns)\"><s:Body><a>&a;</a></s:Body></s:Envelope>"
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data(dtd.utf8))) { XCTAssertEqual($0 as? CDAError, .forbiddenDTD) }
        let deep = "<s:Envelope xmlns:s=\"\(ns)\"><s:Body>" + String(repeating: "<d>", count: 80) +
            String(repeating: "</d>", count: 80) + "</s:Body></s:Envelope>"
        XCTAssertThrowsError(try SOAPEnvelope.parse(Data(deep.utf8))) { XCTAssertEqual($0 as? CDAError, .depthLimit) }
    }

    func test_contentType_carriesActionOnlyInSOAP12() {
        XCTAssertEqual(SOAPVersion.v1_1.contentType(action: "urn:x"), "text/xml; charset=utf-8")
        XCTAssertEqual(SOAPVersion.v1_2.contentType(action: nil), "application/soap+xml; charset=utf-8")
        XCTAssertEqual(SOAPVersion.v1_2.contentType(action: "urn:x\""), "application/soap+xml; charset=utf-8; action=\"urn:x\"")
    }
}

final class WSSecurityTests: XCTestCase {
    func test_digest_matchesProfileFormula() {
        let nonce = Data([0x01, 0x02, 0x03, 0x04])
        let created = "2026-09-12T00:00:00Z"
        var input = nonce
        input.append(Data(created.utf8))
        input.append(Data("secret".utf8))
        let expected = Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
        XCTAssertEqual(WSSecurityUsernameToken.digest(nonce: nonce, created: created, password: "secret"), expected)
    }

    func test_header_serializesTokensWithMustUnderstandAndUTCTimestamps() throws {
        let created = Date(timeIntervalSince1970: 1_789_000_000)
        let header = WSSecurityHeader(
            usernameToken: .init(username: "svc", password: "secret", passwordType: .digest, nonce: Data([9, 9, 9, 9])),
            timestamp: .init(created: created, lifetime: 60),
            binaryToken: .init(value: "AAEC"))
        let node = header.node(version: .v1_2, now: created)
        let envelope = SOAPEnvelope(version: .v1_2, headerElements: [node], body: HL7v3CDA.XMLNode("noop", namespaceURI: ""))
        let text = String(decoding: try envelope.serialize(), as: UTF8.self)
        XCTAssertTrue(text.contains("soap:mustUnderstand=\"true\""))
        XCTAssertTrue(text.contains("<wsu:Created>2026-09-10T00:26:40Z</wsu:Created>"))
        XCTAssertTrue(text.contains("<wsu:Expires>2026-09-10T00:27:40Z</wsu:Expires>"))
        XCTAssertTrue(text.contains("<wsse:Nonce EncodingType=\"\(WSSecurityNamespace.base64Binary)\">CQkJCQ==</wsse:Nonce>"))
        XCTAssertTrue(text.contains("Type=\"\(WSSecurityNamespace.passwordDigest)\""))
        XCTAssertFalse(text.contains("secret"), "digest mode never serializes the clear password")
        XCTAssertTrue(text.contains("ValueType=\"\(WSSecurityNamespace.x509v3)\""))
        let parsed = try SOAPEnvelope.parse(Data(text.utf8))
        XCTAssertEqual(parsed.headerElements.first?.name.namespaceURI, WSSecurityNamespace.wsse)
        let v11 = String(decoding: try SOAPEnvelope(version: .v1_1, headerElements: [header.node(version: .v1_1, now: created)],
                                                    body: HL7v3CDA.XMLNode("noop", namespaceURI: "")).serialize(), as: UTF8.self)
        XCTAssertTrue(v11.contains("soap:mustUnderstand=\"1\""))
    }

    func test_textPassword_isSerializedInClearOnlyWhenRequested() throws {
        let header = WSSecurityHeader(usernameToken: .init(username: "svc", password: "clear", passwordType: .text), mustUnderstand: false)
        let text = String(decoding: try XMLSerializer().serialize(header.node(version: .v1_2)), as: UTF8.self)
        XCTAssertTrue(text.contains("Type=\"\(WSSecurityNamespace.passwordText)\">clear</wsse:Password>"))
        XCTAssertFalse(text.contains("mustUnderstand"))
        XCTAssertFalse(text.contains("Nonce"))
    }
}

final class HL7v3TransportPolicyTests: XCTestCase {
    func test_validate_requiresHTTPSUnlessHostAllowlisted() throws {
        let policy = HL7v3TransportPolicy()
        XCTAssertNoThrow(try policy.validate(URL(string: "https://example.test/soap")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "http://example.test/soap")!)) {
            XCTAssertEqual($0 as? HL7v3TransportError, .insecureEndpoint)
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "ftp://example.test/soap")!)) {
            XCTAssertEqual($0 as? HL7v3TransportError, .invalidEndpoint)
        }
        var lab = policy
        lab.allowInsecureForHosts = ["127.0.0.1"]
        XCTAssertNoThrow(try lab.validate(URL(string: "http://127.0.0.1:1/soap")!))
        XCTAssertThrowsError(try lab.validate(URL(string: "http://example.test/soap")!))
        var broken = policy
        broken.timeout = 0
        XCTAssertThrowsError(try broken.validate(URL(string: "https://example.test/")!)) {
            XCTAssertEqual($0 as? HL7v3TransportError, .invalidConfiguration("limits"))
        }
    }

    func test_retryAdvice_onlyBeforeSendFailuresAreSafe() {
        XCTAssertEqual(HL7v3RetryAdvice.classify(.rejected(.network, status: nil)), .safeToRetry)
        XCTAssertEqual(HL7v3RetryAdvice.classify(.rejected(.status, status: 503)), .doNotRetry)
        XCTAssertEqual(HL7v3RetryAdvice.classify(.uncertain("timeout")), .requiresReconciliation)
        XCTAssertEqual(HL7v3RetryAdvice.classify(.fault(.init(code: "x", reason: "y"), status: 500)), .doNotRetry)
    }

    func test_pinnedRoots_parsesPEMBlocks() throws {
        let material = try HL7v3TLSTestMaterial.write()
        defer { material.remove() }
        guard case .pinnedRoots(let roots) = try HL7v3TransportTrust.pinnedRoots(pemFileAtPath: material.caCertificatePath) else {
            return XCTFail("expected pinned roots")
        }
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].first, 0x30, "DER SEQUENCE")
        XCTAssertThrowsError(try HL7v3TransportTrust.pinnedRoots(pemFileAtPath: material.serverPrivateKeyPath))
    }
}
