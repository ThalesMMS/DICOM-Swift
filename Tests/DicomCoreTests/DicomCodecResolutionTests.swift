import Foundation
import Synchronization
import XCTest
@testable import DicomCore

final class DicomCodecResolutionTests: XCTestCase {
    private let noRuntimes = [
        "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/nonexistent/isis-2317-openjpeg.dylib",
        "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/isis-2317-charls.dylib"
    ]

    func test_recognizedStorageSyntax_withoutDecoderAllowsOnlyPreservation() {
        // JPEG 2000 Part 2 has an experimental own decoder since #2331; with the J2K rollout disabled it is storage-only again.
        let environment = ["DICOM_J2KSWIFT_MODE": "disabled"]
        for syntax in [DicomTransferSyntax.jpeg2000Part2MulticomponentLossless, .jpipReferenced,
                       .mpeg2MainProfileMainLevel, .jpegXLLossless] {
            let preserve = decision(syntax, operation: .preserve, environment: environment)
            XCTAssertTrue(preserve.isRecognized, syntax.rawValue)
            XCTAssertTrue(preserve.canExecute, syntax.rawValue)
            XCTAssertEqual(preserve.backendIdentifier, "dataset-passthrough")
            XCTAssertFalse(decision(syntax, environment: environment).canExecute, syntax.rawValue)
            XCTAssertFalse(decision(syntax, operation: .encode, environment: environment).canExecute, syntax.rawValue)
        }
    }

    func test_everyRegisteredUID_hasAnExplicitExecutableProfileExpectation() {
        var environment = noRuntimes
        environment["DICOM_J2KSWIFT_MODE"] = "preferred"
        environment["DICOM_JLSWIFT_MODE"] = "preferred"
        environment["DICOM_JXLSWIFT_MODE"] = "experimental"
        XCTAssertEqual(Set(DicomTransferSyntaxRegistry.standard.entries.map(\.syntax)), Set(DicomTransferSyntax.allCases))
        for syntax in DicomTransferSyntax.allCases {
            // Exhaustive by design: a newly registered UID must add a qualification expectation here.
            let expected: (decode: Bool, encode: Bool)
            switch syntax {
            case .implicitVRLittleEndian, .explicitVRLittleEndian, .deflatedExplicitVRLittleEndian,
                 .explicitVRBigEndian, .jpegLSLossless, .jpeg2000Lossless, .jpeg2000, .jpegXLLossless, .jpegXL,
                 .jpegLossless, .jpegLosslessFirstOrder, .rleLossless, .deflatedImageFrameCompression:
                expected = (true, true)
            case .jpegBaseline, .jpegExtended, .jpegLSNearLossless, .jpegXLJPEGRecompression:
                // Lossy destinations need an explicit intent; the reversible probe below asks for none.
                expected = (true, false)
            case .htj2kLossless, .htj2kLosslessRPCL, .htj2k:
                expected = (true, true) // The own DicomJPEG2000 HT codec (#2330) decodes and encodes without the OpenJPEG runtime.
            case .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent:
                expected = (true, true) // Experimental own Annex J collection codec (#2331), enabled with the J2K rollout.
            case .jpipReferenced, .jpipReferencedDeflate, .jpipHTJ2KReferenced, .jpipHTJ2KReferencedDeflate,
                 .mpeg2MainProfileMainLevel, .mpeg2MainProfileMainLevelFragmentable,
                 .mpeg2MainProfileHighLevel, .mpeg2MainProfileHighLevelFragmentable,
                 .mpeg4AVCH264HighProfileLevel41, .mpeg4AVCH264HighProfileLevel41Fragmentable,
                 .mpeg4AVCH264BDCompatibleHighProfileLevel41, .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
                 .mpeg4AVCH264HighProfileLevel42For2DVideo, .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
                 .mpeg4AVCH264HighProfileLevel42For3DVideo, .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
                 .mpeg4AVCH264StereoHighProfileLevel42, .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
                 .hevcH265MainProfileLevel51, .hevcH265Main10ProfileLevel51:
                expected = (false, false)
            }
            let decode = decision(syntax, environment: environment)
            let encode = decision(syntax, operation: .encode, environment: environment)
            XCTAssertEqual(decode.canExecute, expected.decode, "decode \(syntax): \(decode.reason ?? "")")
            XCTAssertEqual(encode.canExecute, expected.encode, "encode \(syntax): \(encode.reason ?? "")")
            XCTAssertEqual(decode.backendIdentifier != nil, expected.decode)
            XCTAssertEqual(encode.backendIdentifier != nil, expected.encode)
            XCTAssertTrue(DicomCodecCapabilities.preservationDecision(for: syntax.rawValue).canExecute)
        }
    }

