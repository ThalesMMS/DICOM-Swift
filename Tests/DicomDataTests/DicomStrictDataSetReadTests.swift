import Foundation
import XCTest
@testable import DicomData

final class DicomStrictDataSetReadTests: XCTestCase {
    func test_invalidUTF8_isRejectedOrPreservedWithDiagnosticAndNoReplacement() throws {
        let declaration = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["ISO_IR 192"]))
        ]))
        let invalid = shortElement(tag: 0x00100010, vr: "PN", bytes: [0xC3, 0x28])
        let valid = shortElement(tag: 0x00100020, vr: "LO", bytes: [0x4F, 0x4B])
        var wire = declaration + invalid + valid
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire)) { error in
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .invalidTextEncoding)
        }
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        wire.removeAll()
        XCTAssertEqual(recovered.dataSet[.patientName]?.vr, .UN)
        XCTAssertEqual(recovered.dataSet[.patientName]?.bytesValue, Data([0xC3, 0x28]))
        XCTAssertEqual(recovered.dataSet.string(for: .patientID), "OK")
        XCTAssertEqual(recovered.diagnostics.count, 1)
        XCTAssertEqual(recovered.diagnostics.first?.tag, 0x00100010)
        XCTAssertEqual(recovered.diagnostics.first?.offset, declaration.count + 8)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: declaration + invalid, mode: .recover, maximumDiagnostics: 0))
    }

    func test_incompleteNumericWord_isNotSilentlyDropped() throws {
        let wire = shortElement(tag: 0x00280110, vr: "US", bytes: [1, 0, 0xFF])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire)) { error in
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .invalidBinaryLength)
        }
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.dataSet[0x00280110]?.vr, .UN)
        XCTAssertEqual(recovered.dataSet[0x00280110]?.bytesValue, Data([1, 0, 0xFF]))
        XCTAssertEqual(recovered.diagnostics.count, 1)
    }

    func test_unknownCharset_reportsBoundedRecoveryInsteadOfGuessingUTF8() throws {
        // Invalid input is hand-encoded: the writer rejects unsupported declarations.
        let wire = shortElement(tag: 0x00080005, vr: "CS", bytes: Array("UNKNOWN_CHARSET ".utf8))
            + shortElement(tag: 0x00100010, vr: "PN", bytes: Array("NAME".utf8))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire))
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.diagnostics.map(\.reason), [.unsupportedCharacterSet, .unsupportedCharacterSet])
        XCTAssertEqual(recovered.dataSet[.patientName]?.bytesValue, Data("NAME".utf8))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: .recover, maximumDiagnostics: 1))
    }

    func test_validatedCharsets_rejectUndeclaredBytesAndUnrepresentableStrings() throws {
        XCTAssertThrowsError(try DicomSpecificCharacterSet.defaultCharacterSet.decodeValidated(Data([0xC3, 0xA9])))
        XCTAssertThrowsError(try DicomSpecificCharacterSet("ISO_IR 100").encodeValidated("漢字"))
        XCTAssertEqual(DicomSpecificCharacterSet("\\ISO 2022 IR 87").definedTerms, ["", "ISO 2022 IR 87"])
        let charset = DicomSpecificCharacterSet("\\ISO 2022 IR 87")
        let name = "Yamada^Taro=山田^太郎"
        XCTAssertEqual(try charset.decodeValidated(charset.encodeValidated(name)), name)
        XCTAssertThrowsError(try DicomSpecificCharacterSet("ISO_IR 192\\ISO_IR 100").decodeValidated(Data()))
    }

    func test_oddTextLength_isRejectedOrPreservedWithoutInventedPadding() throws {
        let wire = shortElement(tag: 0x00100020, vr: "LO", bytes: Array("ABC".utf8))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire))
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.dataSet[.patientID]?.vr, .UN)
        XCTAssertEqual(recovered.dataSet[.patientID]?.bytesValue, Data("ABC".utf8))
        XCTAssertEqual(recovered.diagnostics.count, 1)
    }

    func test_duplicateTags_areFatalEvenDuringRecoveryInsteadOfDiscardingAValue() throws {
        let wire = shortElement(tag: 0x00100020, vr: "LO", bytes: Array("FIRST ".utf8))
            + shortElement(tag: 0x00100020, vr: "LO", bytes: Array("SECOND".utf8))
        for mode in [DicomDataSetReadMode.strict, .recover] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire, mode: mode))
        }
    }

    func test_malformedCharset_doesNotFallBackToParentOrDefaultDuringRecovery() throws {
        let inherited = DicomDataSet(elements: [.init(tag: 0x00080104, vr: .LO, value: .strings(["NAME"]))])
        let overridden = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["漢字"]))
        ])
        let nested = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x00081032, vr: .SQ, value: .sequence([.init(dataSet: inherited), .init(dataSet: overridden)]))
        ]))
        let wire = shortElement(tag: 0x00080005, vr: "CS", bytes: [0xFF, 0xFE]) + nested
            + shortElement(tag: 0x00100010, vr: "PN", bytes: Array("NAME".utf8))
        let recovered = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(recovered.diagnostics.map(\.reason), [.invalidTextEncoding, .unsupportedCharacterSet, .unsupportedCharacterSet])
        XCTAssertEqual(recovered.dataSet[.patientName]?.bytesValue, Data("NAME".utf8))
        guard case .sequence(let items) = recovered.dataSet[0x00081032]?.value else { return XCTFail("Missing sequence") }
        XCTAssertEqual(items[0].dataSet[0x00080104]?.bytesValue, Data("NAME".utf8))
        XCTAssertEqual(items[1].dataSet.string(for: 0x00080104), "漢字")
    }

    private func shortElement(tag: UInt32, vr: String, bytes: [UInt8]) -> Data {
        var result = Data([UInt8(truncatingIfNeeded: tag >> 16), UInt8(truncatingIfNeeded: tag >> 24),
                           UInt8(truncatingIfNeeded: tag), UInt8(truncatingIfNeeded: tag >> 8)])
        result.append(contentsOf: vr.utf8)
        result.append(contentsOf: [UInt8(bytes.count), 0])
        result.append(contentsOf: bytes)
        return result
    }
}
