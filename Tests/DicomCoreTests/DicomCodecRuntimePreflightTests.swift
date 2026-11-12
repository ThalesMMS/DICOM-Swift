//
//  DicomCodecRuntimePreflightTests.swift
//  DicomCoreTests
//
//  Checks runtime library discovery, required symbols, and explicit unavailable-library outcomes.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomCodecRuntimePreflightTests: XCTestCase {
    func testConfiguredLibraryWithRequiredSymbolReportsAvailable() {
        let environment = [
            DicomCodecRuntime.openJPEG.libraryPathEnvironmentVariable: "libz.dylib"
        ]

        let status = DicomCodecRuntimePreflight.status(
            for: .openJPEG,
            environment: environment,
            requiredSymbols: ["deflate"]
        )

        XCTAssertEqual(status.runtime, .openJPEG)
        XCTAssertEqual(status.availability, .available)
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.libraryPath, "libz.dylib")
        XCTAssertTrue(status.missingSymbols.isEmpty)
    }

    func testMissingDefaultLibraryReportsMissingLibrary() {
        let status = DicomCodecRuntimePreflight.status(
            for: .charLS,
            environment: [:],
            requiredSymbols: ["charls_jpegls_decoder_create"],
            libraryCandidates: []
        )

        XCTAssertEqual(status.runtime, .charLS)
        XCTAssertEqual(status.availability, .missingLibrary)
        XCTAssertFalse(status.isAvailable)
        XCTAssertNil(status.libraryPath)
        XCTAssertTrue(status.missingSymbols.isEmpty)
    }

    func testConfiguredInvalidLibraryPathReportsInvalidPath() {
        let missingPath = "/tmp/dicom-swift-missing-\(UUID().uuidString).dylib"
        let environment = [
            DicomCodecRuntime.charLS.libraryPathEnvironmentVariable: missingPath
        ]

        let status = DicomCodecRuntimePreflight.status(for: .charLS, environment: environment)

        XCTAssertEqual(status.runtime, .charLS)
        XCTAssertEqual(status.availability, .invalidLibraryPath)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.libraryPath, missingPath)
        XCTAssertTrue(status.message.contains(DicomCodecRuntime.charLS.libraryPathEnvironmentVariable))
    }

    func testConfiguredLibraryMissingCodecSymbolsReportsMissingSymbols() {
        let environment = [
            DicomCodecRuntime.openJPEG.libraryPathEnvironmentVariable: "libz.dylib"
        ]

        let status = DicomCodecRuntimePreflight.status(for: .openJPEG, environment: environment)

        XCTAssertEqual(status.runtime, .openJPEG)
        XCTAssertEqual(status.availability, .missingSymbols)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.libraryPath, "libz.dylib")
        XCTAssertTrue(status.missingSymbols.contains("opj_create_decompress"))
    }

    func testTestRuntimePreflightUsesPackageCodecDiagnostics() {
        let environment = [
            DicomCodecRuntime.openJPEG.libraryPathEnvironmentVariable: "libz.dylib"
        ]

        let status = DicomTestRuntimePreflight.status(for: .openJPEG, environment: environment)

        XCTAssertEqual(status.capability, .openJPEG)
        XCTAssertEqual(status.kind, .missingOptionalRuntime)
        XCTAssertTrue(status.message.contains("missing required symbols"))
    }

    func testCodecDecodeFailuresThrowTypedErrors() {
        XCTAssertThrowsError(try DicomJPEGLSCodec.decode(Data())) { error in
            XCTAssertTrue(error is DICOMError)
        }

        XCTAssertThrowsError(try DicomJPEG2000Codec.decode(Data())) { error in
            XCTAssertTrue(error is DICOMError)
        }
    }
}
