//
//  JPEGExtendedDecoderTests.swift
//  DicomCoreTests
//
//  Coverage for the precision-preserving JPEG Extended decode path
//  (issue #1228): deterministic 12-bit SOF1 fixtures built in-test
//  (DC-only blocks, all-ones quantization, custom canonical Huffman
//  tables), exact pixel and pinned-hash assertions, restart interval
//  handling, typed rejections naming transfer syntax, bit depth,
//  photometric interpretation and samples per pixel, and negative proof
//  that the ImageIO 8-bit fallback is never used for >8-bit frames.
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class JPEGExtendedDecoderTests: XCTestCase {
    // MARK: - Exact decode of deterministic 12-bit fixtures

    func testDecodesTwoBlockFlat12BitImageExactly() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 16, height: 8, blockValues: [1000, 3000]
        )
        let frame = try JPEGExtendedDecoder.decode(stream)

        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 8)
        XCTAssertEqual(frame.precision, 12)
        XCTAssertEqual(frame.pixels, Self.expectedTwoBlockPixels)
    }

    func testRestartIntervalsResetPredictorsBetweenBlocks() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 24, height: 8, blockValues: [1000, 3000, 500],
            restartInterval: 1
        )
        let frame = try JPEGExtendedDecoder.decode(stream)

        XCTAssertEqual(frame.width, 24)
        for row in 0..<8 {
            XCTAssertEqual(frame.pixels[row * 24], 1000, "block 0, row \(row)")
            XCTAssertEqual(frame.pixels[row * 24 + 8], 3000, "block 1, row \(row)")
            XCTAssertEqual(frame.pixels[row * 24 + 16], 500, "block 2, row \(row)")
        }
    }

    func testNonMultipleOfEightDimensionsClipBlockEdges() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 6, height: 5, blockValues: [2222]
        )
        let frame = try JPEGExtendedDecoder.decode(stream)

        XCTAssertEqual(frame.pixels.count, 30)
        XCTAssertTrue(frame.pixels.allSatisfy { $0 == 2222 })
    }

    // MARK: - Precision preservation through the pixel reader (no ImageIO)

    /// 12-bit values above 255 prove the decode did not pass through the
    /// 8-bit ImageIO grayscale path.
    func testPixelReaderDecodes12BitAs16BitBufferWithoutPrecisionLoss() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 16, height: 8, blockValues: [1000, 3000]
        )
        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: stream,
            transferSyntax: .jpegExtended,
            bitDepth: 12,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertNil(result.pixels8, "12-bit output must never surface as an 8-bit buffer")
        XCTAssertEqual(result.pixels16, Self.expectedTwoBlockPixels)
        XCTAssertEqual(result.bitDepth, 12)
        XCTAssertTrue(
            try XCTUnwrap(result.pixels16).contains { $0 > 255 },
            "values above 8 bits prove no ImageIO downconversion happened"
        )
    }

    /// A malformed 12-bit stream must fail typed through the native
    /// decoder; ImageIO is never consulted for >8-bit frames.
    func testMalformed12BitStreamFailsWithoutImageIOFallback() {
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: Data([0xFF, 0xD8, 0xFF, 0xC1, 0x00, 0x0B, 12, 0x00, 0x02, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9]),
            transferSyntax: .jpegExtended,
            bitDepth: 12,
            samplesPerPixel: 1,
            pixelRepresentation: 0,
            logger: logger
        )

        XCTAssertNil(result)
        XCTAssertTrue(logger.contains(level: .warning, text: "JPEG Extended native decoding failed"))
        XCTAssertFalse(logger.contains(level: .warning, text: "ImageIO"))
    }

    // MARK: - Signedness and MONOCHROME1 normalization

    func testSignedAndMonochrome1NormalizationMatchesGrayscaleContract() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 8, height: 8, blockValues: [1000]
        )
        let inverted = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: stream,
            transferSyntax: .jpegExtended,
            bitDepth: 12,
            samplesPerPixel: 1,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME1"
        ))
        XCTAssertEqual(inverted.pixels16?.first, 65535 - 1000, "MONOCHROME1 must invert like the other grayscale paths")

        let signed = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: stream,
            transferSyntax: .jpegExtended,
            bitDepth: 12,
            samplesPerPixel: 1,
            pixelRepresentation: 1
        ))
        XCTAssertEqual(
            signed.pixels16?.first,
            UInt16(Int(Int16(bitPattern: 1000)) - Int(Int16.min)),
            "signed samples must use the shared unsigned-offset normalization"
        )
        XCTAssertTrue(signed.signedImage)
    }

    // MARK: - End-to-end through the production frame reader

    func testDecodedFrameReaderReads12BitJPEGExtendedFrameWithPinnedHash() throws {
        let stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 16, height: 8, blockValues: [1000, 3000]
        )
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegExtended,
            fragments: [stream],
            declaredFrames: 1,
            rows: 8,
            columns: 16,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jpeg-extended-12-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let frame = try reader.frame(at: 0)
        guard case .gray16(let pixels) = frame.pixels else {
            return XCTFail("expected 16-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash(pixels.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            "06b42f0b9b4a5125",
            "decoded 12-bit JPEG Extended pixels must match the pinned deterministic hash"
        )
        XCTAssertEqual(frame.metadata.transferSyntaxUID, DicomTransferSyntax.jpegExtended.rawValue)
        XCTAssertEqual(frame.metadata.bitsStored, 12)
        XCTAssertEqual(frame.metadata.highBit, 11)
        XCTAssertEqual(frame.metadata.width, 16)
        XCTAssertEqual(frame.metadata.height, 8)
    }

    // MARK: - Backend routing pins

    func testResolverRoutesJPEGExtendedByBitDepth() {
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegExtended, requestedBitDepth: 12, samplesPerPixel: 1, bitsStored: 12,
                environment: ["DICOM_JPEGSWIFT_MODE": "disabled"]
            ).backend,
            .nativeJPEGExtended,
            "12-bit grayscale must use the native precision-preserving decoder when the own JPEG backend is disabled"
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegExtended, requestedBitDepth: 16, samplesPerPixel: 1, bitsStored: 12
            ).backend,
            .nativeJPEG,
            "12-bit grayscale uses the own JPEG backend by default"
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegExtended, requestedBitDepth: 8, samplesPerPixel: 1,
                environment: ["DICOM_JPEGSWIFT_MODE": "disabled"]
            ).backend,
            .imageIOJPEGExtended,
            "8-bit frames stay on the delegated ImageIO backend"
        )
    }

    func testColorAndOverPrecisionRejectionsNameEveryAttribute() {
        let color = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .jpegExtended,
            requestedBitDepth: 12,
            samplesPerPixel: 3,
            photometricInterpretation: "YBR_FULL_422"
        )
        XCTAssertEqual(color.backend, .unsupported)
        let colorDiagnostic = color.diagnostics.joined(separator: " ")
        XCTAssertTrue(colorDiagnostic.contains(DicomTransferSyntax.jpegExtended.rawValue))
        XCTAssertTrue(colorDiagnostic.contains("12-bit"))
        XCTAssertTrue(colorDiagnostic.contains("Photometric Interpretation=YBR_FULL_422"))
        XCTAssertTrue(colorDiagnostic.contains("Samples Per Pixel=3"))

        let overPrecision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .jpegExtended,
            requestedBitDepth: 16,
            samplesPerPixel: 1
        )
        XCTAssertEqual(overPrecision.backend, .unsupported)
        XCTAssertTrue(overPrecision.diagnostics.joined().contains("caps sample precision at 12 bits"))
    }

    // MARK: - Typed decoder errors

    func testProgressiveArithmeticAndMultiComponentStreamsFailTyped() {
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(Self.streamWithSOF(marker: 0xC2))) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .progressiveModeUnsupported)
        }
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(Self.streamWithSOF(marker: 0xC9))) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .arithmeticCodingUnsupported)
        }
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(Self.streamWithSOF(marker: 0xC1, components: 3))) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .multiComponentUnsupported(components: 3))
        }
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(Data([0x00, 0x01]))) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .notAJPEGStream)
        }
    }

    func testTruncatedEntropyDataFailsTyped() {
        var stream = JPEGExtendedFixtureFactory.makeDCOnlyStream(
            precision: 12, width: 16, height: 8, blockValues: [1000, 3000]
        )
        stream.removeLast(4) // drop entropy tail + EOI
        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(stream)) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .truncatedStream)
        }
    }

    func testZRLRunPastEndOfBlockFailsTyped() {
        let stream = JPEGExtendedFixtureFactory.makeZRLOverflowStream()

        XCTAssertThrowsError(try JPEGExtendedDecoder.decode(stream)) {
            XCTAssertEqual($0 as? JPEGExtendedDecoder.DecodeError, .invalidHuffmanCode)
        }
    }

    func test_zrlEndingAtBlockBoundary_decodesCompleteBlock() throws {
        let stream = JPEGExtendedFixtureFactory.makeZRLOverflowStream(exactlyFillsBlock: true)
        let decoded = try JPEGExtendedDecoder.decode(stream)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.pixels, Array(repeating: UInt16(2048), count: 64))
    }

    // MARK: - Expected data

    private static let expectedTwoBlockPixels: [UInt16] = {
        var pixels = [UInt16]()
        for _ in 0..<8 {
            pixels.append(contentsOf: [UInt16](repeating: 1000, count: 8))
            pixels.append(contentsOf: [UInt16](repeating: 3000, count: 8))
        }
        return pixels
    }()

    private static func streamWithSOF(marker: UInt8, components: UInt8 = 1) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, marker])
        let length = 8 + 3 * Int(components)
        data.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xFF), 12, 0x00, 0x08, 0x00, 0x08, components])
        for component in 0..<components {
            data.append(contentsOf: [component + 1, 0x11, 0x00])
        }
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }
}

