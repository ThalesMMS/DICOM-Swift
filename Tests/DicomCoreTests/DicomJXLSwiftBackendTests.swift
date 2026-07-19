import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import DicomCore

final class DicomJXLSwiftBackendTests: XCTestCase {
    func test_losslessGray8OddDimensions_roundTripsExactly() async throws {
        let pixels: [UInt8] = [0, 1, 127, 128, 254, 255]
        let descriptor = makeDescriptor(rows: 2, columns: 3, bitsAllocated: 8)

        let decoded = try await roundTrip(
            pixels: Data(pixels),
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )

        XCTAssertEqual(decoded.buffer.data, Data(pixels))
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.bitsPerSample, 8)
    }

    func test_losslessSignedGray16_roundTripsTwosComplementExactly() async throws {
        let values: [Int16] = [.min, -1_024, -1, 0, 1_024, .max]
        var pixels = Data()
        for value in values {
            let pattern = UInt16(bitPattern: value)
            pixels.append(UInt8(truncatingIfNeeded: pattern))
            pixels.append(UInt8(truncatingIfNeeded: pattern >> 8))
        }
        let descriptor = makeDescriptor(
            rows: 2,
            columns: 3,
            bitsAllocated: 16,
            pixelRepresentation: 1
        )

        let decoded = try await roundTrip(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )

        XCTAssertEqual(decoded.buffer.data, pixels)
        XCTAssertEqual(decoded.bitsPerSample, 16)
    }

    func test_losslessRGB8_roundTripsInterleavedSamplesExactly() async throws {
        let pixels = Data([
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            12, 34, 56
        ])
        let descriptor = makeDescriptor(
            rows: 2,
            columns: 2,
            bitsAllocated: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            planarConfiguration: 0
        )

        let decoded = try await roundTrip(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )

        XCTAssertEqual(decoded.buffer.data, pixels)
        XCTAssertEqual(decoded.componentCount, 3)
    }

    func test_generalJPEGXLIrreversible_encodesAndDecodesQualifiedGray8() async throws {
        let pixels = Data((0..<64).map { UInt8($0 * 4) })
        let descriptor = makeDescriptor(rows: 8, columns: 8, bitsAllocated: 8, syntax: .jpegXL)

        let decoded = try await roundTrip(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXL,
            intent: .irreversible(quality: 0.9)
        )

        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.buffer.data.count, pixels.count)
    }

    func test_jpegRecompression_reconstructsBaselineJPEGByteForByte() async throws {
        let jpeg = try makeBaselineJPEG()
        let backend = DicomJXLSwiftBackend()

        let jxl = try await backend.recompressJPEG(jpeg)
        let reconstructed = try await backend.reconstructJPEG(jxl)

        XCTAssertEqual(reconstructed, jpeg)
        XCTAssertTrue(jxl.starts(with: [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]))
    }

    func test_jpegRecompression_rgbBaselineReconstructsByteForByteAndDecodes() async throws {
        let jpeg = try makeBaselineRGBJPEG()
        let backend = DicomJXLSwiftBackend()

        let jxl = try await backend.recompressJPEG(jpeg)
        let reconstructed = try await backend.reconstructJPEG(jxl)
        let decoded = try await backend.decode(DicomFrameDecodeRequest(
            frameData: jxl,
            descriptor: makeDescriptor(
                rows: 2,
                columns: 2,
                bitsAllocated: 8,
                samplesPerPixel: 3,
                photometricInterpretation: "RGB",
                planarConfiguration: 0,
                syntax: .jpegXLJPEGRecompression
            ),
            frameIndex: 0
        ))
        let reference = try XCTUnwrap(DCMPixelReader.decodeCompressedFrameData(
            data: jpeg,
            transferSyntax: .jpegBaseline,
            width: 2,
            height: 2,
            bitDepth: 8,
            samplesPerPixel: 3,
            pixelRepresentation: 0,
            photometricInterpretation: "RGB",
            bitsStored: 8
        ))

        XCTAssertEqual(reconstructed, jpeg)
        XCTAssertEqual(decoded.buffer.data, Data(try XCTUnwrap(reference.pixels24)))
        XCTAssertEqual(decoded.componentCount, 3)
    }

    func test_unqualifiedTwelveBitLayout_isRejectedWithTypedError() async {
        let descriptor = makeDescriptor(
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11
        )
        let frame = DicomCodecDecodedFrame(
            buffer: .owned(Data(repeating: 0, count: 8)),
            width: 2,
            height: 2,
            bitsPerSample: 12,
            componentCount: 1
        )

        do {
            _ = try await DicomJXLSwiftBackend().encode(DicomFrameEncodeRequest(
                frame: frame,
                descriptor: descriptor,
                targetTransferSyntaxUID: DicomTransferSyntax.jpegXLLossless.rawValue,
                intent: .reversible
            ))
            XCTFail("Expected the unqualified 12-bit path to fail")
        } catch let error as DicomJXLSwiftBackendError {
            guard case .unsupportedShape(_, let reason) = error else {
                return XCTFail("Expected unsupportedShape, got \(error)")
            }
            XCTAssertTrue(reason.contains("10/12-bit"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_malformedAndOversizedFrames_failWithoutAllocation() async {
        let backend = DicomJXLSwiftBackend()
        let malformed = DicomFrameDecodeRequest(
            frameData: Data([0xFF, 0x00, 0x01]),
            descriptor: makeDescriptor(rows: 2, columns: 2, bitsAllocated: 8),
            frameIndex: 0
        )
        await XCTAssertThrowsErrorAsync(try await backend.decode(malformed))

        let oversized = DicomFrameDecodeRequest(
            frameData: Data(),
            descriptor: makeDescriptor(rows: 16_385, columns: 1, bitsAllocated: 8),
            frameIndex: 0
        )
        do {
            _ = try await backend.decode(oversized)
            XCTFail("Expected oversized dimensions to fail")
        } catch let error as DicomJXLSwiftBackendError {
            guard case .unsupportedShape(_, let reason) = error else {
                return XCTFail("Expected unsupportedShape, got \(error)")
            }
            XCTAssertTrue(reason.contains("1...16384"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_rolloutMode_defaultsDisabledAndRequiresExplicitValue() {
        XCTAssertEqual(DicomJXLSwiftRolloutMode(environment: [:]), .disabled)
        XCTAssertEqual(
            DicomJXLSwiftRolloutMode(environment: [DicomJXLSwiftRolloutMode.environmentKey: "experimental"]),
            .experimental
        )
        XCTAssertEqual(
            DicomJXLSwiftRolloutMode(environment: [DicomJXLSwiftRolloutMode.environmentKey: "invalid"]),
            .disabled
        )
    }

    func test_frameDecoder_reportsBytesRatioTimingAndBridgeOutcome() async throws {
        let pixels = Data([0, 64, 128, 255])
        let descriptor = makeDescriptor(rows: 2, columns: 2, bitsAllocated: 8)
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )
        let request = DicomFrameDecodeRequest(
            frameData: encoded,
            descriptor: descriptor,
            frameIndex: 3
        )
        let recorder = JXLTelemetryRecorder()

        let disabled = try await DicomJXLSwiftFrameDecoder.decode(
            request,
            environment: [:],
            report: { recorder.record($0) }
        )
        XCTAssertNil(disabled)
        XCTAssertTrue(recorder.values.isEmpty)

        let decoded = try await DicomJXLSwiftFrameDecoder.decode(
            request,
            environment: [DicomJXLSwiftRolloutMode.environmentKey: "forced-for-tests"],
            report: { recorder.record($0) }
        )
        let telemetry = try XCTUnwrap(recorder.values.last)
        XCTAssertEqual(decoded?.buffer.data, pixels)
        XCTAssertEqual(telemetry.frameIndex, 3)
        XCTAssertEqual(telemetry.compressedBytes, encoded.count)
        XCTAssertEqual(telemetry.decodedBytes, pixels.count)
        XCTAssertEqual(telemetry.compressionRatio, Double(pixels.count) / Double(encoded.count))
        XCTAssertGreaterThanOrEqual(telemetry.duration, 0)
        XCTAssertFalse(telemetry.reconstructedJPEG)
        XCTAssertTrue(telemetry.succeeded)
    }

#if os(macOS)
    func test_jxlswiftOutput_decodesByteExactWithLibjxl() async throws {
        let djxl = try requireExecutable("djxl")
        let pixels = Data([0, 1, 127, 128, 254, 255])
        let descriptor = makeDescriptor(rows: 2, columns: 3, bitsAllocated: 8)
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.jxl")
        let output = directory.appendingPathComponent("frame.pgm")
        try encoded.write(to: input)

        try run(djxl, arguments: [input.path, output.path])

        let decoded = try readPNM(output)
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.maximumValue, 255)
        XCTAssertEqual(decoded.pixels, pixels)
    }

    func test_jxlswiftGray16Output_decodesByteExactWithLibjxl() async throws {
        let djxl = try requireExecutable("djxl")
        let values: [UInt16] = [0, 1, 0x1234, 0x8000, 0xFFFE, 0xFFFF]
        var pixels = Data()
        values.forEach { value in
            pixels.append(UInt8(truncatingIfNeeded: value))
            pixels.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        let descriptor = makeDescriptor(rows: 2, columns: 3, bitsAllocated: 16)
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.jxl")
        let output = directory.appendingPathComponent("frame.pgm")
        try encoded.write(to: input)

        try run(djxl, arguments: [input.path, output.path])

        let decoded = try readPNM(output)
        XCTAssertEqual(decoded.maximumValue, 65_535)
        var littleEndian = Data()
        for index in stride(from: 0, to: decoded.pixels.count, by: 2) {
            littleEndian.append(decoded.pixels[index + 1])
            littleEndian.append(decoded.pixels[index])
        }
        XCTAssertEqual(littleEndian, pixels)
    }

    func test_jxlswiftRGB8Output_decodesByteExactWithLibjxl() async throws {
        let djxl = try requireExecutable("djxl")
        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 12, 34, 56])
        let descriptor = makeDescriptor(
            rows: 2,
            columns: 2,
            bitsAllocated: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            planarConfiguration: 0
        )
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.jxl")
        let output = directory.appendingPathComponent("frame.ppm")
        try encoded.write(to: input)

        try run(djxl, arguments: [input.path, output.path])

        let decoded = try readPNM(output)
        XCTAssertEqual(decoded.magic, "P6")
        XCTAssertEqual(decoded.pixels, pixels)
    }

    func test_libjxlLosslessOutput_decodesByteExactWithJXLSwift() async throws {
        let cjxl = try requireExecutable("cjxl")
        let pixels = Data([0, 1, 127, 128, 254, 255])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.pgm")
        let output = directory.appendingPathComponent("frame.jxl")
        var pgm = Data("P5\n3 2\n255\n".utf8)
        pgm.append(pixels)
        try pgm.write(to: input)

        try run(cjxl, arguments: [input.path, output.path, "--distance=0"])

        let encoded = try Data(contentsOf: output)
        let decoded = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: encoded,
            descriptor: makeDescriptor(rows: 2, columns: 3, bitsAllocated: 8),
            frameIndex: 0
        ))
        XCTAssertEqual(decoded.buffer.data, pixels)
    }

    func test_libjxlRGB8Output_decodesByteExactWithJXLSwift() async throws {
        let cjxl = try requireExecutable("cjxl")
        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 12, 34, 56])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.ppm")
        let output = directory.appendingPathComponent("frame.jxl")
        var ppm = Data("P6\n2 2\n255\n".utf8)
        ppm.append(pixels)
        try ppm.write(to: input)
        try run(cjxl, arguments: [input.path, output.path, "--distance=0"])

        let descriptor = makeDescriptor(
            rows: 2,
            columns: 2,
            bitsAllocated: 8,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            planarConfiguration: 0
        )
        let decoded = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: try Data(contentsOf: output),
            descriptor: descriptor,
            frameIndex: 0
        ))
        XCTAssertEqual(decoded.buffer.data, pixels)
    }

    func test_libjxlLossyOutput_decodesWithinToleranceWithJXLSwift() async throws {
        let cjxl = try requireExecutable("cjxl")
        let pixels = Data((0..<64).map { UInt8($0 * 4) })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.pgm")
        let output = directory.appendingPathComponent("frame.jxl")
        var pgm = Data("P5\n8 8\n255\n".utf8)
        pgm.append(pixels)
        try pgm.write(to: input)
        try run(cjxl, arguments: [input.path, output.path, "--distance=1"])

        let descriptor = makeDescriptor(
            rows: 8,
            columns: 8,
            bitsAllocated: 8,
            syntax: .jpegXL
        )
        let decoded = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: try Data(contentsOf: output),
            descriptor: descriptor,
            frameIndex: 0
        ))
        let differences = zip(decoded.buffer.data, pixels).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 8)
    }

    func test_jpegRecompression_reconstructsByteExactWithLibjxl() async throws {
        let djxl = try requireExecutable("djxl")
        let jpeg = try makeBaselineJPEG()
        let encoded = try await DicomJXLSwiftBackend().recompressJPEG(jpeg)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("frame.jxl")
        let output = directory.appendingPathComponent("reconstructed.jpg")
        try encoded.write(to: input)

        try run(djxl, arguments: [input.path, output.path])

        XCTAssertEqual(try Data(contentsOf: output), jpeg)
    }

    func test_performanceProbe_reportsLosslessClinicalShapeMetrics() async throws {
        let cjxl = try requireExecutable("cjxl")
        let djxl = try requireExecutable("djxl")
        let width = 256
        let height = 256
        var pixels = Data(capacity: width * height * 2)
        for index in 0..<(width * height) {
            let value = UInt16(truncatingIfNeeded: index &* 31)
            pixels.append(UInt8(truncatingIfNeeded: value))
            pixels.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        let descriptor = makeDescriptor(rows: height, columns: width, bitsAllocated: 16)
        let encodeStart = ContinuousClock.now
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: .jpegXLLossless,
            intent: .reversible
        )
        let encodeDuration = encodeStart.duration(to: .now)
        let decodeStart = ContinuousClock.now
        let decoded = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: encoded,
            descriptor: descriptor,
            frameIndex: 0
        ))
        let decodeDuration = decodeStart.duration(to: .now)

        XCTAssertEqual(decoded.buffer.data, pixels)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let estimatedWorkingSet = pixels.count + encoded.count + decoded.buffer.data.count
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pgm = directory.appendingPathComponent("clinical.pgm")
        let libjxl = directory.appendingPathComponent("clinical.jxl")
        let libjxlDecoded = directory.appendingPathComponent("clinical-decoded.pgm")
        var pgmData = Data("P5\n\(width) \(height)\n65535\n".utf8)
        for index in stride(from: 0, to: pixels.count, by: 2) {
            pgmData.append(pixels[index + 1])
            pgmData.append(pixels[index])
        }
        try pgmData.write(to: pgm)
        let libjxlEncodeStart = ContinuousClock.now
        try run(cjxl, arguments: [pgm.path, libjxl.path, "--distance=0"])
        let libjxlEncodeDuration = libjxlEncodeStart.duration(to: .now)
        let libjxlDecodeStart = ContinuousClock.now
        try run(djxl, arguments: [libjxl.path, libjxlDecoded.path])
        let libjxlDecodeDuration = libjxlDecodeStart.duration(to: .now)
        let libjxlPixels = try readPNM(libjxlDecoded).pixels
        XCTAssertEqual(libjxlPixels, Data(pgmData.suffix(pixels.count)))
        var childUsage = rusage()
        getrusage(RUSAGE_CHILDREN, &childUsage)
        let libjxlBytes = try Data(contentsOf: libjxl).count
        print(
            "JXL_PERF shape=256x256x16 encode_ms=\(encodeDuration.milliseconds) "
                + "decode_ms=\(decodeDuration.milliseconds) input_bytes=\(pixels.count) "
                + "encoded_bytes=\(encoded.count) ratio=\(Double(pixels.count) / Double(encoded.count)) "
                + "estimated_working_set_bytes=\(estimatedWorkingSet) peak_rss_bytes=\(usage.ru_maxrss) "
                + "libjxl_encode_ms=\(libjxlEncodeDuration.milliseconds) "
                + "libjxl_decode_ms=\(libjxlDecodeDuration.milliseconds) "
                + "libjxl_encoded_bytes=\(libjxlBytes) child_peak_rss_bytes=\(childUsage.ru_maxrss)"
        )
    }
