import CoreGraphics
import ImageIO
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomLossyCodecBackendTests: XCTestCase {
    func testJPEGBaseline8BitUsesExplicitImageIOBackend() throws {
        let image = try makeGrayscaleImage8(width: 2, height: 2, pixels: [48, 96, 144, 192])
        let encoded = try encodeImage(image, type: "public.jpeg" as CFString)

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpegBaseline,
            bitDepth: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertNotNil(result.pixels8)
        XCTAssertNil(result.pixels16)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(result.bitDepth, 8)
        XCTAssertEqual(result.samplesPerPixel, 1)
    }

    func testJPEG2000Lossless16BitGrayscalePreservesPrecision() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)

        let pixels: [UInt16] = [0, 1024, 4096, 65535]
        let encoded = try makeOpenJPEGLosslessCodestream16(width: 2, height: 2, pixels: pixels)

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpeg2000Lossless,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertEqual(result.pixels16, pixels)
        XCTAssertNil(result.pixels8)
        XCTAssertEqual(result.bitDepth, 16)
        XCTAssertEqual(result.samplesPerPixel, 1)
    }

    func testJPEG2000Lossy8BitUsesExplicitImageIOBackend() throws {
        let image = try makeGrayscaleImage8(width: 2, height: 2, pixels: [12, 64, 128, 240])
        let encoded = try encodeImage(
            image,
            type: "public.jpeg-2000" as CFString,
            properties: [kCGImageDestinationLossyCompressionQuality as String: 0.4] as CFDictionary
        )

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpeg2000,
            bitDepth: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        ))

        XCTAssertNotNil(result.pixels8)
        XCTAssertNil(result.pixels16)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.height, 2)
    }

    /// 12-bit JPEG Extended routes to the native decoder (#1228); a
    /// header-only stream fails typed there and ImageIO is never consulted.
    func testJPEGExtended12BitHeaderOnlyStreamFailsNativelyWithoutImageIO() {
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: Data([0xFF, 0xD8, 0xFF, 0xC1, 0x00, 0x0B, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00]),
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

    /// HTJ2K never routes through the generic ImageIO JPEG 2000 fallback:
    /// it decodes via the version-gated OpenJPEG capability (#1231) or
    /// fails typed when that capability is absent.
    func testHTJ2KNeverUsesTheImageIOJPEG2000Fallback() {
        let logger = MockLogger()
        let result = DCMPixelReader.decodeCompressedFrameData(
            data: Data([0xFF, 0x4F, 0xFF, 0x51]),
            transferSyntax: .htj2kLossless,
            bitDepth: 16,
            samplesPerPixel: 1,
            pixelRepresentation: 0,
            logger: logger
        )

        XCTAssertNil(result)
        if DicomJPEG2000Codec.supportsHTJ2K {
            XCTAssertTrue(logger.contains(level: .warning, text: "HTJ2K decoding failed"))
        } else {
            XCTAssertTrue(logger.contains(level: .warning, text: "ImageIO JPEG 2000 fallback is not used"))
        }
    }

    func testBackendResolverDocumentsExplicitDecisions() {
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegBaseline,
                requestedBitDepth: 8,
                samplesPerPixel: 1,
                environment: ["DICOM_JPEGSWIFT_MODE": "disabled"]
            ).backend,
            .imageIOJPEGBaseline,
            "the established ImageIO path stays reachable when the own JPEG backend is disabled"
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegBaseline,
                requestedBitDepth: 8,
                samplesPerPixel: 1
            ).backend,
            .nativeJPEG
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpeg2000Lossless,
                requestedBitDepth: 16,
                samplesPerPixel: 1
            ).backend,
            DicomJPEG2000Codec.isAvailable ? .openJPEG2000 : .unsupported
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpegExtended,
                requestedBitDepth: 12,
                samplesPerPixel: 1
            ).backend,
            .nativeJPEGExtended
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .htj2k,
                requestedBitDepth: 16,
                samplesPerPixel: 1
            ).backend,
            DicomJPEG2000Codec.supportsHTJ2K ? .openJPEGHTJ2K : .unsupported
        )
        XCTAssertEqual(
            DicomCompressedPixelBackendResolver.resolve(
                transferSyntax: .jpeg2000Part2MulticomponentLossless,
                requestedBitDepth: 16,
                samplesPerPixel: 1
            ).backend,
            .unsupported
        )
    }

    // MARK: - JPEG 2000 color transforms (issue #1232)

    /// Lossless JPEG 2000 RGB encodes apply the reversible color transform
    /// (DICOM labels the data YBR_RCT); the OpenJPEG backend reverses it,
    /// so the decoded frame is exact RGB.
    func testJPEG2000RCTColorRoundTripsToExactRGB() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let source: [UInt8] = [
            255, 0, 0, 0, 255, 0,
            0, 0, 255, 200, 150, 100
        ]
        let encoded = try makeOpenJPEGColorCodestream(width: 2, height: 2, rgbPixels: source, lossless: true)

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpeg2000Lossless,
            bitDepth: 8,
            samplesPerPixel: 3,
            pixelRepresentation: 0,
            photometricInterpretation: "YBR_RCT",
            bitsStored: 8
        ))
        XCTAssertEqual(result.pixels24, source, "reversible color transform must round-trip exactly")
        XCTAssertNil(result.pixels8, "RCT color must never surface as grayscale")
    }

    /// Lossy JPEG 2000 RGB uses the irreversible transform (YBR_ICT); the
    /// backend output is RGB within compression tolerance.
    func testJPEG2000ICTLossyColorDecodesToApproximateRGB() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let source: [UInt8] = [
            255, 0, 0, 0, 255, 0,
            0, 0, 255, 200, 150, 100
        ]
        let encoded = try makeOpenJPEGColorCodestream(width: 2, height: 2, rgbPixels: source, lossless: false)

        let result = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: encoded,
            transferSyntax: .jpeg2000,
            bitDepth: 8,
            samplesPerPixel: 3,
            pixelRepresentation: 0,
            photometricInterpretation: "YBR_ICT",
            bitsStored: 8
        ))
        let decoded = try XCTUnwrap(result.pixels24)
        XCTAssertEqual(decoded.count, source.count)
        for (index, expected) in source.enumerated() {
            XCTAssertLessThanOrEqual(
                abs(Int(decoded[index]) - Int(expected)), 24,
                "ICT sample \(index) drifted beyond lossy tolerance"
            )
        }
        XCTAssertNil(result.pixels8, "ICT color must never surface as grayscale")
    }

    private func makeOpenJPEGColorCodestream(
        width: Int,
        height: Int,
        rgbPixels: [UInt8],
        lossless: Bool
    ) throws -> Data {
        XCTAssertEqual(rgbPixels.count, width * height * 3)
        let executable = try DicomTestRuntimePreflight.requireExecutable(.opjCompress, named: "opj_compress")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jpeg2000_color_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.ppm")
        let encodedURL = directory.appendingPathComponent("source.j2k")
        var source = Data("P6\n\(width) \(height)\n255\n".utf8)
        source.append(contentsOf: rgbPixels)
        try source.write(to: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var arguments = ["-i", sourceURL.path, "-o", encodedURL.path, "-n", "1"]
        if !lossless {
            arguments.append(contentsOf: ["-I", "-r", "5"])
        }
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            XCTFail("opj_compress failed: \(error)")
            return Data()
        }
        return try Data(contentsOf: encodedURL)
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

    private func makeOpenJPEGLosslessCodestream16(width: Int, height: Int, pixels: [UInt16]) throws -> Data {
        XCTAssertEqual(pixels.count, width * height)
        let executable = try DicomTestRuntimePreflight.requireExecutable(.opjCompress, named: "opj_compress")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jpeg2000_fixture_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pgm")
        let encodedURL = directory.appendingPathComponent("source.j2k")
        var source = Data("P5\n\(width) \(height)\n65535\n".utf8)
        for pixel in pixels {
            source.append(UInt8(pixel >> 8))
            source.append(UInt8(pixel & 0xFF))
        }
        try source.write(to: sourceURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-i", sourceURL.path, "-o", encodedURL.path, "-n", "1"]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            XCTFail("opj_compress failed: \(error)")
            return Data()
        }
        return try Data(contentsOf: encodedURL)
    }

    private func encodeImage(_ image: CGImage, type: CFString, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw XCTSkip("ImageIO cannot create destination for \(type)")
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO cannot encode \(type)")
        }
        return data as Data
    }
}
