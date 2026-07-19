//
//  ClinicalCodecConformanceManifestTests.swift
//  DicomCoreTests
//

import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class ClinicalCodecConformanceManifestTests: XCTestCase {
    private let requiredCoverageIDs: Set<String> = [
        "modality.ct", "modality.enhanced-ct", "modality.mr", "modality.enhanced-mr",
        "modality.mg", "modality.dx", "modality.cr", "modality.us-color-doppler",
        "modality.secondary-capture", "modality.multiframe",
        "object.seg", "object.rtstruct", "object.rtdose", "object.sr-tid1500", "object.kos",
        "object.presentation-state", "object.parametric-map", "object.real-world-value",
        "object.encapsulated-document", "object.waveform", "object.video-metadata",
        "pixel.monochrome1", "pixel.monochrome2", "pixel.rgb-full-range", "pixel.ybr",
        "pixel.palette-color", "pixel.signed", "pixel.unsigned", "pixel.bits-8", "pixel.bits-10",
        "pixel.bits-12", "pixel.bits-14", "pixel.bits-16", "pixel.planar", "pixel.interleaved",
        "pixel.single-frame", "pixel.multiframe", "pixel.single-tile", "pixel.multitile",
        "pixel.odd-non-power-of-two", "pixel.basic-offset-table", "pixel.empty-basic-offset-table",
        "pixel.extended-offset-table", "pixel.multi-fragment-frame", "pixel.lossless",
        "pixel.near-lossless", "pixel.lossy",
        "negative.truncated-codestream-fragment", "negative.inconsistent-frame-offsets",
        "negative.malformed-marker-box-bin", "negative.decompression-bomb-dimensions",
        "negative.integer-overflow-boundary", "negative.unsupported-component-precision-color"
    ]

    func test_manifestEnumeratesEveryRequiredCategoryAndKeepsGapsVisible() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.issue, 1435)
        XCTAssertEqual(Set(manifest.coverage.map(\.id)), requiredCoverageIDs)
        XCTAssertEqual(manifest.coverage.count, requiredCoverageIDs.count)

        let caseIDs = Set(manifest.cases.map(\.id))
        for coverage in manifest.coverage {
            XCTAssertFalse(coverage.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, coverage.id)
            switch coverage.status {
            case "covered":
                XCTAssertFalse(coverage.caseIDs.isEmpty, coverage.id)
                XCTAssertNil(coverage.gap, coverage.id)
                XCTAssertTrue(Set(coverage.caseIDs).isSubset(of: caseIDs), coverage.id)
            case "gap":
                XCTAssertTrue(coverage.caseIDs.isEmpty, coverage.id)
                XCTAssertFalse(coverage.gap?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, coverage.id)
            default:
                XCTFail("Unsupported coverage status \(coverage.status) for \(coverage.id)")
            }
        }
    }

    func test_committedFixturesHaveProvenancePrivacyAndStableChecksums() throws {
        let manifest = try loadManifest()
        XCTAssertFalse(manifest.fixtures.isEmpty)
        XCTAssertEqual(Set(manifest.fixtures.map(\.id)).count, manifest.fixtures.count)

        for fixture in manifest.fixtures {
            XCTAssertFalse(fixture.provenance.isEmpty, fixture.id)
            XCTAssertFalse(fixture.license.isEmpty, fixture.id)
            XCTAssertTrue(fixture.deidentification.lowercased().contains("non-phi"), fixture.id)
            XCTAssertTrue(fixture.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil, fixture.id)
            XCTAssertFalse(fixture.objectFamily.isEmpty, fixture.id)
            XCTAssertFalse(fixture.transferSyntaxUID.isEmpty, fixture.id)
            XCTAssertGreaterThanOrEqual(fixture.bitsStored, 0, fixture.id)
            XCTAssertGreaterThanOrEqual(fixture.frames, 0, fixture.id)

            let url = packageRoot().appendingPathComponent(fixture.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), fixture.id)
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, fixture.sha256, fixture.id)
        }
    }

    func test_backendQualificationMatchesEveryReportedCapabilityAndRequiresIndependentOracle() throws {
        let manifest = try loadManifest()
        let manifestBackendIDs = Set(manifest.backends.map(\.capabilityID))
        let reportedBackendIDs = Set(
            DicomCodecCapabilities.backendStatuses(environment: [:]).map(\.identifier)
        )
        XCTAssertEqual(manifestBackendIDs, reportedBackendIDs)

        let oracleIDs = Set(manifest.oracles.map(\.id))
        let caseIDs = Set(manifest.cases.map(\.id))
        let allowedVerdicts: Set<String> = ["qualified", "fallback", "experimental", "unsupported", "out-of-scope"]
        for backend in manifest.backends {
            XCTAssertTrue(allowedVerdicts.contains(backend.verdict), backend.capabilityID)
            XCTAssertTrue(Set(backend.independentOracleIDs).isSubset(of: oracleIDs), backend.capabilityID)
            XCTAssertTrue(Set(backend.caseIDs).isSubset(of: caseIDs), backend.capabilityID)
            if backend.verdict == "qualified" {
                XCTAssertFalse(backend.independentOracleIDs.isEmpty, backend.capabilityID)
                XCTAssertFalse(backend.caseIDs.isEmpty, backend.capabilityID)
            }
        }
    }

    func test_casesBindCommandsTestsExpectedResultsAndKnownVerdicts() throws {
        let manifest = try loadManifest()
        let fixtureIDs = Set(manifest.fixtures.map(\.id))
        let allowedVerdicts: Set<String> = ["qualified", "fallback", "experimental", "unsupported", "out-of-scope"]
        let allowedExpectedResults: Set<String> = ["passed", "failed", "skipped", "mismatched"]

        XCTAssertEqual(Set(manifest.cases.map(\.id)).count, manifest.cases.count)
        for item in manifest.cases {
            XCTAssertTrue(Set(item.fixtureIDs).isSubset(of: fixtureIDs), item.id)
            XCTAssertFalse(item.encoderID.isEmpty, item.id)
            XCTAssertFalse(item.decoderID.isEmpty, item.id)
            XCTAssertFalse(item.backendID.isEmpty, item.id)
            XCTAssertFalse(item.comparison.isEmpty, item.id)
            XCTAssertFalse(item.testIdentifier.isEmpty, item.id)
            XCTAssertFalse(item.requiredGates.isEmpty, item.id)
            XCTAssertTrue(allowedExpectedResults.contains(item.expectedResult), item.id)
            XCTAssertTrue(allowedVerdicts.contains(item.supportVerdict), item.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: packageRoot().appendingPathComponent(item.testPath).path), item.id)
        }

        XCTAssertFalse(manifest.commands.fixture.isEmpty)
        XCTAssertFalse(manifest.commands.runtime.isEmpty)
        XCTAssertFalse(manifest.commands.release.isEmpty)
        XCTAssertFalse(manifest.commands.dicomKitNightly.isEmpty)
    }

    func test_manifestPinsDICOMKitWithoutAddingItAsRuntimeDependency() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.dicomKit.repository, "https://github.com/Raster-Lab/DICOMKit.git")
        XCTAssertEqual(manifest.dicomKit.license, "MIT")
        XCTAssertTrue(manifest.dicomKit.commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil)
        XCTAssertEqual(manifest.dicomKit.checkoutEnvironmentVariable, "DICOMKIT_CHECKOUT")
        XCTAssertEqual(manifest.dicomKit.requireEnvironmentVariable, "DICOM_REQUIRE_DICOMKIT_INTEROP")

        let optionalRuntimeManifest = try String(
            contentsOf: packageRoot().appendingPathComponent(
                "Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(optionalRuntimeManifest.contains(manifest.dicomKit.commit))

        let packageText = try String(
            contentsOf: packageRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(packageText.contains("Raster-Lab/DICOMKit"))
        XCTAssertFalse(packageText.contains("product(name: \"DICOMKit\""))
    }

    func test_manifestContainsNoPHIMarkersOrMachineLocalPaths() throws {
        let text = try String(contentsOf: manifestURL(), encoding: .utf8)
        let blocked = [
            "/" + "Users" + "/",
            ["DICOM", "Example"].joined(separator: "_"),
            "DOE" + "^",
            "Demo" + "^"
        ]
        for marker in blocked {
            XCTAssertFalse(text.contains(marker), marker)
        }
    }

    private func loadManifest() throws -> ClinicalCodecConformanceManifest {
        try JSONDecoder().decode(
            ClinicalCodecConformanceManifest.self,
            from: Data(contentsOf: manifestURL())
        )
    }

    private func manifestURL() -> URL {
        packageRoot().appendingPathComponent(
            "Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json"
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ClinicalCodecConformanceManifest: Decodable {
    let version: Int
    let issue: Int
    let policy: Policy
    let dicomKit: DicomKit
    let coverage: [Coverage]
    let fixtures: [Fixture]
    let oracles: [Oracle]
    let backends: [Backend]
    let cases: [Case]
    let commands: Commands

    struct Policy: Decodable {
        let privacy: String
        let lossless: String
        let nearLossless: String
        let lossy: String
        let metadata: String
        let gaps: String
    }

    struct DicomKit: Decodable {
        let repository: String
        let commit: String
        let license: String
        let checkoutEnvironmentVariable: String
        let requireEnvironmentVariable: String
        let fixtureRoot: String
    }

    struct Coverage: Decodable {
        let id: String
        let status: String
        let caseIDs: [String]
        let owner: String
        let gap: String?
    }

    struct Fixture: Decodable {
        let id: String
        let path: String
        let provenance: String
        let license: String
        let deidentification: String
        let sha256: String
        let modality: String
        let objectFamily: String
        let transferSyntaxUID: String
        let photometricInterpretation: String
        let bitsStored: Int
        let signed: Bool
        let frames: Int
    }

    struct Oracle: Decodable {
        let id: String
        let implementation: String
        let version: String
        let availability: String
        let preflightCapabilityID: String
    }

    struct Backend: Decodable {
        let capabilityID: String
        let verdict: String
        let independentOracleIDs: [String]
        let caseIDs: [String]
    }

    struct Case: Decodable {
        let id: String
        let fixtureIDs: [String]
        let encoderID: String
        let decoderID: String
        let backendID: String
        let comparison: String
        let testIdentifier: String
        let testPath: String
        let requiredGates: [String]
        let expectedResult: String
        let supportVerdict: String
    }

    struct Commands: Decodable {
        let fixture: String
        let runtime: String
        let release: String
        let dicomKitNightly: String
    }
}
