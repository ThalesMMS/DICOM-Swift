//
//  DicomInteropScriptTests.swift
//  DicomCoreTests
//
//  Checks explicit opt-in and diagnostic collection in the interoperability script.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest

final class DicomInteropScriptTests: XCTestCase {
    func testQA03Issue281InteropScriptIsOptInAndCapturesDiagnostics() throws {
        let script = try String(contentsOf: interopPath("run_interop_smoke.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("DICOM_INTEROP_SMOKE=1"))
        XCTAssertTrue(script.contains("swift test --filter DicomInteropSmokeTests"))
        XCTAssertTrue(script.contains("docker compose"))
        XCTAssertTrue(script.contains("docker-compose.logs"))
        XCTAssertTrue(script.contains("--no-up"))
        XCTAssertTrue(script.contains("--keep"))
        XCTAssertTrue(script.contains("--orthanc-only"))
    }

    func testQA03Issue281ComposeDefinesOrthancAndDcm4cheeProfiles() throws {
        let compose = try String(contentsOf: interopPath("docker-compose.yml"), encoding: .utf8)

        XCTAssertTrue(compose.contains("orthancteam/orthanc"))
        XCTAssertTrue(compose.contains("DICOM_WEB_PLUGIN_ENABLED"))
        XCTAssertTrue(compose.contains("ORTHANC"))
        XCTAssertTrue(compose.contains("dcm4che/dcm4chee-arc-psql"))
        XCTAssertTrue(compose.contains("dcm4che/postgres-dcm4chee"))
        XCTAssertTrue(compose.contains("dcm4che/slapd-dcm4chee"))
        XCTAssertTrue(compose.contains("11112}:11112"))
        XCTAssertTrue(compose.contains("8042}:8042"))
    }

    func testQA03Issue281ReadmeDocumentsOptInCIAndSmokeCoverage() throws {
        let readme = try String(contentsOf: interopPath("README.md"), encoding: .utf8)

        XCTAssertTrue(readme.contains("DICOM_INTEROP_SMOKE=1"))
        XCTAssertTrue(readme.contains("CI Opt-In"))
        XCTAssertTrue(readme.contains("C-ECHO"))
        XCTAssertTrue(readme.contains("C-FIND"))
        XCTAssertTrue(readme.contains("C-STORE"))
        XCTAssertTrue(readme.contains("C-MOVE"))
        XCTAssertTrue(readme.contains("C-GET"))
        XCTAssertTrue(readme.contains("STOW-RS"))
        XCTAssertTrue(readme.contains("QIDO-RS"))
        XCTAssertTrue(readme.contains("WADO-RS"))
        XCTAssertTrue(readme.contains("Storage SCP"))
    }

    private func interopPath(_ file: String) -> URL {
        repoRoot()
            .appendingPathComponent("DICOM-Swift/Scripts/interop")
            .appendingPathComponent(file)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