/// Deterministic JPEG Extended (SOF1) encoder for tests: flat 8x8 blocks
/// expressed as DC-only coefficients over all-ones quantization tables, so
/// the decoded samples equal the requested block values exactly.
enum JPEGExtendedFixtureFactory {
    static func makeDCOnlyStream(
        precision: Int,
        width: Int,
        height: Int,
        blockValues: [Int],
        restartInterval: Int = 0
    ) -> Data {
        let blocksWide = (width + 7) / 8
        let blocksHigh = (height + 7) / 8
        precondition(blockValues.count == blocksWide * blocksHigh, "one value per 8x8 block")

        var data = Data([0xFF, 0xD8]) // SOI

        // DQT: 16-bit entries, all ones, table 0.
        data.append(contentsOf: [0xFF, 0xDB, 0x00, 0x83, 0x10])
        for _ in 0..<64 {
            data.append(contentsOf: [0x00, 0x01])
        }

        // SOF1: extended sequential, one grayscale component.
        data.append(contentsOf: [0xFF, 0xC1, 0x00, 0x0B, UInt8(precision)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xFF)])
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xFF)])
        data.append(contentsOf: [0x01, 0x01, 0x11, 0x00])

        // DHT DC table 0: sixteen symbols (categories 0...15), all 5 bits.
        data.append(contentsOf: [0xFF, 0xC4, 0x00, 0x23, 0x00])
        data.append(contentsOf: [0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: (0...15).map(UInt8.init))

        // DHT AC table 0: a single one-bit EOB code.
        data.append(contentsOf: [0xFF, 0xC4, 0x00, 0x14, 0x10])
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(0x00)

        if restartInterval > 0 {
            data.append(contentsOf: [0xFF, 0xDD, 0x00, 0x04])
            data.append(contentsOf: [UInt8(restartInterval >> 8), UInt8(restartInterval & 0xFF)])
        }

        // SOS: one component, DC table 0, AC table 0.
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])

        // Entropy-coded data: DC category + magnitude bits, then EOB.
        let levelShift = 1 << (precision - 1)
        var writer = StuffedBitWriter()
        var predictor = 0
        var restartCount = 0
        for (blockIndex, value) in blockValues.enumerated() {
            if restartInterval > 0, blockIndex > 0, blockIndex % restartInterval == 0 {
                writer.flushWithOnePadding(into: &data)
                data.append(contentsOf: [0xFF, UInt8(0xD0 + restartCount % 8)])
                restartCount += 1
                predictor = 0
            }
            let dcCoefficient = (value - levelShift) * 8
            let difference = dcCoefficient - predictor
            predictor = dcCoefficient

            let category = Self.magnitudeCategory(of: difference)
            writer.append(bits: category, count: 5, into: &data) // DC code i = symbol i
            if category > 0 {
                let magnitude = difference >= 0
                    ? difference
                    : difference + (1 << category) - 1
                writer.append(bits: magnitude, count: category, into: &data)
            }
            writer.append(bits: 0, count: 1, into: &data) // EOB ("0")
        }
        writer.flushWithOnePadding(into: &data)

        data.append(contentsOf: [0xFF, 0xD9]) // EOI
        return data
    }

    static func makeZRLOverflowStream(exactlyFillsBlock: Bool = false) -> Data {
        var data = Data([0xFF, 0xD8]) // SOI

        // DQT: 16-bit entries, all ones, table 0.
        data.append(contentsOf: [0xFF, 0xDB, 0x00, 0x83, 0x10])
        for _ in 0..<64 {
            data.append(contentsOf: [0x00, 0x01])
        }

        // SOF1: 12-bit 8x8 grayscale image.
        data.append(contentsOf: [
            0xFF, 0xC1, 0x00, 0x0B, 12, 0x00, 0x08,
            0x00, 0x08, 0x01, 0x01, 0x11, 0x00
        ])

        // DHT DC table 0: one-bit category 0 code.
        data.append(contentsOf: [0xFF, 0xC4, 0x00, 0x14, 0x00])
        data.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(0x00)

        // DHT AC table 0: ZRL and, optionally, fourteen zeros followed by a one-bit coefficient.
        data.append(contentsOf: [0xFF, 0xC4, 0x00, exactlyFillsBlock ? 0x15 : 0x14, 0x10])
        data.append(contentsOf: [exactlyFillsBlock ? 0 : 1, exactlyFillsBlock ? 2 : 0,
                                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        data.append(0xF0)
        if exactlyFillsBlock { data.append(0xE1) }

        // SOS: one component, DC table 0, AC table 0.
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])

        var writer = StuffedBitWriter()
        writer.append(bits: 0, count: 1, into: &data) // DC category 0
        if exactlyFillsBlock {
            writer.append(bits: 1, count: 2, into: &data) // Fourteen zeros, then one nonzero coefficient.
            writer.append(bits: 1, count: 1, into: &data)
        }
        for _ in 0..<(exactlyFillsBlock ? 3 : 4) {
            writer.append(bits: 0, count: exactlyFillsBlock ? 2 : 1, into: &data)
        }
        writer.flushWithOnePadding(into: &data)

        data.append(contentsOf: [0xFF, 0xD9]) // EOI
        return data
    }

    private static func magnitudeCategory(of value: Int) -> Int {
        var magnitude = abs(value)
        var category = 0
        while magnitude > 0 {
            magnitude >>= 1
            category += 1
        }
        return category
    }

    /// Big-endian bit writer with JPEG 0xFF byte stuffing.
    private struct StuffedBitWriter {
        private var currentByte: UInt8 = 0
        private var bitCount = 0

        mutating func append(bits value: Int, count: Int, into data: inout Data) {
            for shift in stride(from: count - 1, through: 0, by: -1) {
                currentByte = (currentByte << 1) | UInt8((value >> shift) & 1)
                bitCount += 1
                if bitCount == 8 {
                    emit(into: &data)
                }
            }
        }

        mutating func flushWithOnePadding(into data: inout Data) {
            while bitCount != 0 {
                currentByte = (currentByte << 1) | 1
                bitCount += 1
                if bitCount == 8 {
                    emit(into: &data)
                }
            }
        }

        private mutating func emit(into data: inout Data) {
            data.append(currentByte)
            if currentByte == 0xFF {
                data.append(0x00)
            }
            currentByte = 0
            bitCount = 0
        }
    }
}
