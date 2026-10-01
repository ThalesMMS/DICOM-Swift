import Foundation
import XCTest
@testable import DicomData

final class DicomDeidentificationTableLoadingTests: XCTestCase {
    func test_packagedTable_loadsThroughTheThrowingAndStandardInterfaces() throws {
        let table = try DicomDeidentificationTable.loadStandard()
        XCTAssertEqual(table.version, "2026c")
        XCTAssertEqual(table.entries.count, 655)
        XCTAssertEqual(table.safePrivateEntries.count, 479)
        XCTAssertEqual(table.entries, DicomDeidentificationTable.standard.entries)
    }

    func test_missingUnreadableAndInvalidResources_reportDistinctFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ps315-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = ["CFBundleIdentifier": "test.ps315.\(UUID().uuidString)", "CFBundleName": "PS315Test", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertThrowsError(try DicomDeidentificationTable.load(from: bundle)) { error in
            guard case DicomDeidentificationTable.LoadError.resourceNotFound = error else { return XCTFail("\(error)") }
        }
        let file = directory.appendingPathComponent("DicomDeidentificationTable.json")
        XCTAssertThrowsError(try DicomDeidentificationTable.load(at: file)) { error in
            guard case DicomDeidentificationTable.LoadError.resourceReadFailed = error else { return XCTFail("\(error)") }
        }
        try Data("{ invalid JSON".utf8).write(to: file)
        XCTAssertThrowsError(try DicomDeidentificationTable.load(at: file)) { error in
            guard case DicomDeidentificationTable.LoadError.invalidTable = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("decode failed"))
        }
    }
}
