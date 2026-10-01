import Foundation
import XCTest
@testable import DicomData

final class DicomDataFidelityTests: XCTestCase {
    func test_modernVRs_preserveFullWidthValuesAndLongHeaders() throws {
        let signed = try XCTUnwrap(DicomVR(code: "SV"))
        let unsigned = try XCTUnwrap(DicomVR(code: "UV"))
        let unlimited = try XCTUnwrap(DicomVR(code: "UC"))
        for vr in [signed, unsigned, unlimited] { XCTAssertTrue(vr.uses32BitLength) }
        let source = DicomDataSet(elements: [
            .init(tag: 0x77771001, vr: signed, value: .signedIntegers([Int.min, -1, Int.max])),
            .init(tag: 0x77771002, vr: unsigned, value: .unsignedIntegers([0, UInt.max])),
            .init(tag: 0x77771003, vr: unlimited, value: .strings(["first", "", "last"]))
        ])
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax)
            XCTAssertEqual(Array(bytes[4..<8]), [0x53, 0x56, 0, 0])
            let parsed = try DicomDataSetParser.dataSet(from: bytes, transferSyntax: syntax)
            XCTAssertEqual(parsed, source)
            try exportForIndependentReader(source, name: syntax.isBigEndian ? "modern-be" : "modern-le", syntax: syntax)
        }
    }

    func test_numericWriter_rejectsInvalidValuesWithoutDroppingMultiplicity() {
        let cases: [(DicomVR, DicomDataValue)] = [
            (.US, .signedIntegers([12, -1, 34])),
            (.SL, .unsignedIntegers([12, UInt.max, 34])),
            (.UL, .strings(["12", "not-a-number", "34"])),
            (.FD, .strings(["12", "invalid", "34"]))
        ]
        for (vr, value) in cases {
            let source = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: value)])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source), vr.code)
        }
    }

    func test_floatWriter_rejectsFiniteOverflowButPreservesIEEEInfinityAndNaN() throws {
        for vr in [DicomVR.FL, .OF] {
            let overflow = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr,
                value: .floats([1, Double.greatestFiniteMagnitude]))])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: overflow))
            let ieee = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr,
                value: .floats([.infinity, -.infinity, .nan]))])
            let bytes = try DicomDataSetWriter.dataSetData(from: ieee)
            let parsed = try DicomDataSetParser.read(from: bytes).dataSet
            guard case .floats(let values) = parsed[0x77771001]?.value else { return XCTFail("Missing floats") }
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values[0], .infinity)
            XCTAssertEqual(values[1], -.infinity)
            XCTAssertTrue(values[2].isNaN)
        }
    }

    func test_binaryWriter_rejectsPartialWordsAndWrongValueTypes() {
        for vr in [DicomVR.OD, .OF, .OV] {
            let source = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .bytes(Data([1, 2, 3])))])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source, purpose: .instance), vr.code)
        }
        for vr in [DicomVR.OB, .OW, .OV, .UN] {
            let source = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .sequence([]))])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source, purpose: .instance), vr.code)
        }
    }

    func test_textVRs_preserveLeadingWhitespaceNewlinesAndLiteralBackslash() throws {
        let text = "  first\\second\nthird"
        for vr in [DicomVR.LT, .ST, .UT] {
            let source = DicomDataSet(elements: [.init(tag: 0x77771001, vr: vr, value: .strings([text]))])
            let bytes = try DicomDataSetWriter.dataSetData(from: source)
            let parsed = try DicomDataSetParser.dataSet(from: bytes)
            XCTAssertEqual(parsed[0x77771001]?.stringValues, [text], vr.code)
            try exportForIndependentReader(source, name: "text-\(vr.code)")
        }
    }

    func test_sequenceWriter_usesItemCharsetWithoutChangingSiblingEncoding() throws {
        let name = "García"
        let item = DicomDataSet(elements: [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: DicomTag.codeMeaning.rawValue, vr: .LO, value: .strings([name]))
        ])
        let source = DicomDataSet(elements: [
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["ISO_IR 100"])),
            .init(tag: 0x00081032, vr: .SQ, value: .sequence([.init(dataSet: item)])),
            .init(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings([name]))
        ])
        let bytes = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertNotNil(bytes.range(of: Data(name.utf8)), "Item declares UTF-8 and must contain UTF-8 bytes")
        XCTAssertNotNil(bytes.range(of: try XCTUnwrap(name.data(using: .isoLatin1))), "Sibling inherits Latin-1")
        let parsed = try DicomDataSetParser.dataSet(from: bytes)
        XCTAssertEqual(parsed, source)
        try exportForIndependentReader(source, name: "nested-charset")
    }

    private func exportForIndependentReader(_ dataSet: DicomDataSet, name: String,
                                            syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("data-fidelity", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax,
            mediaStorageSOPInstanceUID: "2.25.2320001", validationPurpose: .instance))
        try bytes.write(to: root.appendingPathComponent(name + ".dcm"))
    }
}
