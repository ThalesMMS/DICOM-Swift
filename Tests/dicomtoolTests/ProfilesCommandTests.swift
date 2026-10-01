import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class ProfilesCommandTests: XCTestCase {
    func test_profiles_listsTheCatalogInBothFormats() throws {
        var json = try ProfilesCommand.parse(["--format", "json"])
        XCTAssertEqual(json.format, .json)
        XCTAssertNoThrow(try json.run())
        var text = try ProfilesCommand.parse([])
        XCTAssertEqual(text.format, .text)
        XCTAssertNoThrow(try text.run())
        // The command prints through buffered stdout; flush it so XCTest's own completion line
        // starts a fresh line in serial logs (the capability-matrix runner parses those lines).
        fflush(stdout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let encoded = try encoder.encode(DicomQualifiedProfileCatalog.profiles)
        let decoded = try JSONDecoder().decode([DicomQualifiedProfile].self, from: encoded)
        XCTAssertEqual(Set(decoded.map(\.sopClassUID)), DicomInstanceValidator.qualifiedProfiles)
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == ProfilesCommand.self })
    }
}