    func test_unknownSyntax_isNeverAdvertisedAsExecutable() {
        for operation in [DicomCodecOperation.preserve, .decode, .encode] {
            let request = DicomCodecCapabilityRequest(operation: operation, descriptor: descriptor(uid: "2.25.23170000"))
            let result = DicomCodecCapabilities.resolve(request, environment: [:])
            XCTAssertFalse(result.isRecognized)
            XCTAssertFalse(result.canExecute)
            XCTAssertEqual(result.reasonCode, .unknownSyntax)
        }
    }

    func test_missingRuntime_andRolloutPolicyChooseTheActualPixelSupplier() {
        let cases: [(String, String?, Bool)] = [
            ("disabled", nil, false), ("shadow", nil, false), ("preferred", "jlswift", true),
            ("forced-for-tests", "jlswift", true)
        ]
        for (mode, backend, executable) in cases {
            var environment = noRuntimes
            environment["DICOM_JLSWIFT_MODE"] = mode
            let result = decision(.jpegLSLossless, environment: environment)
            XCTAssertEqual(result.canExecute, executable, mode)
            XCTAssertEqual(result.backendIdentifier, backend, mode)
            if mode == "forced-for-tests" { XCTAssertEqual(result.qualification, .testOnly) }
        }
    }

    func test_shadowCandidate_isSeparateFromProduction() {
        let result = decision(.jpegLSLossless, environment: ["DICOM_JLSWIFT_MODE": "shadow"])
        guard result.canExecute else {
            XCTAssertEqual(result.reasonCode, .runtimeUnavailable)
            return
        }
        XCTAssertEqual(result.backendIdentifier, "charls-jpeg-ls")
        XCTAssertEqual(result.shadowBackendIdentifier, "jlswift")
        XCTAssertEqual(result.qualification, .qualified)
    }

    func test_generalUID_doesNotChooseLossyEncodingIntent() {
        for syntax in [DicomTransferSyntax.jpeg2000, .htj2k, .jpegXL] {
            for intent in [DicomEncodingIntent.reversible, .irreversible(quality: 0.8)] {
                let result = decision(syntax, operation: .encode, intent: intent,
                                      environment: ["DICOM_JXLSWIFT_MODE": "experimental"])
                XCTAssertTrue(result.canExecute, "\(syntax.rawValue): \(result.reason ?? "")")
            }
        }
        for syntax in [DicomTransferSyntax.jpeg2000Lossless, .htj2kLossless, .jpegXLLossless] {
            XCTAssertFalse(decision(syntax, operation: .encode, intent: .irreversible(quality: 0.8),
                                    environment: ["DICOM_JXLSWIFT_MODE": "experimental"]).canExecute)
        }
    }

