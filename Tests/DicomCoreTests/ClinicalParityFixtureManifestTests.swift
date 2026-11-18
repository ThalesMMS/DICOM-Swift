//
//  ClinicalParityFixtureManifestTests.swift
//  DicomCoreTests
//
//  Checks parity fixture coverage, golden-test references, metadata, and exclusion of private data
//  or paths.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
@testable import DicomCore

final class ClinicalParityFixtureManifestTests: XCTestCase {
    private let requiredFeatureIDs: Set<String> = [
        "uncompressed",
        "jpeg-lossless",
        "jpeg-2000",
        "rle",
        "multiframe",
        "seg",
        "rtstruct",
        "rtdose",
        "sr-tid1500",
        "kos",
        "pr",
        "hp",
        "rwv",
        "pmap",
        "dicomdir",
        "encapsulated-pdf",
        "waveform",
        "video"
    ]

    private let requiredGoldenCategories: Set<String> = [
        "metadata",
        "pixel-hash",
        "frame-count",
        "geometry",
        "sr-tree",
        "segment-metadata"
    ]

    private let requiredDecoderParityCoverage: Set<String> = [
        "explicit-vr-little-endian-ct-or-mr",
        "implicit-vr-little-endian",
        "secondary-capture",
        "specific-character-set-non-ascii",
        "missing-optional-voi",
        "rescale",
        "multiframe",
        "compressed-transfer-syntax"
    ]

