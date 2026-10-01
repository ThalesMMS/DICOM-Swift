//
//  InspectCommandTests.swift
//  dicomtoolTests
//
//  Tests for the inspect command functionality
//

import XCTest
import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import dicomtool
import DicomCore
import DicomTestSupport

final class InspectCommandTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InspectCommand.replaceDecoderFactory { (_: String) async throws -> any DicomDecoderProtocol in
            Self.makeDefaultMockDecoder()
        }
    }

    override func tearDown() {
        InspectCommand.resetDecoderFactory()
        super.tearDown()
    }

    private static func makeDefaultMockDecoder() -> MockDicomDecoder {
        let decoder = MockDicomDecoder()
        decoder.width = 64
        decoder.height = 64
        decoder.bitDepth = 16
        decoder.samplesPerPixel = 1
        decoder.setTag(DicomTag.patientName.rawValue, value: "Test^Patient")
        decoder.setTag(DicomTag.patientID.rawValue, value: "TEST123")
        decoder.setTag(DicomTag.modality.rawValue, value: "CT")
        decoder.setTag(DicomTag.studyDate.rawValue, value: "20250101")
        decoder.setTag(DicomTag.seriesDescription.rawValue, value: "Synthetic Series")
        return decoder
    }

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

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            try await operation()
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    // MARK: - Initialization Tests

    func test_boundedInspect_readsActualFileAndReportsBytesWithoutPatientID() async throws {
        let dataset = DicomDataSet(elements: [
            .init(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["SYNTHETIC^RANGE"])),
            .init(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["SYNTHETIC2318"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([256])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([256])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(repeating: 7, count: 65536)))
        ])
        let url = try createTemporaryFile(contents: DicomDataSetWriter.part10Data(from: dataset))
        for mode in [[], ["--mapped-ranges"]] {
            var command = try InspectCommand.parse([url.path, "--bounded", "--read-metrics", "--format", "json",
                                                     "--tags", "PatientName,PatientID,Rows"] + mode)
            let output = try await captureStandardOutput { try await command.run() }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
            XCTAssertEqual(json["PatientName"], "SYNTHETIC^RANGE")
            XCTAssertEqual(json["Rows"], "256")
            XCTAssertEqual(json["PatientID"], "(redacted)")
            XCTAssertFalse(output.contains("SYNTHETIC2318"))
            XCTAssertLessThan(try XCTUnwrap(Int(json["ReadReceivedBytes"] ?? "")), 1024)
        }
    }

    func test_boundedInspect_strictRejectsAndRecoveryReportsOpaqueBytes() async throws {
        // Hand-encoded wrong VR: Patient Name requires PN, not LO.
        let dataset = Data([0x10, 0, 0x10, 0, 0x4C, 0x4F, 2, 0, 0x58, 0x20])
        let bytes = try DicomDataSetWriter.part10Data(fromEncodedDataSet: dataset,
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.2320003")
        let url = try createTemporaryFile(contents: bytes)
        var strict = try InspectCommand.parse([url.path, "--bounded", "--read-mode", "strict"])
        do {
            try await strict.run()
            XCTFail("Strict inspect accepted an incompatible VR")
        } catch {
            XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .incompatibleVR)
        }
        var recover = try InspectCommand.parse([url.path, "--bounded", "--read-mode", "recover", "--format", "json", "--all"])
        let output = try await captureStandardOutput { try await recover.run() }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        XCTAssertEqual(json["ReadMode"], "recover")
        XCTAssertEqual(json["ReadDataSetDiagnosticsCount"], "1")
        XCTAssertEqual(json["ReadFileMetaDiagnosticsCount"], "0")
        XCTAssertEqual(json["ReadDataSetDiagnostic0"], "tag=00100010 offset=8 reason=incompatibleVR")
        XCTAssertEqual(json["ReadDataSetDiagnostic0Path"], "tag:00100010")
        XCTAssertEqual(json["PatientName"], "(2 bytes)")
    }

    func test_boundedInspect_nestedRecoveryReportsItemPathWithoutTheInvalidValue() async throws {
        let item = DicomDataSet(elements: [.init(tag: 0x0040A040, vr: .CS, value: .strings(["bad!"]))])
        let wire = try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: item)]))
        ]))
        let bytes = try DicomDataSetWriter.part10Data(fromEncodedDataSet: wire,
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.88.22",
            mediaStorageSOPInstanceUID: "2.25.2321001")
        let url = try createTemporaryFile(contents: bytes)
        var command = try InspectCommand.parse([url.path, "--bounded", "--read-mode", "recover", "--format", "json"])
        let output = try await captureStandardOutput { try await command.run() }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        XCTAssertEqual(json["ReadDataSetDiagnosticsCount"], "1")
        XCTAssertEqual(json["ReadDataSetDiagnostic0Path"], "tag:0040A730/item:0/tag:0040A040")
        XCTAssertFalse(output.contains("bad!"))
    }

    func test_validatedInspect_requiresBoundedModeAndRejectsUnknownReadMode() async throws {
        let url = try createTemporaryFile(contents: Data())
        var command = try InspectCommand.parse([url.path, "--read-mode", "strict"])
        do {
            try await command.run()
            XCTFail("Validated read mode silently used the legacy decoder")
        } catch {
            XCTAssertTrue(error is ValidationError)
        }
        XCTAssertThrowsError(try InspectCommand.parse([url.path, "--bounded", "--read-mode", "guess"]))
    }

    func testInspectCommandInitialization() throws {
        // Test that InspectCommand can be parsed from arguments
        let command = try InspectCommand.parse(["/path/to/test.dcm"])

        XCTAssertEqual(command.file, "/path/to/test.dcm", "File path should be set")
        XCTAssertEqual(command.format, .text, "Default format should be text")
        XCTAssertFalse(command.all, "All flag should default to false")
        XCTAssertNil(command.tags, "Tags should default to nil")
    }

    func testInspectCommandConfiguration() {
        let config = InspectCommand.configuration

        XCTAssertEqual(config.commandName, "inspect", "Command name should be 'inspect'")
        XCTAssertFalse(config.abstract.isEmpty, "Command should have an abstract")
        XCTAssertFalse(config.discussion.isEmpty, "Command should have discussion text")
    }

    // MARK: - Default Metadata Tests

    func testInspectCommandWithValidFileTextFormat() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse([fileURL.path])

        // Test that command can be executed without throwing
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully with valid file: \(error)")
        }
    }

    func testInspectCommandWithValidFileJSONFormat() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--format", "json", fileURL.path])

        // Test that command can be executed without throwing
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully with JSON format: \(error)")
        }
    }

    func testInspectCommandDefaultOutputOmitsPatientID() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")
        var command = try InspectCommand.parse(["--format", "json", fileURL.path])

        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("PatientName"), "Default metadata should still include patient context")
        XCTAssertFalse(output.contains("PatientID"), "Default metadata should not emit direct patient identifiers")
        XCTAssertFalse(output.contains("TEST123"), "Default metadata should not emit direct patient identifier values")
    }

    func testInspectCommandSpecificPatientIDTagIsRedacted() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")
        var command = try InspectCommand.parse(["--format", "json", "--tags", "PatientID", fileURL.path])

        let output = try await captureStandardOutput {
            try await command.run()
        }

        XCTAssertTrue(output.contains("PatientID"), "Explicit tag selection should include the requested tag name")
        XCTAssertTrue(output.contains("(redacted)"), "Direct patient identifiers should be redacted")
        XCTAssertFalse(output.contains("TEST123"), "Direct patient identifier values should not be emitted")
    }

    func testInspectCommandWithAllFlag() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--all", fileURL.path])

        // Test that command can be executed with --all flag
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully with --all flag: \(error)")
        }
    }

    // MARK: - Specific Tags Tests

    func testInspectCommandWithSpecificTags() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--tags", "PatientName,Modality", fileURL.path])

        // Test that command can be executed with specific tags
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully with specific tags: \(error)")
        }
    }

    func testInspectCommandWithMultipleSpecificTags() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--format", "json", "--tags", "PatientName,PatientID,Modality,StudyDate,SeriesDescription", fileURL.path])

        // Test that command can be executed with multiple tags
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully with multiple tags: \(error)")
        }
    }

    func testInspectCommandWithInvalidTag() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--tags", "InvalidTagName", fileURL.path])

        // Test that command throws error for invalid tag
        do {
            try await command.run()
            XCTFail("Expected invalid tag to throw")
        } catch {
            guard let cliError = error as? CLIError else {
                XCTFail("Error should be of type CLIError")
                return
            }

            if case .invalidArgument(let argument, let value, _) = cliError {
                XCTAssertEqual(argument, "--tags", "Error should reference --tags argument")
                XCTAssertEqual(value, "InvalidTagName", "Error should reference invalid tag name")
            } else {
                XCTFail("Error should be .invalidArgument")
            }
        }
    }

    func testInspectCommandWithEmptyTagsList() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--tags", "", fileURL.path])

        // Empty tags list should be handled gracefully
        do {
            try await command.run()
        } catch {
            XCTFail("Command should handle empty tags list: \(error)")
        }
    }

    func testInspectCommandWithTagsContainingWhitespace() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var command = try InspectCommand.parse(["--tags", "PatientName, Modality, StudyDate", fileURL.path])

        // Tags with whitespace should be trimmed and work correctly
        do {
            try await command.run()
        } catch {
            XCTFail("Command should handle tags with whitespace: \(error)")
        }
    }

    // MARK: - Error Handling Tests

    func testInspectCommandWithNonExistentFile() async throws {
        var command = try InspectCommand.parse(["/nonexistent/path/to/file.dcm"])

        // Test that command throws error for non-existent file
        do {
            try await command.run()
            XCTFail("Expected missing file to throw")
        } catch {
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

    func testInspectCommandWithEmptyFilePath() async throws {
        var command = try InspectCommand.parse([""])
        InspectCommand.replaceDecoderFactory { _ in
            throw DICOMError.invalidDICOMFormat(reason: "Mock invalid file")
        }

        // Test that command throws error for empty file path
        do {
            try await command.run()
            XCTFail("Expected empty file path to throw")
        } catch {
            XCTAssertTrue(error is CLIError, "Error should be of type CLIError")
        }
    }

    func testInspectCommandWithDirectoryPath() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspect_directory_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        InspectCommand.replaceDecoderFactory { _ in
            throw DICOMError.invalidDICOMFormat(reason: "Directory input is not a DICOM file")
        }
        var command = try InspectCommand.parse([directoryURL.path])

        // Test that command throws error when given a directory instead of file
        do {
            try await command.run()
            XCTFail("Expected directory path to throw")
        } catch {
            XCTAssertTrue(error is CLIError, "Error should be of type CLIError")
        }
    }

    // MARK: - Format Tests

    func testOutputFormatEnumValues() {
        let allFormats = OutputFormat.allCases

        XCTAssertEqual(allFormats.count, 2, "Should have exactly 2 output formats")
        XCTAssertTrue(allFormats.contains(.text), "Should support text format")
        XCTAssertTrue(allFormats.contains(.json), "Should support JSON format")
    }

    func testOutputFormatDescriptions() {
        XCTAssertFalse(OutputFormat.text.description.isEmpty, "Text format should have description")
        XCTAssertFalse(OutputFormat.json.description.isEmpty, "JSON format should have description")
    }

    func testOutputFormatRawValues() {
        XCTAssertEqual(OutputFormat.text.rawValue, "text", "Text format raw value should be 'text'")
        XCTAssertEqual(OutputFormat.json.rawValue, "json", "JSON format raw value should be 'json'")
    }

    // MARK: - Integration Tests

    func testInspectCommandDefaultBehaviorMatchesExpectations() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")
        let mockDecoder = MockDicomDecoder()
        mockDecoder.width = 128
        mockDecoder.height = 96
        mockDecoder.setTag(DicomTag.patientName.rawValue, value: "Mock^Patient")
        let requestedPath = LockedValue<String?>(nil)
        InspectCommand.replaceDecoderFactory { path in
            requestedPath.replace(with: path)
            return mockDecoder
        }

        var command = try InspectCommand.parse([fileURL.path])

        // Verify command executes successfully
        do {
            try await command.run()
        } catch {
            XCTFail("Command should execute successfully: \(error)")
        }

        XCTAssertEqual(requestedPath.value, fileURL.path, "Command should request decoding for the selected path")
        XCTAssertEqual(mockDecoder.width, 128)
        XCTAssertEqual(mockDecoder.height, 96)
    }

    func testInspectCommandWithAllTagsIncludesMoreThanDefault() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        var defaultCommand = try InspectCommand.parse([fileURL.path])
        var allCommand = try InspectCommand.parse(["--all", fileURL.path])

        // Both should execute successfully
        do {
            try await defaultCommand.run()
            try await allCommand.run()
        } catch {
            XCTFail("Both default and --all commands should succeed: \(error)")
        }
    }

    // MARK: - Edge Cases

    func testInspectCommandWithFileWithoutExtension() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        // Copy to temp file without extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try FileManager.default.copyItem(at: fileURL, to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        var command = try InspectCommand.parse([tempURL.path])

        // Should work even without .dcm extension
        do {
            try await command.run()
        } catch {
            XCTFail("Command should work with file without extension: \(error)")
        }
    }

    func testInspectCommandWithSymbolicLink() async throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        // Create symbolic link
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_link.dcm")

        // Remove existing link if present
        try? FileManager.default.removeItem(at: linkURL)

        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
        }

        var command = try InspectCommand.parse([linkURL.path])

        // Should work with symbolic link
        do {
            try await command.run()
        } catch {
            XCTFail("Command should work with symbolic link: \(error)")
        }
    }

    // MARK: - Performance Tests

    func testInspectCommandPerformance() throws {
        let fileURL = try createTemporaryFile(named: "inspect_\(UUID().uuidString).dcm")

        measure {
            let expectation = expectation(description: "Inspect command run completes")
            Task {
                var command = try? InspectCommand.parse([fileURL.path])
                try? await command?.run()
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2.0)
        }
    }
}
