import Foundation
import XCTest
@testable import DicomCore

final class DicomArchiveIntegrityTests: XCTestCase {
    func test_syntheticArchive_reportsEveryFindingWithoutMutatingFiles() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let fs = DicomLocalIngestFileSystem()
        let bytes = try ingestBytes()
        let hash = DicomArchiveRepresentation.hash(bytes)
        var records: [DicomArchiveIntegrityRecord] = []
        for name in ["wrong", "missing", "unparseable", "identity", "valid"] {
            let path = fixture.root.appendingPathComponent("\(name).dcm")
            if name != "missing" { try (name == "unparseable" ? Data([1, 2]) : bytes).write(to: path) }
            records.append(.init(path: path, recordedSHA256: name == "wrong" ? "0000" : hash,
                                 sopUID: name == "identity" ? "2.25.999" : "2.25.2356001"))
        }
        let inventory = ["orphan.dcm", ".ingest/partial.part", ".conflicts/object.dcm"].map { fixture.root.appendingPathComponent($0) }
        for path in inventory { try fs.createDirectory(path.deletingLastPathComponent()); try bytes.write(to: path) }
        let findings = DicomArchiveIntegrityScanner.verify(records: records, inventory: inventory, fileSystem: fs)
        XCTAssertEqual(Set(findings.map(\.kind)), Set([.checksumMismatch, .missingFile, .unparseable, .identityMismatch,
                                                      .unrecordedFile, .unpublishedTemp, .conflictFile]))
        XCTAssertFalse(findings.contains { $0.path.lastPathComponent == "valid.dcm" })
        for path in inventory { XCTAssertEqual(try Data(contentsOf: path), bytes) }
        let unknown = DicomArchiveIntegrityScanner.verify(records: [.init(path: inventory[0], recordedSHA256: nil,
            sopUID: "2.25.2356001")], fileSystem: fs)
        XCTAssertEqual(unknown.map(\.kind), [.checksumMismatch])
    }

    func test_orphanPlan_neverDeletesWithoutExplicitPerFileConfirmation() throws {
        let root = URL(fileURLWithPath: "/synthetic")
        let paths = ["original.dcm", ".ingest/partial.part", ".conflicts/object.dcm"].map { root.appendingPathComponent($0) }
        let plan = DicomArchiveOrphanClassifier.classify(files: paths, records: [])
        XCTAssertFalse(plan.contains { $0.action == .deleteConfirmedDuplicate })
        XCTAssertEqual(plan.map(\.kind), [.original, .unpublishedTemp, .conflict])
        let confirmed = DicomArchiveOrphanClassifier.classify(files: paths, records: [], confirmedDuplicate: { $0 == paths[0] })
        XCTAssertEqual(confirmed.filter { $0.action == .deleteConfirmedDuplicate }.map(\.path), [paths[0]])
    }

    func test_derivativePlan_regeneratesStaleAndInvalidatesMissingSource() {
        let path = URL(fileURLWithPath: "/synthetic/derived")
        let records: [DicomDerivativeRepairPlanner.Record] = [
            .init(path: path, sourceSOPUID: "1", sourceSHA256: "old", isUsable: true),
            .init(path: path, sourceSOPUID: "2", sourceSHA256: "old", isUsable: false),
            .init(path: path, sourceSOPUID: "1", sourceSHA256: "current", isUsable: true)
        ]
        XCTAssertEqual(DicomDerivativeRepairPlanner.plan(derivatives: records, currentSources: ["1": "current"]).map(\.action),
                       [.regenerate, .invalidate])
    }
}
