//
//  DicomLosslessCodecTests.swift
//  DicomCoreTests
//
//  Checks signed RLE pixel representation and JPEG-LS near-lossless error bounds.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomLosslessCodecTests: XCTestCase {
    func testRLELosslessDecodes16BitGrayscaleFrame() throws {
        let pixels: [UInt16] = [0x0102, 0x0304, 0xABCD, 0xFEDC]
        let frame = makeRLEFrame(segments: [
            pixels.map { UInt8($0 >> 8) },
            pixels.map { UInt8($0 & 0xFF) }
        ])

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: frame,
            transferSyntax: .rleLossless,
            width: 2,
            height: 2,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertEqual(result.pixels16, pixels)
        XCTAssertNil(result.pixels8)
        XCTAssertFalse(result.signedImage)
    }

    func testRLELosslessPreservesSignedPixelRepresentation() throws {
        let source = [UInt16(bitPattern: Int16(-1024)), UInt16(bitPattern: Int16(0))]
        let frame = makeRLEFrame(segments: [
            source.map { UInt8($0 >> 8) },
            source.map { UInt8($0 & 0xFF) }
        ])

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: frame,
            transferSyntax: .rleLossless,
            width: 2,
            height: 1,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 1
        ))

        XCTAssertEqual(result.pixels16, [31_744, 32_768])
        XCTAssertTrue(result.signedImage)
    }

    func testRLELosslessDecodes8BitRGBFrame() throws {
        let frame = makeRLEFrame(segments: [
            [255, 0],
            [0, 128],
            [32, 64]
        ])

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: frame,
            transferSyntax: .rleLossless,
            width: 2,
            height: 1,
            bitDepth: 8,
            samplesPerPixel: 3,
            pixelRepresentation: 0
        ))

        XCTAssertEqual(result.pixels24, [255, 0, 32, 0, 128, 64])
        XCTAssertEqual(result.samplesPerPixel, 3)
    }

    func testDecoderRoutesEncapsulatedRLEThroughFrameIndex() throws {
        let pixels: [UInt16] = [0x1111, 0x2222, 0x3333, 0x4444]
        let frame = makeRLEFrame(segments: [
            pixels.map { UInt8($0 >> 8) },
            pixels.map { UInt8($0 & 0xFF) }
        ])
        let url = try makeTemporaryCompressedDICOM(
            transferSyntax: .rleLossless,
            frame: frame,
            width: 2,
            height: 2,
            bitsAllocated: 16,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            pixelRepresentation: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertTrue(decoder.compressedImage)
        XCTAssertEqual(decoder.getPixels16(), pixels)
    }

    func testJPEGLSLosslessDecodes16BitFrame() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        let pixels: [UInt16] = [100, 200, 1024, 4095]
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: littleEndianData(pixels),
            width: 2,
            height: 2,
            bitsPerSample: 16
        )

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpegLSLossless,
            pixelRepresentation: 0
        ))

        XCTAssertEqual(result.pixels16, pixels)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.bitDepth, 16)
    }

    func testDecoderRoutesEncapsulatedJPEGLSThroughFrameIndex() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        let pixels: [UInt16] = [10, 20, 30, 40]
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: littleEndianData(pixels),
            width: 2,
            height: 2,
            bitsPerSample: 16
        )
        let url = try makeTemporaryCompressedDICOM(
            transferSyntax: .jpegLSLossless,
            frame: encoded,
            width: 2,
            height: 2,
            bitsAllocated: 16,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            pixelRepresentation: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertTrue(decoder.compressedImage)
        XCTAssertEqual(decoder.getPixels16(), pixels)
    }

    func testJPEGLSNearLosslessDecodesWithinNearParameter() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        let pixels = Data([10, 12, 50, 52, 100, 101])
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: pixels,
            width: 3,
            height: 2,
            bitsPerSample: 8,
            nearLossless: 2
        )

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpegLSNearLossless,
            pixelRepresentation: 0
        ))

        let decoded = try XCTUnwrap(result.pixels8)
        XCTAssertEqual(decoded.count, pixels.count)
        for (actual, expected) in zip(decoded, pixels) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - Int(expected)), 2)
        }
    }

    func testJPEGLSLosslessPreservesSignedPixelRepresentation() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        let signedPixels = [UInt16(bitPattern: Int16(-1024)), UInt16(bitPattern: Int16(0))]
        let encoded = try DicomJPEGLSCodec.encodeForTesting(
            bytes: littleEndianData(signedPixels),
            width: 2,
            height: 1,
            bitsPerSample: 16
        )

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpegLSLossless,
            pixelRepresentation: 1
        ))

        XCTAssertEqual(result.pixels16, [31_744, 32_768])
        XCTAssertTrue(result.signedImage)
    }

    private func makeRLEFrame(segments: [[UInt8]]) -> Data {
        var frame = Data(count: 64)
        writeUInt32(UInt32(segments.count), to: &frame, offset: 0)

        var encodedSegments: [Data] = []
        var nextOffset = 64
        for (index, segment) in segments.enumerated() {
            writeUInt32(UInt32(nextOffset), to: &frame, offset: 4 + index * 4)
            let encoded = Data(encodeLiteralPackBits(segment))
            encodedSegments.append(encoded)
            nextOffset += encoded.count
        }
        for segment in encodedSegments {
            frame.append(segment)
        }
        return frame
    }

    private func encodeLiteralPackBits(_ bytes: [UInt8]) -> [UInt8] {
        var encoded: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let count = min(128, bytes.count - index)
            encoded.append(UInt8(count - 1))
            encoded.append(contentsOf: bytes[index..<index + count])
            index += count
        }
        return encoded
    }

    private func makeTemporaryCompressedDICOM(
        transferSyntax: DicomTransferSyntax,
        frame: Data,
        width: UInt16,
        height: UInt16,
        bitsAllocated: UInt16,
        samplesPerPixel: UInt16,
        photometricInterpretation: String,
        pixelRepresentation: UInt16
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lossless_codec_\(UUID().uuidString).dcm")
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendElement(tag: DicomTag.transferSyntaxUID.rawValue, vr: "UI", value: ui(transferSyntax.rawValue), to: &data)
        appendElement(tag: DicomTag.samplesPerPixel.rawValue, vr: "US", value: uint16Data(samplesPerPixel), to: &data)
        appendElement(tag: DicomTag.photometricInterpretation.rawValue, vr: "CS", value: stringData(photometricInterpretation, padding: 0x20), to: &data)
        appendElement(tag: DicomTag.rows.rawValue, vr: "US", value: uint16Data(height), to: &data)
        appendElement(tag: DicomTag.columns.rawValue, vr: "US", value: uint16Data(width), to: &data)
        appendElement(tag: DicomTag.bitsAllocated.rawValue, vr: "US", value: uint16Data(bitsAllocated), to: &data)
        appendElement(tag: DicomTag.bitsStored.rawValue, vr: "US", value: uint16Data(bitsAllocated), to: &data)
        appendElement(tag: DicomTag.highBit.rawValue, vr: "US", value: uint16Data(bitsAllocated - 1), to: &data)
        appendElement(tag: DicomTag.pixelRepresentation.rawValue, vr: "US", value: uint16Data(pixelRepresentation), to: &data)
        appendPixelData(makeEncapsulatedPixelData(frame: frame), to: &data)

        try data.write(to: url)
        return url
    }

    private func makeEncapsulatedPixelData(frame: Data) -> Data {
        var data = Data()
        appendItem(Data(), to: &data)
        appendItem(frame, to: &data)
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private func appendPixelData(_ value: Data, to data: inout Data) {
        appendTag(DicomTag.pixelData.rawValue, to: &data)
        data.append(contentsOf: "OB".utf8)
        data.append(contentsOf: [0x00, 0x00])
        appendUInt32(0xFFFFFFFF, to: &data)
        data.append(value)
    }

    private func appendElement(tag: Int, vr: String, value: Data, to data: inout Data) {
        appendTag(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OW", "OV", "SQ", "UN", "UT"].contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32(UInt32(value.count), to: &data)
        } else {
            appendUInt16(UInt16(value.count), to: &data)
        }
        data.append(value)
    }

    private func appendItem(_ value: Data, to data: inout Data) {
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }

    private func appendTag(_ tag: Int, to data: inout Data) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func uint16Data(_ value: UInt16) -> Data {
        var data = Data()
        appendUInt16(value, to: &data)
        return data
    }

    private func ui(_ value: String) -> Data {
        stringData(value, padding: 0x00)
    }

    private func stringData(_ value: String, padding: UInt8) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(padding)
        }
        return data
    }

    private func littleEndianData(_ pixels: [UInt16]) -> Data {
        pixels.reduce(into: Data()) { data, pixel in
            appendUInt16(pixel, to: &data)
        }
    }
}
