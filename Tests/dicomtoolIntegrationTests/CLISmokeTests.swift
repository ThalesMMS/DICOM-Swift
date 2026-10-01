//
//  CLISmokeTests.swift
//  dicomtoolIntegrationTests
//
//  Smoke tests for documented CLI entrypoints.
//

import Foundation
import XCTest

final class CLISmokeTests: XCTestCase {
    func testRootHelpExitsSuccessfully() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicomtool-smoke-\(UUID().uuidString)")
        let stdoutURL = scratchPath.appendingPathComponent("stdout.txt")
        let stderrURL = scratchPath.appendingPathComponent("stderr.txt")
        try FileManager.default.createDirectory(at: scratchPath, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: scratchPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "run",
            "--scratch-path",
            scratchPath.path,
            "dicomtool",
            "--help",
        ]
        process.currentDirectoryURL = packageRoot

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = expectation(description: "`swift run dicomtool --help` finished")
        process.terminationHandler = { _ in
            finished.fulfill()
        }

        try process.run()
        // A clean build in the scratch path now compiles the vendored JPEG/JPEG-LS/JPEG 2000 cores as well (#2329).
        wait(for: [finished], timeout: 900)

        if process.isRunning {
            process.terminate()
            try stdout.close()
            try stderr.close()
            XCTFail("Timed out waiting for `swift run dicomtool --help` to finish.")
            return
        }

        try stdout.close()
        try stderr.close()

        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Expected `swift run dicomtool --help` to exit 0.\nstdout:\n\(stdoutText)\nstderr:\n\(stderrText)"
        )
        XCTAssertTrue(stdoutText.contains("DICOM file inspection"), "Expected help output to include the CLI abstract.")
        XCTAssertTrue(stdoutText.contains("dicomtool"), "Expected help output to reference dicomtool.")
    }
}

extension CLISmokeTests {
    /// `dicomtool preflight` (issue #1219) must run without the XCTest
    /// suite, report every manifest capability, and exit zero when only
    /// optional capabilities are absent.
    func testPreflightReportsManifestCapabilitiesAndExitsZeroByDefault() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratchDirectory = try DicomtoolPreflightScratchDirectory()
        let scratchPath = scratchDirectory.url
        let stdoutURL = scratchPath.appendingPathComponent("stdout.txt")
        let stderrURL = scratchPath.appendingPathComponent("stderr.txt")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        addTeardownBlock {
            try? scratchDirectory.remove()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "run",
            "--scratch-path",
            scratchPath.path,
            "dicomtool",
            "preflight",
            "--package-root",
            packageRoot.path,
        ]
        process.currentDirectoryURL = packageRoot
        // The default policy must not require optional runtimes in this test.
        var environment = ProcessInfo.processInfo.environment
        environment["DICOM_REQUIRE_OPTIONAL_RUNTIMES"] = nil
        process.environment = environment

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = expectation(description: "`swift run dicomtool preflight` finished")
        process.terminationHandler = { _ in
            finished.fulfill()
        }

        try process.run()
        wait(for: [finished], timeout: 900)

        if process.isRunning {
            process.terminate()
            try stdout.close()
            try stderr.close()
            XCTFail("Timed out waiting for `swift run dicomtool preflight` to finish.")
            return
        }

        try stdout.close()
        try stderr.close()

        XCTAssertEqual(process.terminationStatus, 0, "preflight must exit zero when only optional capabilities are absent")

        let output = try String(contentsOf: stdoutURL, encoding: .utf8)
        for capabilityID in [
            "bundled-synthetic-fixtures",
            "large-dicom-fixtures",
            "jpeg-lossless-conformance-fixtures",
            "charls-runtime",
            "openjpeg-runtime",
            "opj-compress-tool",
            "metal-device",
            "network-security-tls",
            "network-interop-smoke",
        ] {
            XCTAssertTrue(output.contains(capabilityID), "preflight report must cover \(capabilityID)")
        }
        XCTAssertTrue(output.contains("Summary:"), "preflight report must end with a summary")
    }
}
