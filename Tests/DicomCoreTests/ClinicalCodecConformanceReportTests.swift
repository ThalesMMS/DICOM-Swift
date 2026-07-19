//
//  ClinicalCodecConformanceReportTests.swift
//  DicomCoreTests
//

import Foundation
import XCTest

final class ClinicalCodecConformanceReportTests: XCTestCase {
    func test_reportGeneratorEmitsAuditableJSONCSVAndMarkdown() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let output = temporary.appendingPathComponent("report", isDirectory: true)

        try Data(#"[{"id":"bundled-synthetic-fixtures","kind":"fixture","status":"available","message":"fixtures present","required":true}]"#.utf8)
            .write(to: preflight)
        try Data("""
        Test Case '-[DicomCoreTests.ClinicalInteropFixtureExportTests test_committedClinicalObjectFixturesMatchDeterministicBuildersAndParse]' passed (0.125 seconds).
        Test Case '-[DicomCoreTests.ClinicalParityFixtureManifestTests test_manifestMatchesCommittedFixtures]' passed (0.250 seconds).
        """.utf8).write(to: testLog)

        let result = try runReport(
            preflight: preflight,
            testLog: testLog,
            output: output,
            gate: "fixture"
        )
        XCTAssertEqual(result.status, 0, result.output)

        let jsonURL = output.appendingPathComponent("report.json")
        let csvURL = output.appendingPathComponent("report.csv")
        let markdownURL = output.appendingPathComponent("report.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csvURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        )
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        let objectExport = try XCTUnwrap(cases.first { $0["caseID"] as? String == "dicomswift-object-export" })
        XCTAssertEqual(objectExport["result"] as? String, "passed")
        XCTAssertEqual(
            try XCTUnwrap(objectExport["durationSeconds"] as? Double),
            0.125,
            accuracy: 0.000_001
        )
        let fixtures = try XCTUnwrap(objectExport["fixtures"] as? [[String: Any]])
        XCTAssertTrue(fixtures.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
        let metadataParity = try XCTUnwrap(cases.first { $0["caseID"] as? String == "fixture-metadata-parity" })
        XCTAssertEqual(metadataParity["encoderVersion"] as? String, "workspace HEAD")
        let jpegLS = try XCTUnwrap(cases.first { $0["caseID"] as? String == "jpegls-cross-oracle" })
        XCTAssertTrue(try XCTUnwrap(jpegLS["encoderVersion"] as? String).contains("JLSwift"))
        XCTAssertFalse(try XCTUnwrap(jpegLS["encoderVersion"] as? String).contains("not-declared"))
        XCTAssertFalse(try XCTUnwrap(object["gaps"] as? [[String: Any]]).isEmpty)

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("fixtureChecksums"))
        XCTAssertTrue(csv.contains("clinical-object-builders"))
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Capability gaps"))
        XCTAssertTrue(markdown.contains("## Backend verdicts"))
    }

    func test_enforcedReportFailsWhenRequiredCasesAreMissing() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        try Data("[]".utf8).write(to: preflight)
        try Data().write(to: testLog)

        let result = try runReport(
            preflight: preflight,
            testLog: testLog,
            output: temporary.appendingPathComponent("report"),
            gate: "fixture",
            enforce: true
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Clinical conformance gate failed"))
    }

    private func runReport(
        preflight: URL,
        testLog: URL,
        output: URL,
        gate: String,
        enforce: Bool = false
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = Self.packageRoot
        process.arguments = [
            "python3",
            "Scripts/clinical_conformance_report.py",
            "--manifest",
            "Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json",
            "--preflight", preflight.path,
            "--test-log", testLog.path,
            "--output-dir", output.path,
            "--gate", gate
        ] + (enforce ? ["--enforce-required"] : [])
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clinical-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
