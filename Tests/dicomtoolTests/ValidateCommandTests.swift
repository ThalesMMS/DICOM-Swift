//
//  ValidateCommandTests.swift
//  dicomtoolTests
//
//  Tests for the validate command functionality
//

import XCTest
import ArgumentParser
@testable import dicomtool
import DicomCore

final class ValidateCommandTests: XCTestCase {

    // MARK: - Test Fixtures

    private final class MockDicomValidator: DICOMValidating, @unchecked Sendable {
        private let resultProvider: @Sendable (String) -> (isValid: Bool, issues: [String])
        private let paths = LockedValue<[String]>([])

        var validatedPaths: [String] {
            paths.value
        }

        init(resultProvider: @escaping @Sendable (String) -> (isValid: Bool, issues: [String])) {
            self.resultProvider = resultProvider
        }

        func validateDICOMFile(_ filename: String) -> (isValid: Bool, issues: [String]) {
            paths.withValue { $0.append(filename) }
            return resultProvider(filename)
        }
    }

    override func setUp() {
        super.setUp()
        ValidateCommand.replaceValidatorFactory {
            MockDicomValidator { _ in (isValid: true, issues: []) }
        }
    }

    override func tearDown() {
        ValidateCommand.resetValidatorFactory()
        super.tearDown()
    }

    /// Create a temporary file for command path validation tests.
    private func createTemporaryFile(
        named name: String = UUID().uuidString,
        contents: Data = Data([0x01])
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Create a temporary invalid DICOM file for testing
    private func createInvalidDICOMFile() throws -> URL {
        try createTemporaryFile(
            named: "invalid_\(UUID().uuidString).dcm",
            contents: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        )
    }

    // MARK: - Initialization Tests

    func testValidateCommandInitialization() throws {
        // Test that ValidateCommand can be parsed from arguments
        let command = try ValidateCommand.parse(["/path/to/test.dcm"])

        XCTAssertEqual(command.file, "/path/to/test.dcm", "File path should be set")
        XCTAssertEqual(command.format, .text, "Default format should be text")
    }

    func testValidateCommandConfiguration() {
        let config = ValidateCommand.configuration

        XCTAssertEqual(config.commandName, "validate", "Command name should be 'validate'")
        XCTAssertFalse(config.abstract.isEmpty, "Command should have an abstract")
        XCTAssertFalse(config.discussion.isEmpty, "Command should have discussion text")
    }

    // MARK: - Valid File Tests

    func testValidateCommandWithValidFileTextFormat() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        var command = try ValidateCommand.parse([fileURL.path])

        // Test that command can be executed without throwing
        XCTAssertNoThrow(try command.run(), "Command should execute successfully with valid file")
    }

    func testValidateCommandWithValidFileJSONFormat() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        var command = try ValidateCommand.parse(["--format", "json", fileURL.path])

