import XCTest
@testable import DicomCore

final class DicomStudyPackageSafetyTests: StudyPackageTestCase {
    func test_unsafePaths_rejectedByWriterAndReader() throws {
        let file = try source()
        let data = Data([1])
        for path in ["../A", "/A", "A\\B", "A//B", "A/./B", "C:/A"] {
            assertError(.invalidRelativePath(path)) {
                try DicomStudyPackageWriter().write(members: [.init(sourceURL: file, relativePath: path)], to: root.appendingPathComponent("out"), producer: "tests", includeDICOMDIR: false)
            }
            let url = try zip(manifest([entry(path, data: data)]), payloads: [(path, data)])
            assertError(.invalidRelativePath(path)) { try DicomStudyPackageReader(url: url) }
        }
    }
    func test_duplicatesAndReservedNames_rejected() throws {
        let file = try source()
        let data = Data([1])
        for path in ["manifest.json", "DICOMDIR"] {
            assertError(.reservedName(path)) {
                try DicomStudyPackageWriter().write(members: [.init(sourceURL: file, relativePath: path)], to: root.appendingPathComponent("out"), producer: "tests", includeDICOMDIR: false)
            }
            let url = try zip(manifest([entry(path, data: data)]), payloads: path == "manifest.json" ? [] : [(path, data)])
            assertError(.reservedName(path)) { try DicomStudyPackageReader(url: url) }
        }
        assertError(.duplicateRelativePath("a")) {
            try DicomStudyPackageWriter().write(members: [.init(sourceURL: file, relativePath: "A"), .init(sourceURL: file, relativePath: "a")], to: root.appendingPathComponent("out"), producer: "tests", includeDICOMDIR: false)
        }
        let url = try zip(manifest([entry("A", data: data), entry("A", data: data)]), payloads: [("A", data)])
        assertError(.duplicateRelativePath("A")) { try DicomStudyPackageReader(url: url) }
    }
    func test_symlink_rejectedAtOpen() throws {
        let data = Data("/tmp".utf8)
        let url = try zip(manifest([entry("LINK", data: data)]), payloads: [("LINK", data)], symlink: "LINK")
        assertError(.symlinkEntry("LINK")) { try DicomStudyPackageReader(url: url) }
    }
    func test_extract_existingAndEscapeRefusedAndFailureRollsBack() throws {
        let data = Data([1])
        let reader = try DicomStudyPackageReader(url: zip(manifest([entry("A", data: data), entry("DIR/B", data: data)]), payloads: [("A", data), ("DIR/B", Data([2]))]))
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try reader.extract(to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("A"))
        assertError(.destinationExists) { try reader.extract(members: ["A"], to: output) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("DIR"), withDestinationURL: outside)
        assertError(.invalidRelativePath("DIR/B")) { try reader.extract(members: ["DIR/B"], to: output) }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("A")), data)
        XCTAssertEqual(try reader.extract(members: ["A"], to: root.appendingPathComponent("selected")).count, 1)
    }
}
