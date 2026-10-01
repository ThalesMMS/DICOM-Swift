import XCTest
@testable import HL7v2

final class HL7DataTypeTests: XCTestCase {
    func test_timestamp_roundTripsAllPrecisionsAndOffsets() throws {
        for text in ["2024", "202402", "20240229", "2024022912", "202402291230", "20240229123059",
                     "20240229123059.0010-0330", "20240229123059+0000", "20240229123059-0000"] {
            let timestamp = try XCTUnwrap(HL7Timestamp(text))
            XCTAssertEqual(timestamp.rawValue, text)
            XCTAssertEqual(HL7Timestamp(timestamp.hl7Value)?.rawValue, text)
        }
        XCTAssertEqual(HL7Timestamp("20240229123059.0010-0330")?.timezoneOffsetMinutes, -210)
        XCTAssertEqual(HL7Timestamp("20240229123059.0010-0330")?.fraction, "0010")
        XCTAssertEqual(HL7Timestamp("2024")?.precision, .year)
    }
    func test_timestamp_rejectsInvalidCalendarAndSyntax() {
        for text in ["20230229", "19000229", "20241301", "20240001", "20240100", "20240101240000", "20240101126000",
                     "20240101120060", "20240101120000+1260", "20240101120000+2400", "2024.1", "20240101120000.12345",
                     "0000", " 2024", "2024Z", "20241"] { XCTAssertNil(HL7Timestamp(text), text) }
        XCTAssertNotNil(HL7Timestamp("20000229"))
    }
    func test_number_rejectsNonHL7NumericForms() {
        for text in ["12", "-12.50", "+.5", "0", "1."] { XCTAssertNotNil(HL7Number(.text(text)), text) }
        for text in ["1e5", "NaN", "inf", "1,000", "", " 1", "1 2", "--2"] { XCTAssertNil(HL7Number(.text(text)), text) }
    }
    func test_compositeMappings_preserveNestedAuthorityAndAlternates() throws {
        let cx = HL7ExtendedID(id: "SYNTHETIC", authority: .init(namespace: "LAB", universalID: "1.2.3", universalIDType: "ISO"), identifierType: "MR")
        let decoded = try XCTUnwrap(HL7ExtendedID(cx.hl7Value))
        XCTAssertEqual(decoded.id, "SYNTHETIC")
        XCTAssertEqual(decoded.identifierType, "MR")
        XCTAssertEqual(decoded.authority?.universalID, "1.2.3")
        let name = HL7PersonName(family: "Example", given: "Test", middle: "M", suffix: "Jr", prefix: "Dr")
        XCTAssertEqual(HL7PersonName(name.hl7Value)?.family, "Example")
        XCTAssertEqual(HL7PersonName(name.hl7Value)?.prefix, "Dr")
        let coded = HL7CodedElement(identifier: "A", text: "Example", system: "LOCAL", alternateIdentifier: "B", alternateText: "Other", alternateSystem: "ALT")
        XCTAssertEqual(HL7CodedElement(coded.hl7Value)?.alternateSystem, "ALT")
        XCTAssertEqual(HL7CodedElement(coded.hl7Value)?.identifier, "A")
    }
    func test_addressAndTelecom_mapComponents() {
        let address = HL7Address(street: "Test Street", city: "City", state: "ST", postalCode: "00000", country: "BRA")
        XCTAssertEqual(HL7Address(address.hl7Value)?.postalCode, "00000")
        let telecom = HL7Telecom(number: "123", use: "PRN", equipment: "PH", email: "test@example.invalid")
        XCTAssertEqual(HL7Telecom(telecom.hl7Value)?.email, "test@example.invalid")
        XCTAssertNil(HL7PersonName(.null))
    }
    func test_typeDefinition_rejectsWrongWrapperAndTooManyComponents() {
        let schema = HL7SchemaRegistry.shared.schema(for: .v2_5_1)!
        XCTAssertNil(HL7PersonName(.text("Test"), definition: schema.dataTypes[.CX]))
        XCTAssertNil(HL7CodedElement(hl7Repetition(Array(repeating: "x", count: 7)), definition: schema.dataTypes[.CE]))
    }
    func test_compositeInitializer_validatesDefinitionComponents() {
        var cx = HL7ExtendedID(id: "SYNTHETIC").hl7Value
        cx[7] = HL7Component(subcomponents: [.text("20230229")])
        let definition = HL7SchemaRegistry.shared.schema(for: .v2_5_1)!.dataTypes[.CX]!
        XCTAssertNil(HL7ExtendedID(cx, definition: definition))
        cx[7] = HL7Component(subcomponents: [.text("20240229")])
        XCTAssertNotNil(HL7ExtendedID(cx, definition: definition))
    }
    func test_invalidNMAndDT_returnExactPaths() {
        var message = lotBAdmission()
        var obx = HL7Segment(name: "OBX")
        obx[2] = HL7Field(.text("NM")); obx[3] = HL7Field(.text("TEST"))
        obx[5] = HL7Field(.text("not-a-number")); obx[11] = HL7Field(.text("F"))
        message.segments.append(obx)
        message["PID"]?[3][1][7][1] = .text("20230229")
        let report = lotBValidator().validate(message)
        XCTAssertTrue(report.findings.contains { $0.code == .dataTypeInvalid && $0.path == HL7Path("OBX-5") })
        XCTAssertTrue(report.findings.contains { $0.code == .dataTypeInvalid && $0.path == HL7Path("PID-3.7") })
    }
}
