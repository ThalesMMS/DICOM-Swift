import Foundation
import DicomJPEG2000
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
import Darwin
#endif

final class DicomJ2KSwiftBackendTests: XCTestCase {
    func test_shadowCancellation_preservesProductionPixelsAndReportsCancellation() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let before = await DicomShadowExecutor.shared.snapshot
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            Self.fixture().request,
            environment: ["DICOM_J2KSWIFT_MODE": "shadow", "DICOM_SHADOW_SAMPLE_EVERY": "1"],
            candidate: ShadowCandidateFixture(
                capabilities: DicomJ2KSwiftBackend().capabilities, output: nil, cancelled: true
            )
        ) { recorder.record($0) }
        XCTAssertEqual(frame?.buffer.data, Data(HTJ2KDecodeTests.sourcePixels()))
        let outcome = await recorder.waitFor { $0.backend == .j2kSwiftCPU }
        XCTAssertEqual(outcome?.outcome, .cancelled)
        let after = await DicomShadowExecutor.shared.snapshot
        XCTAssertEqual(after.cancelled, before.cancelled + 1)
        XCTAssertEqual(after.failed, before.failed)
    }

    func test_shadowFailureAndMismatch_preserveOpenJPEGPixelsAndReportOutcome() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let request = try Self.fixture().request
        let expected = Data(HTJ2KDecodeTests.sourcePixels())
        for output: Data? in [nil, Data(repeating: 0, count: expected.count)] {
            let recorder = DicomJ2KSwiftTelemetryRecorder()
            let frame = try await DicomJ2KSwiftFrameDecoder.decode(
                request,
                environment: ["DICOM_J2KSWIFT_MODE": "shadow", "DICOM_SHADOW_SAMPLE_EVERY": "1"],
                candidate: ShadowCandidateFixture(capabilities: DicomJ2KSwiftBackend().capabilities, output: output)
            ) { recorder.record($0) }
            XCTAssertEqual(frame?.buffer.data, expected)
            let reported = await recorder.waitFor {
                guard $0.backend == .j2kSwiftCPU else { return false }
                if output != nil { return $0.outcome == .mismatched }
                if case .failed = $0.outcome { return true }
                return false
            }
            XCTAssertNotNil(reported)
        }
    }

    func test_cancellationBetweenPipelineStages_preventsImagePublication() async throws {
        let data = try Self.fixture().request.frameData
        let task = Task {
            try await J2KDecoder().decode(data) { update in
                if update.stage == .tileExtraction && update.progress == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled pipeline published an image")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private struct FailingCandidate: DicomFrameCodecBackend {
        let capabilities = DicomJ2KSwiftBackend().capabilities
        let error: any Error

        func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
            throw error
        }
    }

    func test_preferredCandidateUnsupportedFeature_retriesQualifiedOpenJPEG() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let codestream = try await Self.losslessCodestream(width: 8, height: 8, levels: 0)
        let request = Self.request(codestream: codestream, width: 8, height: 8,
                                   bitsStored: 8, samplesPerPixel: 1, pixelRepresentation: 0)
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            request, environment: ["DICOM_J2KSWIFT_MODE": "preferred"],
            candidate: FailingCandidate(error: J2KError.unsupportedFeature("candidate profile"))
        ) { recorder.record($0) }
        let expected = try await DicomOpenJPEGFrameBackend().decode(request)
        XCTAssertEqual(frame?.buffer.data, expected.buffer.data)
        XCTAssertEqual(recorder.values.map(\.backend), [.j2kSwiftCPU, .openJPEGCPU, .openJPEGCPU])
        guard case .fellBack = recorder.values.last?.outcome else { return XCTFail("Missing fallback telemetry") }
    }

    func test_preferredCandidateCorruptedEntropy_retriesOpenJPEGWithTelemetry() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let codestream = try await Self.losslessCodestream(width: 8, height: 8, levels: 0)
        let request = Self.request(codestream: codestream, width: 8, height: 8,
                                   bitsStored: 8, samplesPerPixel: 1, pixelRepresentation: 0)
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        _ = try await DicomJ2KSwiftFrameDecoder.decode(
            request, environment: ["DICOM_J2KSWIFT_MODE": "preferred"],
            candidate: FailingCandidate(error: J2KError.corruptedEntropyData("a code-block left 9 of 40 declared bytes unread"))
        ) { recorder.record($0) }
        guard case .fellBack(let reason) = recorder.values.last?.outcome else { return XCTFail("Missing fallback telemetry") }
        XCTAssertTrue(reason.contains("Corrupted entropy data"), reason)
    }

    func test_preferredCandidateFailure_respectsStrictPreferenceCancellationAndCorruption() async throws {
        let request = Self.request(codestream: Data([0, 1]), width: 8, height: 8,
                                   bitsStored: 8, samplesPerPixel: 1, pixelRepresentation: 0)
        let cases: [(any Error, Bool)] = [
            (J2KError.unsupportedFeature("strict preference"), false),
            (J2KError.invalidData("corrupt stream"), true),
            (CancellationError(), true)
        ]
        for (error, allowsFallback) in cases {
            let recorder = DicomJ2KSwiftTelemetryRecorder()
            let selected = DicomFrameDecodeRequest(frameData: request.frameData, descriptor: request.descriptor,
                frameIndex: 0, backendPreference: .preferred(.j2kSwiftCPU, allowsFallback: allowsFallback))
            do {
                _ = try await DicomJ2KSwiftFrameDecoder.decode(
                    selected, environment: ["DICOM_J2KSWIFT_MODE": "preferred"],
                    candidate: FailingCandidate(error: error)
                ) { recorder.record($0) }
                XCTFail("Expected candidate failure")
            } catch let actual {
                XCTAssertEqual(actual is CancellationError, error is CancellationError)
            }
            XCTAssertEqual(recorder.values.map(\.backend), [.j2kSwiftCPU])
            if error is CancellationError {
                XCTAssertEqual(recorder.values.last?.outcome, .cancelled)
            }
        }
    }

    func test_rolloutModeParsesEveryPolicyAndDefaultsToPreferred() {
        XCTAssertEqual(DicomJ2KSwiftRolloutMode(environment: [:]), .preferred)
        for mode in DicomJ2KSwiftRolloutMode.allCases {
            XCTAssertEqual(
                DicomJ2KSwiftRolloutMode(environment: [
                    DicomJ2KSwiftRolloutMode.environmentKey: mode.rawValue
                ]),
                mode
            )
        }
        XCTAssertEqual(
            DicomJ2KSwiftRolloutMode(environment: [
                DicomJ2KSwiftRolloutMode.environmentKey: "unknown"
            ]),
            .preferred
        )
    }

    func test_capabilitiesListOnlyQualifiedFrameSyntaxesAndShapes() {
        let capabilities = DicomJ2KSwiftBackend().capabilities
        XCTAssertEqual(capabilities.identifier, .j2kSwiftCPU)
        XCTAssertEqual(capabilities.version, "11.0.2-vendored")
        XCTAssertEqual(capabilities.source, .packageLinked)
        XCTAssertEqual(capabilities.executionClass, .cpu)
        XCTAssertEqual(capabilities.supportedGrayscaleBitDepths, 1...16)
        XCTAssertEqual(capabilities.supportedColorBitDepths, 1...8)
        // #2330: the five frame syntaxes (.90/.91 and .201/.202/.203) are qualified for decode and encode alike;
        // #2331 adds the two Part 2 collection syntaxes (experimental, frames as components).
        XCTAssertEqual(capabilities.transferSyntaxUIDs,
                       DicomJ2KSwiftBackend.allFrameTransferSyntaxes.union(DicomJ2KSwiftBackend.part2TransferSyntaxes))
        XCTAssertEqual(capabilities.transferSyntaxUIDs.count, 7)
        XCTAssertTrue(
            capabilities.transferSyntaxUIDs.contains(
                DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue
            )
        )
    }

    func test_forcedModeDecodesOpenJPHHTJ2KDirectlyFromData() async throws {
        let fixture = try Self.fixture()
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            fixture.request,
            environment: [DicomJ2KSwiftRolloutMode.environmentKey: "forced-for-tests"]
        ) { recorder.record($0) }

        let decoded = try XCTUnwrap(frame)
        XCTAssertEqual(decoded.width, 8)
        XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(decoded.bitsPerSample, 8)
        XCTAssertEqual(decoded.componentCount, 1)
        XCTAssertEqual(decoded.buffer.data.count, HTJ2KDecodeTests.sourcePixels().count)
        // Before #2329 the vendored 11.0.2 core mis-decoded this OpenJPH fixture (precinct partition anchored to the
        // band origin); the T.800 B.6/B.7 geometry fix makes it exact.
        XCTAssertEqual([UInt8](decoded.buffer.data), HTJ2KDecodeTests.sourcePixels())

        let telemetry = recorder.values
        XCTAssertEqual(telemetry.count, 1)
        XCTAssertEqual(telemetry[0].backend, .j2kSwiftCPU)
        XCTAssertEqual(telemetry[0].width, 8)
        XCTAssertEqual(telemetry[0].height, 8)
        XCTAssertEqual(telemetry[0].outcome, .succeeded)
        XCTAssertGreaterThan(telemetry[0].durationNanoseconds, 0)
    }

    func test_preferredModeDecodesHTJ2KWithoutTheOpenJPEGRuntime() async throws {
        // #2330: HTJ2K decode is qualified on the own backend; the OpenJPEG runtime is only the fallback.
        let fixture = try Self.fixture()
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            fixture.request,
            environment: [
                DicomJ2KSwiftRolloutMode.environmentKey: "preferred",
                "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/nonexistent/libopenjp2.dylib"
            ]
        ) { recorder.record($0) }
        XCTAssertEqual(frame.map { [UInt8]($0.buffer.data) }, HTJ2KDecodeTests.sourcePixels())
        XCTAssertEqual(recorder.values.map(\.backend), [.j2kSwiftCPU])
        XCTAssertEqual(recorder.values.first?.outcome, .succeeded)
    }

    func test_shadowModeReturnsOpenJPEGPixelsAndRecordsHTJ2KParity() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let fixture = try Self.fixture()
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            fixture.request,
            environment: [DicomJ2KSwiftRolloutMode.environmentKey: "shadow", "DICOM_SHADOW_SAMPLE_EVERY": "1"]
        ) { recorder.record($0) }

        XCTAssertEqual(
            frame.map { [UInt8]($0.buffer.data) },
            HTJ2KDecodeTests.sourcePixels()
        )
        let comparison = await recorder.waitFor {
            $0.backend == .j2kSwiftCPU
                && $0.width == 8
                && $0.height == 8
                && $0.outcome == .matched
        }
        XCTAssertNotNil(comparison, "the own decoder now matches OpenJPEG on the OpenJPH fixture")
    }

    func test_preferredModeUsesTheOwnBackendForHTJ2KWithoutFallingBack() async throws {
        let fixture = try Self.fixture()
        let recorder = DicomJ2KSwiftTelemetryRecorder()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            fixture.request,
            environment: [DicomJ2KSwiftRolloutMode.environmentKey: "preferred"]
        ) { recorder.record($0) }

        XCTAssertEqual(
            frame.map { [UInt8]($0.buffer.data) },
            HTJ2KDecodeTests.sourcePixels()
        )
        XCTAssertEqual(recorder.values.map(\.backend), [.j2kSwiftCPU])
        XCTAssertFalse(recorder.values.contains { if case .fellBack = $0.outcome { return true }; return false })
    }

    func test_disabledModeLeavesTheLegacyPathUntouched() async throws {
        let fixture = try Self.fixture()
        let frame = try await DicomJ2KSwiftFrameDecoder.decode(
            fixture.request,
            environment: [DicomJ2KSwiftRolloutMode.environmentKey: "disabled"]
        )
        XCTAssertNil(frame)
    }

    func test_adapterSourceUsesDirectDataWithoutTemporaryFileIO() throws {
        let sourceURL = Self.repoRoot()
            .appendingPathComponent("Sources/DicomCore/DicomJ2KSwiftBackend.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let adapter = try XCTUnwrap(
            source.components(separatedBy: "struct DicomOpenJPEGFrameBackend").first
        )
        XCTAssertFalse(adapter.contains("temporaryDirectory"))
        XCTAssertFalse(adapter.contains(".write(to:"))
        XCTAssertTrue(adapter.contains("J2KDecoder(sampleByteOrder: .littleEndian)"))
    }

    func test_losslessPrecisionSignednessAndTilingMatrixMatchesOpenJPEG() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        for bitDepth in [8, 10, 12, 14, 16] {
            for signed in [false, true] {
                for tiled in [false, true] {
                    let width = 37
                    let height = 29
                    let image = Self.grayscaleImage(
                        width: width,
                        height: height,
                        bitDepth: bitDepth,
                        signed: signed
                    )
                    var configuration = J2KEncodingConfiguration(
                        quality: 1,
                        lossless: true,
                        decompositionLevels: 2,
                        qualityLayers: 1,
                        progressionOrder: .lrcp
                    )
                    configuration.tileSize = tiled ? (19, 17) : (0, 0)
                    let codestream = try await J2KEncoder(
                        encodingConfiguration: configuration
                    ).encode(image)
                    let request = Self.request(
                        codestream: codestream,
                        width: width,
                        height: height,
                        bitsStored: bitDepth,
                        samplesPerPixel: 1,
                        pixelRepresentation: signed ? 1 : 0
                    )

                    let candidate = try await DicomJ2KSwiftBackend().decode(request)
                    let oracle = try await DicomOpenJPEGFrameBackend().decode(request)
                    XCTAssertEqual(candidate.buffer.data, oracle.buffer.data, "bitDepth=\(bitDepth), signed=\(signed), tiled=\(tiled)")
                    XCTAssertEqual(candidate.width, oracle.width)
                    XCTAssertEqual(candidate.height, oracle.height)
                    XCTAssertEqual(candidate.bitsPerSample, oracle.bitsPerSample)
                }
            }
        }
    }

    func test_losslessRGBComponentOrderMatchesOpenJPEGForPlanarMetadata() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let width = 31
        let height = 23
        let pixelCount = width * height
        let components = (0..<3).map { componentIndex in
            J2KComponent(
                index: componentIndex,
                bitDepth: 8,
                width: width,
                height: height,
                data: Data((0..<pixelCount).map {
                    UInt8(($0 * (componentIndex + 3) + componentIndex * 41) % 251)
                })
            )
        }
        let image = J2KImage(
            width: width,
            height: height,
            components: components,
            colorSpace: .sRGB
        )
        let configuration = J2KEncodingConfiguration(
            quality: 1,
            lossless: true,
            decompositionLevels: 2,
            qualityLayers: 1,
            progressionOrder: .lrcp
        )
        let codestream = try await J2KEncoder(
            encodingConfiguration: configuration
        ).encode(image)

        for planarConfiguration in [0, 1] {
            let request = Self.request(
                codestream: codestream,
                width: width,
                height: height,
                bitsStored: 8,
                samplesPerPixel: 3,
                pixelRepresentation: 0,
                photometricInterpretation: "RGB",
                planarConfiguration: planarConfiguration
            )
            let candidate = try await DicomJ2KSwiftBackend().decode(request)
            let oracle = try await DicomOpenJPEGFrameBackend().decode(request)
            XCTAssertEqual(candidate.buffer.data, oracle.buffer.data)
            XCTAssertEqual(candidate.componentCount, 3)
        }
    }

    func test_forcedModeReportsDescriptorMismatchWithTransferSyntaxContext() async throws {
        let fixture = try Self.fixture(columns: 9)
        do {
            _ = try await DicomJ2KSwiftFrameDecoder.decode(
                fixture.request,
                environment: [DicomJ2KSwiftRolloutMode.environmentKey: "forced-for-tests"]
            )
            XCTFail("Expected descriptor mismatch")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .metadataMismatch(let uid, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(uid, DicomTransferSyntax.htj2kLossless.rawValue)
            XCTAssertTrue(reason.contains("8x8"))
            XCTAssertTrue(reason.contains("9x8"))
        }
    }

    /// A codestream whose signedness contradicts Pixel Representation (pydicom `J2K_pixelrep_mismatch`) is
    /// decoded as the codestream declares and the Bits Stored pattern is then read under the DICOM attribute,
    /// the convention GDCM, DCMTK and pydicom share; the backend no longer refuses the object.
    func test_signednessContradictionBetweenCodestreamAndPixelRepresentationFollowsTheOracleConvention() async throws {
        let width = 23, height = 19, bitsStored = 13
        for codestreamSigned in [false, true] {
            let image = Self.grayscaleImage(width: width, height: height, bitDepth: bitsStored, signed: codestreamSigned)
            let codestream = try await J2KEncoder(encodingConfiguration: J2KEncodingConfiguration(
                quality: 1, lossless: true, decompositionLevels: 2, qualityLayers: 1, progressionOrder: .lrcp
            )).encode(image)
            let consistent = try await DicomJ2KSwiftBackend().decode(Self.request(
                codestream: codestream, width: width, height: height, bitsStored: bitsStored, samplesPerPixel: 1,
                pixelRepresentation: codestreamSigned ? 1 : 0))
            let contradictory = try await DicomJ2KSwiftBackend().decode(Self.request(
                codestream: codestream, width: width, height: height, bitsStored: bitsStored, samplesPerPixel: 1,
                pixelRepresentation: codestreamSigned ? 0 : 1))
            XCTAssertEqual(contradictory.width, width); XCTAssertEqual(contradictory.height, height)
            XCTAssertEqual(contradictory.bitsPerSample, bitsStored)
            // The 16-bit words carry the reconstructed samples; only the stored bit pattern matters downstream.
            let mask = UInt16((1 << bitsStored) - 1)
            let expected = consistent.buffer.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { $0 & mask } }
            let actual = contradictory.buffer.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { $0 & mask } }
            XCTAssertEqual(actual, expected, "codestreamSigned=\(codestreamSigned): the stored bit pattern is unchanged")
            XCTAssertTrue(expected.contains { $0 >> (bitsStored - 1) == 1 }, "the fixture exercises the sign bit")
            if (try? DicomTestRuntimePreflight.require(.openJPEG)) != nil {
                let oracle = try await DicomOpenJPEGFrameBackend().decode(Self.request(
                    codestream: codestream, width: width, height: height, bitsStored: bitsStored, samplesPerPixel: 1,
                    pixelRepresentation: codestreamSigned ? 0 : 1))
                let oracleValues = oracle.buffer.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { $0 & mask } }
                XCTAssertEqual(actual, oracleValues, "codestreamSigned=\(codestreamSigned): OpenJPEG agrees on the stored pattern")
            }
        }
    }

    func test_asyncFrameReaderUsesTheShadowPipelineWithoutChangingPixels() async throws {
        try HTJ2KDecodeTests.skipUnlessHTJ2KSupported()
        let url = Self.repoRoot().appendingPathComponent(HTJ2KDecodeTests.fixtureRelativePath)
        let frame = try await DicomDecodedFrameReader(contentsOf: url).frame(at: 0)
        guard case .gray8(let pixels) = frame.pixels else {
            return XCTFail("Expected gray8 pixels")
        }
        XCTAssertEqual(pixels, HTJ2KDecodeTests.sourcePixels())
    }

    func test_partialCapabilitiesReportQualifiedCombinations() {
        let partial = DicomJ2KSwiftBackend().capabilities.partialDecode

        XCTAssertTrue(partial.supportsRegionOfInterest)
        XCTAssertTrue(partial.supportsResolutionLevels)
        XCTAssertTrue(partial.supportsQualityLayers)
        XCTAssertTrue(partial.supportsCombinedRegionAndResolution)
        XCTAssertTrue(partial.supportsQualityWithSpatialReduction, "issue #2382: layers combine with region and resolution")
    }

    /// Issue #2854 (`Osirix10vs8BitsStored`): a 10-bit codestream under Bits Stored 8 in 16-bit words keeps its
    /// precision, as GDCM reads it; a codestream wider than Bits Allocated is still refused.
    func test_codestreamMorePreciseThanBitsStored_keepsItsPrecisionWithinBitsAllocated() async throws {
        let width = 11, height = 9
        let image = Self.grayscaleImage(width: width, height: height, bitDepth: 10, signed: false)
        let codestream = try await J2KEncoder(encodingConfiguration: J2KEncodingConfiguration(
            quality: 1, lossless: true, decompositionLevels: 1, qualityLayers: 1, progressionOrder: .lrcp
        )).encode(image)
        var request = Self.request(codestream: codestream, width: width, height: height, bitsStored: 10,
                                   samplesPerPixel: 1, pixelRepresentation: 0)
        let reference = try await DicomJ2KSwiftBackend().decode(request)
        request = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: DicomCompressedFrameDescriptor(
                transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue, rows: height, columns: width,
                bitsAllocated: 16, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 1,
                photometricInterpretation: "MONOCHROME2", planarConfiguration: nil),
            frameIndex: 0)
        let decoded = try await DicomJ2KSwiftBackend().decode(request)
        XCTAssertEqual(decoded.bitsPerSample, 10)
        XCTAssertEqual(decoded.buffer.data, reference.buffer.data)
        let values = decoded.buffer.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertGreaterThan(values.max() ?? 0, 255, "the fixture uses the bits above Bits Stored")

        let narrow = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: DicomCompressedFrameDescriptor(
                transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue, rows: height, columns: width,
                bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 1,
                photometricInterpretation: "MONOCHROME2", planarConfiguration: nil),
            frameIndex: 0)
        do {
            _ = try await DicomJ2KSwiftBackend().decode(narrow)
            XCTFail("a 10-bit codestream does not fit 8-bit words")
        } catch is DicomJ2KSwiftBackendError {}
    }

    /// Issue #2856 (`SC16BitsAllocated_8BitsStoredJ2K`): an 8-bit lossless codestream under Bits Allocated and Bits
    /// Stored 16 decodes to 8-bit samples instead of being refused for its precision.
    func test_eightBitCodestreamUnderSixteenBitDeclaration_decodesToEightBitSamples() async throws {
        let width = 9, height = 7
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 1)
        let eightBit = try await DicomJ2KSwiftBackend().decode(Self.request(
            codestream: codestream, width: width, height: height, bitsStored: 8, samplesPerPixel: 1,
            pixelRepresentation: 0))
        let declared16 = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: DicomCompressedFrameDescriptor(
                transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue, rows: height, columns: width,
                bitsAllocated: 16, bitsStored: 16, highBit: 15, pixelRepresentation: 0, samplesPerPixel: 1,
                photometricInterpretation: "MONOCHROME2", planarConfiguration: nil),
            frameIndex: 0)
        let decoded = try await DicomJ2KSwiftBackend().decode(declared16)
        XCTAssertEqual(decoded.bitsPerSample, 8)
        XCTAssertEqual(decoded.buffer.data, eightBit.buffer.data)
    }

    /// Issue #2858: CT frames pad after EOC with whatever byte the encoder's buffer held; they decode like the
    /// unpadded codestream instead of being refused as unparseable.
    func test_anyPadByteAfterEndOfCodestream_decodesLikeTheUnpaddedFrame() async throws {
        let codestream = try await Self.losslessCodestream(width: 9, height: 7, levels: 2)
        let padded = codestream + Data([0x5A])
        XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.jpeg2000Lossless.rawValue, in: padded))
        let request = { (data: Data) in
            Self.request(codestream: data, width: 9, height: 7, bitsStored: 8, samplesPerPixel: 1,
                         pixelRepresentation: 0)
        }

        let expected = try await DicomJ2KSwiftBackend().decode(request(codestream))
        let decoded = try await DicomJ2KSwiftBackend().decode(request(padded))

        XCTAssertEqual(decoded.buffer.data, expected.buffer.data)
    }

    func test_partialRegionMatchesCropFromFullDecode() async throws {
        let width = 9
        let height = 7
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 2)
        let fullRequest = Self.request(
            codestream: codestream,
            width: width,
            height: height,
            bitsStored: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )
        let partialRequest = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: fullRequest.descriptor,
            frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(
                region: .init(x: 2, y: 1, width: 5, height: 4)
            )
        )

        let full = try await DicomJ2KSwiftBackend().decode(fullRequest)
        let partial = try await DicomJ2KSwiftBackend().decode(partialRequest)

        var expected = Data()
        for y in 1..<5 {
            expected.append(full.buffer.data.subdata(in: (y * width + 2)..<(y * width + 7)))
        }
        XCTAssertEqual(partial.width, 5)
        XCTAssertEqual(partial.height, 4)
        XCTAssertEqual(partial.buffer.data, expected)
    }

    func test_partialResolutionUsesCeilingGeometryForOddDimensions() async throws {
        let width = 9
        let height = 7
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 2)
        let base = Self.request(
            codestream: codestream,
            width: width,
            height: height,
            bitsStored: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )
        let request = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: base.descriptor,
            frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(resolutionLevel: 0)
        )

        let partial = try await DicomJ2KSwiftBackend().decode(request)

        XCTAssertEqual(partial.width, 5)
        XCTAssertEqual(partial.height, 4)
        XCTAssertEqual(partial.buffer.data.count, 20)
    }

    func test_partialRegionAndResolutionAreCombinedDirectly() async throws {
        let width = 9
        let height = 7
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 2)
        let base = Self.request(
            codestream: codestream,
            width: width,
            height: height,
            bitsStored: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )
        let request = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: base.descriptor,
            frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(
                region: .init(x: 2, y: 1, width: 5, height: 5),
                resolutionLevel: 0
            )
        )

        let partial = try await DicomJ2KSwiftBackend().decode(request)

        XCTAssertEqual(partial.width, 3)
        XCTAssertEqual(partial.height, 3)
        XCTAssertEqual(partial.buffer.data.count, 9)
    }

    func test_qualityLayerDecodeCombinesWithRegionAndMatchesTheCropOfTheLayerDecode() async throws {
        // The own encoder collapses to one layer here; the pinned 4-layer fixture exercises the combination.
        let fixtureURL = Self.repoRoot().appendingPathComponent(".build/checkouts/J2KSwift/Tests/Fixtures/MultiLayer/ct512_L4.j2k")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("The pinned J2KSwift multi-layer fixture is unavailable")
        }
        let codestream = try Data(contentsOf: fixtureURL)
        let width = 512, height = 512
        let base = Self.request(codestream: codestream, width: width, height: height, bitsStored: 16, samplesPerPixel: 1, pixelRepresentation: 0)
        let qualityRequest = DicomFrameDecodeRequest(
            frameData: codestream, descriptor: base.descriptor, frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(maximumQualityLayer: 0))
        let combinedRequest = DicomFrameDecodeRequest(
            frameData: codestream, descriptor: base.descriptor, frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(region: .init(x: 100, y: 60, width: 64, height: 48), maximumQualityLayer: 0))

        let preview = try await DicomJ2KSwiftBackend().decode(qualityRequest)
        XCTAssertEqual(preview.width, width)
        XCTAssertEqual(preview.height, height)
        XCTAssertGreaterThan(try XCTUnwrap(preview.codecBytesAvoided), 0, "layers 1...3 are parsed past, never entropy-decoded")
        XCTAssertNil(DicomJ2KSwiftBackend().capabilities.unsupportedReason(for: combinedRequest), "issue #2382: quality combines with spatial decode")
        let combined = try await DicomJ2KSwiftBackend().decode(combinedRequest)
        XCTAssertEqual(combined.width, 64)
        XCTAssertEqual(combined.height, 48)
        var expected = Data()
        for y in 60..<108 {
            expected.append(preview.buffer.data.subdata(in: ((y * width + 100) * 2)..<((y * width + 164) * 2)))
        }
        XCTAssertEqual(combined.buffer.data, expected, "region of layer 0 equals the crop of the layer-0 decode")
        XCTAssertEqual(combined.codecBytesAvoided, preview.codecBytesAvoided)
        let finalLayer = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: codestream, descriptor: base.descriptor, frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(region: .init(x: 100, y: 60, width: 64, height: 48), maximumQualityLayer: 3)))
        XCTAssertEqual(finalLayer.codecBytesAvoided, 0, "the last layer skips nothing")
    }

    func test_partialBackendHonorsCancellationBeforeDecode() async throws {
        let codestream = try await Self.losslessCodestream(width: 9, height: 7, levels: 2)
        let base = Self.request(
            codestream: codestream,
            width: 9,
            height: 7,
            bitsStored: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )
        let request = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: base.descriptor,
            frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(resolutionLevel: 0)
        )
        let task = Task {
            try await DicomJ2KSwiftBackend().decode(request)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func test_partialFrameReaderClipsRegionAndReportsCodestreamLimits() async throws {
        let width = 9
        let height = 7
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 2)
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [codestream],
            declaredFrames: 1,
            rows: height,
            columns: width
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-reader-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let capabilities = try await reader.partialDecodeCapabilities()
        XCTAssertEqual(capabilities.maximumResolutionReductionLevel, 1)
        XCTAssertEqual(capabilities.qualityLayerCount, 1)
        let result = try await reader.frame(
            at: 0,
            partial: DicomPartialFrameDecodeRequest(
                sourceRegion: DicomFrameRegion(x: 7, y: 5, width: 8, height: 8)
            )
        )
        XCTAssertEqual(result.decodedSourceRegion, DicomFrameRegion(x: 7, y: 5, width: 2, height: 2))
        XCTAssertEqual(result.frame.metadata.width, 2)
        XCTAssertEqual(result.frame.metadata.height, 2)
        XCTAssertEqual(result.execution, .directRegion)
        XCTAssertTrue(result.isFinalQuality)
    }

    func test_partialFrameReaderReportsQualityStateAndRejectsProvisionalFinalRequest() async throws {
        let width = 512
        let height = 512
        let fixtureURL = Self.repoRoot()
            .appendingPathComponent(".build/checkouts/J2KSwift/Tests/Fixtures/MultiLayer/ct512_L4.j2k")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("The pinned J2KSwift multi-layer fixture is unavailable")
        }
        let codestream = try Data(contentsOf: fixtureURL)
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [codestream],
            declaredFrames: 1,
            rows: height,
            columns: width,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-quality-reader-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let preview = try await reader.frame(
            at: 0,
            partial: DicomPartialFrameDecodeRequest(maximumQualityLayer: 0)
        )
        XCTAssertEqual(preview.qualityState, .preview)
        XCTAssertEqual(preview.deliveredQualityLayer, 0)
        XCTAssertEqual(preview.execution, .directQualityLayer)
        XCTAssertFalse(preview.isFinalQuality)

        do {
            _ = try await reader.frame(
                at: 0,
                partial: DicomPartialFrameDecodeRequest(
                    maximumQualityLayer: 0,
                    requiresFinalQuality: true
                )
            )
            XCTFail("Expected finalQualityUnavailable")
        } catch let error as DicomPartialFrameDecodeError {
            XCTAssertEqual(error, .finalQualityUnavailable(requestedLayer: 0, finalLayer: 3))
        }
    }

    func test_externalJPEG2000CorpusMatchesOpenJPEGWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["DICOM_J2K_CORPUS_PATH"] else {
            throw XCTSkip("Set DICOM_J2K_CORPUS_PATH to run external JPEG 2000 parity.")
        }
        let limit = ProcessInfo.processInfo.environment["DICOM_J2K_CORPUS_LIMIT"]
            .flatMap(Int.init) ?? 20
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension.lowercased() == "dcm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(limit)
        guard !urls.isEmpty else {
            return XCTFail("No DICOM files found at \(path)")
        }

        var mismatches: [String] = []
        var j2kTimings: [UInt64] = []
        var openJPEGTimings: [UInt64] = []
        let liveHeapBlocksBefore = Self.liveHeapBlocks()
        for url in urls {
            let fixture = try Self.fixture(at: url)
            let j2kStart = DispatchTime.now().uptimeNanoseconds
            let j2k = try await DicomJ2KSwiftBackend().decode(fixture.request)
            j2kTimings.append(DispatchTime.now().uptimeNanoseconds - j2kStart)

            let openJPEGStart = DispatchTime.now().uptimeNanoseconds
            let openJPEG = try await DicomOpenJPEGFrameBackend().decode(fixture.request)
            openJPEGTimings.append(DispatchTime.now().uptimeNanoseconds - openJPEGStart)
            if j2k.width != openJPEG.width
                || j2k.height != openJPEG.height
                || j2k.bitsPerSample != openJPEG.bitsPerSample
                || j2k.componentCount != openJPEG.componentCount
                || j2k.buffer.data != openJPEG.buffer.data {
                mismatches.append(url.lastPathComponent)
            }
        }
        let liveHeapBlocksAfter = Self.liveHeapBlocks()
        let j2kDuration = j2kTimings.reduce(0, +)
        let openJPEGDuration = openJPEGTimings.reduce(0, +)
        print(
            "J2K corpus frames=\(urls.count) mismatches=\(mismatches.count)"
                + " j2kswift_ms=\(Double(j2kDuration) / 1_000_000)"
                + " openjpeg_ms=\(Double(openJPEGDuration) / 1_000_000)"
                + " j2kswift_cold_ms=\(Double(j2kTimings[0]) / 1_000_000)"
                + " j2kswift_warm_median_ms=\(Self.medianMilliseconds(j2kTimings.dropFirst()))"
                + " openjpeg_cold_ms=\(Double(openJPEGTimings[0]) / 1_000_000)"
                + " openjpeg_warm_median_ms=\(Self.medianMilliseconds(openJPEGTimings.dropFirst()))"
                + " peak_rss_bytes=\(BenchmarkMemorySampler.currentPeakResidentMemoryBytes() ?? 0)"
                + " live_heap_blocks_before=\(liveHeapBlocksBefore ?? 0)"
                + " live_heap_blocks_after=\(liveHeapBlocksAfter ?? 0)"
        )
        XCTAssertEqual(mismatches, [])
    }

    func test_performanceReportComparesColdWarmThroughputAndRSS() async throws {
        try DicomTestRuntimePreflight.require(.openJPEG)
        let width = 128
        let height = 128
        let iterations = 8
        let image = Self.grayscaleImage(width: width, height: height, bitDepth: 12, signed: false)
        let codestream = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1,
                lossless: true,
                decompositionLevels: 2,
                qualityLayers: 1,
                progressionOrder: .lrcp
            )
        ).encode(image)
        let request = Self.request(
            codestream: codestream,
            width: width,
            height: height,
            bitsStored: 12,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )

        let j2kColdStart = DispatchTime.now().uptimeNanoseconds
        let j2kCold = try await DicomJ2KSwiftBackend().decode(request)
        let j2kColdNanoseconds = DispatchTime.now().uptimeNanoseconds - j2kColdStart
        let openJPEGColdStart = DispatchTime.now().uptimeNanoseconds
        let openJPEGCold = try await DicomOpenJPEGFrameBackend().decode(request)
        let openJPEGColdNanoseconds = DispatchTime.now().uptimeNanoseconds - openJPEGColdStart
        XCTAssertEqual(j2kCold.buffer.data, openJPEGCold.buffer.data)

        var j2kWarmSeconds = [Double]()
        var openJPEGWarmSeconds = [Double]()
        for _ in 0..<iterations {
            let j2kStart = DispatchTime.now().uptimeNanoseconds
            let candidate = try await DicomJ2KSwiftBackend().decode(request)
            j2kWarmSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - j2kStart) / 1_000_000_000)

            let openJPEGStart = DispatchTime.now().uptimeNanoseconds
            let oracle = try await DicomOpenJPEGFrameBackend().decode(request)
            openJPEGWarmSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - openJPEGStart) / 1_000_000_000)
            XCTAssertEqual(candidate.buffer.data, oracle.buffer.data)
        }

        let environment = Self.performanceEnvironment(mode: .warmIsolated)
        let gate = ClinicalPerformanceGate(
            warningLimit: 0.225,
            failureLimit: 0.250,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )
        let work = ClinicalPerformanceWorkMetrics(usefulBytes: UInt64(width * height * 2))
        let resources = ClinicalPerformanceResourceMetrics(
            peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes()
        )
        let j2kStatistics = try ClinicalPerformanceStatistics(
            samples: j2kWarmSeconds,
            workUnitsPerSample: Double(width * height * 2)
        )
        let openJPEGStatistics = try ClinicalPerformanceStatistics(
            samples: openJPEGWarmSeconds,
            workUnitsPerSample: Double(width * height * 2)
        )
        let measurements = [
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "j2kswift-warm-decode",
                stage: "decode",
                unit: "seconds",
                statistics: j2kStatistics,
                correctnessPassed: true,
                gate: gate,
                environment: environment,
                work: work,
                resources: resources
            ),
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "openjpeg-warm-decode",
                stage: "decode",
                unit: "seconds",
                statistics: openJPEGStatistics,
                correctnessPassed: true,
                gate: gate,
                environment: environment,
                work: work,
                resources: resources
            )
        ]
        XCTAssertFalse(measurements.contains { $0.verdict == .failure })

        let report = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment,
            warmupIterations: 2,
            benchmarkIterations: iterations,
            backendFlags: ["candidate": "j2kswift-cpu", "oracle": "openjpeg"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: measurements
        )
        try Self.writePerformanceReportIfRequested(report, stem: "dicom-j2k-performance")

        let coldEnvironment = Self.performanceEnvironment(mode: .coldSDKFirstCall)
        let coldMeasurements = [
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "j2kswift-cold-decode",
                stage: "decode",
                unit: "seconds",
                statistics: try ClinicalPerformanceStatistics(
                    samples: [Double(j2kColdNanoseconds) / 1_000_000_000],
                    workUnitsPerSample: Double(width * height * 2)
                ),
                correctnessPassed: true,
                gate: gate,
                environment: coldEnvironment,
                work: work,
                resources: resources
            ),
            ClinicalPerformanceEvaluator.evaluate(
                metricID: "openjpeg-cold-decode",
                stage: "decode",
                unit: "seconds",
                statistics: try ClinicalPerformanceStatistics(
                    samples: [Double(openJPEGColdNanoseconds) / 1_000_000_000],
                    workUnitsPerSample: Double(width * height * 2)
                ),
                correctnessPassed: true,
                gate: gate,
                environment: coldEnvironment,
                work: work,
                resources: resources
            )
        ]
        let coldReport = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: coldEnvironment,
            warmupIterations: 0,
            benchmarkIterations: 1,
            backendFlags: ["candidate": "j2kswift-cpu", "oracle": "openjpeg"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: coldMeasurements
        )
        try Self.writePerformanceReportIfRequested(coldReport, stem: "dicom-j2k-cold-performance")

        print(
            String(
                format: "J2KSWIFT_PERF cold_ms=%.3f warm_p50_ms=%.3f warm_p95_ms=%.3f throughput_bytes_s=%.1f "
                    + "OPENJPEG cold_ms=%.3f warm_p50_ms=%.3f warm_p95_ms=%.3f throughput_bytes_s=%.1f peak_rss_bytes=%llu",
                Double(j2kColdNanoseconds) / 1_000_000,
                j2kStatistics.p50 * 1_000,
                j2kStatistics.p95 * 1_000,
                j2kStatistics.throughputPerSecond ?? 0,
                Double(openJPEGColdNanoseconds) / 1_000_000,
                openJPEGStatistics.p50 * 1_000,
                openJPEGStatistics.p95 * 1_000,
                openJPEGStatistics.throughputPerSecond ?? 0,
                resources.peakRSSBytes ?? 0
            )
        )
    }

    func test_partialPerformanceReportMeasuresFullDecodeAndWorkAvoided() async throws {
        let width = 128
        let height = 128
        let region = DicomFrameRegion(x: 32, y: 48, width: 32, height: 32)
        let iterations = 8
        let codestream = try await Self.losslessCodestream(width: width, height: height, levels: 3)
        let fullRequest = Self.request(
            codestream: codestream,
            width: width,
            height: height,
            bitsStored: 8,
            samplesPerPixel: 1,
            pixelRepresentation: 0
        )
        let partialRequest = DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: fullRequest.descriptor,
            frameIndex: 0,
            partialRequest: DicomPartialDecodeRequest(
                region: .init(x: region.x, y: region.y, width: region.width, height: region.height)
            )
        )

        let full = try await DicomJ2KSwiftBackend().decode(fullRequest)
        let partial = try await DicomJ2KSwiftBackend().decode(partialRequest)
        var expected = Data()
        for y in region.y..<(region.y + region.height) {
            let start = y * width + region.x
            expected.append(full.buffer.data.subdata(in: start..<(start + region.width)))
        }
        XCTAssertEqual(partial.buffer.data, expected)

        var fullSeconds = [Double]()
        var partialSeconds = [Double]()
        for _ in 0..<iterations {
            let fullStart = DispatchTime.now().uptimeNanoseconds
            _ = try await DicomJ2KSwiftBackend().decode(fullRequest)
            fullSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - fullStart) / 1_000_000_000)

            let partialStart = DispatchTime.now().uptimeNanoseconds
            _ = try await DicomJ2KSwiftBackend().decode(partialRequest)
            partialSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - partialStart) / 1_000_000_000)
        }

        let fullStatistics = try ClinicalPerformanceStatistics(samples: fullSeconds)
        let partialStatistics = try ClinicalPerformanceStatistics(samples: partialSeconds)
        let environment = Self.performanceEnvironment(mode: .warmSustained)
        let work = ClinicalPerformanceWorkMetrics(
            usefulBytes: UInt64(region.width * region.height),
            bytesAvoided: UInt64(width * height - region.width * region.height),
            pixelsAvoided: UInt64(width * height - region.width * region.height)
        )
        let gate = ClinicalPerformanceGate(
            warningLimit: 0.225,
            failureLimit: 0.250,
            relativeWarningPercent: 10,
            relativeFailurePercent: 20,
            lowerIsBetter: true
        )
        let measurement = ClinicalPerformanceEvaluator.evaluate(
            metricID: "j2kswift-partial-roi-decode",
            stage: "preview-frame",
            unit: "seconds",
            statistics: partialStatistics,
            correctnessPassed: partial.buffer.data == expected,
            gate: gate,
            environment: environment,
            baseline: (environment, fullStatistics),
            work: work,
            resources: ClinicalPerformanceResourceMetrics(
                peakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes(),
                temporaryFileIOBytes: 0
            )
        )
        XCTAssertNotEqual(measurement.verdict, .failure)
        XCTAssertEqual(measurement.work?.pixelsAvoided, 15_360)

        let report = ClinicalPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment,
            warmupIterations: 1,
            benchmarkIterations: iterations,
            backendFlags: ["partial": "j2kswift-direct-region", "fallback": "openjpeg-full-frame"],
            conformanceManifest: "ClinicalCodecConformanceManifest.json",
            measurements: [measurement]
        )
        try Self.writePerformanceReportIfRequested(report, stem: "dicom-j2k-partial-performance")
        print(
            String(
                format: "J2K_PARTIAL_PERF full_p95_ms=%.3f roi_p50_ms=%.3f roi_p95_ms=%.3f pixels_avoided=%llu bytes_avoided=%llu",
                fullStatistics.p95 * 1_000,
                partialStatistics.p50 * 1_000,
                partialStatistics.p95 * 1_000,
                work.pixelsAvoided,
                work.bytesAvoided
            )
        )
    }

    private static func fixture(columns: Int = 8) throws -> (
        request: DicomFrameDecodeRequest,
        decoder: DCMDecoder
    ) {
        let url = repoRoot().appendingPathComponent(HTJ2KDecodeTests.fixtureRelativePath)
        return try fixture(at: url, columns: columns)
    }

    private static func fixture(
        at url: URL,
        columns: Int? = nil
    ) throws -> (
        request: DicomFrameDecodeRequest,
        decoder: DCMDecoder
    ) {
        let decoder = try DCMDecoder(contentsOf: url)
        let frameData = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
        let bitsStored = decoder.intValue(for: Int(DicomTag.bitsStored.rawValue)) ?? decoder.bitDepth
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: decoder.transferSyntaxUID,
            rows: decoder.height,
            columns: columns ?? decoder.width,
            bitsAllocated: decoder.bitDepth,
            bitsStored: bitsStored,
            highBit: decoder.intValue(for: Int(DicomTag.highBit.rawValue)) ?? bitsStored - 1,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.photometricInterpretation,
            planarConfiguration: decoder.intValue(for: Int(DicomTag.planarConfiguration.rawValue))
        )
        return (
            DicomFrameDecodeRequest(
                frameData: frameData,
                descriptor: descriptor,
                frameIndex: 0
            ),
            decoder
        )
    }

    private static func request(
        codestream: Data,
        width: Int,
        height: Int,
        bitsStored: Int,
        samplesPerPixel: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String = "MONOCHROME2",
        planarConfiguration: Int? = nil,
        transferSyntax: DicomTransferSyntax = .jpeg2000Lossless
    ) -> DicomFrameDecodeRequest {
        DicomFrameDecodeRequest(
            frameData: codestream,
            descriptor: DicomCompressedFrameDescriptor(
                transferSyntaxUID: transferSyntax.rawValue,
                rows: height,
                columns: width,
                bitsAllocated: bitsStored <= 8 ? 8 : 16,
                bitsStored: bitsStored,
                highBit: bitsStored - 1,
                pixelRepresentation: pixelRepresentation,
                samplesPerPixel: samplesPerPixel,
                photometricInterpretation: photometricInterpretation,
                planarConfiguration: planarConfiguration
            ),
            frameIndex: 0
        )
    }

    private static func losslessCodestream(width: Int, height: Int, levels: Int) async throws -> Data {
        try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1,
                lossless: true,
                decompositionLevels: levels,
                qualityLayers: 1,
                progressionOrder: .lrcp
            )
        ).encode(grayscaleImage(width: width, height: height, bitDepth: 8, signed: false))
    }

    private static func grayscaleImage(
        width: Int,
        height: Int,
        bitDepth: Int,
        signed: Bool
    ) -> J2KImage {
        let pixelCount = width * height
        let data: Data
        if bitDepth <= 8 {
            let offset = signed ? 1 << (bitDepth - 1) : 0
            data = Data((0..<pixelCount).map {
                let sample = (($0 * 17 + 11) % (1 << bitDepth)) - offset
                return UInt8(bitPattern: Int8(clamping: sample))
            })
        } else {
            let offset = signed ? 1 << (bitDepth - 1) : 0
            var bytes = Data()
            bytes.reserveCapacity(pixelCount * 2)
            for index in 0..<pixelCount {
                let sample = ((index * 37 + 19) % (1 << bitDepth)) - offset
                let word = signed
                    ? UInt16(bitPattern: Int16(clamping: sample))
                    : UInt16(sample)
                bytes.append(UInt8(word >> 8))
                bytes.append(UInt8(word & 0xFF))
            }
            data = bytes
        }
        return J2KImage(
            width: width,
            height: height,
            components: [
                J2KComponent(
                    index: 0,
                    bitDepth: bitDepth,
                    signed: signed,
                    width: width,
                    height: height,
                    data: data,
                    sampleByteOrder: bitDepth > 8 ? .bigEndian : nil
                )
            ],
            colorSpace: .grayscale
        )
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func performanceEnvironment(
        mode: ClinicalPerformanceBenchmarkMode
    ) -> ClinicalPerformanceEnvironment {
        let platform = PlatformInfo()
        let processEnvironment = ProcessInfo.processInfo.environment
        let tier = processEnvironment["CLINICAL_PERFORMANCE_TIER"]
            .flatMap(ClinicalPerformanceTier.init(rawValue:)) ?? .pullRequestSmoke
        return ClinicalPerformanceEnvironment(
            deviceName: platform.modelIdentifier,
            osVersion: platform.osVersion,
            architecture: platform.architecture,
            modelIdentifier: platform.modelIdentifier,
            buildConfiguration: {
#if DEBUG
                "debug"
#else
                "release"
#endif
            }(),
            benchmarkMode: mode,
            fixtureID: "ct-explicit-vr-le-rescale",
            tier: tier,
            commandLineStartupIncluded: processEnvironment["CLINICAL_PERFORMANCE_CLI_STARTUP"] == "true"
        )
    }

    private static func writePerformanceReportIfRequested(_ report: ClinicalPerformanceReport,
                                                          stem: String) throws {
        guard let outputPath = ProcessInfo.processInfo.environment["CLINICAL_PERFORMANCE_OUTPUT_DIR"] else {
            return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reporter = ClinicalPerformanceReporter(report: report)
        try Data(reporter.jsonString().utf8).write(to: output.appendingPathComponent("\(stem).json"))
        try Data(reporter.csvString().utf8).write(to: output.appendingPathComponent("\(stem).csv"))
        try Data(reporter.markdownString().utf8).write(to: output.appendingPathComponent("\(stem).md"))
    }

    private static func medianMilliseconds<S: Sequence>(_ timings: S) -> Double
    where S.Element == UInt64 {
        let sorted = timings.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            median = Double(sorted[middle - 1] + sorted[middle]) / 2
        } else {
            median = Double(sorted[middle])
        }
        return median / 1_000_000
    }

    private static func liveHeapBlocks() -> UInt64? {
        #if os(macOS)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.blocks_in_use)
        #else
        return nil
        #endif
    }
}
