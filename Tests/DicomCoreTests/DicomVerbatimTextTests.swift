//
//  DicomVerbatimTextTests.swift
//  DicomCoreTests
//
//  Issue #3255: a CR from the DICOM_Example corpus declares Specific Character Set `ISO_2022_IR_6`
//  (underscores, not a defined term), so no text element of it could be re-encoded and `dicomtool
//  codec transcode` refused the object at its Accession Number. PACS write such files and the
//  viewer opens them. A value read from the file and left unchanged is now written back byte for
//  byte with a warning; a new value is still validated.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import DicomData
import Foundation
import XCTest
@testable import DicomCore

final class DicomVerbatimTextTests: XCTestCase {
    /// A Part 10 CR-like object whose Specific Character Set and Accession
    /// Number are patched in place after a valid write, as a source PACS
    /// would have produced them.
    private static func source(characterSet: String, accession: [UInt8]) throws -> Data {
        let pixelData = try DicomSecondaryCapturePixelData(data: Data(repeating: 7, count: 8), columns: 2, rows: 2,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", bitsAllocated: 16, bitsStored: 12, highBit: 11)
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(pixelData: pixelData, options: .init(
            sopInstanceUID: "2.25.32551", studyInstanceUID: "2.25.32552", seriesInstanceUID: "2.25.32553",
            patientName: "Charset^Case", patientID: "P3255", seriesNumber: 1, instanceNumber: 1))
        // A valid term of the same length, so the first write succeeds.
        let placeholderSet = characterSet.replacingOccurrences(of: "IR_", with: "IR ")
        let placeholderAccession = String(repeating: "Z", count: accession.count)
        dataSet.set(.init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings([placeholderSet])))
        dataSet.set(.init(tag: 0x0008_0050, vr: .SH, value: .strings([placeholderAccession])))
        var bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
            mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))
        if placeholderSet != characterSet {
            try replace(Data(placeholderSet.utf8), with: Data(characterSet.utf8), in: &bytes)
        }
        try replace(Data(placeholderAccession.utf8), with: Data(accession), in: &bytes)
        return bytes
    }

    private static func replace(_ old: Data, with new: Data, in bytes: inout Data) throws {
        let range = try XCTUnwrap(bytes.range(of: old), "placeholder not written")
        bytes.replaceSubrange(range, with: new)
    }

    /// Reads `part10` back and returns the verbatim source bytes kept for its Accession Number (0008,0050).
    private static func accessionBytes(in part10: Data) throws -> Data {
        let decoder = try DCMDecoder(data: part10)
        let element = try XCTUnwrap(decoder.dataSet.element(for: 0x0008_0050))
        let verbatim = try XCTUnwrap(element.verbatimText, "the reader did not keep the source bytes")
        return verbatim.bytes
    }

    /// An Accession Number under the undefined term `ISO_IR_100` is kept verbatim and written back byte for byte,
    /// padding included.
    func test_anUndefinedCharacterSetTerm_isWrittenBackByteForByte() throws {
        let source = try Self.source(characterSet: "ISO_IR_100", accession: Array("A1234".utf8) + [0xE9, 0x20])
        let dataSet = try DCMDecoder(data: source).dataSet
        XCTAssertEqual(DicomDataSetWriter.verbatimTextElements(in: dataSet).map(\.tag).contains(0x0008_0050), true)

        let written = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
            mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))

        XCTAssertNotNil(written.range(of: Data(Array("A1234".utf8) + [0xE9, 0x20])),
                        "The Accession Number's bytes did not survive the rewrite")
        // Byte for byte, the source's padding included.
        XCTAssertEqual(try Self.accessionBytes(in: written), try Self.accessionBytes(in: source))
    }

    /// A byte outside the declared ISO_IR 6 repertoire survives the rewrite as read.
    func test_charactersOutsideTheDeclaredRepertoire_areKeptAsRead() throws {
        // ISO_IR 6 is ASCII; 0xE9 is outside it.
        let source = try Self.source(characterSet: "ISO_IR 6", accession: Array("ACC".utf8) + [0xE9])
        let dataSet = try DCMDecoder(data: source).dataSet

        let written = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
            mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))

        XCTAssertNotNil(written.range(of: Data(Array("ACC".utf8) + [0xE9])))
    }

    /// A value set after reading is still validated: a non-ASCII Accession Number under ISO_IR 6 is refused.
    func test_aNewValue_isStillValidatedAgainstTheDeclaredCharacterSet() throws {
        let source = try Self.source(characterSet: "ISO_IR 6", accession: Array("ACC".utf8) + [0xE9])
        var dataSet = try DCMDecoder(data: source).dataSet
        dataSet.set(.init(tag: 0x0008_0050, vr: .SH, value: .strings(["NEWÉ"])))

        XCTAssertThrowsError(try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
            mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))) { error in
            guard case .unsupportedValue(let tag, _, _)? = error as? DicomDataSetWriterError else {
                return XCTFail("Expected the new value to be refused, got \(error)")
            }
            XCTAssertEqual(tag, 0x0008_0050)
        }
    }

    func test_aValidSource_keepsNoVerbatimCopies() throws {
        let source = try Self.source(characterSet: "ISO_IR 100", accession: Array("ACC1".utf8))
        XCTAssertTrue(DicomDataSetWriter.verbatimTextElements(in: try DCMDecoder(data: source).dataSet).isEmpty)
    }

    func test_transcode_completesWithAWarningAndKeepsTheBytes() async throws {
        let accession = Array("A1234".utf8) + [0xE9, 0x20]
        let source = try Self.source(characterSet: "ISO_IR_100", accession: accession)

        let result = try await DicomCodecWorkflowEngine().transcode(source, to: .explicitVRLittleEndian,
                                                                    environment: [:], verifyDecodedPixels: false)

        XCTAssertTrue(result.report.success)
        let warning = try XCTUnwrap(result.report.diagnostics.first { $0.code == "codec.transcode.verbatimText" })
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertTrue(warning.message.contains("(0008,0050) SH"))
        XCTAssertFalse(warning.message.contains("A1234"), "The warning must not carry the value")
        XCTAssertNotNil(result.data.range(of: Data(accession)))
    }
}
