//
//  DicomTranscoderTests.swift
//  DicomCoreTests
//
//  Executable transcoding routes (issue #1237): native-to-native rewrite,
//  compressed pass-through, compressed-to-native decompression with
//  stored-value fidelity, the explicitly chosen JPEG-LS lossless encoder
//  route, and typed failures for every unsupported route before any
//  output is produced.
//

import CoreGraphics
import Foundation
import ImageIO
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomTranscoderTests: XCTestCase {
    // MARK: - Native-to-native rewrite and compressed pass-through

    func testNativeToNativeRewritePreservesMetadataAndPixels() throws {
        let source = try Self.makeNativeFile(storedValues: [-1000, -500, 0, 250])
        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)

        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(decoder.info(for: .patientName), "PARITY^TRANSCODE")
        XCTAssertEqual(decoder.intValue(for: .bitsStored), 16)
        XCTAssertEqual(Self.storedInt16Pixels(decoder), [-1000, -500, 0, 250],
                       "stored pixel values must survive the rewrite")
    }

    func testCompressedPassThroughPreservesEncapsulatedBytes() throws {
        let source = try Self.makeJPEGLosslessFile(storedValues: [100, 200, 300, 400])
        let output = try DicomTranscoder().transcode(source, to: .jpegLosslessFirstOrder)

        let sourceReader = try Self.open(source).makeEncapsulatedPixelFrameReader()
        let outputDecoder = try Self.open(output)
        XCTAssertEqual(outputDecoder.info(for: .transferSyntaxUID),
                       DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        let outputReader = try outputDecoder.makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(try outputReader.frameData(at: 0), try sourceReader.frameData(at: 0),
                       "compressed pass-through must preserve the frame payload byte-for-byte")
    }

    // MARK: - Compressed-to-native decompression

    func testCompressedToNativeDecompressionPreservesStoredValuesAndMetadata() throws {
        let stored = [100, 200, 300, 400]
        let source = try Self.makeJPEGLosslessFile(storedValues: stored)
        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)

        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertFalse(decoder.compressedImage)
        XCTAssertEqual(decoder.info(for: .patientName), "PARITY^TRANSCODE")
        XCTAssertEqual(decoder.intValue(for: .bitsAllocated), 16)
        XCTAssertEqual(decoder.intValue(for: .bitsStored), 16)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()).map(Int.init), stored,
                       "decompressed stored values must match the compressed source")
    }

    func testSignedCompressedSourceDecompressesWithStoredValueFidelity() throws {
        let stored: [Int16] = [-1000, -500, 0, 250]
        let patterns = stored.map { Int(UInt16(bitPattern: $0)) }
        let codestream = makeJPEGLosslessStream(planes: [patterns], width: 2, height: 2, precision: 16)
        let source = try Self.makeEncapsulatedFile(
            codestream: codestream, pixelRepresentation: 1
        )
        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)

        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.pixelRepresentationTagValue, 1)
        XCTAssertEqual(Self.storedInt16Pixels(decoder), stored.map(Int.init),
                       "signed stored values must survive decompression")
    }

    // MARK: - MONOCHROME1 decompression

    func testMonochrome1CompressedSourceDecompressesWithStoredValueFidelity() throws {
        let stored = [100, 200, 300, 400]
        let source = try Self.makeJPEGLosslessFile(storedValues: stored, photometricInterpretation: "MONOCHROME1")
        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)

        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(decoder.photometricInterpretation, "MONOCHROME1",
                       "the photometric interpretation must survive decompression")
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()).map(Int.init), stored.map { 65535 - $0 },
                       "native MONOCHROME1 display buffers re-invert, so stored values must round-trip exactly")
    }

    func testSignedMonochrome1CompressedSourceDecompressesWithStoredValueFidelity() throws {
        let stored: [Int16] = [-1000, -500, 0, 250]
        let patterns = stored.map { Int(UInt16(bitPattern: $0)) }
        let codestream = makeJPEGLosslessStream(planes: [patterns], width: 2, height: 2, precision: 16)
        let source = try Self.makeEncapsulatedFile(
            codestream: codestream, pixelRepresentation: 1, photometricInterpretation: "MONOCHROME1"
        )
        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)

        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.pixelRepresentationTagValue, 1)
        XCTAssertEqual(decoder.photometricInterpretation, "MONOCHROME1")
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()).map(Int.init),
                       stored.map { 65535 - (Int($0) + 32768) },
                       "signed stored values must survive decompression of display-inverted sources")
    }

    func testCompressRouteStillRejectsMonochrome1WithUnsupportedPixelShape() throws {
        try DicomTestRuntimePreflight.require(.charLS)
        let native = try Self.makeNativeFile(storedValues: [1, 2, 3, 4], photometricInterpretation: "MONOCHROME1")
        XCTAssertThrowsError(try DicomTranscoder().transcode(native, to: .jpegLSLossless)) { error in
            guard case DicomTranscoder.TranscodeError.unsupportedPixelShape = error else {
                return XCTFail("expected unsupportedPixelShape, got \(error)")
            }
        }
    }

    // MARK: - JPEG-LS lossless encoder route (CharLS-gated)

    func testNativeToJPEGLSLosslessRoundTripsThroughCharLS() throws {
        try DicomTestRuntimePreflight.require(.charLS)
        let stored = [-1000, -500, 0, 250]
        let source = try Self.makeNativeFile(storedValues: stored)

        let compressed = try DicomTranscoder().transcode(source, to: .jpegLSLossless)
        let compressedDecoder = try Self.open(compressed)
        XCTAssertEqual(compressedDecoder.info(for: .transferSyntaxUID),
                       DicomTransferSyntax.jpegLSLossless.rawValue)
        XCTAssertNotNil(try compressedDecoder.makeEncapsulatedPixelFrameReader(),
                        "the encoded output must be properly encapsulated")

        // Round trip back to native: stored values must be identical.
        let roundTrip = try DicomTranscoder().transcode(compressed, to: .explicitVRLittleEndian)
        let decoder = try Self.open(roundTrip)
        XCTAssertEqual(Self.storedInt16Pixels(decoder), stored,
                       "JPEG-LS lossless round trip must preserve stored values exactly")
    }

    func testAsyncJLSwiftLosslessRouteEncapsulatesEveryFrame() async throws {
        let source = try Self.makeNative8BitFile(framePixels: [
            [1, 2, 3, 4],
            [250, 100, 50, 0]
        ])

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpegLSLossless,
            intent: .reversible
        )
        let decoder = try Self.open(compressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLSLossless.rawValue)
        XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 2)

        let reader = DicomDecodedFrameReader(decoder: decoder)
        let expectedFrames: [[UInt8]] = [[1, 2, 3, 4], [250, 100, 50, 0]]
        for (index, expected) in expectedFrames.enumerated() {
            let frame = try await reader.frame(at: index)
            guard case .gray8(let pixels) = frame.pixels else {
                return XCTFail("Expected gray8 output for frame \(index)")
            }
            XCTAssertEqual(pixels, expected)
        }
    }

    func testAsyncJLSwiftNearLosslessRoutePreservesBoundAndLossyMetadata() async throws {
        let near = 2
        let sourcePixels: [UInt8] = [10, 12, 50, 52]
        let source = try Self.makeNative8BitFile(framePixels: [sourcePixels])
        let sourceSOPInstanceUID = try Self.open(source).info(for: .sopInstanceUID)

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpegLSNearLossless,
            intent: .jpegLSNearLossless(near: near)
        )
        let decoder = try Self.open(compressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLSNearLossless.rawValue)
        XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
        XCTAssertTrue(decoder.info(for: .lossyImageCompressionMethod).contains("ISO_14495_1"))
        XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), sourceSOPInstanceUID)

        let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        guard case .gray8(let pixels) = frame.pixels else {
            return XCTFail("Expected gray8 near-lossless output")
        }
        for (expected, actual) in zip(sourcePixels, pixels) {
            XCTAssertLessThanOrEqual(abs(Int(expected) - Int(actual)), near)
        }
    }

    func testAsyncJLSwiftNearLosslessRequiresExplicitNearIntent() async throws {
        let source = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4]])

        do {
            _ = try await DicomTranscoder().transcode(
                source,
                to: .jpegLSNearLossless,
                intent: .irreversible(quality: 0.8)
            )
            XCTFail("Expected the ambiguous quality intent to be rejected")
        } catch let error as DicomTranscoder.TranscodeError {
            guard case .encodeFailed(_, _, let reason) = error else {
                return XCTFail("Expected encodeFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("explicit JPEG-LS NEAR"))
        }
    }

    // MARK: - Experimental JPEG XL routes

    func testAsyncJPEGXLLosslessRouteEncapsulatesEveryFrameAndRoundTrips() async throws {
        try await withJXLSwiftExperimentalMode {
            let expectedFrames: [[UInt8]] = [
                [1, 2, 3, 4],
                [250, 100, 50, 0]
            ]
            let source = try Self.makeNative8BitFile(framePixels: expectedFrames)
            let compressed = try await DicomTranscoder().transcode(
                source,
                to: .jpegXLLossless,
                intent: .reversible
            )
            let compressedDecoder = try Self.open(compressed)
            XCTAssertEqual(
                compressedDecoder.info(for: .transferSyntaxUID),
                DicomTransferSyntax.jpegXLLossless.rawValue
            )
            XCTAssertEqual(try compressedDecoder.makeEncapsulatedPixelFrameReader().frameCount, 2)

            let reader = DicomDecodedFrameReader(decoder: compressedDecoder)
            for (index, expected) in expectedFrames.enumerated() {
                let frame = try await reader.frame(at: index)
                guard case .gray8(let pixels) = frame.pixels else {
                    return XCTFail("Expected gray8 output for frame \(index)")
                }
                XCTAssertEqual(pixels, expected)
            }

            let native = try await DicomTranscoder().transcode(
                compressed,
                to: .explicitVRLittleEndian,
                intent: .reversible
            )
            let nativeReader = DicomDecodedFrameReader(decoder: try Self.open(native))
            for (index, expected) in expectedFrames.enumerated() {
                guard case .gray8(let pixels) = try await nativeReader.frame(at: index).pixels else {
                    return XCTFail("Expected native gray8 output for frame \(index)")
                }
                XCTAssertEqual(pixels, expected)
            }
        }
    }

    func testAsyncJPEGXLLosslessSigned16RoundTripPreservesStoredValues() async throws {
        try await withJXLSwiftExperimentalMode {
            let stored = [-1_000, -500, 0, 250]
            let source = try Self.makeNativeFile(storedValues: stored)
            let compressed = try await DicomTranscoder().transcode(
                source,
                to: .jpegXLLossless,
                intent: .reversible
            )
            let native = try await DicomTranscoder().transcode(
                compressed,
                to: .explicitVRLittleEndian,
                intent: .reversible
            )

            XCTAssertEqual(Self.storedInt16Pixels(try Self.open(native)), stored)
        }
    }

    func testAsyncGeneralJPEGXLLossyRouteUpdatesDerivedMetadata() async throws {
        try await withJXLSwiftExperimentalMode {
            let source = try Self.makeNative8BitFile(framePixels: [[
                0, 64, 128, 255
            ]])
            let sourceSOPInstanceUID = try Self.open(source).info(for: .sopInstanceUID)

            let compressed = try await DicomTranscoder().transcode(
                source,
                to: .jpegXL,
                intent: .irreversible(quality: 0.9)
            )
            let decoder = try Self.open(compressed)

            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegXL.rawValue)
            XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
            XCTAssertTrue(decoder.info(for: .lossyImageCompressionMethod).contains("ISO_18181_1"))
            XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), sourceSOPInstanceUID)
            XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 1)
        }
    }

    func testAsyncJPEGRecompressionPreservesJPEGBytesAndExistingLossyMetadata() async throws {
        try await withJXLSwiftExperimentalMode {
            let source = try Self.makeJPEGBaselineFile()
            let sourceDecoder = try Self.open(source)
            let sourceJPEG = try sourceDecoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
            let sourceSOPInstanceUID = sourceDecoder.info(for: .sopInstanceUID)

            let compressed = try await DicomTranscoder().transcode(
                source,
                to: .jpegXLJPEGRecompression,
                intent: .reversible
            )
            let decoder = try Self.open(compressed)
            let jxl = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
            let reconstructed = try await DicomJXLSwiftBackend().reconstructJPEG(jxl)

            XCTAssertEqual(reconstructed, Self.jpegStreamThroughEOI(sourceJPEG))
            XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
            XCTAssertTrue(decoder.info(for: .lossyImageCompressionMethod).contains("ISO_10918_1"))
            XCTAssertEqual(decoder.info(for: .sopInstanceUID), sourceSOPInstanceUID)
            XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 1)
        }
    }

    func testAsyncJPEGXLRouteRemainsDisabledWithoutExplicitFlag() async throws {
        let source = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4]])
        try await withJXLSwiftMode(nil) {
            do {
                _ = try await DicomTranscoder().transcode(
                    source,
                    to: .jpegXLLossless,
                    intent: .reversible
                )
                XCTFail("Expected JPEG XL to remain disabled")
            } catch let error as DicomTranscoder.TranscodeError {
                guard case .routeUnsupported(_, _, let diagnostics) = error else {
                    return XCTFail("Expected routeUnsupported, got \(error)")
                }
                XCTAssertTrue(diagnostics.joined().contains("DICOM_JXLSWIFT_MODE=experimental"))
            }
        }
    }

    // MARK: - Unsupported routes stay typed

    func testUnsupportedEncoderRoutesFailTypedBeforeOutput() throws {
        let native = try Self.makeNativeFile(storedValues: [1, 2, 3, 4])
        XCTAssertThrowsError(try DicomTranscoder().transcode(native, to: .jpeg2000Lossless)) { error in
            guard case DicomTranscoder.TranscodeError.routeUnsupported(_, let destination, _) = error else {
                return XCTFail("expected routeUnsupported, got \(error)")
            }
            XCTAssertEqual(destination, DicomTransferSyntax.jpeg2000Lossless.rawValue)
        }

        let compressed = try Self.makeJPEGLosslessFile(storedValues: [1, 2, 3, 4])
        XCTAssertThrowsError(try DicomTranscoder().transcode(compressed, to: .rleLossless)) { error in
            guard case DicomTranscoder.TranscodeError.routeUnsupported = error else {
                return XCTFail("expected routeUnsupported for compressed-to-compressed, got \(error)")
            }
        }
    }

    func testDecompressionToNonNativeTargetFailsTyped() throws {
        let compressed = try Self.makeJPEGLosslessFile(storedValues: [1, 2, 3, 4])
        XCTAssertThrowsError(try DicomTranscoder().transcode(compressed, to: .explicitVRBigEndian)) { error in
            guard case DicomTranscoder.TranscodeError.routeUnsupported(_, _, let diagnostics) = error else {
                return XCTFail("expected routeUnsupported, got \(error)")
            }
            XCTAssertTrue(diagnostics.joined().contains("Explicit VR Little Endian"))
        }
    }

    // MARK: - Builders

    private static func makeNativeFile(
        storedValues: [Int],
        photometricInterpretation: String = "MONOCHROME2"
    ) throws -> Data {
        var pixelData = Data()
        for value in storedValues {
            let pattern = UInt16(bitPattern: Int16(value))
            pixelData.append(UInt8(pattern & 0xFF))
            pixelData.append(UInt8(pattern >> 8))
        }
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            photometricInterpretation: photometricInterpretation,
            pixelRepresentation: 1
        )
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^TRANSCODE"])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12370001"
            )
        )
    }

    private static func makeJPEGLosslessFile(
        storedValues: [Int],
        photometricInterpretation: String = "MONOCHROME2"
    ) throws -> Data {
        let codestream = makeJPEGLosslessStream(planes: [storedValues], width: 2, height: 2, precision: 16)
        return try makeEncapsulatedFile(
            codestream: codestream,
            pixelRepresentation: 0,
            photometricInterpretation: photometricInterpretation
        )
    }

    private static func makeNative8BitFile(framePixels: [[UInt8]]) throws -> Data {
        var pixels = Data(framePixels.flatMap { $0 })
        if !pixels.count.isMultiple(of: 2) {
            pixels.append(0x00)
        }
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: framePixels.count,
            rows: 2,
            columns: 2,
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            photometricInterpretation: "MONOCHROME2",
            pixelRepresentation: 0
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: .OB,
            value: .bytes(pixels)
        ))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.14320001"
            )
        )
    }

    private static func makeJPEGBaselineFile() throws -> Data {
        let jpeg = try makeBaselineJPEG()
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegBaseline,
            fragments: [jpeg],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            photometricInterpretation: "MONOCHROME2",
            pixelRepresentation: 0
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompression.rawValue,
            vr: .CS,
            value: .strings(["01"])
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompressionMethod.rawValue,
            vr: .CS,
            value: .strings(["ISO_10918_1"])
        ))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpegBaseline,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.14330001"
            )
        )
    }

    private static func makeBaselineJPEG() throws -> Data {
        let pixels: [UInt8] = [0, 64, 128, 255]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
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
              ) else {
            throw DicomTranscoder.TranscodeError.unsupportedPixelShape(
                reason: "ImageIO could not create the JPEG Baseline test image."
            )
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw DicomTranscoder.TranscodeError.unsupportedPixelShape(
                reason: "ImageIO could not create the JPEG Baseline destination."
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DicomTranscoder.TranscodeError.unsupportedPixelShape(
                reason: "ImageIO could not finalize the JPEG Baseline fixture."
            )
        }
        return data as Data
    }

    private static func jpegStreamThroughEOI(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        for index in stride(from: data.count - 2, through: 0, by: -1) where
            data[index] == 0xFF && data[index + 1] == 0xD9 {
            return data.prefix(index + 2)
        }
        return data
    }

    private static func makeEncapsulatedFile(
        codestream: Data,
        pixelRepresentation: Int,
        photometricInterpretation: String = "MONOCHROME2"
    ) throws -> Data {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [codestream],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15,
            photometricInterpretation: photometricInterpretation,
            pixelRepresentation: pixelRepresentation
        )
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^TRANSCODE"])))
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpegLosslessFirstOrder,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12370001"
            )
        )
    }

    private static func storedInt16Pixels(_ decoder: DCMDecoder) -> [Int] {
        guard let normalized = decoder.getPixels16() else { return [] }
        if decoder.pixelRepresentationTagValue == 1 {
            return normalized.map { Int(Int16(truncatingIfNeeded: Int32($0) + Int32(Int16.min))) }
        }
        return normalized.map(Int.init)
    }

    private static func open(_ data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcoder_test_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func withJXLSwiftExperimentalMode<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await withJXLSwiftMode("experimental", operation)
    }

    private func withJXLSwiftMode<T>(
        _ value: String?,
        _ operation: () async throws -> T
    ) async throws -> T {
        let key = DicomJXLSwiftRolloutMode.environmentKey
        let previous = getenv(key).map { String(cString: $0) }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }
}