    func test_partialCombinations_andCodestreamLimitsFailClosed() {
        let region = DicomPartialDecodeRequest.Region(x: 0, y: 0, width: 1, height: 1)
        // Minimal COD header used only to qualify resolution/layer requests, not to decode pixels.
        let header = Data([0xFF, 0x4F, 0xFF, 0x52, 0, 10, 0, 0, 0, 2, 0, 3, 0, 0])
        let cases: [(DicomPartialDecodeRequest, Data?, DicomCodecDecision.ReasonCode?)] = [
            (.init(region: region, resolutionLevel: 2), header, nil),
            // Issue #2382: quality layers combine with spatial reduction in the own codec.
            (.init(region: region, maximumQualityLayer: 0), header, nil),
            (.init(resolutionLevel: 4), header, .partialUnsupported),
            (.init(maximumQualityLayer: 2), header, .partialUnsupported),
            (.init(resolutionLevel: -1), header, .partialUnsupported),
            (.init(region: .init(x: Int.max, y: 0, width: 1, height: 1)), header, .partialUnsupported),
            (.init(region: region), nil, .codestreamRequired),
            (.init(region: region), Data([0, 1]), .codestreamInvalid)
        ]
        for (partial, data, code) in cases {
            let request = DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor(),
                                                     frameData: data, partialDecode: partial)
            let result = DicomCodecCapabilities.resolve(request, environment: [:])
            XCTAssertEqual(result.reasonCode, code)
            XCTAssertEqual(result.canExecute, code == nil)
        }
    }

    func test_strictPreference_doesNotEnableAForbiddenShadowCandidate() {
        let request = DicomCodecCapabilityRequest(operation: .decode,
                                                 descriptor: descriptor(uid: DicomTransferSyntax.jpegLSLossless.rawValue),
                                                 preferredBackend: "jlswift", allowsFallback: false)
        let result = DicomCodecCapabilities.resolve(request, environment: ["DICOM_JLSWIFT_MODE": "shadow"])
        XCTAssertFalse(result.canExecute)
        XCTAssertNotNil(result.reasonCode)
    }

    func test_disabledMode_honorsStrictRegisteredLegacyPreference() throws {
        guard DicomCodecCapabilities.capability(for: .openJPEG, environment: [:]).isAvailable else {
            throw XCTSkip("OpenJPEG is required to exercise competing legacy decoders")
        }
        for (backend, mode) in [("imageio-jpeg-2000", "disabled"), ("imageio-jpeg-2000", "shadow"),
                                ("openjpeg-cpu", "disabled")] {
            let request = DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor(),
                                                     preferredBackend: backend, allowsFallback: false)
            let result = DicomCodecCapabilities.resolve(request, environment: ["DICOM_J2KSWIFT_MODE": mode])
            XCTAssertTrue(result.canExecute, result.reason ?? backend)
            XCTAssertEqual(result.backendIdentifier, backend)
        }
    }

    func test_disabledMode_doesNotEnableStrictRolloutCandidate() {
        let request = DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor(),
                                                 preferredBackend: "j2kswift-cpu", allowsFallback: false)
        XCTAssertFalse(DicomCodecCapabilities.resolve(request,
            environment: ["DICOM_J2KSWIFT_MODE": "disabled"]).canExecute)
    }

    func test_cpuOwnedData_cannotSatisfyAGPUSharedBufferRequest() {
        let request = DicomCodecCapabilityRequest(operation: .encode, descriptor: descriptor(),
                                                 requiredExecutionClass: .metal, requiredOutputOwnership: .sharedBuffer)
        let result = DicomCodecCapabilities.resolve(request, environment: [:])
        XCTAssertFalse(result.canExecute)
        XCTAssertEqual(result.reasonCode, .ownershipUnsupported)
    }

    func test_dimensionAndByteLimits_areQualifiedWithoutAllocatingPixels() {
        for shape in [(65_536, 1), (65_535, 65_535)] {
            let request = DicomCodecCapabilityRequest(operation: .encode,
                                                     descriptor: descriptor(rows: shape.0, columns: shape.1))
            let result = DicomCodecCapabilities.resolve(request, environment: [:])
            XCTAssertFalse(result.canExecute)
            XCTAssertEqual(result.reasonCode, .invalidMetadata)
        }
    }

    func test_candidateDecodeFailure_doesNotRetryAnotherBackend() async {
        let request = DicomFrameDecodeRequest(frameData: Data([0, 1, 2, 3]), descriptor: descriptor(), frameIndex: 0)
        let backends = Mutex<[DicomCodecBackendIdentifier]>([])
        do {
            _ = try await DicomJ2KSwiftFrameDecoder.decode(request, environment: ["DICOM_J2KSWIFT_MODE": "preferred"]) {
                event in backends.withLock { $0.append(event.backend) }
            }
            XCTFail("Corrupt pixels must fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(backends.withLock { $0 }, [.j2kSwiftCPU])
    }

    func test_cancelledDecode_neverStartsTheCandidateOrFallback() async {
        let request = DicomFrameDecodeRequest(frameData: Data([0, 1, 2, 3]), descriptor: descriptor(), frameIndex: 0)
        let backends = Mutex<[DicomCodecBackendIdentifier]>([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DicomJ2KSwiftFrameDecoder.decode(request, environment: ["DICOM_J2KSWIFT_MODE": "preferred"]) {
                event in backends.withLock { $0.append(event.backend) }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must survive codec selection")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backends.withLock { $0.isEmpty })
    }

    #if os(macOS)
    func test_runtimeVersions_rejectIncompatibleABIAndHTJ2KProfileBeforeDecode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for version in ["2.4.0", "3.0.0"] {
            let source = directory.appendingPathComponent("runtime-\(version).c")
            let library = directory.appendingPathComponent("runtime-\(version).dylib")
            // Only the loader is exercised; any attempted native decode aborts this test process.
            let symbols = DicomCodecRuntime.openJPEG.requiredSymbols.map {
                "void \($0)(void) { abort(); }"
            }.joined(separator: "\n")
            try ("#include <stdlib.h>\nconst char *opj_version(void) { return \"\(version)\"; }\n" + symbols)
                .write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compiler.arguments = ["-dynamiclib", source.path, "-o", library.path]
            try compiler.run()
            compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let environment = ["DICOM_DECODER_OPENJPEG_LIBRARY_PATH": library.path, "DICOM_J2KSWIFT_MODE": "preferred"]
            for syntax in [DicomTransferSyntax.htj2kLossless, .htj2kLosslessRPCL, .htj2k] {
                // The established route rejects the incompatible runtime before any native call (disabled rollout);
                // in the preferred rollout the own HT decoder (#2330) executes without the OpenJPEG runtime.
                let established = decision(syntax, environment: environment.merging(["DICOM_J2KSWIFT_MODE": "disabled"]) { $1 })
                XCTAssertFalse(established.canExecute, version)
                XCTAssertEqual(established.reasonCode, .runtimeIncompatible, version)
                let own = decision(syntax, environment: environment)
                XCTAssertTrue(own.canExecute, version)
                XCTAssertEqual(own.backendIdentifier, "j2kswift-cpu", version)
                let request = DicomFrameDecodeRequest(frameData: Data([0, 1]),
                                                       descriptor: descriptor(uid: syntax.rawValue), frameIndex: 0)
                do {
                    _ = try await DicomJ2KSwiftFrameDecoder.decode(request, environment: environment)
                    XCTFail("Two bytes are not an HT codestream")
                } catch is DicomJ2KSwiftBackendError {
                } catch let error as DicomCodecSelectionError {
                    XCTFail("The own decoder must be selected, got \(error)")
                }
            }
        }
    }
    #endif

    func test_rawDICOMwebAndDIMSE_preserveSyntaxEvenWhenDecodeIsForbidden() throws {
        for syntax in [DicomTransferSyntax.jpegXLLossless, .jpeg2000Part2MulticomponentLossless] {
            let payload = Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
            let request = try DicomStoreRequest(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.7", sopInstanceUID: "2.25.2317",
                transferSyntax: syntax, dataSetData: payload
            )
            let selection = try DicomWebMediaTypeNegotiator.rawFrameSelection(
                accept: "multipart/related; transfer-syntax=\(syntax.rawValue)",
                transferSyntax: syntax, isCompressed: true
            )
            let storageOnly = noRuntimes.merging(["DICOM_J2KSWIFT_MODE": "disabled"]) { $1 }
            XCTAssertTrue(decision(syntax, operation: .preserve, environment: storageOnly).canExecute)
            XCTAssertFalse(decision(syntax, environment: storageOnly).canExecute)
            XCTAssertEqual(selection.transferSyntaxUID, syntax.rawValue)
            XCTAssertEqual(request.transferSyntax, syntax)
            XCTAssertEqual(request.dataSetData, payload)
        }
    }

    private func decision(
        _ syntax: DicomTransferSyntax,
        operation: DicomCodecOperation = .decode,
        intent: DicomEncodingIntent = .reversible,
        environment: [String: String] = [:]
    ) -> DicomCodecDecision {
        DicomCodecCapabilities.resolve(
            .init(operation: operation, descriptor: descriptor(uid: syntax.rawValue), intent: intent),
            environment: environment
        )
    }

    private func descriptor(
        uid: String = DicomTransferSyntax.jpeg2000Lossless.rawValue,
        rows: Int = 2,
        columns: Int = 2
    ) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: rows, columns: columns,
                                       bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
                                       samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
    }
}
