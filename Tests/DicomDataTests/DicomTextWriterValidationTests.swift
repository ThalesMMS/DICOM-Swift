import Foundation
import XCTest
@testable import DicomData

final class DicomTextWriterValidationTests: XCTestCase {
    func test_unsupportedDeclaration_withByteSafeValuesRequiresOptInValidation() throws {
        let source = DicomDataSet(elements: [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["UNKNOWN_CHARSET"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: bytes), source)
        for purpose in [DicomDataSetPurpose.instance, .query] {
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source, purpose: purpose)) {
                guard case .unsupportedValue(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, reason: _) =
                        $0 as? DicomDataSetWriterError else {
                    return XCTFail("Expected unsupported character-set declaration, got \($0)")
                }
            }
        }
    }

    func test_unrepresentableText_rejectsInsteadOfWritingUndeclaredUTF8() {
        for declaration in ["ISO_IR 6", "ISO_IR 100", "UNKNOWN_CHARSET"] {
            let source = dataSet(charset: declaration, vr: .PN, value: .strings(["漢字"]))
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source), declaration)
        }
    }

    func test_restrictedVR_doesNotUseExtendedDatasetCharset() {
        for vr in [DicomVR.AE, .AS, .CS, .DA, .DS, .DT, .IS, .TM, .UI, .UR] {
            let source = dataSet(charset: "ISO_IR 192", vr: vr, value: .strings(["漢字"]))
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source), vr.code)
        }
    }

    func test_textValue_rejectsTypeAndMultiplicityThatWouldLoseMeaning() {
        let cases: [(DicomVR, DicomDataValue)] = [
            (.LO, .bytes(Data([0xFF, 0xFE]))), (.LO, .sequence([])),
            (.LO, .strings(["first\\second"])), (.PN, .strings(["first\\second"])),
            (.LT, .strings(["first", "second"])), (.ST, .strings(["first", "second"])),
            (.UT, .strings(["first", "second"])), (.UR, .strings(["first", "second"]))
        ]
        for (vr, value) in cases {
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: dataSet(charset: "ISO_IR 192", vr: vr, value: value)))
        }
    }

    func test_extendedTextAndEmptyComponents_roundTripWithoutLoss() throws {
        for vr in [DicomVR.SH, .LO, .PN, .UC] {
            let source = dataSet(charset: "ISO_IR 192", vr: vr, value: .strings([vr == .PN ? "=漢字" : "漢字", "", "García"]))
            let bytes = try DicomDataSetWriter.dataSetData(from: source)
            XCTAssertEqual(try DicomDataSetParser.read(from: bytes).dataSet, source)
        }
    }

    private func dataSet(charset: String, vr: DicomVR, value: DicomDataValue) -> DicomDataSet {
        .init(elements: [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings([charset])),
            .init(tag: 0x77771001, vr: vr, value: value)
        ])
    }
}
