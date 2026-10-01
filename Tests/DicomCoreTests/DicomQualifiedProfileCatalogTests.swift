import Foundation
import XCTest
@testable import DicomCore

/// The catalog is the single source of the qualified profiles and of the generated conformance declaration.
final class DicomQualifiedProfileCatalogTests: XCTestCase {
    func test_catalog_matchesEveryCompositionHelperExactlyOnce() {
        let profiles = DicomQualifiedProfileCatalog.profiles
        XCTAssertEqual(Set(profiles.map(\.sopClassUID)), DicomQualifiedProfileCatalog.composedSOPClassUIDs)
        XCTAssertEqual(Set(profiles.map(\.sopClassUID)), DicomInstanceValidator.qualifiedProfiles)
        XCTAssertEqual(profiles.count, Set(profiles.map(\.sopClassUID)).count)
        XCTAssertEqual(profiles.count, Set(profiles.map(\.name)).count)
        XCTAssertEqual(profiles.count, 53)
        for profile in profiles {
            XCTAssertTrue(profile.sopClassUID.hasPrefix("1.2.840.10008.5.1.4.1.1."), profile.name)
            XCTAssertTrue(profile.lot.range(of: #"^L[0-9]+$"#, options: .regularExpression) != nil, profile.name)
            XCTAssertTrue(profile.coverageDocument.hasPrefix("Docs/QA/") && profile.coverageDocument.hasSuffix("ConformanceCoverage.md"), profile.name)
        }
    }

    func test_coverageDocumentsAndOraclesExistInTheRepository() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for profile in DicomQualifiedProfileCatalog.profiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(profile.coverageDocument).path), profile.coverageDocument)
            let oracle = root.appendingPathComponent("DICOM-Swift/Scripts/conformance/\(profile.oracle)_oracle.py")
            XCTAssertTrue(FileManager.default.fileExists(atPath: oracle.path), oracle.path)
        }
    }

    func test_catalog_roundTripsAsSortedJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(DicomQualifiedProfileCatalog.profiles)
        XCTAssertEqual(try JSONDecoder().decode([DicomQualifiedProfile].self, from: data), DicomQualifiedProfileCatalog.profiles)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("conformant"))
    }
}
