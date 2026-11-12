//
//  MockDicomDecoderInitializationErrorTests.swift
//  DicomCoreTests
//
//  Checks one-shot path-specific initialization errors and the global fallback error.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore
import DicomTestSupport

final class MockDicomDecoderInitializationErrorTests: XCTestCase {

    private let firstPath = "/tmp/mock-dicom-first.dcm"
    private let secondPath = "/tmp/mock-dicom-second.dcm"
    private let fallbackPath = "/tmp/mock-dicom-fallback.dcm"

    override func setUp() {
        super.setUp()
        MockDicomDecoder.resetInitializationErrorModes()
    }

    override func tearDown() {
        MockDicomDecoder.resetInitializationErrorModes()
        super.tearDown()
    }

    func testPathScopedInitializationErrorIsOneShot() throws {
        MockDicomDecoder.setInitializationErrorMode(.fileNotFound, forPath: firstPath)
        MockDicomDecoder.setInitializationErrorMode(.invalidFormat, forPath: secondPath)

        XCTAssertThrowsError(try MockDicomDecoder(contentsOfFile: firstPath)) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, firstPath)
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOfFile: firstPath))

        let firstURL = URL(fileURLWithPath: firstPath)
        MockDicomDecoder.setInitializationErrorMode(.fileNotFound, forPath: firstPath)

        XCTAssertThrowsError(try MockDicomDecoder(contentsOf: firstURL)) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, firstPath)
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOf: firstURL))

        XCTAssertThrowsError(try MockDicomDecoder(contentsOfFile: secondPath)) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                XCTFail("Expected invalidDICOMFormat, got \(error)")
                return
            }
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOfFile: secondPath))
    }

    func testPathScopedInitializationErrorNormalizesEquivalentPaths() throws {
        let nonStandardPath = "/tmp/mock-dicom-fixture/../mock-dicom-normalized.dcm"
        let normalizedPath = "/tmp/mock-dicom-normalized.dcm"

        MockDicomDecoder.setInitializationErrorMode(.fileNotFound, forPath: nonStandardPath)

        XCTAssertThrowsError(try MockDicomDecoder(contentsOfFile: normalizedPath)) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, normalizedPath)
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOfFile: normalizedPath))
    }

    func testGlobalInitializationErrorRemainsFallback() throws {
        MockDicomDecoder.setInitializationErrorMode(.invalidFormat, forPath: firstPath)
        MockDicomDecoder.setNextInitializationErrorMode(.fileNotFound)

        XCTAssertThrowsError(try MockDicomDecoder(contentsOfFile: firstPath)) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                XCTFail("Expected path-scoped invalidDICOMFormat, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try MockDicomDecoder(contentsOfFile: fallbackPath)) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fallback fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, fallbackPath)
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOfFile: fallbackPath))

        let fallbackURL = URL(fileURLWithPath: fallbackPath)
        MockDicomDecoder.setNextInitializationErrorMode(.fileNotFound)

        XCTAssertThrowsError(try MockDicomDecoder(contentsOf: fallbackURL)) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fallback fileNotFound, got \(error)")
                return
            }
            XCTAssertEqual(path, fallbackPath)
        }

        XCTAssertNoThrow(try MockDicomDecoder(contentsOf: fallbackURL))
    }
}
