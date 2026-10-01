//
//  CodecVolumeRobustnessBaselineTests.swift
//  DicomCoreTests
//
//  Baseline for the codec/volume robustness series (issue #1225): pins the
//  current multiframe compressed behavior for the first natively supported
//  transfer syntax (RLE) and the typed unsupported/limited behavior for
//  HTJ2K and JPEG Extended 12-bit, before #1226-#1234 implement the paths.
//  The implementation order of record lives in IMPLEMENTATION_GAPS.md
//  ("Codec/Volume Implementation Order").
//

import Foundation
import XCTest
@testable import DicomCore

final class CodecVolumeRobustnessBaselineTests: XCTestCase {
    // MARK: - Multiframe compressed baseline (RLE, natively decoded)

    /// A two-frame encapsulated RLE file must expose its per-frame
    /// compressed payloads and decode the first frame natively. Whole-stack
    /// multiframe decode lands with #1226/#1227.
    func testMultiframeRLEExposesPerFramePayloadsAndDecodesFirstFrame() throws {
        let frameOne = Self.rleSegment(samples: [10, 20, 30, 40])
        let frameTwo = Self.rleSegment(samples: [50, 60, 70, 80])
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rle-multiframe-\(UUID().uuidString).dcm")
        try Self.makeEncapsulatedRLEFile(fragments: [frameOne, frameTwo], frames: 2).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let decoder = try DCMDecoder(contentsOf: fileURL)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.rleLossless.rawValue)

        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        XCTAssertEqual(descriptor.numberOfFrames, 2, "both frames must be addressable")

        let firstFrame = try XCTUnwrap(decoder.getEncapsulatedFrame(0))
        let secondFrame = try XCTUnwrap(decoder.getEncapsulatedFrame(1))
        XCTAssertEqual(firstFrame.data, frameOne)
        XCTAssertEqual(secondFrame.data, frameTwo)

        let pixels = try XCTUnwrap(decoder.getPixels8(), "first RLE frame must decode natively")
        XCTAssertEqual(Array(pixels.prefix(4)), [10, 20, 30, 40])
    }

    // MARK: - Typed unsupported/limited behavior (pre-implementation pins)

    /// HTJ2K rows name the own DicomJPEG2000 HT decoder (#2330) and keep the
    /// version-gated OpenJPEG runtime (#1231) as the documented fallback.
    func testHTJ2KRowsNameTheOwnDecoderAndTheVersionGatedFallback() {
        let registry = DicomTransferSyntaxRegistry.standard
        for syntax in [DicomTransferSyntax.htj2kLossless, .htj2kLosslessRPCL, .htj2k] {
            let support = registry.compressedPixelSupport(for: syntax)
            XCTAssertEqual(support?.status, .delegated, "\(syntax) is decoded by a codec backend")
            XCTAssertTrue(support?.diagnostic.contains("j2kswift-cpu") == true, "\(syntax) diagnostic must name the own decoder")
            XCTAssertTrue(support?.diagnostic.contains("2.5") == true, "\(syntax) diagnostic must name the version gate")
        }
    }

    /// A malformed 12-bit JPEG Extended payload (headers without a scan)
    /// must fail typed through the native decoder added by #1228 — never
    /// fall back to a silent precision-losing ImageIO decode. The
    /// well-formed 12-bit path is pinned in `JPEGExtendedDecoderTests`.
    func testJPEGExtended12BitDecodeFailsWithTypedDiagnostics() throws {
        // Minimal JPEG Extended (SOF1) header so the file parses; the
        // native decoder rejects the stream because it has no SOS segment.
        var codestream = Data([0xFF, 0xD8]) // SOI
        codestream.append(contentsOf: [0xFF, 0xC1, 0x00, 0x0B, 12, 0x00, 0x02, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00]) // SOF1, 12-bit, 2x2
        codestream.append(contentsOf: [0xFF, 0xD9]) // EOI

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jpeg-extended-12-\(UUID().uuidString).dcm")
        try Self.makeEncapsulatedFile(
            transferSyntax: .jpegExtended,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11,
            fragments: [codestream],
            frames: 1
        ).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let decoder = try DCMDecoder(contentsOf: fileURL)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegExtended.rawValue)
        XCTAssertNil(
            decoder.getPixels16(),
            "12-bit JPEG Extended must not decode through the 8-bit delegated path"
        )
        XCTAssertNil(decoder.getPixels8(), "12-bit JPEG Extended must not silently downconvert")
    }

    // MARK: - Builders (deterministic, non-PHI)

    private static func rleSegment(samples: [UInt8]) -> Data {
        var rle = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { rle.append(contentsOf: $0) }
        }
        rle.append(UInt8(samples.count - 1))
        rle.append(contentsOf: samples)
        if rle.count % 2 != 0 {
            rle.append(0x00)
        }
        return rle
    }

    private static func makeEncapsulatedRLEFile(fragments: [Data], frames: Int) throws -> Data {
        try makeEncapsulatedFile(
            transferSyntax: .rleLossless,
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            fragments: fragments,
            frames: frames
        )
    }

    private static func makeEncapsulatedFile(
        transferSyntax: DicomTransferSyntax,
        bitsAllocated: UInt,
        bitsStored: UInt,
        highBit: UInt,
        fragments: [Data],
        frames: Int
    ) throws -> Data {
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12250001"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^ROBUST"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1225"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12250002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12250003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsAllocated])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([bitsStored])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([highBit])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames)"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                             value: .bytes(encapsulatedPixelData(fragments: fragments)))
        ])
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12250001"
            )
        )
    }

    private static func encapsulatedPixelData(fragments: [Data]) -> Data {
        var data = Data()
        var offsets: [UInt32] = []
        var runningOffset: UInt32 = 0
        for fragment in fragments {
            offsets.append(runningOffset)
            runningOffset += UInt32(8 + fragment.count)
        }
        var offsetTable = Data()
        for offset in offsets {
            withUnsafeBytes(of: offset.littleEndian) { offsetTable.append(contentsOf: $0) }
        }
        appendItem(offsetTable, to: &data)
        for fragment in fragments {
            appendItem(fragment, to: &data)
        }
        appendTag(0xFFFE_E0DD, to: &data)
        withUnsafeBytes(of: UInt32(0).littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func appendItem(_ payload: Data, to data: inout Data) {
        appendTag(0xFFFE_E000, to: &data)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
    }

    private static func appendTag(_ tag: UInt32, to data: inout Data) {
        withUnsafeBytes(of: UInt16(tag >> 16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(tag & 0xFFFF).littleEndian) { data.append(contentsOf: $0) }
    }
}
