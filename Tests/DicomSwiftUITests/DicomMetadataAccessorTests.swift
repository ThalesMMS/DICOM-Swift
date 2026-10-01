import XCTest
@testable import DicomSwiftUI
import DicomCore
import DicomTestSupport

final class DicomMetadataAccessorTests: XCTestCase {

    func testOptionalString_emptyStringTreatsAsMissing() {
        let decoder = MockDicomDecoder()
        decoder.setTag(DicomTag.patientName.rawValue, value: "")

        let accessor = DicomMetadataAccessor(decoder: decoder)
        XCTAssertNil(accessor.optionalString(.patientName))
    }

    func testOptionalString_nonEmptyValueReturnsValue() {
        let decoder = MockDicomDecoder()
        decoder.setTag(DicomTag.patientName.rawValue, value: "Doe^John")

        let accessor = DicomMetadataAccessor(decoder: decoder)
        XCTAssertEqual(accessor.optionalString(.patientName), "Doe^John")
    }

    func testString_fallbackUsesFallbackWhenEmpty() {
        let decoder = MockDicomDecoder()
        decoder.setTag(DicomTag.patientID.rawValue, value: "")

        let accessor = DicomMetadataAccessor(decoder: decoder)
        XCTAssertEqual(accessor.string(.patientID, fallback: "N/A"), "N/A")
    }

    func testString_rawStringDoesNotTreatEmptyAsMissing() {
        let decoder = MockDicomDecoder()
        decoder.setTag(DicomTag.patientID.rawValue, value: "")

        let accessor = DicomMetadataAccessor(decoder: decoder)
        XCTAssertEqual(accessor.string(.patientID), "")
    }
}
