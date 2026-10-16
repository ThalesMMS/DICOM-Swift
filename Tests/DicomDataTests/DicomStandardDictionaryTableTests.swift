import Foundation
import XCTest
@testable import DicomData

final class DicomStandardDictionaryTableTests: XCTestCase {
    private struct Archive: Decodable {
        let schemaVersion: Int
        let dicomEdition: String
        let definitions: [String: DicomDictionaryDefinition]
    }

    /// The JSON stays the reviewed source; the compiled table read at runtime must carry exactly its definitions.
    func test_generatedTable_matchesDefinitionsJSON() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/DicomData/Resources/DCMDictionary-Definitions.json")
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        XCTAssertEqual(archive.schemaVersion, 1)
        XCTAssertEqual(DicomStandardDictionaryTable.edition, archive.dicomEdition)

        let entries = DicomStandardDictionaryTable.entries
        XCTAssertEqual(entries.map(\.key), archive.definitions.keys.sorted())
        for entry in entries {
            let definition = DicomDictionaryDefinition(standardVRs: entry.vrs, multiplicity: entry.vm, name: entry.name,
                                                       keyword: entry.keyword, retired: entry.retired)
            XCTAssertTrue(definition.isValid, entry.key)
            XCTAssertEqual(definition, archive.definitions[entry.key], entry.key)
        }
    }

    /// `DCMDictionary.value(forTag:)` and `vrCode(forTag:)` read the compiled definitions instead of the bundled name
    /// plists (#3041); that is only equivalent while every bundled name equals the legacy VR and name of a definition,
    /// fixed or repeating-group.
    func test_bundledNames_equalTheCompiledDefinitions() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/DicomData/Resources")
        let dictionary = DCMDictionary()
        var checked = 0
        for name in ["DCMDictionary-Core", "DCMDictionary-Imaging", "DCMDictionary-RTAndSpecial"] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(name).plist"))
            let names = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for (key, value) in names {
                let tag = try XCTUnwrap(Int(key, radix: 16), key)
                let definition = DicomStandardDictionary.shared.definition(for: tag)
                XCTAssertNotNil(definition, "\(name) \(key) has no standard definition")
                XCTAssertEqual(definition.map { $0.legacyVR.code + $0.name }, value, "\(name) \(key)")
                XCTAssertEqual(dictionary.value(forTag: tag), value, "\(name) \(key)")
                XCTAssertEqual(dictionary.value(forKey: key), value, "\(name) \(key)")
                XCTAssertEqual(dictionary.vrCode(forTag: tag), String(value.prefix(2)), "\(name) \(key)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5000)
    }
}