#endif

    private func roundTrip(
        pixels: Data,
        descriptor: DicomCompressedFrameDescriptor,
        syntax: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> DicomCodecDecodedFrame {
        let encoded = try await encode(
            pixels: pixels,
            descriptor: descriptor,
            syntax: syntax,
            intent: intent
        )
        return try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: encoded,
            descriptor: descriptor,
            frameIndex: 0
        ))
    }

    private func encode(
        pixels: Data,
        descriptor: DicomCompressedFrameDescriptor,
        syntax: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        let frame = DicomCodecDecodedFrame(
            buffer: .owned(pixels),
            width: descriptor.columns,
            height: descriptor.rows,
            bitsPerSample: descriptor.bitsStored,
            componentCount: descriptor.samplesPerPixel
        )
        return try await DicomJXLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: frame,
            descriptor: descriptor,
            targetTransferSyntaxUID: syntax.rawValue,
            intent: intent
        ))
    }

    private func makeDescriptor(
        rows: Int,
        columns: Int,
        bitsAllocated: Int,
        bitsStored: Int? = nil,
        highBit: Int? = nil,
        pixelRepresentation: Int = 0,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        planarConfiguration: Int? = nil,
        syntax: DicomTransferSyntax = .jpegXLLossless
    ) -> DicomCompressedFrameDescriptor {
        let stored = bitsStored ?? bitsAllocated
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue,
            rows: rows,
            columns: columns,
            bitsAllocated: bitsAllocated,
            bitsStored: stored,
            highBit: highBit ?? stored - 1,
            pixelRepresentation: pixelRepresentation,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometricInterpretation,
            planarConfiguration: planarConfiguration
        )
    }

    private func makeBaselineJPEG() throws -> Data {
        let pixels: [UInt8] = [0, 64, 128, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeBaselineRGBJPEG() throws -> Data {
        let pixels = Data([
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            32, 64, 96
        ])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: 6,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            // Expected.
        }
    }

#if os(macOS)
    private func requireExecutable(_ name: String) throws -> String {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = (pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Required interoperability tool \(name) is unavailable")
        }
        return executable
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostic = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return XCTFail("\(executable) failed: \(diagnostic)")
        }
    }

    private func readPNM(
        _ url: URL
    ) throws -> (magic: String, width: Int, height: Int, maximumValue: Int, pixels: Data) {
        let data = try Data(contentsOf: url)
        var index = 0
        func nextToken() -> String? {
            while index < data.count && data[index].isASCIIWhitespace { index += 1 }
            guard index < data.count else { return nil }
            let start = index
            while index < data.count && !data[index].isASCIIWhitespace { index += 1 }
            return String(data: data[start..<index], encoding: .ascii)
        }
        guard let magic = nextToken(), magic == "P5" || magic == "P6",
              let widthToken = nextToken(), let width = Int(widthToken),
              let heightToken = nextToken(), let height = Int(heightToken),
              let maximumToken = nextToken(), let maximumValue = Int(maximumToken) else {
            throw DicomJXLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: DicomTransferSyntax.jpegXLLossless.rawValue,
                reason: "djxl did not emit a binary PGM/PPM"
            )
        }
        while index < data.count && data[index].isASCIIWhitespace { index += 1 }
        return (magic, width, height, maximumValue, Data(data[index...]))
    }
#endif
}

private final class JXLTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomJXLSwiftDecodeTelemetry] = []

    var values: [DicomJXLSwiftDecodeTelemetry] {
        lock.withLock { storage }
    }

    func record(_ telemetry: DicomJXLSwiftDecodeTelemetry) {
        lock.withLock { storage.append(telemetry) }
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1.0e15
    }
}
