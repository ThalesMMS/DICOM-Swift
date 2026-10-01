//
//  DicomCodecWorkflowEngineTests.swift
//  DicomCoreTests
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomCodecWorkflowEngineTests: XCTestCase {
    private let engine = DicomCodecWorkflowEngine()

    func test_conformanceText_formatsTagItemAndFramePathsCanonically() {
        let conformance = DicomValidationReport(diagnostics: [
            .init(code: .invalidCodestream, severity: .error, layer: .codestream,
                  path: [.tag(0x00081199), .item(2), .tag(0x7FE00010), .frame(3)])
        ])
        let report = DicomCodecStructuredReport(operation: .validate, success: false, conformance: conformance)

        let line = DicomCodecCanonicalRenderer.text(report).components(separatedBy: "\n")
            .first { $0.hasPrefix("conformance-diagnostic:") }

        XCTAssertEqual(line, "conformance-diagnostic: error invalidCodestream tag:00081199/item:2/tag:7FE00010/frame:3")
    }

    func test_inspectRendersStablePHIFreeJSON() throws {
        let data = try Data(contentsOf: Self.nativeFixture)

        let report = try engine.inspect(data, environment: [:])
        let first = try DicomCodecCanonicalRenderer.jsonData(report)
        let second = try DicomCodecCanonicalRenderer.jsonData(report)
        let text = String(decoding: first, as: UTF8.self)

        XCTAssertEqual(first, second)
        XCTAssertEqual(report.operation, .inspect)
        XCTAssertEqual(report.sourceObject?.transferSyntaxUID, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertFalse(text.contains("PatientName"))
        XCTAssertFalse(text.contains("PatientID"))
        XCTAssertFalse(text.contains(Self.fixturesDirectory.path))
    }

    func test_capabilitiesDoNotExposeRuntimeLibraryPaths() throws {
        let report = engine.capabilities(environment: [
            "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/private/example/libopenjp2.dylib"
        ])
        let json = try DicomCodecCanonicalRenderer.jsonString(report)

        XCTAssertEqual(report.operation, .capabilities)
        XCTAssertFalse(json.contains("/private/example"))
        XCTAssertTrue(report.backends.contains { $0.identifier == "j2kswift-cpu" })
    }

    func test_decodeReturnsInMemoryPixelsAndActualNativeBackend() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)

        let result = try await engine.decode(data, environment: [:])

        XCTAssertFalse(result.data.isEmpty)
        XCTAssertEqual(result.report.operation, .decode)
        XCTAssertEqual(result.report.frames.count, 1)
        XCTAssertEqual(result.report.artifact?.byteCount, result.data.count)
        XCTAssertEqual(result.report.backends.map(\.identifier), ["native-uncompressed"])
    }

    func test_validateChecksEncapsulationAndOffsetTables() throws {
        let data = try Data(contentsOf: Self.rleFixture)

        let report = try engine.validate(data, environment: [:])

        XCTAssertTrue(report.success)
        XCTAssertEqual(report.operation, .validate)
        XCTAssertEqual(report.encapsulation?.valid, true)
        XCTAssertEqual(report.encapsulation?.mappedFrameCount, 1)
        XCTAssertGreaterThan(report.encapsulation?.fragmentCount ?? 0, 0)
    }

    func test_validateRejectsInconsistentPixelAttributes() throws {
        let source = try DCMDecoder(contentsOf: Self.nativeFixture)
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: source)
        dataSet.set(DicomDataElement(
            tag: DicomTag.bitsStored.rawValue,
            vr: .US,
            value: .unsignedIntegers([17])
        ))
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRLittleEndian)
        )

        let report = try engine.validate(data, environment: [:])

        XCTAssertFalse(report.success)
        XCTAssertTrue(report.diagnostics.contains { $0.code == "codec.pixel.bits-stored" })
    }

    func test_validateAcceptsExtendedOffsetTableFrameMapping() throws {
        let source = try DCMDecoder(contentsOf: Self.rleFixture)
        let frame = try source.makeEncapsulatedPixelFrameReader().frameData(at: 0)
        let encapsulated = try DicomTranscoder.encapsulate(
            fragments: [frame],
            forceExtendedOffsets: true
        )
        var dataSet = source.dataSet
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: .OB,
            value: .bytes(encapsulated.pixelData)
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.extendedOffsetTable.rawValue,
            vr: .OV,
            value: .bytes(try XCTUnwrap(encapsulated.extendedOffsetTable))
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.extendedOffsetTableLengths.rawValue,
            vr: .OV,
            value: .bytes(try XCTUnwrap(encapsulated.extendedOffsetTableLengths))
        ))
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: .rleLossless)
        )

        let report = try engine.validate(data, environment: [:])

        XCTAssertTrue(report.success)
        XCTAssertEqual(report.encapsulation?.basicOffsetCount, 0)
        XCTAssertEqual(report.encapsulation?.extendedOffsetCount, 1)
        XCTAssertEqual(report.encapsulation?.mappedFrameCount, 1)
    }

    func test_transcodeReturnsValidatedPart10BytesWithExactDecodedParity() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)

        let result = try await engine.transcode(
            data,
            to: .implicitVRLittleEndian,
            environment: [:]
        )
        let output = try DCMDecoder(data: result.data)

        XCTAssertEqual(output.transferSyntaxUID, DicomTransferSyntax.implicitVRLittleEndian.rawValue)
        XCTAssertEqual(result.report.transcodeRoute, "rewrite-native")
        XCTAssertEqual(result.report.artifact?.validationPassed, true)
        XCTAssertEqual(result.report.artifact?.comparisonMode, "exact-decoded-pixels")
        XCTAssertEqual(result.report.artifact?.comparisonPassed, true)
    }

    func test_announcedSupplier_matchesNativeAndEachJPEG2000ExecutionMode() async throws {
        let native = try Data(contentsOf: Self.nativeFixture)
        let nativeAnnouncement = try engine.inspect(native, environment: [:])
        let nativeExecution = try await engine.decode(native, environment: [:])
        XCTAssertEqual(nativeAnnouncement.decisions?.first?.backendIdentifier,
                       nativeExecution.report.backends.first { $0.role == .production }?.identifier)
        for syntax in [DicomTransferSyntax.jpeg2000Lossless, .htj2kLossless] {
            if syntax == .htj2kLossless {
                do { try HTJ2KDecodeTests.skipUnlessHTJ2KSupported() }
                catch is XCTSkip { continue }
            }
            let compressed = try await engine.transcode(native, to: syntax,
                                                         environment: ["DICOM_J2KSWIFT_MODE": "preferred"])
            for mode in ["disabled", "shadow", "preferred"] {
                let environment = ["DICOM_J2KSWIFT_MODE": mode]
                let announcement = try engine.inspect(compressed.data, environment: environment)
                let execution = try await engine.decode(compressed.data, environment: environment)
                let backend = try XCTUnwrap(execution.report.backends.first { $0.role == .production }?.identifier)
                let announced = try XCTUnwrap(announcement.decisions?.first)
                XCTAssertEqual(announced.backendIdentifier, backend, "\(syntax) \(mode)")
                let strict = DicomCodecCapabilities.resolve(.init(
                    operation: .decode, descriptor: announced.descriptor,
                    preferredBackend: backend, allowsFallback: false
                ), environment: environment)
                XCTAssertTrue(strict.canExecute, "\(syntax) \(mode): \(strict.reason ?? "")")
                XCTAssertEqual(strict.backendIdentifier, backend)
            }
        }
    }

    func test_jpeg2000WorkflowReportsVersionedEncoderAndDecoder() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)
        let environment = ["DICOM_J2KSWIFT_MODE": "forced-for-tests"]

        let encoded = try await engine.transcode(
            data,
            to: .jpeg2000Lossless,
            environment: environment
        )
        let decoded = try await engine.decode(encoded.data, environment: environment)

        XCTAssertEqual(encoded.report.encapsulation?.valid, true)
        XCTAssertGreaterThan(encoded.report.encapsulation?.basicOffsetCount ?? 0, 0)
        XCTAssertEqual(encoded.report.artifact?.comparisonPassed, true)
        XCTAssertTrue(encoded.report.backends.contains {
            $0.identifier == "j2kswift-cpu" && $0.role == .encoder && $0.version == "11.0.2-vendored"
        })
        XCTAssertTrue(decoded.report.backends.contains {
            $0.identifier == "j2kswift-cpu" && $0.role == .production && $0.version == "11.0.2-vendored"
        })
    }

    func test_jpegLSWorkflowReportsVersionedEncoderAndDecoder() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)
        let environment = ["DICOM_JLSWIFT_MODE": "forced-for-tests"]

        let encoded = try await engine.transcode(
            data,
            to: .jpegLSLossless,
            environment: environment
        )
        let decoded = try await engine.decode(encoded.data, environment: environment)

        XCTAssertEqual(encoded.report.encapsulation?.valid, true)
        XCTAssertEqual(encoded.report.artifact?.comparisonPassed, true)
        XCTAssertTrue(encoded.report.backends.contains {
            $0.identifier == "jlswift" && $0.role == .encoder && $0.version == "0.9.1-vendored"
        })
        XCTAssertTrue(decoded.report.backends.contains {
            $0.identifier == "jlswift" && $0.role == .production && $0.version == "0.9.1-vendored"
        })
    }

    func test_jpegXLWorkflowHonorsFeatureGateAndReportsVersionedBackend() async throws {
        let data = try Data(contentsOf: Self.nativeFixture)

        try await withJXLSwiftMode("experimental") {
            let environment = ["DICOM_JXLSWIFT_MODE": "forced-for-tests"]
            let encoded = try await engine.transcode(
                data,
                to: .jpegXLLossless,
                environment: environment
            )
            let decoded = try await engine.decode(encoded.data, environment: environment)

            XCTAssertEqual(encoded.report.encapsulation?.valid, true)
            XCTAssertEqual(encoded.report.artifact?.comparisonPassed, true)
            XCTAssertTrue(encoded.report.backends.contains {
                $0.identifier == "jxlswift" && $0.role == .encoder && $0.version == "1.4.0-vendored"
            })
            XCTAssertTrue(decoded.report.backends.contains {
                $0.identifier == "jxlswift" && $0.role == .production && $0.version == "1.4.0-vendored"
            })
        }
    }

    func test_invalidInputUsesTypedWorkflowError() {
        XCTAssertThrowsError(try engine.inspect(Data([0x00, 0x01, 0x02]))) { error in
            guard let workflowError = error as? DicomCodecWorkflowError else {
                return XCTFail("expected DicomCodecWorkflowError, got \(error)")
            }
            XCTAssertEqual(workflowError.category, .invalidInput)
        }
    }

    func test_transcodePreflightWithholdsShadowJPEGLSWithoutCharLS() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .jpegLSLossless,
            environment: [
                "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib",
                "DICOM_JLSWIFT_MODE": "shadow"
            ]
        )

        XCTAssertFalse(result.canExecute)
        XCTAssertEqual(result.unavailableReason, "No codec in this build can verify its decoded pixels")
    }

    func test_transcodePreflightOffersPreferredJPEGLSWithoutCharLS() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .jpegLSLossless,
            environment: [
                "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib",
                "DICOM_JLSWIFT_MODE": "preferred"
            ]
        )

        XCTAssertTrue(result.canExecute)
        XCTAssertNil(result.unavailableReason)
    }

    func test_transcodePreflightWithholdsSixteenBitJPEG2000WithoutOpenJPEG() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .jpeg2000Lossless,
            environment: [
                "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/nonexistent/libopenjp2.dylib",
                "DICOM_J2KSWIFT_MODE": "shadow"
            ]
        )

        XCTAssertFalse(result.canExecute)
        XCTAssertEqual(result.unavailableReason, "No codec in this build can verify its decoded pixels")
    }

    func test_transcodePreflightWithholdsJPEGXLWhenRolloutIsDisabled() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .jpegXLLossless,
            environment: ["DICOM_JXLSWIFT_MODE": "disabled"]
        )

        XCTAssertFalse(result.canExecute)
        XCTAssertEqual(
            result.unavailableReason,
            "Transcoding 1.2.840.10008.1.2.1 to 1.2.840.10008.1.2.4.110 is unsupported: "
                + "Experimental JPEG XL transcoding requires DICOM_JXLSWIFT_MODE=experimental."
        )
    }

    func test_transcodePreflightRejectsUnsupportedNativeDecompressionDestination() throws {
        // Implicit and deflated little-endian destinations decode since #2325; big endian stays outside the route.
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.rleFixture),
            to: .explicitVRBigEndian
        )

        XCTAssertFalse(result.canExecute)
        // Big Endian generation is refused up front (#2355): the carrying writer does not
        // byte-swap OW words, so the route reports that limitation before decompression rules.
        XCTAssertEqual(
            result.unavailableReason,
            "Transcoding 1.2.840.10008.1.2.5 to 1.2.840.10008.1.2.2 is unsupported: "
                + "Explicit VR Big Endian generation is unavailable: binary value byte-order conversion is not implemented."
        )
    }

    func test_transcodePreflightAllowsForcedHTJ2KFullFrameVerification() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .htj2kLossless,
            environment: ["DICOM_J2KSWIFT_MODE": "forced-for-tests"]
        )

        XCTAssertTrue(result.canExecute)
        XCTAssertNil(result.unavailableReason)
    }

    func test_transcodePreflightCanSkipUnavailableOutputDecoderVerification() throws {
        let result = try DicomTranscoder().preflight(
            Data(contentsOf: Self.nativeFixture),
            to: .jpegLSLossless,
            environment: [
                "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib",
                "DICOM_JLSWIFT_MODE": "shadow"
            ],
            verifyDecodedPixels: false
        )

        XCTAssertTrue(result.canExecute)
        XCTAssertNil(result.unavailableReason)
    }

    func test_jpegLSDecompressionHonorsInjectedPreferredModeWithoutCharLS() async throws {
        let source = try Data(contentsOf: Self.nativeFixture)
        let encoded = try await engine.transcode(
            source,
            to: .jpegLSLossless,
            environment: ["DICOM_JLSWIFT_MODE": "forced-for-tests"]
        )
        let environment = [
            "DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib",
            "DICOM_JLSWIFT_MODE": "preferred"
        ]

        let decoded = try await engine.transcode(
            encoded.data,
            to: .explicitVRLittleEndian,
            environment: environment
        )

        XCTAssertEqual(decoded.report.artifact?.comparisonPassed, true)
        let selected = try await engine.decode(encoded.data, environment: environment)
        XCTAssertTrue(selected.report.backends.contains {
            $0.identifier == "jlswift" && $0.role == .production
        })
    }

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    private static let nativeFixture = fixturesDirectory
        .appendingPathComponent("DecoderParity/ct_explicit_vr_le_rescale.dcm")
    private static let rleFixture = fixturesDirectory
        .appendingPathComponent("DecoderParity/rle_parity.dcm")

    private func withJXLSwiftMode<T>(
        _ value: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        let key = "DICOM_JXLSWIFT_MODE"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, value, 1)
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