        // Test that command can be executed without throwing
        XCTAssertNoThrow(try command.run(), "Command should execute successfully with JSON format")
    }

    func testValidateCommandReturnsSuccessForValidFile() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")
        var command = try ValidateCommand.parse([fileURL.path])
        XCTAssertNoThrow(try command.run(), "Valid DICOM file should pass validation")
    }

    // MARK: - Invalid File Tests

    func testValidateCommandWithInvalidDICOMFile() throws {
        let invalidFileURL = try createInvalidDICOMFile()
        defer {
            try? FileManager.default.removeItem(at: invalidFileURL)
        }

        var command = try ValidateCommand.parse([invalidFileURL.path])
        let mockValidator = MockDicomValidator { _ in
            (isValid: false, issues: ["Missing DICM signature"])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertThrowsError(try command.run()) { error in
            guard let exitCode = error as? ExitCode else {
                XCTFail("Expected ExitCode for invalid validation result")
                return
            }
            XCTAssertEqual(exitCode, .failure)
        }
        XCTAssertEqual(mockValidator.validatedPaths, [invalidFileURL.path])
    }

    func testValidateCommandWithInvalidDICOMFileJSON() throws {
        let invalidFileURL = try createInvalidDICOMFile()
        defer {
            try? FileManager.default.removeItem(at: invalidFileURL)
        }

        var command = try ValidateCommand.parse(["--format", "json", invalidFileURL.path])
        let mockValidator = MockDicomValidator { _ in
            (isValid: true, issues: ["Warning: Missing optional metadata"])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertNoThrow(try command.run(), "Warning-only validation should not fail command")
        XCTAssertEqual(mockValidator.validatedPaths, [invalidFileURL.path])
    }

    // MARK: - Error Handling Tests

    func testValidateCommandWithNonExistentFile() throws {
        var command = try ValidateCommand.parse(["/nonexistent/path/to/file.dcm"])

        // Test that command throws error for non-existent file
        XCTAssertThrowsError(try command.run()) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Error should be of type CLIError")
                return
            }

            if case .fileNotReadable(let path, let reason) = cliError {
                XCTAssertTrue(path.contains("nonexistent"), "Error should reference non-existent path")
                XCTAssertTrue(reason.contains("not exist"), "Error should mention file doesn't exist")
            } else {
                XCTFail("Error should be .fileNotReadable, got \(cliError)")
            }
        }
    }

    func testValidateCommandWithEmptyFilePath() throws {
        var command = try ValidateCommand.parse([""])
        let resolvedPath = URL(fileURLWithPath: "").path
        let mockValidator = MockDicomValidator { path in
            XCTAssertEqual(path, resolvedPath)
            return (isValid: true, issues: [])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertNoThrow(try command.run())
        XCTAssertEqual(mockValidator.validatedPaths, [resolvedPath])
    }

    func testValidateCommandWithDirectoryPath() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate_directory_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var command = try ValidateCommand.parse([directoryURL.path])
        let mockValidator = MockDicomValidator { _ in
            (isValid: true, issues: [])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertNoThrow(try command.run(), "Directory path should be passed to validator")
        XCTAssertEqual(mockValidator.validatedPaths, [directoryURL.path])
    }

    // MARK: - Validation Result Tests

    func testValidationResultInitialization() {
        let result = ValidationResult(isValid: true, errors: [], warnings: [])

        XCTAssertTrue(result.isValid, "isValid should be true")
        XCTAssertTrue(result.errors.isEmpty, "Errors should be empty")
        XCTAssertTrue(result.warnings.isEmpty, "Warnings should be empty")
    }

    func testValidationResultWithErrors() {
        let errors = ["Missing DICM marker", "Invalid transfer syntax"]
        let result = ValidationResult(isValid: false, errors: errors, warnings: [])

        XCTAssertFalse(result.isValid, "isValid should be false")
        XCTAssertEqual(result.errors.count, 2, "Should have 2 errors")
        XCTAssertTrue(result.warnings.isEmpty, "Warnings should be empty")
    }

    func testValidationResultWithWarnings() {
        let warnings = ["Missing optional tag", "Non-standard value"]
        let result = ValidationResult(isValid: true, errors: [], warnings: warnings)

        XCTAssertTrue(result.isValid, "isValid should be true")
        XCTAssertTrue(result.errors.isEmpty, "Errors should be empty")
        XCTAssertEqual(result.warnings.count, 2, "Should have 2 warnings")
    }

    func testValidationResultCodable() throws {
        let result = ValidationResult(
            isValid: true,
            errors: ["Error 1"],
            warnings: ["Warning 1"]
        )

        // Test encoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        XCTAssertFalse(data.isEmpty, "Encoded data should not be empty")

        // Test decoding
        let decoder = JSONDecoder()
        let decodedResult = try decoder.decode(ValidationResult.self, from: data)

        XCTAssertEqual(decodedResult.isValid, result.isValid, "isValid should match")
        XCTAssertEqual(decodedResult.errors, result.errors, "Errors should match")
        XCTAssertEqual(decodedResult.warnings, result.warnings, "Warnings should match")
    }

    // MARK: - Format Tests

    func testValidateCommandTextFormat() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        var command = try ValidateCommand.parse([fileURL.path])

        // Should execute successfully with text format
        XCTAssertNoThrow(try command.run(), "Command should execute with text format")
    }

    func testValidateCommandJSONFormat() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        var command = try ValidateCommand.parse(["--format", "json", fileURL.path])

        // Should execute successfully with JSON format
        XCTAssertNoThrow(try command.run(), "Command should execute with JSON format")
    }

    // MARK: - Integration Tests

    func testValidateCommandUsesInjectedValidator() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        var command = try ValidateCommand.parse([fileURL.path])
        let mockValidator = MockDicomValidator { path in
            XCTAssertEqual(path, fileURL.path)
            return (isValid: true, issues: [])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertNoThrow(try command.run(), "Command should use injected validator")
        XCTAssertEqual(mockValidator.validatedPaths, [fileURL.path])
    }

    func testValidateCommandErrorsSeparatedFromWarnings() {
        XCTAssertTrue(ValidationIssueClassifier.isWarning("Warning: Missing optional tag"))
        XCTAssertTrue(ValidationIssueClassifier.isWarning("File smaller than 132 bytes"))
        XCTAssertTrue(ValidationIssueClassifier.isWarning("missing optional attribute"))
        XCTAssertFalse(ValidationIssueClassifier.isWarning("Invalid DICOM format"))
    }

    // MARK: - Edge Cases

    func testValidateCommandWithFileWithoutExtension() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        // Copy to temp file without extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.copyItem(at: fileURL, to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        var command = try ValidateCommand.parse([tempURL.path])

        // Should work even without .dcm extension
        XCTAssertNoThrow(try command.run(), "Command should work with file without extension")
    }

    func testValidateCommandWithSymbolicLink() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        // Create symbolic link
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_validate_link.dcm")

        // Remove existing link if present
        try? FileManager.default.removeItem(at: linkURL)

        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
        }

        var command = try ValidateCommand.parse([linkURL.path])

        // Should work with symbolic link
        XCTAssertNoThrow(try command.run(), "Command should work with symbolic link")
    }

    func testValidateCommandWithEmptyFile() throws {
        // Create empty file
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty_\(UUID().uuidString).dcm")

        let emptyData = Data()
        try emptyData.write(to: emptyURL)
        defer {
            try? FileManager.default.removeItem(at: emptyURL)
        }

        var command = try ValidateCommand.parse([emptyURL.path])
        let mockValidator = MockDicomValidator { _ in
            (isValid: false, issues: ["File is empty"])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertThrowsError(try command.run(), "Empty file should fail validation")
        XCTAssertEqual(mockValidator.validatedPaths, [emptyURL.path])
    }

    func testValidateCommandWithTooSmallFile() throws {
        // Create file smaller than minimum DICOM size (132 bytes)
        let smallURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("small_\(UUID().uuidString).dcm")

        let smallData = Data(count: 100) // Less than 132 bytes
        try smallData.write(to: smallURL)
        defer {
            try? FileManager.default.removeItem(at: smallURL)
        }

        var command = try ValidateCommand.parse([smallURL.path])
        let mockValidator = MockDicomValidator { _ in
            (isValid: true, issues: ["File smaller than 132 bytes; DICOM preamble may be missing"])
        }
        let previousFactory = ValidateCommand.replaceValidatorFactory { mockValidator }
        defer { ValidateCommand.replaceValidatorFactory(previousFactory) }

        XCTAssertNoThrow(try command.run(), "Small file with warning-only result should pass")
        XCTAssertEqual(mockValidator.validatedPaths, [smallURL.path])
    }

    // MARK: - Performance Tests

    func testValidateCommandPerformance() throws {
        let fileURL = try createTemporaryFile(named: "valid_\(UUID().uuidString).dcm")

        measure {
            var command = try? ValidateCommand.parse([fileURL.path])
            try? command?.run()
        }
    }

    // MARK: - Output Formatter Tests

    func testOutputFormatterValidationFormatting() throws {
        let formatter = OutputFormatter(format: .text)

        let result = ValidationResult(
            isValid: true,
            errors: [],
            warnings: ["Warning 1"]
        )

        let output = try formatter.formatValidation(result)
        XCTAssertFalse(output.isEmpty, "Formatted output should not be empty")
        XCTAssertTrue(output.contains("Validation"), "Output should mention validation")
    }

    func testOutputFormatterJSONValidationFormatting() throws {
        let formatter = OutputFormatter(format: .json)

        let result = ValidationResult(
            isValid: false,
            errors: ["Error 1"],
            warnings: []
        )

        let output = try formatter.formatValidation(result)
        XCTAssertFalse(output.isEmpty, "Formatted JSON output should not be empty")

        // Verify it's valid JSON
        let data = output.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data),
                        "Output should be valid JSON")
    }
}
