import Foundation
import XCTest
@testable import DicomData

final class DicomISO2022Tests: XCTestCase {
    func test_declaredRepertoires_decodeIndependentByteFixturesAndRoundTrip() throws {
        // Character bytes independently obtained from Python standard codecs;
        // escape designations are from PS3.3 tables C.12-3 and C.12-4.
        let cases: [(String, String, [UInt8])] = [
            ("ISO 2022 IR 100", "é", [0x1B, 0x2D, 0x41, 0xE9]),
            ("ISO 2022 IR 101", "Ą", [0x1B, 0x2D, 0x42, 0xA1]),
            ("ISO 2022 IR 109", "Ħ", [0x1B, 0x2D, 0x43, 0xA1]),
            ("ISO 2022 IR 110", "Ā", [0x1B, 0x2D, 0x44, 0xC0]),
            ("ISO 2022 IR 127", "ش", [0x1B, 0x2D, 0x47, 0xD4]),
            ("ISO 2022 IR 126", "Ω", [0x1B, 0x2D, 0x46, 0xD9]),
            ("ISO 2022 IR 138", "ש", [0x1B, 0x2D, 0x48, 0xF9]),
            ("ISO 2022 IR 148", "Ğ", [0x1B, 0x2D, 0x4D, 0xD0]),
            ("ISO 2022 IR 166", "ท", [0x1B, 0x2D, 0x54, 0xB7]),
            ("ISO 2022 IR 159", "丂", [0x1B, 0x24, 0x28, 0x44, 0x30, 0x21, 0x1B, 0x28, 0x42]),
            ("ISO 2022 IR 144", "Ж", [0x1B, 0x2D, 0x4C, 0xB6]),
            ("ISO 2022 IR 203", "€", [0x1B, 0x2D, 0x62, 0xA4]),
            ("ISO 2022 IR 87", "山", [0x1B, 0x24, 0x42, 0x3B, 0x33, 0x1B, 0x28, 0x42]),
            ("ISO 2022 IR 149", "홍", [0x1B, 0x24, 0x29, 0x43, 0xC8, 0xAB]),
            ("ISO 2022 IR 58", "中", [0x1B, 0x24, 0x29, 0x41, 0xD6, 0xD0]),
            ("ISO 2022 IR 13", "ﾔ", [0x1B, 0x29, 0x49, 0xD4])
        ]
        for (term, expected, bytes) in cases {
            let charset = DicomSpecificCharacterSet(definedTerms: ["", term])
            XCTAssertEqual(try charset.decodeValidated(Data(bytes)), expected, term)
            let source = DicomDataSet(elements: [
                .init(tag: 0x00080005, vr: .CS, value: .strings(["", term])),
                .init(tag: 0x00100010, vr: .PN, value: .strings(["NAME=" + expected + "^" + expected])),
                .init(tag: 0x00082111, vr: .ST, value: .strings([expected + "\r\n" + expected]))
            ])
            for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian,
                           .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
                let wire = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax)
                XCTAssertEqual(try DicomDataSetParser.read(from: wire, transferSyntax: syntax).dataSet, source, term)
                try export(source, name: "ir-" + term.components(separatedBy: " ").last!, syntax: syntax)
            }
        }
    }

    func test_initialG1_resetsAtNameValueAndLineBoundaries() throws {
        let charset = DicomSpecificCharacterSet(definedTerms: ["ISO 2022 IR 100", "ISO 2022 IR 126"])
        let source = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(charset.definedTerms)),
            .init(tag: 0x00081070, vr: .PN, value: .strings(["García=Ω^é", "Renée=Ω"])),
            .init(tag: 0x00082111, vr: .ST, value: .strings(["Ω\r\né\tΩ"]))
        ])
        let wire = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertEqual(try DicomDataSetParser.read(from: wire).dataSet, source)
        XCTAssertThrowsError(try charset.decodeValidated(Data([0x1B, 0x2D, 0x46, 0xD9])))
        let valid: [UInt8] = [0x1B, 0x2D, 0x46, 0xD9, 0x1B, 0x2D, 0x41, 0x0D, 0x0A, 0xE9]
        XCTAssertEqual(try charset.decodeValidated(Data(valid)), "Ω\r\né")
        // A component after a boundary must designate its noninitial G1 again.
        let undeclaredAfterLine: [UInt8] = [0x1B, 0x24, 0x29, 0x43, 0xC8, 0xAB, 0x0D, 0x0A, 0xC8, 0xAB]
        XCTAssertThrowsError(try DicomSpecificCharacterSet("\\ISO 2022 IR 149").decodeValidated(Data(undeclaredAfterLine)))
        try export(source, name: "mixed-initial-g1", syntax: .explicitVRLittleEndian)
    }

    func test_jisX0201_isSingleByteAndPreservesRomajiAndLiteralYen() throws {
        let charset = DicomSpecificCharacterSet("ISO_IR 13")
        XCTAssertEqual(try charset.decodeValidated(Data([0xD4, 0x5C, 0x7E])), "ﾔ¥‾")
        XCTAssertEqual(try charset.encodeValidated("ﾔ¥‾"), Data([0xD4, 0x5C, 0x7E]))
        XCTAssertThrowsError(try charset.encodeValidated("山"))
        XCTAssertThrowsError(try charset.decodeValidated(Data([0x8E, 0x52])))
        XCTAssertThrowsError(try charset.decodeValidated(Data([0x1B, 0x29, 0x49, 0xD4])))
    }

    func test_nestedItems_inheritDeclarationButNeverEscapeStateOrSiblingOverride() throws {
        let inherited = DicomDataSet(elements: [.init(tag: 0x00080104, vr: .LO, value: .strings(["Ω"]))])
        let overridden = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["", "ISO 2022 IR 87"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["山"]))
        ])
        let source = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO 2022 IR 100", "ISO 2022 IR 126"])),
            .init(tag: 0x00081032, vr: .SQ, value: .sequence([inherited, overridden, inherited].map { .init(dataSet: $0) }))
        ])
        let wire = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertEqual(try DicomDataSetParser.read(from: wire).dataSet, source)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: wire), source)
        try export(source, name: "nested", syntax: .explicitVRLittleEndian)
    }

    func test_yenDelimiter_cannotChangeMultiplicityAndLegacyReadKeepsSeparators() throws {
        let source = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 13"])),
            .init(tag: 0x00081070, vr: .PN, value: .strings(["ﾔ", "ﾛ"]))
        ])
        let wire = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertEqual(try DicomDataSetParser.read(from: wire).dataSet, source)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: wire), source)
        var invalid = source
        invalid.set(.init(tag: 0x00081070, vr: .PN, value: .strings(["ﾔ¥ﾛ"])))
        XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: invalid))
    }

    func test_iso2022_rejectsUndeclaredEscapesShiftsTruncationAndMissingResets() throws {
        let charset = DicomSpecificCharacterSet(definedTerms: ["", "ISO 2022 IR 87"])
        let invalid: [[UInt8]] = [
            [0x1B], [0x1B, 0x24], [0x1B, 0x24, 0x40], // Unregistered old JIS escape.
            [0x1B, 0x2D, 0x41, 0xE9], [0x1B, 0x28, 0x4A, 0x41],
            [0x0E, 0x41, 0x0F], [0x8E, 0x41], [0x1B, 0x4E, 0x41],
            [0x1B, 0x24, 0x42, 0x3B], // Incomplete two-byte character.
            [0x1B, 0x24, 0x42, 0x3B, 0x33], // Missing reset at end.
            [0x1B, 0x24, 0x42, 0x3B, 0x33, 0x0A, 0x1B, 0x28, 0x42]
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try charset.decodeValidated(Data(bytes)), bytes.description)
        }
        for declaration in ["ISO 2022 IR 87", "ISO 2022 IR 149", "ISO 2022 IR 100\\ISO 2022 IR 100",
                            "ISO_IR 100\\ISO 2022 IR 87", "ISO 2022 IR 87\\ISO 2022 IR 6"] {
            XCTAssertThrowsError(try DicomSpecificCharacterSet(declaration).validateDeclaration(), declaration)
        }
        XCTAssertThrowsError(try DicomSpecificCharacterSet("ISO_IR 100").decodeValidated(Data([0x1B, 0x28, 0x42])))
    }

    func test_personName_doesNotAllowCodeExtensionInAlphabeticGroup() throws {
        let source = DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["", "ISO 2022 IR 87"])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["山田^太郎"]))
        ])
        XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source))
        var wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [source.elements[0]]))
        let japanese: [UInt8] = [0x1B, 0x24, 0x42, 0x3B, 0x33, 0x1B, 0x28, 0x42]
        wire.append(contentsOf: [0x10, 0, 0x10, 0, 0x50, 0x4E, 8, 0] + japanese)
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire))
        let result = try DicomDataSetParser.read(from: wire, mode: .recover)
        XCTAssertEqual(result.dataSet[.patientName]?.bytesValue, Data(japanese))
        XCTAssertEqual(result.diagnostics.map(\.reason), [.invalidTextEncoding])
    }
    private func export(_ source: DicomDataSet, name: String, syntax: DicomTransferSyntax) throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_DIFFERENTIAL_REWRITE_DIR"] else { return }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("charset-fidelity", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax,
            mediaStorageSOPInstanceUID: "2.25.2320002"))
        try bytes.write(to: root.appendingPathComponent(name + "-" + syntax.rawValue + ".dcm"))
    }

}
