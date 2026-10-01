import Foundation
import XCTest
@testable import DicomData

final class DicomVRRoundTripMatrixTests: XCTestCase {
    private let syntaxes: [DicomTransferSyntax] = [
        .implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian, .deflatedExplicitVRLittleEndian
    ]

    func test_allStandardVRs_preserveValuesAcrossFourDatasetSyntaxes() throws {
        for syntax in syntaxes {
            let source = makeDataSet(bigEndian: syntax.isBigEndian)
            XCTAssertEqual(source.elements.count, 36)
            let dictionary = try privateDictionary(from: source)
            let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
            let parsed = try DicomDataSetParser.read(from: bytes, transferSyntax: syntax, privateDictionary: dictionary)
            XCTAssertEqual(parsed.dataSet, source, syntax.rawValue)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
            try export(source, syntax: syntax, prefix: "all-vr")
        }
    }

    func test_allStandardVRs_emptyValuesHaveZeroLengthAndRemainEmpty() throws {
        for syntax in syntaxes {
            let values = makeDataSet(bigEndian: syntax.isBigEndian)
            let source = DicomDataSet(elements: values.elements.map { element in
                guard element.tag >= 0x77771000 else { return element }
                return .init(tag: element.tag, vr: element.vr, value: element.vr == .SQ ? .sequence([]) : .empty)
            })
            let bytes = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax, purpose: .instance)
            let parsed = try DicomDataSetParser.read(from: bytes, transferSyntax: syntax,
                                                    privateDictionary: privateDictionary(from: values))
            XCTAssertEqual(parsed.dataSet, source, syntax.rawValue)
            try export(source, syntax: syntax, prefix: "empty-vr")
        }
    }

    private func makeDataSet(bigEndian: Bool) -> DicomDataSet {
        let values: [(DicomVR, DicomDataValue)] = [
            (.AE, .strings(["SOURCE", "DESTINATION"])), (.AS, .strings(["018Y"])),
            (.AT, .unsignedIntegers([0x00100010, 0x00280103])), (.CS, .strings(["ORIGINAL", "PRIMARY"])),
            (.DA, .strings(["20260908"])), (.DS, .strings(["1.23456789012345", "-1.23456789E-123"])),
            (.DT, .strings(["20260908010203.123456-0300"])), (.FD, .floats([-1.25, 1e200])),
            (.FL, .floats([-1.25, 65536])), (.IS, .strings(["-2147483648", "2147483647"])),
            (.LO, .strings(["García", "", "漢字"])), (.LT, .strings(["  first\\second\r\nthird"])),
            (.OB, .bytes(Data([0x01, 0x80, 0xFF, 0]))), (.OD, .floats([-1.25, 1e200])),
            (.OF, .floats([-1.25, 65536])), (.OL, .unsignedIntegers([0, UInt(UInt32.max)])),
            (.OV, .bytes(Data(bigEndian ? [1, 2, 3, 4, 5, 6, 7, 8] : [8, 7, 6, 5, 4, 3, 2, 1]))),
            (.OW, .bytes(Data(bigEndian ? [0x12, 0x34, 0xAB, 0xCD] : [0x34, 0x12, 0xCD, 0xAB]))),
            (.PN, .strings(["Yamada^Taro=山田^太郎=ヤマダ^タロウ", "García^José"])),
            (.SH, .strings(["Résumé"])), (.SL, .signedIntegers([Int(Int32.min), Int(Int32.max)])),
            (.SQ, .sequence([.init(dataSet: .init(elements: [
                .init(tag: DicomTag.codeMeaning.rawValue, vr: .LO, value: .strings(["García"]))
            ]))])), (.SS, .signedIntegers([Int(Int16.min), Int(Int16.max)])),
            (.ST, .strings(["  first\\second"])), (.SV, .signedIntegers([Int.min, -1, Int.max])),
            (.TM, .strings(["010203.123456"])), (.UC, .strings(["漢字", "", "Résumé"])),
            (.UI, .strings(["2.25.23201", "2.25.23202"])), (.UL, .unsignedIntegers([0, UInt(UInt32.max)])),
            (.UN, .bytes(Data([0xFF, 0xFE, 0xFD, 0xFC]))), (.UR, .strings(["https://example.invalid/a%20b"])),
            (.US, .unsignedIntegers([0, UInt(UInt16.max)])), (.UT, .strings(["  first\\second\r\nthird"])),
            (.UV, .unsignedIntegers([0, UInt.max]))
        ]
        return .init(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: 0x77770010, vr: .LO, value: .strings(["ISIS VR MATRIX"]))
        ] + values.enumerated().map { .init(tag: 0x77771000 + $0.offset, vr: $0.element.0, value: $0.element.1) })
    }

    private func privateDictionary(from source: DicomDataSet) throws -> DicomPrivateDictionary {
        try .init(entries: source.elements.filter { $0.tag >= 0x77771000 }.map {
            .init(group: 0x7777, creator: "ISIS VR MATRIX", offset: UInt8($0.tag & 0xFF), vr: $0.vr)
        })
    }

    private func export(_ source: DicomDataSet, syntax: DicomTransferSyntax, prefix: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("data-fidelity")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax,
            mediaStorageSOPInstanceUID: "2.25.2320003", validationPurpose: .instance))
        try bytes.write(to: root.appendingPathComponent("\(prefix)-\(syntax.rawValue).dcm"))
    }
}
