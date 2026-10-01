import Foundation
import XCTest
@testable import HL7v3CDA

final class HL7v3DataTypeTests: CDATestCase {
    func test_identifierRoots_requireSupportedSyntax() throws {
        for root in ["2.25.2362", "1.2.840.10008", "550e8400-e29b-41d4-a716-446655440000", "HL7-Reserved-1"] {
            let identifier = try II(root: root, extension: "local")
            XCTAssertEqual(identifier.root, root)
            try roundTrip(identifier)
        }
        for root in ["", " ", "not an identifier", "1.02.3", "3.1.2", "1.2.", "urn:oid:1.2.3", "2.25.2362\n",
                     "550e8400-e29b-41d4-a716-44665544000g"] {
            XCTAssertThrowsError(try II(root: root), root) {
                XCTAssertEqual($0 as? CDAError, .invalidDataType("II"))
            }
        }
    }

    func test_codedSimpleValues_rejectProhibitedMetadata() throws {
        for attribute in ["codeSystem", "codeSystemName", "codeSystemVersion", "displayName", "originalText"] {
            for attributes in [["code": "N", attribute: "invalid"], ["nullFlavor": "UNK", attribute: "invalid"]] {
                XCTAssertThrowsError(try CS(node: Node("value", attributes: attributes)), attribute) {
                    XCTAssertEqual($0 as? CDAError, .invalidDataType("CS"))
                }
            }
        }
        XCTAssertThrowsError(try CS(node: Node("value", attributes: ["code": "N"], children: [Node("originalText", text: "invalid")])))
        for child in [Node("translation", attributes: ["code": "other"]), Node("qualifier")] {
            XCTAssertThrowsError(try CS(node: Node("value", attributes: ["code": "N"], children: [child])))
        }
        XCTAssertEqual(try CS(code: "N").code, "N")
        XCTAssertEqual(CS(nullFlavor: .UNK).nullFlavor, .UNK)
    }

    func test_csWithoutCodeOrNullFlavor_isRejected() throws {
        XCTAssertThrowsError(try CS(node: Node("value")))
        XCTAssertThrowsError(try CS(code: ""))
        XCTAssertEqual(try CS(code: "N").code, "N")
        XCTAssertEqual(CS(nullFlavor: .UNK).nullFlavor, .UNK)
    }

