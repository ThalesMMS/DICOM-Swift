import CoreGraphics
import ImageIO
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomCompressedPixelCodecMatrixTests: XCTestCase {
    func testCompressedPixelSupportMatrixCoversEveryCompressedReferencedAndVideoSyntax() throws {
        let registry = DicomTransferSyntaxRegistry.standard
        let matrix = registry.compressedPixelSupportMatrix
        let matrixBySyntax = Dictionary(uniqueKeysWithValues: matrix.map { ($0.syntax, $0) })
        let expectedSyntaxes = registry.entries
            .filter { $0.isCompressed || $0.pixelEncoding == .referenced }
            .map(\.syntax)

        XCTAssertEqual(Set(matrixBySyntax.keys), Set(expectedSyntaxes))
        XCTAssertEqual(matrixBySyntax[.deflatedExplicitVRLittleEndian]?.status, .outOfScope)
        XCTAssertEqual(matrixBySyntax[.jpegBaseline]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.jpegExtended]?.status, .decoded)
        XCTAssertEqual(matrixBySyntax[.jpegLossless]?.status, .decoded)
        XCTAssertEqual(matrixBySyntax[.jpegLosslessFirstOrder]?.status, .decoded)
        XCTAssertEqual(matrixBySyntax[.jpegLSLossless]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.jpegLSNearLossless]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.jpeg2000Lossless]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.jpeg2000]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.jpeg2000Part2MulticomponentLossless]?.status, .experimental)
        XCTAssertEqual(matrixBySyntax[.jpeg2000Part2Multicomponent]?.status, .experimental)
        XCTAssertEqual(matrixBySyntax[.jpipReferenced]?.status, .streamedOnly)
        XCTAssertEqual(matrixBySyntax[.jpipReferencedDeflate]?.status, .streamedOnly)
        XCTAssertEqual(matrixBySyntax[.htj2kLossless]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.htj2kLosslessRPCL]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.htj2k]?.status, .delegated)
        XCTAssertEqual(matrixBySyntax[.rleLossless]?.status, .decoded)
        XCTAssertEqual(matrixBySyntax[.deflatedImageFrameCompression]?.status, .decoded)

        for syntax in videoTransferSyntaxes {
            XCTAssertEqual(matrixBySyntax[syntax]?.status, .streamedOnly, "\(syntax) should be streamed-only")
        }

        for row in matrix {
            XCTAssertFalse(row.diagnostic.isEmpty, "\(row.syntax) should have a stable diagnostic")
        }
    }

    func testLocalFixtureBackedDecodedAndDelegatedSyntaxesReturnPixels() throws {
        let jpegBaseline = try encodeImage(
            makeGrayscaleImage8(width: 2, height: 2, pixels: [20, 60, 120, 240]),
            type: "public.jpeg" as CFString
        )

        for transferSyntax in [DicomTransferSyntax.jpegBaseline, .jpegExtended] {
            let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
                data: jpegBaseline,
                transferSyntax: transferSyntax,
                bitDepth: 8,
                samplesPerPixel: 1,
                pixelRepresentation: 0
            ))

            XCTAssertEqual(result.width, 2)
            XCTAssertEqual(result.height, 2)
            XCTAssertEqual(result.bitDepth, 8)
            XCTAssertNotNil(result.pixels8)
        }

        for transferSyntax in [DicomTransferSyntax.jpegLossless, .jpegLosslessFirstOrder] {
            let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
                data: makeMinimalJPEGLosslessData(width: 2, height: 2),
                transferSyntax: transferSyntax,
                bitDepth: 16,
                samplesPerPixel: 1,
                pixelRepresentation: 0
            ))

            XCTAssertEqual(result.pixels16, [32_768, 32_768, 32_768, 32_768])
            XCTAssertEqual(result.bitDepth, 16)
            XCTAssertEqual(result.samplesPerPixel, 1)
        }

        let rlePixels: [UInt16] = [0x0102, 0x0304, 0xABCD, 0xFEDC]
        let rleFrame = makeRLEFrame(segments: [
            rlePixels.map { UInt8($0 >> 8) },
            rlePixels.map { UInt8($0 & 0xFF) }
        ])
        let rleResult = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: rleFrame,
            transferSyntax: .rleLossless,
            width: 2,
            height: 2,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertEqual(rleResult.pixels16, rlePixels)
    }

    func testUnsupportedCompressedPixelSyntaxesReturnStableDiagnostics() {
        assertUnsupported(
            transferSyntax: .jpegExtended,
            bitDepth: 12,
            samplesPerPixel: 3,
            photometricInterpretation: "YBR_FULL_422",
            expectedTexts: [
                "single-component grayscale only",
                "1.2.840.10008.1.2.4.51",
                "Photometric Interpretation=YBR_FULL_422",
                "Samples Per Pixel=3"
            ]
        )
        assertUnsupported(
            transferSyntax: .jpegExtended,
            bitDepth: 16,
            samplesPerPixel: 1,
            expectedTexts: ["caps sample precision at 12 bits", "16-bit output is not representable"]
        )
        assertUnsupported(
            transferSyntax: .jpipReferenced,
            bitDepth: 16,
            samplesPerPixel: 1,
            expectedTexts: ["references remote pixel data", "DicomJPIPClient"]
        )
        assertUnsupported(
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            bitDepth: 8,
            samplesPerPixel: 3,
            expectedTexts: ["encoded video stream", "video player"]
        )
    }

    func testMultiComponentUnsupportedPathsIncludePhotometricAndSampleContext() {
        assertUnsupported(
            transferSyntax: .jpegLossless,
            bitDepth: 16,
            samplesPerPixel: 3,
            photometricInterpretation: "YBR_FULL",
            expectedTexts: ["multi-component", "Photometric Interpretation=YBR_FULL", "Samples Per Pixel=3"]
        )
        assertUnsupported(
            transferSyntax: .jpeg2000Lossless,
            bitDepth: 16,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            expectedTexts: ["color output above 8 bits", "Photometric Interpretation=RGB", "Samples Per Pixel=3"]
        )
        assertUnsupported(
            transferSyntax: .jpeg2000Part2MulticomponentLossless,
            bitDepth: 16,
            samplesPerPixel: 3,
            photometricInterpretation: "MONOCHROME2",
            expectedTexts: [
                "Annex J collections",
                "Photometric Interpretation=MONOCHROME2",
                "Samples Per Pixel=3"
            ]
        )
    }

    /// Restart intervals decode natively since #1229: a DRI marker is
    /// parsed instead of rejected, and the stream decodes normally.
    func testJPEGLosslessRestartIntervalStreamsDecode() throws {
        var jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        guard let sosIndex = markerIndex(JPEGMarker.sos.rawValue, in: jpegData) else {
            XCTFail("Missing SOS marker in minimal JPEG Lossless data")
            return
        }

        jpegData.insert(contentsOf: [0xFF, JPEGMarker.dri.rawValue, 0x00, 0x04, 0x00, 0x04], at: sosIndex)

        let result = try JPEGLosslessDecoder().decode(data: jpegData)
        XCTAssertEqual(result.pixels.count, 4)
        XCTAssertEqual(result.componentCount, 1)
    }

    private var videoTransferSyntaxes: [DicomTransferSyntax] {
        [
            .mpeg2MainProfileMainLevel,
            .mpeg2MainProfileMainLevelFragmentable,
            .mpeg2MainProfileHighLevel,
            .mpeg2MainProfileHighLevelFragmentable,
            .mpeg4AVCH264HighProfileLevel41,
            .mpeg4AVCH264HighProfileLevel41Fragmentable,
            .mpeg4AVCH264BDCompatibleHighProfileLevel41,
            .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
            .mpeg4AVCH264HighProfileLevel42For2DVideo,
            .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
            .mpeg4AVCH264HighProfileLevel42For3DVideo,
            .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
            .mpeg4AVCH264StereoHighProfileLevel42,
            .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
            .hevcH265MainProfileLevel51,
            .hevcH265Main10ProfileLevel51
        ]
    }

    private func assertUnsupported(
        transferSyntax: DicomTransferSyntax,
        bitDepth: Int,
        samplesPerPixel: Int,
        photometricInterpretation: String = "MONOCHROME2",
        expectedTexts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            transferSyntax: transferSyntax,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel,
            pixelRepresentation: 0,
            photometricInterpretation: photometricInterpretation,
            logger: logger
        )

        XCTAssertNil(result, file: file, line: line)
        for text in expectedTexts {
            XCTAssertTrue(
                logger.contains(level: .warning, text: text),
                "Expected warning to contain '\(text)'",
                file: file,
                line: line
            )
        }
    }

    private func makeGrayscaleImage8(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        XCTAssertEqual(pixels.count, width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func encodeImage(_ image: CGImage, type: CFString) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw XCTSkip("ImageIO cannot create destination for \(type)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO cannot encode \(type)")
        }
        return data as Data
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

    private func writeUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func markerIndex(_ marker: UInt8, in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        for index in 0..<(data.count - 1) where data[index] == JPEGMarker.prefix && data[index + 1] == marker {
            return index
        }
        return nil
    }
}
