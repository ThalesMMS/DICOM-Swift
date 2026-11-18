//
//  DCMDecoderValidationTests.swift
//  DicomCoreTests
//
//  Checks validation of missing files, empty paths, and uninitialized decoders.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderValidationTests: XCTestCase {

    func testValidateDICOMFileWithNonExistentFile() {
        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile("/nonexistent/file.dcm")

        XCTAssertFalse(result.isValid, "Validation should fail for nonexistent file")
        XCTAssertFalse(result.issues.isEmpty, "Should have validation issues")
        XCTAssertTrue(result.issues.contains("File does not exist"), "Should report file does not exist")
    }

    func testValidateDICOMFileWithEmptyPath() {
        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile("")

        XCTAssertFalse(result.isValid, "Validation should fail for empty path")
        XCTAssertFalse(result.issues.isEmpty, "Should have validation issues")
    }

    func testIsValidWithUninitializedDecoder() {
        let decoder = DCMDecoder()
        XCTAssertFalse(decoder.isValid(), "Uninitialized decoder should not be valid")
    }

    func testGetValidationStatusDetails() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()

        XCTAssertNotNil(status.isValid, "Status should have isValid field")
        XCTAssertNotNil(status.width, "Status should have width field")
        XCTAssertNotNil(status.height, "Status should have height field")
        XCTAssertNotNil(status.hasPixels, "Status should have hasPixels field")
        XCTAssertNotNil(status.isCompressed, "Status should have isCompressed field")

        XCTAssertFalse(status.isValid, "Initial status should be invalid")
        XCTAssertFalse(status.hasPixels, "Initial status should have no pixels")
        XCTAssertFalse(status.isCompressed, "Initial status should not be compressed")
    }

    func testValidationBeforeLoading() {
        let decoder = DCMDecoder()

        let validation1 = decoder.validateDICOMFile("/nonexistent/file.dcm")
        XCTAssertFalse(validation1.isValid, "Validation should fail for nonexistent file")
        XCTAssertFalse(validation1.issues.isEmpty, "Should have validation issues")

        let validation2 = decoder.validateDICOMFile("")
        XCTAssertFalse(validation2.isValid, "Validation should fail for empty path")

        XCTAssertFalse(decoder.isValid(), "Decoder should remain invalid")
    }

    func testValidationIssuesContent() {
        let decoder = DCMDecoder()
        let validation = decoder.validateDICOMFile("/nonexistent/file.dcm")

        XCTAssertFalse(validation.isValid, "Validation should fail")
        XCTAssertGreaterThan(validation.issues.count, 0, "Should have at least one issue")
        XCTAssertFalse(validation.issues.joined(separator: " ").isEmpty, "Issues should not be empty")
    }
}
