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

    func test_duplicateInteropResults_cannotOverwriteFailureWithSuccess() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let interop = temporary.appendingPathComponent("interop.jsonl")
        try Data("[]".utf8).write(to: preflight)
        try Data().write(to: testLog)
        try Data("""
        {"caseID":"dicomkit-synthetic-read","result":"failed","failureLocation":"frame[1].sample[17]"}
        {"caseID":"dicomkit-synthetic-read","result":"passed"}
        """.utf8).write(to: interop)

        let result = try runReport(
            preflight: preflight, testLog: testLog,
            output: temporary.appendingPathComponent("report"), gate: "nightly", interop: interop
        )
        XCTAssertNotEqual(result.status, 0, "Contradictory evidence must be rejected, even without gate enforcement")
        XCTAssertTrue(result.output.contains("duplicate caseID"), result.output)
    }

    func test_externalSuccess_cannotHideLocalFailureForSameCase() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let interop = temporary.appendingPathComponent("interop.jsonl")
        try Data("[]".utf8).write(to: preflight)
        try Data("""
        Test Case '-[DicomCoreTests.ClinicalIndependentCorpusTests test_fixture]' failed (0.1 seconds).
        """.utf8).write(to: testLog)
        try Data(#"{"caseID":"independent-native-corpus","result":"passed"}"#.utf8).write(to: interop)
        let result = try runReport(
            preflight: preflight, testLog: testLog,
            output: temporary.appendingPathComponent("report"), gate: "differential", interop: interop
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("conflicting evidence"), result.output)
    }

    func test_externalSuccess_canSupplyEvidenceForSkippedLocalCase() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let interop = temporary.appendingPathComponent("interop.jsonl")
        let output = temporary.appendingPathComponent("report")
        try Data("[]".utf8).write(to: preflight)
        try Data("""
        Test Case '-[DicomCoreTests.ClinicalIndependentCorpusTests test_fixture]' skipped (0.1 seconds).
        """.utf8).write(to: testLog)
        try Data(#"{"caseID":"independent-native-corpus","result":"passed"}"#.utf8).write(to: interop)
        let result = try runReport(
            preflight: preflight, testLog: testLog, output: output, gate: "differential", interop: interop
        )
        XCTAssertEqual(result.status, 0, result.output)
        let cases = try XCTUnwrap(readReport(output)["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.first { $0["caseID"] as? String == "independent-native-corpus" }?["result"] as? String,
                       "passed")
    }

    func test_missingSuiteInCombinedCase_doesNotQualifyClinicalObjects() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let output = temporary.appendingPathComponent("report")
        try Data("[]".utf8).write(to: preflight)
        try Data("""
        Test Case '-[DicomCoreTests.DicomSegmentationTests test_binary]' passed (0.1 seconds).
        Test Case '-[DicomCoreTests.DicomRTObjectsTests test_dose]' passed (0.1 seconds).
        """.utf8).write(to: testLog)

        let result = try runReport(preflight: preflight, testLog: testLog, output: output, gate: "fixture")
        XCTAssertEqual(result.status, 0, result.output)
        let report = try readReport(output)
        let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
        let clinical = try XCTUnwrap(cases.first { $0["caseID"] as? String == "clinical-object-roundtrip" })
        XCTAssertEqual(clinical["result"] as? String, "missing")
        XCTAssertEqual(clinical["missingTestIdentifiers"] as? [String], ["DicomAIInferenceTests"])
        XCTAssertEqual(clinical["metadataValidation"] as? String, "not-executed")
        let backends = try XCTUnwrap(report["backends"] as? [[String: Any]])
        XCTAssertFalse(backends.contains { $0["verdict"] as? String == "qualified" })
    }

    func test_unknownInteropCase_isRejectedInsteadOfSilentlyIgnored() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let interop = temporary.appendingPathComponent("interop.jsonl")
        try Data("[]".utf8).write(to: preflight)
        try Data().write(to: testLog)
        try Data(#"{"caseID":"misspelled-case","result":"passed"}"#.utf8).write(to: interop)
        let result = try runReport(
            preflight: preflight, testLog: testLog,
            output: temporary.appendingPathComponent("report"), gate: "nightly", interop: interop
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("unknown caseID"), result.output)
    }

    func test_requiredUnavailableOracle_failsEvenWhenGateHasNoRequiredCases() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        try Data(#"[{"id":"independent-oracle","status":"unavailable","required":true}]"#.utf8)
            .write(to: preflight)
        try Data().write(to: testLog)
        let result = try runReport(
            preflight: preflight, testLog: testLog,
            output: temporary.appendingPathComponent("report"), gate: "oracle-probe", enforce: true
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("required capability independent-oracle"), result.output)
    }

    func test_mismatchEvidence_preservesFirstDifferenceAndMetricsInEveryFormat() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preflight = temporary.appendingPathComponent("preflight.json")
        let testLog = temporary.appendingPathComponent("test.log")
        let interop = temporary.appendingPathComponent("interop.jsonl")
        let output = temporary.appendingPathComponent("report")
        try Data("[]".utf8).write(to: preflight)
        try Data().write(to: testLog)
        try Data("""
        {"caseID":"dicomkit-synthetic-read","result":"mismatched","failureLocation":"frame[2].pixel[7].component[1]","firstDifference":{"frame":2,"pixel":7,"component":1,"expected":16,"actual":17},"metrics":{"samplesCompared":144,"maximumAbsoluteError":1}}
        """.utf8).write(to: interop)
        let result = try runReport(
            preflight: preflight, testLog: testLog, output: output, gate: "nightly", interop: interop
        )
        XCTAssertEqual(result.status, 0, result.output)
        let report = try readReport(output)
        let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
        let mismatch = try XCTUnwrap(cases.first { $0["caseID"] as? String == "dicomkit-synthetic-read" })
        XCTAssertEqual(mismatch["result"] as? String, "mismatched")
        let difference = try XCTUnwrap(mismatch["firstDifference"] as? [String: Int])
        XCTAssertEqual(difference, ["frame": 2, "pixel": 7, "component": 1, "expected": 16, "actual": 17])
        let metrics = try XCTUnwrap(mismatch["metrics"] as? [String: Int])
        XCTAssertEqual(metrics["samplesCompared"], 144)
        let environment = try XCTUnwrap(report["environment"] as? [String: Any])
        let hashes = try XCTUnwrap(environment["evidenceSHA256"] as? [String: String])
        XCTAssertEqual(Set(hashes.keys), ["manifest", "preflight", "testLog", "interop"])
        XCTAssertTrue(hashes.values.allSatisfy { $0.count == 64 })
        for filename in ["report.csv", "report.md"] {
            let text = try String(contentsOf: output.appendingPathComponent(filename), encoding: .utf8)
            XCTAssertTrue(text.contains("component"), filename)
            XCTAssertTrue(text.contains("samplesCompared"), filename)
        }
    }

    private func readReport(_ output: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathComponent("report.json"))
        ) as? [String: Any])
    }

    private func runReport(
        preflight: URL,
        testLog: URL,
        output: URL,
        gate: String,
        enforce: Bool = false,
        interop: URL? = nil
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
            + (interop.map { ["--interop-results", $0.path] } ?? [])
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
