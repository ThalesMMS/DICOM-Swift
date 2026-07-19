import Foundation
import XCTest
import DicomTestSupport

final class DicomTestRuntimePreflightTests: XCTestCase {
    func testOptionalRuntimeFixtureManifestDeclaresRequiredCapabilitiesAndCoverage() throws {
        let manifestURL = packageRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json")
        let manifest = try JSONDecoder().decode(
            OptionalRuntimeFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.version, 1)
        XCTAssertFalse(manifest.ciPolicy.default.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(manifest.ciPolicy.requiredCapabilityEnv.contains("DICOM_REQUIRE_<CAPABILITY>"))
        XCTAssertTrue(manifest.ciPolicy.networkSmoke.contains("DICOM_INTEROP_SMOKE=1"))

        let manifestIDs = Set(manifest.capabilities.map(\.id))
        let expectedIDs = Set(DicomRuntimeCapability.allCases.map(\.manifestID))
            .union(["j2kswift-backend", "jlswift-backend", "jxlswift-backend", "dicomkit-interop"])
        XCTAssertEqual(manifestIDs, expectedIDs)

        for capability in manifest.capabilities {
            XCTAssertFalse(capability.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.phiStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.expectedMetadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.expectedPixelBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.testCoverage.isEmpty, capability.id)
            XCTAssertFalse(capability.preflight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)
            XCTAssertFalse(capability.ciBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.id)

            for testCoveragePath in capability.testCoverage {
                let path = packageRoot().appendingPathComponent(testCoveragePath)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: path.path),
                    "\(capability.id) references missing coverage path: \(testCoveragePath)"
                )
            }
        }
    }

    func testRuntimePreflightsReportExplicitOutcomeCategories() {
        let acceptedKinds: Set<DicomRuntimeStatusKind> = [
            .available,
            .missingOptionalRuntime,
            .regression,
            .unsupportedFeature
        ]

        for capability in DicomRuntimeCapability.allCases {
            let status = DicomTestRuntimePreflight.status(for: capability)
            XCTAssertEqual(status.capability, capability)
            XCTAssertTrue(acceptedKinds.contains(status.kind), capability.manifestID)
            XCTAssertFalse(status.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, capability.manifestID)
        }
    }

    func testRuntimeRequirementPolicyTurnsRequiredAbsenceIntoFailure() {
        let environment = ["DICOM_REQUIRE_OPENJPEG": "1"]
        XCTAssertTrue(DicomTestRuntimePreflight.isRequired(.openJPEG, environment: environment))
        XCTAssertFalse(DicomTestRuntimePreflight.isRequired(.charLS, environment: environment))
        XCTAssertTrue(DicomTestRuntimePreflight.isRequired(.bundledSyntheticFixtures, environment: [:]))

        let allRequiredEnvironment = [DicomTestRuntimePreflight.requireAllOptionalRuntimesEnvironmentVariable: "1"]
        XCTAssertTrue(DicomTestRuntimePreflight.isRequired(.charLS, environment: allRequiredEnvironment))
        XCTAssertTrue(DicomTestRuntimePreflight.isRequired(.networkInteropSmoke, environment: allRequiredEnvironment))
    }

    func testPreflightMessagesDistinguishMissingRuntimeUnsupportedFeatureAndRegression() {
        let missing = DicomRuntimeStatus(
            capability: .openJPEG,
            kind: .missingOptionalRuntime,
            message: "OpenJPEG runtime library is not loadable."
        )
        let unsupported = DicomRuntimeStatus(
            capability: .metalDevice,
            kind: .unsupportedFeature,
            message: "Metal framework is unavailable on this platform."
        )
        let regression = DicomRuntimeStatus(
            capability: .bundledSyntheticFixtures,
            kind: .regression,
            message: "Required bundled synthetic fixtures are missing."
        )

        XCTAssertTrue(DicomTestRuntimePreflight.skipMessage(for: missing).contains("classification=missing-optional-runtime"))
        XCTAssertTrue(DicomTestRuntimePreflight.skipMessage(for: unsupported).contains("classification=unsupported-feature"))
        XCTAssertTrue(DicomTestRuntimePreflight.failureMessage(for: regression).contains("classification=regression"))
        XCTAssertTrue(DicomTestRuntimePreflight.failureMessage(for: missing).contains("is required but unavailable"))
    }

    private func packageRoot() -> URL {
        var current = URL(fileURLWithPath: #filePath)
        while current.lastPathComponent != "DICOM-Swift" {
            let next = current.deletingLastPathComponent()
            precondition(next.path != current.path, "Could not find DICOM-Swift package root from \(#filePath)")
            current = next
        }
        return current
    }
}

private struct OptionalRuntimeFixtureManifest: Decodable {
    struct CIPolicy: Decodable {
        let `default`: String
        let requiredCapabilityEnv: String
        let networkSmoke: String
    }

    struct Capability: Decodable {
        let id: String
        let kind: String
        let source: String
        let phiStatus: String
        let expectedMetadata: String
        let expectedPixelBehavior: String
        let testCoverage: [String]
        let preflight: String
        let ciBehavior: String
    }

    let version: Int
    let ciPolicy: CIPolicy
    let capabilities: [Capability]
}