    func testManifestCoversRequiredClinicalParityFixtures() throws {
        let manifestURL = repoRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json")
        let manifest = try JSONDecoder().decode(
            ClinicalParityFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.version, 1)
        XCTAssertFalse(manifest.policy.storage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(manifest.policy.privacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(manifest.policy.ci.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let ids = manifest.features.map(\.id)
        XCTAssertEqual(Set(ids), requiredFeatureIDs)
        XCTAssertEqual(ids.count, requiredFeatureIDs.count)

        for feature in manifest.features {
            XCTAssertFalse(feature.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)
            XCTAssertFalse(feature.representation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)
            XCTAssertFalse(feature.artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)
            XCTAssertFalse(feature.synthesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)
            XCTAssertFalse(feature.issues.isEmpty, feature.id)
            XCTAssertFalse(feature.goldens.isEmpty, feature.id)
            XCTAssertFalse(feature.tests.isEmpty, feature.id)
            XCTAssertFalse(feature.ci.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)

            for issue in feature.issues {
                XCTAssertTrue(issue.range(of: #"^#[0-9]+$"#, options: .regularExpression) != nil,
                              "Invalid issue reference for \(feature.id): \(issue)")
            }
            for golden in feature.goldens {
                XCTAssertFalse(golden.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, feature.id)
            }
            assertRepoPathExists(feature.artifact, featureID: feature.id)
            for testPath in feature.tests {
                assertRepoPathExists(testPath, featureID: feature.id)
            }
        }

        let coveredGoldenCategories = Set(manifest.features.flatMap(\.goldens))
        XCTAssertTrue(requiredGoldenCategories.isSubset(of: coveredGoldenCategories),
                      "Manifest must cover QA-02 golden categories: \(requiredGoldenCategories.subtracting(coveredGoldenCategories).sorted())")
    }

    func testDoneMatrixFeaturesAreBoundToIssuesAndGoldenTests() throws {
        let manifestURL = repoRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json")
        let matrixURL = repoRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/DICOMAdvancedParityMatrix.md")
        let manifest = try JSONDecoder().decode(
            ClinicalParityFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let matrixText = try String(contentsOf: matrixURL, encoding: .utf8)
        let doneIssues = Set(matrixText
            .split(separator: "\n")
            .filter { $0.contains("| Done") || $0.contains("| Done:") }
            .compactMap { row -> String? in
                guard let range = row.range(of: #"#\d+"#, options: .regularExpression) else {
                    return nil
                }
                return String(row[range])
            })

        for feature in manifest.features {
            let doneFeatureIssues = feature.issues.filter(doneIssues.contains)
            guard !doneFeatureIssues.isEmpty else {
                continue
            }
            XCTAssertFalse(feature.tests.isEmpty, "\(feature.id) must keep CI-visible tests while \(doneFeatureIssues) is marked done")
            XCTAssertFalse(feature.goldens.isEmpty, "\(feature.id) must keep golden expectations while \(doneFeatureIssues) is marked done")
        }
    }

    func testManifestDoesNotExposePrivateDataOrLocalPaths() throws {
        let manifestURL = repoRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json")
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        let blockedMarkers = [
            "/" + "Users" + "/",
            ["DICOM", "Example"].joined(separator: "_"),
            "Demo" + "^",
            ["D", "OE"].joined()
        ]

        for marker in blockedMarkers {
            XCTAssertFalse(manifestText.contains(marker), "Manifest contains blocked marker: \(marker)")
        }
    }

    func testDecoderParityFixtureManifestListsRequiredMetadataAndFiles() throws {
        let manifest = try loadManifest()
        let fixtures = manifest.decoderParity.fixtures

        XCTAssertEqual(manifest.decoderParity.issue, "#1052")
        XCTAssertGreaterThanOrEqual(fixtures.count, 7)
        XCTAssertEqual(Set(fixtures.map(\.id)).count, fixtures.count, "Fixture IDs must be unique")

        let coverage = Set(fixtures.flatMap(\.coverage))
        XCTAssertTrue(
            requiredDecoderParityCoverage.isSubset(of: coverage),
            "Missing coverage: \(requiredDecoderParityCoverage.subtracting(coverage).sorted())"
        )

        for fixture in fixtures {
            assertRepoPathExists(fixture.path, featureID: fixture.id)
            XCTAssertFalse(fixture.sopClassUID.isEmpty, fixture.id)
            XCTAssertFalse(fixture.transferSyntaxUID.isEmpty, fixture.id)
            XCTAssertFalse(fixture.modality.isEmpty, fixture.id)
            XCTAssertFalse(fixture.specificCharacterSet.isEmpty, fixture.id)
            XCTAssertFalse(fixture.expectedUIDs.studyInstanceUID.isEmpty, fixture.id)
            XCTAssertFalse(fixture.expectedUIDs.seriesInstanceUID.isEmpty, fixture.id)
            XCTAssertFalse(fixture.expectedUIDs.sopInstanceUID.isEmpty, fixture.id)
            XCTAssertGreaterThan(fixture.dimensions.rows, 0, fixture.id)
            XCTAssertGreaterThan(fixture.dimensions.columns, 0, fixture.id)
            XCTAssertGreaterThan(fixture.dimensions.frames, 0, fixture.id)
            XCTAssertGreaterThan(fixture.pixel.samplesPerPixel, 0, fixture.id)
            XCTAssertFalse(fixture.pixel.photometricInterpretation.isEmpty, fixture.id)

            if fixture.window.present {
                XCTAssertNotNil(fixture.window.center, fixture.id)
                XCTAssertNotNil(fixture.window.width, fixture.id)
            }
            if fixture.rescale.present {
                XCTAssertNotNil(fixture.rescale.slope, fixture.id)
                XCTAssertNotNil(fixture.rescale.intercept, fixture.id)
            }
        }
    }

    func testDecoderParityFixtureMetadataMatchesDecoderOutput() throws {
        for fixture in try loadManifest().decoderParity.fixtures {
            let decoder = try DCMDecoder(contentsOf: repoRoot().appendingPathComponent(fixture.path))

            XCTAssertEqual(trim(decoder.info(for: .sopClassUID)), fixture.sopClassUID, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .sopInstanceUID)), fixture.expectedUIDs.sopInstanceUID, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .studyInstanceUID)), fixture.expectedUIDs.studyInstanceUID, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .seriesInstanceUID)), fixture.expectedUIDs.seriesInstanceUID, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .modality)), fixture.modality, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .patientName)), fixture.text.patientName, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .patientID)), fixture.text.patientID, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.info(for: .studyDescription)), fixture.text.studyDescription, fixture.id)
            XCTAssertEqual(
                optionalTrim(decoder.dataSet.string(for: DicomTag.seriesDescription)),
                fixture.text.seriesDescription,
                fixture.id
            )
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: 0x0008_0050)), fixture.text.accessionNumber, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .institutionName)), fixture.text.institutionName, fixture.id)
            XCTAssertEqual(
                optionalTrim(decoder.dataSet.string(for: .referringPhysicianName)),
                fixture.text.referringPhysicianName,
                fixture.id
            )
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .bodyPartExamined)), fixture.text.bodyPartExamined, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .acquisitionProtocolName)), fixture.text.protocolName, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: 0x0010_0030)), fixture.text.patientBirthDate, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .patientSex)), fixture.text.patientSex, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .patientAge)), fixture.text.patientAge, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .studyDate)), fixture.dates.studyDate, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .studyTime)), fixture.dates.studyTime, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .seriesDate)), fixture.dates.seriesDate, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .seriesTime)), fixture.dates.seriesTime, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .acquisitionDate)), fixture.dates.acquisitionDate, fixture.id)
            XCTAssertEqual(optionalTrim(decoder.dataSet.string(for: .acquisitionTime)), fixture.dates.acquisitionTime, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: .numberOfStudyRelatedSeries), fixture.counts.numberOfStudyRelatedSeries, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: 0x0020_1208), fixture.counts.numberOfStudyRelatedInstances, fixture.id)
            XCTAssertEqual(
                decoder.dataSet.int(for: .numberOfSeriesRelatedInstances),
                fixture.counts.numberOfSeriesRelatedInstances,
                fixture.id
            )
            XCTAssertEqual(decoder.dataSet.int(for: .seriesNumber), fixture.instance.seriesNumber, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: 0x0020_0012), fixture.instance.acquisitionNumber, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: .instanceNumber), fixture.instance.instanceNumber, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .transferSyntaxUID)), fixture.transferSyntaxUID, fixture.id)

            if fixture.specificCharacterSetPresent {
                XCTAssertEqual(trim(decoder.info(for: .specificCharacterSet)), fixture.specificCharacterSet, fixture.id)
            } else {
                XCTAssertTrue(trim(decoder.info(for: .specificCharacterSet)).isEmpty, fixture.id)
            }

            XCTAssertEqual(decoder.height, fixture.dimensions.rows, fixture.id)
            XCTAssertEqual(decoder.width, fixture.dimensions.columns, fixture.id)
            XCTAssertEqual(decoder.nImages, fixture.dimensions.frames, fixture.id)
            XCTAssertEqual(decoder.samplesPerPixel, fixture.pixel.samplesPerPixel, fixture.id)
            XCTAssertEqual(trim(decoder.info(for: .photometricInterpretation)), fixture.pixel.photometricInterpretation, fixture.id)
            XCTAssertEqual(decoder.bitDepth, fixture.pixel.bitsAllocated, fixture.id)
            XCTAssertEqual(decoder.pixelRepresentationTagValue, fixture.pixel.pixelRepresentation, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: 0x0028_0106), fixture.pixel.smallestImagePixelValue, fixture.id)
            XCTAssertEqual(decoder.dataSet.int(for: 0x0028_0107), fixture.pixel.largestImagePixelValue, fixture.id)

            XCTAssertEqual(decoder.isMultiFrame, fixture.status.multiframe, fixture.id)
            XCTAssertEqual(decoder.compressedImage, fixture.status.compressed, fixture.id)

            assertVector(decoder.info(for: .pixelSpacing), equals: fixture.geometry.pixelSpacing, fixtureID: fixture.id)
            if let imagePosition = decoder.imagePosition, !fixture.geometry.imagePositionPatient.isEmpty {
                assertValues(
                    [imagePosition.x, imagePosition.y, imagePosition.z],
                    equals: fixture.geometry.imagePositionPatient,
                    fixtureID: fixture.id
                )
            }
            if let orientation = decoder.imageOrientation, !fixture.geometry.imageOrientationPatient.isEmpty {
                assertValues(
                    [
                        orientation.row.x, orientation.row.y, orientation.row.z,
                        orientation.column.x, orientation.column.y, orientation.column.z
                    ],
                    equals: fixture.geometry.imageOrientationPatient,
                    fixtureID: fixture.id
                )
            }

            if fixture.window.present {
                XCTAssertEqual(decoder.windowSettingsV2.center, try XCTUnwrap(fixture.window.center), accuracy: 0.0001, fixture.id)
                XCTAssertEqual(decoder.windowSettingsV2.width, try XCTUnwrap(fixture.window.width), accuracy: 0.0001, fixture.id)
            } else {
                XCTAssertTrue(trim(decoder.info(for: .windowCenter)).isEmpty, fixture.id)
                XCTAssertTrue(trim(decoder.info(for: .windowWidth)).isEmpty, fixture.id)
            }

            if fixture.rescale.present {
                XCTAssertEqual(decoder.rescaleParametersV2.slope, try XCTUnwrap(fixture.rescale.slope), accuracy: 0.0001, fixture.id)
                XCTAssertEqual(
                    decoder.rescaleParametersV2.intercept,
                    try XCTUnwrap(fixture.rescale.intercept),
                    accuracy: 0.0001,
                    fixture.id
                )
            } else {
                XCTAssertNil(decoder.doubleValue(for: .rescaleSlope), fixture.id)
                XCTAssertNil(decoder.doubleValue(for: .rescaleIntercept), fixture.id)
            }
        }
    }

    func testDecoderParityMTKValidationFixturesExposeGeometryWindowAndRescaleInputs() throws {
        let parity = try loadManifest().decoderParity
        let fixturesByID = Dictionary(uniqueKeysWithValues: parity.fixtures.map { ($0.id, $0) })

        XCTAssertFalse(parity.mtkValidation.eligibleFixtureIDs.isEmpty)
        for fixtureID in parity.mtkValidation.eligibleFixtureIDs {
            let fixture = try XCTUnwrap(fixturesByID[fixtureID], "Missing MTK validation fixture row: \(fixtureID)")
            XCTAssertEqual(fixture.geometry.imagePositionPatient.count, 3, fixtureID)
            XCTAssertEqual(fixture.geometry.imageOrientationPatient.count, 6, fixtureID)
            XCTAssertEqual(fixture.geometry.pixelSpacing.count, 2, fixtureID)
            XCTAssertTrue(fixture.rescale.present, fixtureID)
            if fixture.window.present {
                XCTAssertNotNil(fixture.window.center, fixtureID)
                XCTAssertNotNil(fixture.window.width, fixtureID)
            }
        }
    }

    private func loadManifest() throws -> ClinicalParityFixtureManifest {
        let manifestURL = repoRoot().appendingPathComponent("Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json")
        return try JSONDecoder().decode(
            ClinicalParityFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }

    private func assertRepoPathExists(_ path: String, featureID: String) {
        let url = repoRoot().appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Missing manifest path for \(featureID): \(path)")
    }

    private func assertVector(
        _ rawValue: String,
        equals expected: [Double],
        fixtureID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = rawValue
            .split(separator: "\\")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        assertValues(actual, equals: expected, fixtureID: fixtureID, file: file, line: line)
    }

    private func assertValues(
        _ actual: [Double],
        equals expected: [Double],
        fixtureID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, fixtureID, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: 0.0001, fixtureID, file: file, line: line)
        }
    }

    private func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    private func optionalTrim(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = trim(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ClinicalParityFixtureManifest: Decodable {
    var version: Int
    var policy: ClinicalParityFixtureManifestPolicy
    var decoderParity: DecoderParityFixtureManifest
    var features: [ClinicalParityFixtureManifestFeature]
}

private struct ClinicalParityFixtureManifestPolicy: Decodable {
    var storage: String
    var privacy: String
    var ci: String
}

private struct ClinicalParityFixtureManifestFeature: Decodable {
    var id: String
    var label: String
    var issues: [String]
    var goldens: [String]
    var representation: String
    var artifact: String
    var synthesis: String
    var tests: [String]
    var ci: String
}

private struct DecoderParityFixtureManifest: Decodable {
    var issue: String
    var description: String
    var manifestRoot: String
    var mtkValidation: DecoderParityMTKValidation
    var fixtures: [DecoderParityFixture]
}

private struct DecoderParityMTKValidation: Decodable {
    var eligibleFixtureIDs: [String]
}

private struct DecoderParityFixture: Decodable {
    var id: String
    var path: String
    var coverage: [String]
    var sopClassUID: String
    var transferSyntaxUID: String
    var transferSyntaxName: String
    var modality: String
    var specificCharacterSet: String
    var specificCharacterSetPresent: Bool
    var expectedUIDs: DecoderParityFixtureUIDs
    var text: DecoderParityFixtureText
    var dates: DecoderParityFixtureDates
    var counts: DecoderParityFixtureCounts
    var instance: DecoderParityFixtureInstance
    var dimensions: DecoderParityFixtureDimensions
    var geometry: DecoderParityFixtureGeometry
    var window: DecoderParityFixtureWindow
    var rescale: DecoderParityFixtureRescale
    var pixel: DecoderParityFixturePixel
    var status: DecoderParityFixtureStatus
}

private struct DecoderParityFixtureUIDs: Decodable {
    var studyInstanceUID: String
    var seriesInstanceUID: String
    var sopInstanceUID: String
    var frameOfReferenceUID: String?
}

private struct DecoderParityFixtureText: Decodable {
    var patientName: String
    var patientID: String
    var studyDescription: String?
    var seriesDescription: String?
    var accessionNumber: String?
    var institutionName: String?
    var referringPhysicianName: String?
    var bodyPartExamined: String?
    var protocolName: String?
    var patientBirthDate: String?
    var patientSex: String?
    var patientAge: String?
}

private struct DecoderParityFixtureDates: Decodable {
    var studyDate: String?
    var studyTime: String?
    var seriesDate: String?
    var seriesTime: String?
    var acquisitionDate: String?
    var acquisitionTime: String?
}

private struct DecoderParityFixtureCounts: Decodable {
    var numberOfStudyRelatedSeries: Int?
    var numberOfStudyRelatedInstances: Int?
    var numberOfSeriesRelatedInstances: Int?
}

private struct DecoderParityFixtureInstance: Decodable {
    var seriesNumber: Int?
    var acquisitionNumber: Int?
    var instanceNumber: Int?
}

private struct DecoderParityFixtureDimensions: Decodable {
    var rows: Int
    var columns: Int
    var frames: Int
}

private struct DecoderParityFixtureGeometry: Decodable {
    var pixelSpacing: [Double]
    var imagePositionPatient: [Double]
    var imageOrientationPatient: [Double]
    var sliceThickness: Double
}

private struct DecoderParityFixtureWindow: Decodable {
    var present: Bool
    var center: Double?
    var width: Double?
}

private struct DecoderParityFixtureRescale: Decodable {
    var present: Bool
    var slope: Double?
    var intercept: Double?
    var type: String?
}

private struct DecoderParityFixturePixel: Decodable {
    var pixelRepresentation: Int
    var samplesPerPixel: Int
    var photometricInterpretation: String
    var bitsAllocated: Int
    var bitsStored: Int
    var highBit: Int
    var smallestImagePixelValue: Int?
    var largestImagePixelValue: Int?
}

private struct DecoderParityFixtureStatus: Decodable {
    var multiframe: Bool
    var compressed: Bool
}
