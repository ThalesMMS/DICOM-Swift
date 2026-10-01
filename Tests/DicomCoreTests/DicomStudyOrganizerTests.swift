import Foundation
import XCTest
@testable import DicomCore

final class DicomStudyOrganizerTests: XCTestCase {
    func test_decodedPlan_rejectsDestinationEscapesBeforeCopyOrMove() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let root = directory.appendingPathComponent("output")
        let outside = directory.appendingPathComponent("output-other")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let original = Data("source must survive a rejected plan".utf8)
        for mode in [DicomStudyOrganizer.Mode.copy, .move] {
            for destination in [outside.appendingPathComponent("direct.dcm"),
                                root.appendingPathComponent("../output-other/traversal.dcm"),
                                root.appendingPathComponent("link/new/symlink.dcm")] {
                let source = directory.appendingPathComponent("source.dcm")
                try original.write(to: source)
                let plan = DicomStudyOrganizerPlan(root: root.path, entries: [
                    .init(source: source.path, destination: destination.path, studyInstanceUID: nil,
                          seriesInstanceUID: nil, sopInstanceUID: nil, skipReason: nil)
                ])
                let decoded = try JSONDecoder().decode(DicomStudyOrganizerPlan.self, from: JSONEncoder().encode(plan))
                let result = DicomStudyOrganizer.apply(decoded, mode: mode)
                XCTAssertTrue(result.applied.isEmpty)
                XCTAssertEqual(result.failures.count, 1)
                XCTAssertFalse(fm.fileExists(atPath: destination.path))
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func test_generatedPlan_importsAnExplicitSourceOutsideDestinationRoot() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.dcm")
        let bytes = try CLIParityLibraryTests.part10(CLIParityLibraryTests.gray16())
        try bytes.write(to: source)
        let root = directory.appendingPathComponent("output")
        let plan = await DicomStudyOrganizer.plan(files: [source], into: root)
        let result = DicomStudyOrganizer.apply(plan, mode: .copy)
        XCTAssertEqual(result.applied.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let destination = try XCTUnwrap(result.applied.first?.destination)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
}
