//
//  JPEGLosslessRestartAndColorTests.swift
//  DicomCoreTests
//
//  Coverage for JPEG Lossless restart intervals and multicomponent decode
//  (issue #1229): deterministic SOF3 streams built by the in-repo encoder
//  (makeJPEGLosslessStream) round-trip through the native decoder with
//  pinned pixel hashes, restart markers reset prediction and are validated
//  in order, and interleaved 8-bit RGB decodes while ambiguous color shapes
//  fail with diagnostics naming transfer syntax, photometric
//  interpretation, samples per pixel, and restart context.
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class JPEGLosslessRestartAndColorTests: XCTestCase {
    // MARK: - Restart intervals

    func testRestartIntervalStreamRoundTripsWithPinnedHash() throws {
        let width = 16, height = 4
        let samples = Self.gradientSamples(width: width, height: height)
        let stream = makeJPEGLosslessStream(
            planes: [samples],
            width: width,
            height: height,
            precision: 12,
            selectionValue: 1,
            restartInterval: width
        )

        let result = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(result.componentCount, 1)
        XCTAssertEqual(result.pixels.map(Int.init), samples)
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash(result.pixels.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            "ff6b098ea81aded5",
            "restart-interval decode must match the pinned deterministic hash"
        )
    }

    /// The same samples encoded with and without restart intervals must
    /// decode identically — restarts change framing, never pixel values.
    func testRestartFramingDoesNotChangeDecodedPixels() throws {
        let width = 8, height = 4
        let samples = Self.gradientSamples(width: width, height: height)
        let plain = try JPEGLosslessDecoder().decode(data: makeJPEGLosslessStream(
            planes: [samples], width: width, height: height, precision: 12
        ))
        let restarted = try JPEGLosslessDecoder().decode(data: makeJPEGLosslessStream(
            planes: [samples], width: width, height: height, precision: 12, restartInterval: width
        ))
        XCTAssertEqual(plain.pixels, restarted.pixels)
        XCTAssertEqual(restarted.pixels.map(Int.init), samples)
    }

    func testRestartMarkerOutOfOrderIsTypedWithContext() throws {
        let width = 8, height = 2
        var stream = makeJPEGLosslessStream(
            planes: [Self.gradientSamples(width: width, height: height)],
            width: width,
            height: height,
            precision: 12,
            restartInterval: width
        )
        // Corrupt the first restart marker (RST0 -> RST3) after the scan header.
        guard let sosRange = stream.range(of: Data([0xFF, 0xDA])),
              let markerRange = stream.range(of: Data([0xFF, 0xD0]), in: sosRange.upperBound..<stream.count) else {
            return XCTFail("expected an RST0 marker in the entropy data")
        }
        stream[markerRange.lowerBound + 1] = 0xD3

        XCTAssertThrowsError(try JPEGLosslessDecoder().decode(data: stream)) { error in
            guard case DICOMError.invalidDICOMFormat(let reason) = error else {
                return XCTFail("expected invalidDICOMFormat, got \(error)")
            }
            XCTAssertTrue(reason.contains("expected RST0"), reason)
            XCTAssertTrue(reason.contains("found RST3"), reason)
        }
    }

    func testEntropyDataEndingBeforeRestartMarkerIsTyped() throws {
        let width = 8, height = 2
        var stream = makeJPEGLosslessStream(
            planes: [Self.gradientSamples(width: width, height: height)],
            width: width,
            height: height,
            precision: 12,
            restartInterval: width
        )
        // Truncate right after the first restart marker so the second
        // interval's data (and any further marker) is missing.
        guard let sosRange = stream.range(of: Data([0xFF, 0xDA])),
              let markerRange = stream.range(of: Data([0xFF, 0xD0]), in: sosRange.upperBound..<stream.count) else {
            return XCTFail("expected an RST0 marker in the entropy data")
        }
        stream = stream.prefix(markerRange.upperBound + 1)

        XCTAssertThrowsError(try JPEGLosslessDecoder().decode(data: stream)) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                return XCTFail("expected invalidDICOMFormat, got \(error)")
            }
        }
    }

    /// T.81 H.1.2: the first line uses the Ra predictor for every selection
    /// value, so non-trivial first-row data must round-trip for SV != 1.
    func testSelectionValuePredictorsRoundTripWithFirstLineData() throws {
        let width = 4, height = 3
        let samples = [
            120, 340, 99, 4001,
            2048, 17, 805, 4095,
            33, 1500, 2500, 7
        ]
        for selectionValue in 1...7 {
            let stream = makeJPEGLosslessStream(
                planes: [samples],
                width: width,
                height: height,
                precision: 12,
                selectionValue: selectionValue
            )
            let result = try JPEGLosslessDecoder().decode(data: stream)
            XCTAssertEqual(result.pixels.map(Int.init), samples, "selection value \(selectionValue)")
        }
    }

    // MARK: - Multicomponent decode

    func testInterleavedRGB8BitDecodesThroughPixelReader() throws {
        let width = 4, height = 2
        let red = [10, 20, 30, 40, 50, 60, 70, 80]
        let green = [15, 25, 35, 45, 55, 65, 75, 85]
        let blue = [200, 190, 180, 170, 160, 150, 140, 130]
        let stream = makeJPEGLosslessStream(
            planes: [red, green, blue],
            width: width,
            height: height,
            precision: 8
        )

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: stream,
            transferSyntax: .jpegLosslessFirstOrder,
            bitDepth: 8,
            samplesPerPixel: 3,
            pixelRepresentation: 0,
            photometricInterpretation: "RGB",
            bitsStored: 8
        ))

        var expected = [UInt8]()
        for pixel in 0..<(width * height) {
            expected.append(contentsOf: [UInt8(red[pixel]), UInt8(green[pixel]), UInt8(blue[pixel])])
        }
        XCTAssertEqual(result.pixels24, expected)
        XCTAssertNil(result.pixels8)
        XCTAssertNil(result.pixels16)
        XCTAssertEqual(result.samplesPerPixel, 3)
    }

    func testRGBLosslessWithRestartsDecodesEndToEnd() throws {
        let width = 4, height = 2
        let red = [1, 2, 3, 4, 5, 6, 7, 8]
        let green = [11, 12, 13, 14, 15, 16, 17, 18]
        let blue = [21, 22, 23, 24, 25, 26, 27, 28]
        let stream = makeJPEGLosslessStream(
            planes: [red, green, blue],
            width: width,
            height: height,
            precision: 8,
            restartInterval: 4
        )
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [stream],
            declaredFrames: 1,
            rows: height,
            columns: width,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jll-rgb-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = try DicomDecodedFrameReader(contentsOf: url).frame(at: 0)
        guard case .rgb8(let interleaved) = frame.pixels else {
            return XCTFail("expected rgb8, got \(frame.pixels)")
        }
        var expected = [UInt8]()
        for pixel in 0..<(width * height) {
            expected.append(contentsOf: [UInt8(red[pixel]), UInt8(green[pixel]), UInt8(blue[pixel])])
        }
        XCTAssertEqual(interleaved, expected)
        XCTAssertEqual(frame.metadata.samplesPerPixel, 3)
        XCTAssertEqual(frame.metadata.photometricInterpretation, "RGB")
    }

    // MARK: - Rejected color shapes (typed, fully named)

    func testAmbiguousColorShapesAreRejectedWithFullContext() {
        // Issue #2821: YBR_FULL and YBR_FULL_422 components come out as coded; a partial-range YBR does not.
        XCTAssertEqual(DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .jpegLosslessFirstOrder, requestedBitDepth: 8, samplesPerPixel: 3,
            photometricInterpretation: "YBR_FULL", bitsStored: 8
        ).backend, .nativeJPEGLossless)
        let ybr = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .jpegLosslessFirstOrder,
            requestedBitDepth: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "YBR_PARTIAL_422",
            bitsStored: 8
        )
        XCTAssertEqual(ybr.backend, .unsupported)
        let ybrDiagnostic = ybr.diagnostics.joined(separator: " ")
        XCTAssertTrue(ybrDiagnostic.contains("multi-component"), ybrDiagnostic)
        XCTAssertTrue(ybrDiagnostic.contains(DicomTransferSyntax.jpegLosslessFirstOrder.rawValue), ybrDiagnostic)
        XCTAssertTrue(ybrDiagnostic.contains("Photometric Interpretation=YBR_PARTIAL_422"), ybrDiagnostic)
        XCTAssertTrue(ybrDiagnostic.contains("Samples Per Pixel=3"), ybrDiagnostic)

        let sixteenBitColor = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: .jpegLossless,
            requestedBitDepth: 16,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            bitsStored: 16
        )
        XCTAssertEqual(sixteenBitColor.backend, .unsupported)
        XCTAssertTrue(sixteenBitColor.diagnostics.joined().contains("16-bit"))
    }

    /// A >8-bit color stream that reaches the decoder through the legacy
    /// sniffing path must still fail with a stable diagnostic.
    func testHighBitDepthColorStreamFailsAtTheDecoderGuard() throws {
        let width = 2, height = 2
        let planes = [
            [100, 200, 300, 400],
            [500, 600, 700, 800],
            [900, 1000, 1100, 1200]
        ]
        let stream = makeJPEGLosslessStream(planes: planes, width: width, height: height, precision: 12)
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: stream,
            photometricInterpretation: "RGB",
            logger: logger
        )
        XCTAssertNil(result)
        XCTAssertTrue(logger.contains(level: .warning, text: "8 bits per component"))
    }

    func testSeparateScanMulticomponentIsRejectedWithContext() throws {
        // A 3-component frame whose scan selects only one component is the
        // non-interleaved (multi-scan) shape this decoder does not support.
        var stream = makeJPEGLosslessStream(
            planes: [[1, 2, 3, 4]],
            width: 2,
            height: 2,
            precision: 8
        )
        guard let sofRange = stream.range(of: Data([0xFF, 0xC3])) else {
            return XCTFail("missing SOF3")
        }
        // Rewrite SOF3 to declare 3 components (extend payload accordingly).
        let sofPayloadStart = sofRange.upperBound + 2
        var sof = Data()
        sof.append(contentsOf: [0x00, 0x11]) // new length: 8 + 3*3
        sof.append(stream[sofPayloadStart])  // precision
        sof.append(contentsOf: stream[(sofPayloadStart + 1)...(sofPayloadStart + 4)]) // dims
        sof.append(3)
        for id in 1...3 {
            sof.append(contentsOf: [UInt8(id), 0x11, 0x00])
        }
        stream.replaceSubrange(sofRange.upperBound..<(sofPayloadStart + 9), with: sof)

        XCTAssertThrowsError(try JPEGLosslessDecoder().decode(data: stream)) { error in
            guard case DICOMError.invalidDICOMFormat(let reason) = error else {
                return XCTFail("expected invalidDICOMFormat, got \(error)")
            }
            // Frame validation names both counts before scan decoding starts.
            XCTAssertTrue(reason.contains("SOF3=3"), reason)
            XCTAssertTrue(reason.contains("SOS=1"), reason)
        }
    }

    // MARK: - Helpers

    private static func gradientSamples(width: Int, height: Int) -> [Int] {
        var samples = [Int]()
        for y in 0..<height {
            for x in 0..<width {
                samples.append(100 + 13 * x + 57 * y)
            }
        }
        return samples
    }
}
