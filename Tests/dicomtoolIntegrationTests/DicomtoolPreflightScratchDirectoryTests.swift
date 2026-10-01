import Foundation
import XCTest

final class DicomtoolPreflightScratchDirectoryTests: XCTestCase {
    func test_init_withoutOverride_usesDefaultRoot() throws {
        let root = try makeHarnessRoot()
        let scratch = try DicomtoolPreflightScratchDirectory(
            environment: [:],
            defaultRootURL: root,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        XCTAssertEqual(scratch.url.deletingLastPathComponent(), root.standardizedFileURL)
        XCTAssertEqual(
            scratch.url.lastPathComponent,
            "dicomtool-preflight-00000000-0000-0000-0000-000000000001"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.url.path))
    }

    func test_init_withOverride_createsMissingRoot() throws {
        let harnessRoot = try makeHarnessRoot()
        let configuredRoot = harnessRoot.appendingPathComponent("configured", isDirectory: true)

        let scratch = try DicomtoolPreflightScratchDirectory(
            environment: [DicomtoolPreflightScratchDirectory.environmentKey: configuredRoot.path],
            defaultRootURL: harnessRoot
        )

        XCTAssertEqual(scratch.url.deletingLastPathComponent(), configuredRoot.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.url.path))
    }

    func test_init_createsUniqueChildren() throws {
        let root = try makeHarnessRoot()
        let environment = [DicomtoolPreflightScratchDirectory.environmentKey: root.path]

        let first = try DicomtoolPreflightScratchDirectory(
            environment: environment,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = try DicomtoolPreflightScratchDirectory(
            environment: environment,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url.deletingLastPathComponent(), root.standardizedFileURL)
        XCTAssertEqual(second.url.deletingLastPathComponent(), root.standardizedFileURL)
    }

    func test_remove_deletesOnlyOwnedChild() throws {
        let root = try makeHarnessRoot()
        let sibling = root.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let scratch = try DicomtoolPreflightScratchDirectory(
            environment: [DicomtoolPreflightScratchDirectory.environmentKey: root.path]
        )

        try scratch.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func test_init_withFileAsOverride_throwsDeterministicError() throws {
        let root = try makeHarnessRoot()
        let fileURL = root.appendingPathComponent("not-a-directory")
        try Data().write(to: fileURL)

        XCTAssertThrowsError(
            try DicomtoolPreflightScratchDirectory(
                environment: [DicomtoolPreflightScratchDirectory.environmentKey: fileURL.path]
            )
        ) { error in
            XCTAssertEqual(
                error as? DicomtoolPreflightScratchDirectory.Error,
                .cannotPrepareRoot(fileURL.standardizedFileURL.path)
            )
        }
    }

    private func makeHarnessRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let parent = environment[DicomtoolPreflightScratchDirectory.environmentKey].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = parent
            .appendingPathComponent("scratch-helper-tests-(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