    private func roundTrip<T: HL7DataType>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let node = value.xml(named: "value", anyTyped: true)
        let parsed = try SafeXMLParser().parse(XMLSerializer().serialize(node))
        XCTAssertEqual(try T(node: parsed), try T(node: node), file: file, line: line)
    }
    func test_eachDataType_roundTripsPayloadAndNullFlavor() throws {
        try roundTrip(II(root: "2.25.2362", extension: "test", assigningAuthorityName: "Test"))
        try roundTrip(CD(code: "test", codeSystem: "2.25.2362", codeSystemName: "Test", codeSystemVersion: "1",
                         displayName: "Synthetic", originalText: ED(text: "Test"), translations: [CD(code: "other")],
                         qualifiers: [Node("qualifier", children: [Node("name", attributes: ["code": "test"]), Node("value", attributes: ["code": "test"])])]))
        try roundTrip(CE(code: "test")); try roundTrip(CS(code: "test")); try roundTrip(CV(code: "test"))
        try roundTrip(ST("A < B & C"))
        try roundTrip(ED(text: "VGVzdA==", mediaType: "text/plain", representation: .B64, compression: "DF"))
        try roundTrip(TS("20260912123456.123-0300"))
        try roundTrip(IVL_TS(low: TS("2026"), high: TS("2027")))
        try roundTrip(PIVL_TS(phase: IVL_TS(low: TS("20260912")), period: PQ(value: "8", unit: "h")))
        try roundTrip(PQ(value: "1.250", unit: "mg/dL"))
        try roundTrip(IVL_PQ(width: PQ(value: "1", unit: "mg"), center: PQ(value: "2", unit: "mg")))
        try roundTrip(INT("42")); try roundTrip(REAL("1.25")); try roundTrip(BL(true))
        try roundTrip(TEL(value: "mailto:test@example.invalid", use: ["WP"]))
        try roundTrip(AD(parts: [ADXP(part: "city", text: "Test")]))
        try roundTrip(ADXP(part: "streetAddressLine", text: "1 Test Street"))
        try roundTrip(EN(parts: [.init(part: "given", text: "Test")]))
        try roundTrip(PN(parts: [.init(part: "given", text: "Test"), .init(part: "family", text: "Testsson")]))
        try roundTrip(ON(parts: [.init(part: "delimiter", text: "Test")]))
        for flavor in NullFlavor.allCases {
            try roundTrip(II(nullFlavor: flavor)); try roundTrip(CD(nullFlavor: flavor))
            try roundTrip(CE(nullFlavor: flavor)); try roundTrip(CS(nullFlavor: flavor)); try roundTrip(CV(nullFlavor: flavor))
            try roundTrip(ST(nullFlavor: flavor)); try roundTrip(ED(nullFlavor: flavor)); try roundTrip(TS(nullFlavor: flavor))
            try roundTrip(IVL_TS(nullFlavor: flavor)); try roundTrip(PIVL_TS(nullFlavor: flavor))
            try roundTrip(PQ(nullFlavor: flavor)); try roundTrip(IVL_PQ(nullFlavor: flavor))
            try roundTrip(INT(nullFlavor: flavor)); try roundTrip(REAL(nullFlavor: flavor)); try roundTrip(BL(nullFlavor: flavor))
            try roundTrip(TEL(nullFlavor: flavor)); try roundTrip(AD(nullFlavor: flavor)); try roundTrip(ADXP(nullFlavor: flavor))
            try roundTrip(EN(nullFlavor: flavor)); try roundTrip(PN(nullFlavor: flavor)); try roundTrip(ON(nullFlavor: flavor))
        }
    }
    func test_nullFlavorAndPayload_isRejected() {
        for type in CDAInspection.dataTypes {
            XCTAssertThrowsError(try HL7TypeValidation.validate(Node("value", attributes: ["nullFlavor": "UNK", "value": "1"]), type: type))
            XCTAssertThrowsError(try HL7TypeValidation.validate(Node("value", attributes: ["nullFlavor": "UNK"], text: "test"), type: type))
        }
        XCTAssertThrowsError(try II(node: Node("id", attributes: ["nullFlavor": "UNK", "root": "2.25.2362"])))
        XCTAssertThrowsError(try PN(node: Node("name", attributes: ["nullFlavor": "UNK"], children: [Node("given", text: "Test")])))
    }

    func test_otherAndUnencodedConcepts_preserveOriginalTextAndTranslations() throws {
        for flavor in ["OTH", "UNC"] {
            let xml = "<value xmlns=\"urn:hl7-org:v3\" nullFlavor=\"\(flavor)\"><originalText>Unencoded concept</originalText><translation code=\"test\" codeSystem=\"2.25.2362\"/></value>"
            let node = try SafeXMLParser().parse(Data(xml.utf8))
            try roundTrip(CD(node: node)); try roundTrip(CE(node: node))
            XCTAssertEqual(try CD(node: node).node.first("originalText")?.textContent, "Unencoded concept")
            for type in ["CD", "CE"] {
                var payload = node; payload[attribute: "code"] = "test"
                XCTAssertThrowsError(try HL7TypeValidation.validate(payload, type: type))
                payload = node; payload.content.append(.text("direct text"))
                XCTAssertThrowsError(try HL7TypeValidation.validate(payload, type: type))
                payload = node; payload.children = [Node("originalText", namespaceURI: "urn:foreign", text: "foreign")]
                XCTAssertThrowsError(try HL7TypeValidation.validate(payload, type: type))
                payload = node; payload[attribute: "nullFlavor"] = "UNK"
                XCTAssertThrowsError(try HL7TypeValidation.validate(payload, type: type))
            }
        }
    }
    func test_timestampPrecisionAndZone_arePreserved() throws {
        let cases: [(String, TS.Precision)] = [("2026", .year), ("202609", .month), ("20260912", .day),
            ("2026091212", .hour), ("202609121230", .minute), ("20260912123059", .second), ("20260912123059.001", .fraction)]
        for (raw, precision) in cases { XCTAssertEqual(try TS(raw).precision, precision) }
        XCTAssertEqual(try TS("20260912120000-0330").timeZoneOffsetMinutes, -210)
        XCTAssertEqual(try TS("20260912120000+0545").timeZoneOffsetMinutes, 345)
        XCTAssertNil(try TS("2026").timeZoneOffsetMinutes)
        for invalid in ["20260229", "202613", "202600", "2026091225", "202609121260", "20260912.1", "20260912+2460"] {
            XCTAssertThrowsError(try TS(invalid))
        }
        XCTAssertNoThrow(try TS("20240229"))
    }
    func test_quantityUnitAndLexicalPrecision_areNotConverted() throws {
        let quantity = try PQ(value: "1.2500", unit: "mm[Hg]")
        XCTAssertEqual(quantity.value, "1.2500"); XCTAssertEqual(quantity.unit, "mm[Hg]")
        XCTAssertThrowsError(try PQ(value: "nan", unit: "mg"))
    }
    func test_nameAndAddressParts_keepOrderAndQualifiers() throws {
        let name = try PN(parts: [.init(part: "prefix", text: "Dr"), .init(part: "given", text: "Test", qualifiers: ["CL"]), .init(part: "family", text: "Testsson")])
        XCTAssertEqual(name.parts.map(\.part), ["prefix", "given", "family"])
        XCTAssertEqual(name.parts[1].qualifiers, ["CL"])
        let address = try AD(parts: [ADXP(part: "streetAddressLine", text: "1 Test Street"), ADXP(part: "city", text: "Test City")], use: ["HP"])
        XCTAssertEqual(address.parts.map(\.part), ["streetAddressLine", "city"])
        XCTAssertEqual(address.use, ["HP"])
    }
    func test_intervals_rejectContradictoryForms() throws {
        XCTAssertThrowsError(try IVL_TS(low: TS("2026"), center: TS("2027")))
        XCTAssertThrowsError(try IVL_PQ(low: PQ(value: "1", unit: "mg"), high: PQ(value: "2", unit: "mg"), width: PQ(value: "1", unit: "mg")))
    }
    func test_scalarAndED_invalidRepresentationsAreRejected() {
        XCTAssertThrowsError(try INT("1.5")); XCTAssertThrowsError(try REAL("NaN")); XCTAssertThrowsError(try BL("yes"))
        XCTAssertThrowsError(try ED(text: "!invalid!", representation: .B64))
        XCTAssertThrowsError(try ED(node: Node("text", attributes: ["representation": "HEX"])))
    }
}
