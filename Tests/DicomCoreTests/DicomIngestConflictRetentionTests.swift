import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestConflictRetentionTests: XCTestCase {
    func test_overBudget_removesOldestByCreationAndPreservesIncoming() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let directory = fixture.root.appendingPathComponent(".conflicts")
        let oldest = try sparseFile(in: directory, name: "z-oldest.dcm", bytes: 300 * 1024 * 1024, created: 1000)
        let newer = try sparseFile(in: directory, name: "a-newer.dcm", bytes: 300 * 1024 * 1024, created: 2000)
        let incoming = try sparseFile(in: directory, name: "incoming.dcm", bytes: 4, created: 500)
        // Issue #2530: opposite mtime/name order proves eviction follows creation time, with incoming exempt.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3000)],
                                             ofItemAtPath: newer.path)
        DicomConflictRetention.enforce(in: directory, preserving: [incoming])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try totalBytes(directory), 300 * 1024 * 1024 + 4)
        XCTAssertLessThanOrEqual(try totalBytes(directory), DicomConflictRetention.maximumBytes)
    }

    func test_multipleEvictions_stopAtBudgetAndKeepNewestOldFile() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let directory = fixture.root.appendingPathComponent(".conflicts")
        let first = try sparseFile(in: directory, name: "first.dcm", bytes: 200 * 1024 * 1024, created: 1000)
        let second = try sparseFile(in: directory, name: "second.dcm", bytes: 200 * 1024 * 1024, created: 2000)
        let third = try sparseFile(in: directory, name: "third.dcm", bytes: 200 * 1024 * 1024, created: 3000)
        let incoming = try sparseFile(in: directory, name: "incoming.dcm", bytes: 300 * 1024 * 1024, created: 4000)
        DicomConflictRetention.enforce(in: directory, preserving: [incoming])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try totalBytes(directory), 500 * 1024 * 1024)
    }

    func test_exactBudget_doesNotEvict() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let directory = fixture.root.appendingPathComponent(".conflicts")
        let old = try sparseFile(in: directory, name: "old.dcm",
                                 bytes: DicomConflictRetention.maximumBytes - 4, created: 1000)
        let incoming = try sparseFile(in: directory, name: "incoming.dcm", bytes: 4, created: 2000)
        DicomConflictRetention.enforce(in: directory, preserving: [incoming])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try totalBytes(directory), DicomConflictRetention.maximumBytes)
    }

    func test_oversizedIncoming_survivesAndOlderFilesAreRemoved() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let directory = fixture.root.appendingPathComponent(".conflicts")
        let old = try sparseFile(in: directory, name: "old.dcm", bytes: 4, created: 1000)
        let incoming = try sparseFile(in: directory, name: "incoming.dcm",
                                      bytes: DicomConflictRetention.maximumBytes + 1, created: 500)
        DicomConflictRetention.enforce(in: directory, preserving: [incoming])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try totalBytes(directory), DicomConflictRetention.maximumBytes + 1)
    }

    func test_ingest_evictionKeepsIntegrityInventoryConsistentAndAllowsResend() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let original = try await fixture.coordinator.ingest(part10Data: ingestBytes())
        let oldBytes = try ingestBytes(pixel: 2)
        let old = try await fixture.coordinator.ingest(part10Data: oldBytes)
        // Issue #2530: sparse extension exercises the real budget without allocating half a GiB in a test.
        try extend(old.record.path, to: DicomConflictRetention.maximumBytes)
        let incomingBytes = try ingestBytes(pixel: 3)
        let incoming = try await fixture.coordinator.ingest(part10Data: incomingBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.record.path.path))
        XCTAssertTrue(incoming.record.isConflict)
        try assertIngestObject(incoming.record, bytes: incomingBytes)
        try assertIngestObject(original.record, bytes: ingestBytes())
        XCTAssertLessThanOrEqual(try totalBytes(incoming.record.path.deletingLastPathComponent()),
                                 DicomConflictRetention.maximumBytes)
        let reopened = try DicomJSONLIngestRegistrar(path: fixture.root.appendingPathComponent(".ingest/registry.jsonl"))
        let records = try await reopened.records()
        XCTAssertEqual(Set(records.map(\.path)), [original.record.path, incoming.record.path])
        let integrity = records.map {
            DicomArchiveIntegrityRecord(path: $0.path, recordedSHA256: $0.contentSHA256, sopUID: $0.sopInstanceUID)
        }
        let fs = DicomLocalIngestFileSystem()
        XCTAssertTrue(DicomArchiveIntegrityScanner.verify(records: integrity, fileSystem: fs).isEmpty)
        let inventory = try fs.contentsOf(incoming.record.path.deletingLastPathComponent())
        let canonical = integrity.filter { $0.path == original.record.path }
        let findings = DicomArchiveIntegrityScanner.verify(records: canonical, inventory: inventory, fileSystem: fs)
        XCTAssertEqual(findings.map(\.kind), [.conflictFile])
        XCTAssertEqual(findings.map { $0.path.standardizedFileURL }, [incoming.record.path.standardizedFileURL])
        let orphans = DicomArchiveOrphanClassifier.classify(files: inventory, records: canonical)
        XCTAssertEqual(orphans.map(\.kind), [.conflict])
        XCTAssertEqual(orphans.map(\.action), [.preserveConflict])
        let replay = try await DicomIngestRecovery.replay(journal: fixture.journal, fileSystem: fs, registrar: reopened)
        XCTAssertTrue(replay.items.allSatisfy { $0.outcome == .complete })
        let resent = try await DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
                                                     registrar: reopened).ingest(part10Data: oldBytes)
        XCTAssertTrue(resent.record.isConflict)
        try assertIngestObject(resent.record, bytes: oldBytes)
    }

    func test_ingest_cleanupFailureStillReturnsStoredConflict() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        _ = try await fixture.coordinator.ingest(part10Data: ingestBytes())
        let old = try sparseFile(in: fixture.root.appendingPathComponent(".conflicts"), name: "old.dcm",
                                 bytes: DicomConflictRetention.maximumBytes, created: 1000)
        let fs = DicomFaultInjectingFileSystem(operation: .remove, fault: .fail(EACCES))
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                                                journal: fixture.journal, registrar: fixture.registrar)
        let bytes = try ingestBytes(pixel: 2)
        let result = try await coordinator.ingest(part10Data: bytes)
        XCTAssertTrue(result.record.isConflict)
        XCTAssertEqual(result.classification.representationConflict, .conflictingContent)
        XCTAssertEqual(result.durability, .publishedAndRegistered)
        try assertIngestObject(result.record, bytes: bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func test_memoryRegistrar_evictedConflictCanBeStoredAgain() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let registrar = DicomInMemoryIngestRegistrar()
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: registrar)
        _ = try await coordinator.ingest(part10Data: ingestBytes())
        let oldBytes = try ingestBytes(pixel: 2)
        let old = try await coordinator.ingest(part10Data: oldBytes)
        try extend(old.record.path, to: DicomConflictRetention.maximumBytes)
        _ = try await coordinator.ingest(part10Data: ingestBytes(pixel: 3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.record.path.path))
        let records = await registrar.records()
        XCTAssertFalse(records.contains { $0.path == old.record.path })
        let resent = try await coordinator.ingest(part10Data: oldBytes)
        XCTAssertTrue(resent.record.isConflict)
        try assertIngestObject(resent.record, bytes: oldBytes)
    }

    func test_batch_conflictsApplyRetentionAndSurviveTogether() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        _ = try await fixture.coordinator.ingest(part10Data: ingestBytes())
        let directory = fixture.root.appendingPathComponent(".conflicts")
        let old = try sparseFile(in: directory, name: "old.dcm",
                                 bytes: DicomConflictRetention.maximumBytes, created: 1000)
        let bytes = try [ingestBytes(pixel: 2), ingestBytes(pixel: 3)]
        let results = try await fixture.coordinator.ingest(part10Batch: bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for (index, result) in results.enumerated() {
            let stored = try result.get()
            XCTAssertTrue(stored.record.isConflict)
            try assertIngestObject(stored.record, bytes: bytes[index])
        }
        XCTAssertEqual(try totalBytes(directory), Int64(bytes.reduce(0) { $0 + $1.count }))
    }

    private func sparseFile(in directory: URL, name: String, bytes: Int64, created: TimeInterval) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try Data().write(to: path)
        try extend(path, to: bytes)
        let date = Date(timeIntervalSince1970: created)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.creationDate] as? Date, date)
        return path
    }

    private func extend(_ path: URL, to bytes: Int64) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    private func totalBytes(_ directory: URL) throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).reduce(0) {
            $0 + (try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as! NSNumber).int64Value
        }
    }
}
