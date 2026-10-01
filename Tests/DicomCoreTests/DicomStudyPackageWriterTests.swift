import XCTest
import ZIPFoundation
@testable import DicomCore

class StudyPackageTestCase: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func source(_ name: String = "SOURCE", instance: Int = 1, series: Int = 1) throws -> URL {
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: UInt8(instance), count: 12)),
            options: .init(sopInstanceUID: "2.25.2357\(instance)", studyInstanceUID: "2.25.23570",
                           seriesInstanceUID: "2.25.23570\(series)", patientName: "Test^Package", patientID: "TEST",
                           seriesNumber: series, instanceNumber: instance), requiredType2Attributes: .init())
        let url = root.appendingPathComponent(name)
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: url)
        return url
    }
    func entry(_ path: String, data: Data, count: Int64? = nil) -> DicomStudyPackageManifest.Entry {
        .init(relativePath: path, role: .other, byteCount: count ?? Int64(data.count), sha256: DicomStudyPackageManifest.digest(data))
    }
    func manifest(_ entries: [DicomStudyPackageManifest.Entry]) -> DicomStudyPackageManifest {
        .init(producer: "tests", studies: [], entries: entries,
              totals: .init(entryCount: entries.count, byteCount: entries.reduce(0) { $0 + $1.byteCount }))
    }
    func zip(_ manifest: DicomStudyPackageManifest, payloads: [(String, Data)], first: Bool = true,
             symlink: String? = nil, compression: CompressionMethod = .none) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: path == symlink ? .symlink : .file, uncompressedSize: Int64(data.count), compressionMethod: compression) {
                offset, count in data.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        if first { try add("manifest.json", manifest.encode()) }
        for (path, data) in payloads { try add(path, data) }
        if !first { try add("manifest.json", manifest.encode()) }
        return url
    }
    func assertError<T>(_ expected: DicomStudyPackageError, _ body: () throws -> T,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? DicomStudyPackageError, expected, file: file, line: line) }
    }
}

final class DicomStudyPackageWriterTests: StudyPackageTestCase {
    func test_roundTrip_preservesThreeOriginalsAndDICOMDIR() throws {
        let sources = try (1...3).map { try source("SRC\($0)", instance: $0, series: $0 == 3 ? 2 : 1) }
        let members = sources.enumerated().map { DicomStudyPackageWriter.Member(sourceURL: $0.element, relativePath: "IMAGES/I\($0.offset)") }
        let result = try DicomStudyPackageWriter().write(members: members, to: root.appendingPathComponent("study.zip"), producer: "tests", includeDICOMDIR: true)
        let reader = try DicomStudyPackageReader(url: result.packageURL)
        XCTAssertEqual(reader.manifest, result.manifest)
        XCTAssertEqual(reader.manifest.studies.first?.series.count, 2)
        XCTAssertEqual(try reader.verify().verifiedEntries, 4)
        XCTAssertEqual(try reader.verify().status, .verified)
        for member in members { XCTAssertEqual(try reader.data(for: member.relativePath), try Data(contentsOf: member.sourceURL)) }
        let directory = try DicomDirectoryReader.read(data: reader.data(for: "DICOMDIR"))
        XCTAssertEqual(directory.patients.flatMap(\.studies).flatMap(\.series).flatMap(\.images).count, 3)
        let archive = try Archive(url: result.packageURL, accessMode: .read)
        XCTAssertEqual(Array(archive).first?.path, "manifest.json")
        XCTAssertEqual(try reader.manifest.encode(), try DicomStudyPackageManifest.decode(reader.manifest.encode()).encode())
        XCTAssertEqual(try reader.manifest.manifestSHA256.count, 64)
    }
    func test_cancellation_removesStaging() throws {
        let file = try source()
        let destination = root.appendingPathComponent("cancel.zip")
        var calls = 0
        assertError(.cancelled) {
            try DicomStudyPackageWriter().write(members: [.init(sourceURL: file, relativePath: "A"), .init(sourceURL: file, relativePath: "B")],
                to: destination, producer: "tests", includeDICOMDIR: false, isCancelled: { calls += 1; return calls >= 7 })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }
    func test_limits_rejectBeforeWriting() throws {
        let file = try source()
        for limits in [DicomArchiveLimits(maxEntries: 1), DicomArchiveLimits(maxTotalBytes: 1)] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(try DicomStudyPackageWriter(limits: limits).write(members: [.init(sourceURL: file, relativePath: "A")], to: destination, producer: "tests", includeDICOMDIR: false))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"))
        }
    }
    func test_invalidOriginalAndDICOMDIRFailure_throw() throws {
        let file = root.appendingPathComponent("bad")
        try Data([1, 2]).write(to: file)
        assertError(.unreadableMember("A")) {
            try DicomStudyPackageWriter().write(members: [.init(sourceURL: file, relativePath: "A")], to: root.appendingPathComponent("bad.zip"), producer: "tests", includeDICOMDIR: false)
        }
        let good = try source()
        XCTAssertThrowsError(try DicomStudyPackageWriter().write(members: [.init(sourceURL: good, relativePath: "bad.dcm")], to: root.appendingPathComponent("dir.zip"), producer: "tests", includeDICOMDIR: true)) {
            guard case DicomStudyPackageError.directoryBuildFailed = $0 else { return XCTFail("\($0)") }
        }
    }
}
