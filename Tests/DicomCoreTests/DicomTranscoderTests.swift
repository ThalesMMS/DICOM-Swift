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
    @MainActor
    func test_oddJPEGExtendedTable_roundTripsCanonicalAndLegacyLengths() async throws {
        var odd = try Self.makeBaselineJPEG()
        if odd.count.isMultiple(of: 2) {
            // A one-byte JPEG comment changes parity without changing image samples.
            odd.insert(contentsOf: [0xFF, 0xFE, 0, 3, 0x41], at: 2)
        }
        var even = odd
        even.insert(contentsOf: [0xFF, 0xFE, 0, 3, 0x42], at: 2)
        let frames = [odd, even]
        let encapsulation = try DicomTranscoder.encapsulate(fragments: frames, forceExtendedOffsets: true)
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegBaseline, fragments: frames, declaredFrames: 2,
            rows: 2, columns: 2, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            photometricInterpretation: "MONOCHROME2", pixelRepresentation: 0
        )
        DicomTranscoder.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        let reference = try Self.open(Self.makeJPEGBaselineFile())
        let referencePixels = try XCTUnwrap(reference.getPixels8())
        XCTAssertEqual(referencePixels.count, 4)
        for legacy in [false, true] {
            if legacy {
                var lengths = Data()
                for frame in frames {
                    let stored = UInt64(frame.count + frame.count % 2)
                    withUnsafeBytes(of: stored.littleEndian) { lengths.append(contentsOf: $0) }
                }
                dataSet.set(.init(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV, value: .bytes(lengths)))
            }
            let part10 = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .jpegBaseline))
            let decoder = try Self.open(part10)
            let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
            XCTAssertTrue(descriptor.diagnostics.isEmpty)
            XCTAssertEqual(descriptor.extendedOffsetTable?.lengths,
                           frames.map { UInt64($0.count + (legacy ? $0.count % 2 : 0)) })
            XCTAssertEqual(try XCTUnwrap(decoder.getPixels8()), referencePixels)
            let report = try DicomInstanceValidator.validate(part10)
            XCTAssertEqual(report[.structure], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .pixelDataLengthMismatch })
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
            for index in frames.indices {
                let bytes = try await session.frameData(at: index)
                XCTAssertEqual(bytes, frames[index] + (legacy && index == 0 ? Data([0]) : Data()))
            }
            await session.close()
            if let folder = ProcessInfo.processInfo.environment["DICOM_EOT_WRITER_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try part10.write(to: directory.appendingPathComponent(legacy ? "legacy.dcm" : "canonical.dcm"))
                for index in frames.indices {
                    try frames[index].write(to: directory.appendingPathComponent("frame\(index).jpg"))
                }
            }
        }
    }

    func test_explicitLossForTheSameGeneralUID_recompressesAndReportsTheActualRoute() async throws {
        let environment = ["DICOM_J2KSWIFT_MODE": "preferred", "DICOM_JXLSWIFT_MODE": "experimental"]
        let native = try Self.makeNativeFile(storedValues: [-1000, -500, 0, 250])
        let engine = DicomCodecWorkflowEngine()
        for syntax in [DicomTransferSyntax.jpeg2000, .htj2k, .jpegXL] {
            let reversible = try await engine.transcode(native, to: syntax, environment: environment)
            let source = try Self.open(reversible.data)
            let result = try await engine.transcode(reversible.data, to: syntax,
                                                    intent: .irreversible(quality: 0.8), environment: environment)
            let output = try Self.open(result.data)
            XCTAssertEqual(result.report.transcodeRoute, "recompress", syntax.rawValue)
            XCTAssertEqual(output.info(for: .lossyImageCompression), "01", syntax.rawValue)
            XCTAssertNotEqual(output.info(for: .sopInstanceUID), source.info(for: .sopInstanceUID), syntax.rawValue)
        }
    }

    func test_lossyIntentForNativeOutput_isRejectedByPreflightAndExecution() async throws {
        let native = try Self.makeNativeFile(storedValues: [1, 2, 3, 4])
        let preflight = try DicomTranscoder().preflight(native, to: .explicitVRLittleEndian,
                                                       intent: .irreversible(quality: 0.8))
        XCTAssertFalse(preflight.canExecute)
        do {
            _ = try await DicomTranscoder().transcode(native, to: .explicitVRLittleEndian,
                                                      intent: .irreversible(quality: 0.8))
            XCTFail("Native output cannot fulfill lossy intent")
        } catch is DicomTranscoder.TranscodeError {
            // Typed refusal agrees with preflight.
        }
    }

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

    func testNativeRewriteDoesNotInventPixelDataForStructuredReport() throws {
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.88.11"
        let sopInstanceUID = "2.25.1869"
        let source = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClassUID])),
                DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
                DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["SR"]))
            ]),
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )

        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)
        let sourceDecoder = try Self.open(source)
        let outputDecoder = try Self.open(output)

        XCTAssertFalse(sourceDecoder.dataSet.contains(.pixelData))
        XCTAssertFalse(outputDecoder.dataSet.contains(.pixelData))
        XCTAssertEqual(outputDecoder.info(for: .modality), "SR")
        XCTAssertEqual(outputDecoder.info(for: .sopInstanceUID), sopInstanceUID)
    }

    func testImplicitUnknownElementPreservesRawBytesDuringExplicitRewrite() throws {
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.88.11"
        let sopInstanceUID = "2.25.18690001"
        let privateTag = 0x0011_1010
        let rawValue = Data([0x00, 0x01, 0xFF, 0x20])
        let source = try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([sopClassUID])),
                DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
                DicomDataElement(tag: privateTag, vr: .OB, value: .bytes(rawValue))
            ]),
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )

        let sourceElement = try XCTUnwrap(Self.open(source).dataSet.element(for: privateTag))
        XCTAssertEqual(sourceElement.vr, .implicitRaw)
        XCTAssertEqual(sourceElement.bytesValue, rawValue)

        let output = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)
        let outputElement = try XCTUnwrap(Self.open(output).dataSet.element(for: privateTag))
        XCTAssertEqual(outputElement.vr, .UN)
        XCTAssertEqual(outputElement.bytesValue, rawValue)
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
        let environment = [DicomJLSwiftRolloutMode.environmentKey: "forced-for-tests"]
        let source = try Self.makeNative8BitFile(framePixels: [
            [1, 2, 3, 4],
            [250, 100, 50, 0]
        ])

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpegLSLossless,
            intent: .reversible,
            environment: environment
        )
        let decoder = try Self.open(compressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLSLossless.rawValue)
        XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 2)

        let reader = DicomDecodedFrameReader(decoder: decoder)
        let expectedFrames: [[UInt8]] = [[1, 2, 3, 4], [250, 100, 50, 0]]
        for (index, expected) in expectedFrames.enumerated() {
            let frame = try await reader.frameExecution(at: index, environment: environment).frame
            guard case .gray8(let pixels) = frame.pixels else {
                return XCTFail("Expected gray8 output for frame \(index)")
            }
            XCTAssertEqual(pixels, expected)
        }
    }

    func testAsyncJLSwiftNearLosslessRoutePreservesBoundAndLossyMetadata() async throws {
        let environment = [DicomJLSwiftRolloutMode.environmentKey: "forced-for-tests"]
        let near = 2
        let sourcePixels: [UInt8] = [10, 12, 50, 52]
        let source = try Self.makeNative8BitFile(framePixels: [sourcePixels])
        let sourceSOPInstanceUID = try Self.open(source).info(for: .sopInstanceUID)

        let compressed = try await DicomTranscoder().transcode(
            source,
            to: .jpegLSNearLossless,
            intent: .jpegLSNearLossless(near: near),
            environment: environment
        )
        let decoder = try Self.open(compressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLSNearLossless.rawValue)
        XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
        XCTAssertTrue(decoder.info(for: .lossyImageCompressionMethod).contains("ISO_14495_1"))
        XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), sourceSOPInstanceUID)

        let frame = try await DicomDecodedFrameReader(decoder: decoder)
            .frameExecution(at: 0, environment: environment)
            .frame
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

    func test_unsupportedCompressionDiagnostic_namesExecutableCodecFamilies() throws {
        let native = try Self.makeNativeFile(storedValues: [1, 2, 3, 4])
        let decoder = try DCMDecoder(data: native)
        XCTAssertThrowsError(try DicomTranscoder().resolveExecutionRoute(
            decoder: decoder, source: .explicitVRLittleEndian, destination: .mpeg2MainProfileMainLevel,
            intent: .reversible, environment: [:]
        )) { error in
            guard case DicomTranscoder.TranscodeError.routeUnsupported(_, _, let diagnostics) = error else {
                return XCTFail("Expected an unsupported encoder route, got \(error)")
            }
            let message = diagnostics.joined(separator: " ")
            for family in ["JPEG,", "JPEG-LS", "JPEG 2000/HTJ2K", "JPEG 2000 Part 2", "RLE", "JPEG XL"] {
                XCTAssertTrue(message.contains(family))
            }
            XCTAssertFalse(message.contains("only executable lossless"))
        }
    }

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
            XCTAssertTrue(diagnostics.joined().contains("native little-endian"))
        }
    }

    func test_preflightAndExecution_shareRouteAndIntentRejections() async throws {
        let native = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4]])
        let jpeg = try Self.makeJPEGBaselineFile()
        let cases: [(Data, DicomTransferSyntax, DicomEncodingIntent, [String: String])] = [
            (native, .jpegXLLossless, .reversible, ["DICOM_JXLSWIFT_MODE": "disabled"]),
            (jpeg, .explicitVRBigEndian, .reversible, [:]),
            (native, .jpegLSNearLossless, .irreversible(quality: 0.8), [:]),
            (native, .jpeg2000Lossless, .jpegLSNearLossless(near: 2), [:]),
            (jpeg, .jpegXLJPEGRecompression, .irreversible(quality: 0.8),
             ["DICOM_JXLSWIFT_MODE": "experimental"])
        ]
        for (source, destination, intent, environment) in cases {
            let preflight = try DicomTranscoder().preflight(
                source, to: destination, intent: intent, environment: environment, verifyDecodedPixels: false
            )
            XCTAssertFalse(preflight.canExecute, destination.rawValue)
            do {
                _ = try await DicomTranscoder().transcode(
                    source, to: destination, intent: intent, environment: environment
                )
                XCTFail("Expected rejection for \(destination.rawValue)")
            } catch {
                XCTAssertEqual(preflight.unavailableReason, error.localizedDescription, destination.rawValue)
            }
        }
    }

    func test_preferredHTJ2KWithoutOpenJPEG_usesTheOwnDecoder() async throws {
        // #2330: the own HT decoder is qualified, so the absent OpenJPEG runtime no longer blocks HTJ2K decompression.
        let native = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4]])
        let environment = [
            "DICOM_J2KSWIFT_MODE": "preferred",
            "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/nonexistent/isis-2317-openjpeg.dylib"
        ]
        for syntax in [DicomTransferSyntax.htj2kLossless, .htj2kLosslessRPCL, .htj2k] {
            let compressed = try await DicomTranscoder().transcode(
                native, to: syntax, intent: .reversible, environment: environment
            )
            let preflight = try DicomTranscoder().preflight(
                compressed, to: .explicitVRLittleEndian, environment: environment,
                verifyDecodedPixels: false
            )
            XCTAssertTrue(preflight.canExecute, "\(syntax.rawValue): \(preflight.unavailableReason ?? "")")
            let decompressed = try await DicomTranscoder().transcode(
                compressed, to: .explicitVRLittleEndian, intent: .reversible, environment: environment
            )
            XCTAssertEqual(try Self.open(decompressed).getAllFrames()?.first?.data, Data([1, 2, 3, 4]), syntax.rawValue)
        }
    }

    func test_preflightAllowsExplicitNearIntent_supportedByAsyncExecution() async throws {
        let source = try Self.makeNative8BitFile(framePixels: [[10, 12, 50, 52]])
        let environment = ["DICOM_JLSWIFT_MODE": "preferred"]
        let intent = DicomEncodingIntent.jpegLSNearLossless(near: 2)
        XCTAssertTrue(try DicomTranscoder().preflight(
            source, to: .jpegLSNearLossless, intent: intent, environment: environment
        ).canExecute)
        let output = try await DicomTranscoder().transcode(
            source, to: .jpegLSNearLossless, intent: intent, environment: environment
        )
        let decoder = try Self.open(output)
        XCTAssertEqual(decoder.info(for: .lossyImageCompression), "01")
        XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), try Self.open(source).info(for: .sopInstanceUID))
        let frame = try await DicomDecodedFrameReader(decoder: decoder).frameExecution(
            at: 0, environment: environment
        ).frame
        guard case .gray8(let pixels) = frame.pixels else { return XCTFail("Expected grayscale pixels") }
        for (actual, expected) in zip(pixels, [10, 12, 50, 52]) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 2)
        }
    }

    func test_preflightWithoutOutputVerification_requiresTheSourceDecoderForRecompression() async throws {
        let native = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4]])
        let source = try await DicomTranscoder().transcode(
            native, to: .jpegXLLossless, intent: .reversible,
            environment: ["DICOM_JXLSWIFT_MODE": "experimental"]
        )
        let disabled = ["DICOM_JXLSWIFT_MODE": "disabled", "DICOM_JLSWIFT_MODE": "preferred"]
        let preflight = try DicomTranscoder().preflight(
            source, to: .jpegLSLossless, environment: disabled, verifyDecodedPixels: false
        )
        XCTAssertFalse(preflight.canExecute)
        do {
            _ = try await DicomTranscoder().transcode(
                source, to: .jpegLSLossless, intent: .reversible, environment: disabled
            )
            XCTFail("The disabled JPEG XL source decoder must prevent recompression")
        } catch {
            XCTAssertNotNil(error as? DicomTranscoder.TranscodeError)
        }
        let passThrough = try DicomTranscoder().preflight(
            source, to: .jpegXLLossless, environment: disabled, verifyDecodedPixels: false
        )
        XCTAssertTrue(passThrough.canExecute, "Byte preservation does not require decoding")
        let carried = try await DicomTranscoder().transcode(
            source, to: .jpegXLLossless, intent: .reversible, environment: disabled
        )
        XCTAssertEqual(try Self.open(carried).makeEncapsulatedPixelFrameReader().frameData(at: 0),
                       try Self.open(source).makeEncapsulatedPixelFrameReader().frameData(at: 0))
    }

    func test_preflightQualifiedLosslessFamilies_preservePixelsAndMetadata() async throws {
        let source = try Self.makeNative8BitFile(framePixels: [[1, 2, 3, 4], [250, 100, 50, 0]])
        let environment = [
            "DICOM_JLSWIFT_MODE": "preferred", "DICOM_J2KSWIFT_MODE": "forced-for-tests",
            "DICOM_JXLSWIFT_MODE": "experimental"
        ]
        let original = try Self.open(source)
        for destination in [DicomTransferSyntax.jpegLSLossless, .jpeg2000Lossless, .jpegXLLossless] {
            XCTAssertTrue(try DicomTranscoder().preflight(
                source, to: destination, environment: environment
            ).canExecute, destination.rawValue)
            let encoded = try await DicomTranscoder().transcode(
                source, to: destination, intent: .reversible, environment: environment
            )
            let decoded = try Self.open(try await DicomTranscoder().transcode(
                encoded, to: .explicitVRLittleEndian, intent: .reversible, environment: environment
            ))
            XCTAssertEqual(decoded.info(for: .sopInstanceUID), original.info(for: .sopInstanceUID))
            XCTAssertEqual(decoded.intValue(for: .numberOfFrames), 2)
            XCTAssertEqual(decoded.dataSet[.pixelData]?.bytesValue, original.dataSet[.pixelData]?.bytesValue)
        }
    }

    func test_syncAndAsyncNativeRoutes_preserveTheSamePixelsAndMetadata() async throws {
        let native = try Self.makeNativeFile(storedValues: [-1000, -500, 0, 250])
        let compressed = try Self.makeJPEGLosslessFile(storedValues: [100, 200, 300, 400])
        for source in [native, compressed] {
            let synchronous = try Self.open(DicomTranscoder().transcode(source, to: .explicitVRLittleEndian))
            let asynchronous = try Self.open(try await DicomTranscoder().transcode(
                source, to: .explicitVRLittleEndian, intent: .reversible, environment: [:]
            ))
            XCTAssertEqual(synchronous.dataSet[.pixelData]?.bytesValue, asynchronous.dataSet[.pixelData]?.bytesValue)
            XCTAssertEqual(synchronous.info(for: .sopInstanceUID), asynchronous.info(for: .sopInstanceUID))
            XCTAssertEqual(synchronous.info(for: .patientName), asynchronous.info(for: .patientName))
        }
    }

    func test_syncAndAsyncDecompression_removeEncapsulatedOffsetTables() async throws {
        let stored = [100, 200, 300, 400]
        let decoder = try Self.open(Self.makeJPEGLosslessFile(storedValues: stored))
        let frame = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
        let encapsulation = try DicomTranscoder.encapsulate(fragments: [frame], forceExtendedOffsets: true)
        var dataSet = decoder.dataSet
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                     value: .bytes(encapsulation.pixelData)))
        dataSet.set(DicomDataElement(tag: DicomTag.extendedOffsetTable.rawValue, vr: .OV,
                                     value: .bytes(try XCTUnwrap(encapsulation.extendedOffsetTable))))
        dataSet.set(DicomDataElement(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV,
                                     value: .bytes(try XCTUnwrap(encapsulation.extendedOffsetTableLengths))))
        let source = try DicomDataSetWriter.part10Data(
            from: dataSet, options: .init(transferSyntax: .jpegLosslessFirstOrder)
        )
        let synchronous = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)
        let asynchronous = try await DicomTranscoder().transcode(
            source, to: .explicitVRLittleEndian, intent: .reversible, environment: [:]
        )
        for (name, output) in [("sync", synchronous), ("async", asynchronous)] {
            let result = try Self.open(output)
            XCTAssertFalse(result.dataSet.contains(.extendedOffsetTable), name)
            XCTAssertFalse(result.dataSet.contains(.extendedOffsetTableLengths), name)
            XCTAssertEqual(try XCTUnwrap(result.getPixels16()).map(Int.init), stored, name)
        }
    }

    func test_preflightAndDecompression_agreeAcrossJPEGLSRolloutModes() async throws {
        let pixels: [UInt8] = [1, 2, 3, 4]
        let native = try Self.makeNative8BitFile(framePixels: [pixels])
        let source = try await DicomTranscoder().transcode(
            native, to: .jpegLSLossless, intent: .reversible, environment: ["DICOM_JLSWIFT_MODE": "preferred"]
        )
        for mode in ["disabled", "shadow", "preferred", "forced-for-tests"] {
            let environment = [
                "DICOM_JLSWIFT_MODE": mode,
                "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib"
            ]
            let expected = mode == "preferred" || mode == "forced-for-tests"
            let preflight = try DicomTranscoder().preflight(
                source, to: .explicitVRLittleEndian, environment: environment, verifyDecodedPixels: false
            )
            XCTAssertEqual(preflight.canExecute, expected, mode)
            do {
                let output = try await DicomTranscoder().transcode(
                    source, to: .explicitVRLittleEndian, intent: .reversible, environment: environment
                )
                XCTAssertTrue(expected, mode)
                XCTAssertEqual(try Self.open(output).getPixels8(), pixels, mode)
            } catch {
                XCTAssertFalse(expected, mode)
                XCTAssertNotNil(error as? DicomTranscoder.TranscodeError)
            }
        }
    }

    func test_syncAndAsyncColorDecompression_writeRGBMetadataForDecodedPixels() async throws {
        let pixels = Data([UInt8(255), 0, 0, 0, 255, 0, 0, 0, 255, 100, 150, 200])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let jpeg = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .jpegBaseline, fragments: [jpeg as Data], declaredFrames: 1,
            rows: 2, columns: 2, bitsAllocated: 8, bitsStored: 8, highBit: 7,
            samplesPerPixel: 3, photometricInterpretation: "YBR_FULL_422", pixelRepresentation: 0
        )
        let source = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .jpegBaseline))
        let decoder = try Self.open(source)
        let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        guard case .rgb8(let expected) = frame.pixels else { return XCTFail("Expected decoded RGB") }
        let synchronous = try DicomTranscoder().transcode(source, to: .explicitVRLittleEndian)
        let asynchronous = try await DicomTranscoder().transcode(
            source, to: .explicitVRLittleEndian, intent: .reversible, environment: [:]
        )
        for (name, output) in [("sync", synchronous), ("async", asynchronous)] {
            let result = try Self.open(output)
            XCTAssertEqual(result.photometricInterpretation, "RGB", name)
            XCTAssertEqual(result.intValue(for: .planarConfiguration), 0, name)
            XCTAssertEqual(try result.displayRGBPixelBuffer(frame: 0).rgbData, Data(expected), name)
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
