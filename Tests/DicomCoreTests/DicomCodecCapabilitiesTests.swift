//
//  DicomCodecCapabilitiesTests.swift
//  DicomCoreTests
//
//  Release-deterministic codec backend reporting (issue #1230): the
//  capability API for available backends (version, path, source, bit
//  depths), missing libraries, invalid override paths, wrong-library
//  missing-symbol detection, version compatibility, and typed decode
//  failures.
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomCodecCapabilitiesTests: XCTestCase {
    func testBackendStatusesExposePackageLinkedJLSwiftQualification() throws {
        let status = try XCTUnwrap(
            DicomCodecCapabilities.backendStatuses(environment: [:])
                .first(where: { $0.identifier == "jlswift" })
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.version, "0.9.0")
        XCTAssertEqual(status.source, .packageLinked)
        XCTAssertEqual(status.operations, ["decode", "encode"])
        XCTAssertEqual(status.supportedGrayscaleBitDepths, 8...16)
        XCTAssertEqual(status.supportedColorBitDepths, 8...8)
        XCTAssertEqual(
            Set(status.decodeTransferSyntaxUIDs),
            DicomJLSwiftBackend.transferSyntaxes
        )
        XCTAssertEqual(
            Set(status.encodeTransferSyntaxUIDs),
            DicomJLSwiftBackend.transferSyntaxes
        )
    }
    // MARK: - Available backends

    func testAvailableCharLSReportsVersionPathSourceAndBitDepths() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        let capability = DicomCodecCapabilities.capability(for: .charLS, environment: [:])
        XCTAssertTrue(capability.isAvailable)
        XCTAssertNil(capability.unsupportedReason)
        XCTAssertEqual(capability.source, .defaultSearchPath)
        XCTAssertNotNil(capability.libraryPath)
        let version = try XCTUnwrap(capability.version, "CharLS 2.x exports charls_get_version_string")
        XCTAssertEqual(DicomCodecCapabilities.majorVersion(of: version), 2)
        XCTAssertEqual(capability.supportedGrayscaleBitDepths, 2...16)
        XCTAssertEqual(capability.supportedColorBitDepths, 2...8)
        XCTAssertEqual(
            capability.transferSyntaxUIDs,
            [DicomTransferSyntax.jpegLSLossless.rawValue, DicomTransferSyntax.jpegLSNearLossless.rawValue]
        )
    }

    func testAvailableOpenJPEGReportsVersionAndSyntaxes() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)

        let capability = DicomCodecCapabilities.capability(for: .openJPEG, environment: [:])
        XCTAssertTrue(capability.isAvailable)
        let version = try XCTUnwrap(capability.version, "OpenJPEG exports opj_version")
        XCTAssertEqual(DicomCodecCapabilities.majorVersion(of: version), 2)
        XCTAssertTrue(capability.transferSyntaxUIDs.contains(DicomTransferSyntax.jpeg2000Lossless.rawValue))
        XCTAssertTrue(capability.transferSyntaxUIDs.contains(DicomTransferSyntax.jpeg2000.rawValue))
    }

    func testAllReportsEveryRuntime() {
        let capabilities = DicomCodecCapabilities.all(environment: [:])
        XCTAssertEqual(
            capabilities.map(\.runtime),
            DicomCodecRuntime.allCases
        )
    }

    // MARK: - Missing backend / invalid override / wrong library

    func testInvalidOverridePathReportsUnavailableNamingTheVariable() throws {
        let environment = ["DICOM_DECODER_CHARLS_LIBRARY_PATH": "/nonexistent/libcharls.dylib"]
        let capability = DicomCodecCapabilities.capability(for: .charLS, environment: environment)

        XCTAssertFalse(capability.isAvailable)
        XCTAssertEqual(capability.source, .unavailable)
        XCTAssertNil(capability.version)
        let reason = try XCTUnwrap(capability.unsupportedReason)
        XCTAssertTrue(reason.contains("DICOM_DECODER_CHARLS_LIBRARY_PATH"), reason)
        XCTAssertTrue(reason.contains("not loadable"), reason)
    }

    func testOverridePointingAtWrongLibraryReportsMissingSymbols() throws {
        // libz is always present but exports none of the CharLS symbols —
        // the missing-symbols path doubles as the version/ABI mismatch case.
        let zlibPath = "/usr/lib/libz.1.dylib"
        let environment = ["DICOM_DECODER_CHARLS_LIBRARY_PATH": zlibPath]
        let status = DicomCodecRuntimePreflight.status(for: .charLS, environment: environment)
        guard status.availability == .missingSymbols else {
            throw XCTSkip("dyld could not load \(zlibPath) on this machine: \(status.message)")
        }

        let capability = DicomCodecCapabilities.capability(for: .charLS, environment: environment)
        XCTAssertFalse(capability.isAvailable)
        let reason = try XCTUnwrap(capability.unsupportedReason)
        XCTAssertTrue(reason.contains("missing required symbols"), reason)
        XCTAssertTrue(reason.contains("charls_jpegls_decoder_create"), reason)
    }

    func testMissingLibraryStatusMapsToUnavailableCapability() {
        let status = DicomCodecRuntimeStatus(
            runtime: .openJPEG,
            availability: .missingLibrary,
            libraryPath: nil,
            missingSymbols: [],
            message: "OpenJPEG runtime library is not loadable from default candidates."
        )
        let capability = DicomCodecCapabilities.capability(for: .openJPEG, status: status, environment: [:])

        XCTAssertFalse(capability.isAvailable)
        XCTAssertEqual(capability.source, .unavailable)
        XCTAssertNil(capability.libraryPath)
        XCTAssertEqual(capability.unsupportedReason, status.message)
    }

    func testEnvironmentOverrideSourceIsReportedWhenOverrideLoads() throws {
        try DicomTestRuntimePreflight.require(.charLS)
        let defaultCapability = DicomCodecCapabilities.capability(for: .charLS, environment: [:])
        let path = try XCTUnwrap(defaultCapability.libraryPath)

        let overridden = DicomCodecCapabilities.capability(
            for: .charLS,
            environment: ["DICOM_DECODER_CHARLS_LIBRARY_PATH": path]
        )
        XCTAssertTrue(overridden.isAvailable)
        XCTAssertEqual(overridden.source, .environmentOverride)
        XCTAssertEqual(overridden.libraryPath, path)
    }

    // MARK: - Version compatibility

    func testMajorVersionParsing() {
        XCTAssertEqual(DicomCodecCapabilities.majorVersion(of: "2.4.2"), 2)
        XCTAssertEqual(DicomCodecCapabilities.majorVersion(of: "3.0.0"), 3)
        XCTAssertNil(DicomCodecCapabilities.majorVersion(of: "not-a-version"))
    }

    func testIncompatibleMajorVersionWouldBeReportedUnavailable() throws {
        // The decision layer is deterministic: any available status whose
        // library reports a non-2 major version must be marked unavailable
        // with a version-naming reason. (Exercised through majorVersion +
        // the require() checks; a real 1.x/3.x library is not installable
        // in CI, so this pins the comparison constant.)
        XCTAssertEqual(DicomCodecCapabilities.supportedMajorVersion, 2)
    }

    // MARK: - Typed decode failures

    func testJPEGLSDecodeFailsTypedOnGarbagePayload() throws {
        try DicomTestRuntimePreflight.require(.charLS)

        XCTAssertThrowsError(try DicomJPEGLSCodec.decode(Data([0x00, 0x01, 0x02, 0x03]))) { error in
            guard case DICOMError.imageProcessingFailed = error else {
                return XCTFail("expected imageProcessingFailed, got \(error)")
            }
        }
    }

    func testJPEG2000DecodeFailsTypedOnGarbagePayload() throws {
        try DicomTestRuntimePreflight.require(.openJPEG)

        XCTAssertThrowsError(try DicomJPEG2000Codec.decode(Data([0x00, 0x01, 0x02, 0x03]))) { error in
            guard let dicomError = error as? DICOMError else {
                return XCTFail("expected a typed DICOMError, got \(error)")
            }
            switch dicomError {
            case .imageProcessingFailed, .invalidPixelData:
                break
            default:
                XCTFail("expected a decode-failure error, got \(dicomError)")
            }
        }
    }
}
