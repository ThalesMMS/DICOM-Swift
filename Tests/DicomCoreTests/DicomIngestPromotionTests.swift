import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestPromotionTests: XCTestCase {
    func test_metadataPreview_neverReadsPixelValueRanges() async throws {
        let data = try ingestBytes()
        let source = DicomByteSource(data: data)
        let metadata = try await DicomIngestMetadata.read(from: source)
        let metrics = await source.metrics
        await source.close()
        XCTAssertEqual(metadata.studyInstanceUID, "2.25.2356002")
        XCTAssertEqual(metadata.attributes[0x00100010], "SYNTHETIC^INGEST")
        let pixelValue = (data.count - 2)..<data.count
        XCTAssertFalse(metrics.ranges.contains { $0.overlaps(pixelValue) })
        XCTAssertNil(metadata.dataSet.element(for: 0x7FE00010))
    }

    func test_promote_twiceRestoresBytesAndExactlyOneCanonicalReceipt() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let original = try ingestBytes()
        let changed = try ingestBytes(pixel: 2)
        let first = try await fixture.coordinator.ingest(part10Data: original).record
        let second = try await fixture.coordinator.ingest(part10Data: changed).record
        let promoted = try await fixture.coordinator.promoteConflict(at: second.path, replacing: first.path)
        XCTAssertEqual(promoted.durability, .publishedAndRegistered)
        try assertIngestObject(promoted.record, bytes: changed)
        XCTAssertEqual(try Data(contentsOf: second.path), original)
        let records = try await fixture.registrar.records()
        XCTAssertEqual(records.filter { !$0.isConflict }.count, 1)
        let restored = try await fixture.coordinator.promoteConflict(at: second.path, replacing: first.path)
        try assertIngestObject(restored.record, bytes: original)
        XCTAssertEqual(try Data(contentsOf: second.path), changed)
        let reopened = try IngestFixture(root: fixture.root)
        let reopenedRecords = try await reopened.registrar.records()
        XCTAssertEqual(reopenedRecords, [first, second])
        let duplicate = try await reopened.coordinator.ingest(part10Data: original)
        XCTAssertEqual(duplicate.record.path, first.path)
        XCTAssertFalse(duplicate.record.isConflict)
    }

    func test_promotion_withAliasedFilePaths_matchesExistingReceipts() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let original = try ingestBytes()
        let changed = try ingestBytes(pixel: 2)
        let first = try await fixture.coordinator.ingest(part10Data: original).record
        let second = try await fixture.coordinator.ingest(part10Data: changed).record
        let alias = fixture.root.appendingPathComponent("archive-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let promoted = try await fixture.coordinator.promoteConflict(
            at: alias.appendingPathComponent(".conflicts").appendingPathComponent(second.path.lastPathComponent),
            replacing: alias.appendingPathComponent(first.path.lastPathComponent))
        XCTAssertEqual(promoted.record.path, first.path)
        try assertIngestObject(promoted.record, bytes: changed)
        XCTAssertEqual(try Data(contentsOf: second.path), original)
    }

    func test_exchangeCrashBeforeAndAfter_keepsCanonicalReadableAndReplayIsIdempotent() async throws {
        for fault in [DicomFaultInjectingFileSystem.Fault.crashBefore, .crashAfter] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let first = try await fixture.coordinator.ingest(part10Data: ingestBytes()).record
            let second = try await fixture.coordinator.ingest(part10Data: ingestBytes(pixel: 2)).record
            let fs = DicomFaultInjectingFileSystem(operation: .exchange, fault: fault)
            let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                                                    journal: fixture.journal, registrar: fixture.registrar)
            do {
                _ = try await coordinator.promoteConflict(at: second.path, replacing: first.path)
                XCTFail("Expected injected crash")
            } catch is DicomIngestCrash { }
            let bytes = try Data(contentsOf: first.path)
            let original = try ingestBytes()
            let changed = try ingestBytes(pixel: 2)
            XCTAssertTrue(bytes == original || bytes == changed)
            for _ in 0..<2 {
                let report = try await DicomIngestRecovery.replay(journal: fixture.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .failed || $0.outcome == .loss })
                XCTAssertEqual(try Data(contentsOf: first.path), try ingestBytes(pixel: 2))
                XCTAssertEqual(try Data(contentsOf: second.path), try ingestBytes())
            }
        }
    }

    func test_journalCrashAtEveryPromotionCheckpoint_preservesBothVersions() async throws {
        for checkpoint in 1...4 {
            for after in [false, true] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let first = try await fixture.coordinator.ingest(part10Data: ingestBytes()).record
                let second = try await fixture.coordinator.ingest(part10Data: ingestBytes(pixel: 2)).record
                let journal = IngestFaultJournal(base: fixture.journal, nth: checkpoint, after: after)
                let coordinator = DicomIngestCoordinator(root: fixture.root, journal: journal, registrar: fixture.registrar)
                do {
                    _ = try await coordinator.promoteConflict(at: second.path, replacing: first.path)
                    XCTFail("Expected injected crash")
                } catch is DicomIngestCrash { }
                XCTAssertTrue(FileManager.default.fileExists(atPath: first.path.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: second.path.path))
                let report = try await DicomIngestRecovery.replay(journal: fixture.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .failed || $0.outcome == .loss })
                let contents = try [Data(contentsOf: first.path), Data(contentsOf: second.path)]
                XCTAssertEqual(Set(contents), Set([try ingestBytes(), try ingestBytes(pixel: 2)]))
            }
        }
    }

    func test_promotionRetention_protectsNewlyDemotedOldestFile() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let first = try await fixture.coordinator.ingest(part10Data: ingestBytes()).record
        let second = try await fixture.coordinator.ingest(part10Data: ingestBytes(pixel: 2)).record
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: first.path.path)
        let disposable = second.path.deletingLastPathComponent().appendingPathComponent("later.dcm")
        try Data().write(to: disposable)
        let handle = try FileHandle(forWritingTo: disposable)
        try handle.truncate(atOffset: UInt64(DicomConflictRetention.maximumBytes))
        try handle.close()
        _ = try await fixture.coordinator.promoteConflict(at: second.path, replacing: first.path)
        XCTAssertEqual(try Data(contentsOf: second.path), try ingestBytes())
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))
    }

    func test_concurrentReader_alwaysOpensOneCompleteCanonicalObject() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let old = try ingestBytes()
        let new = try ingestBytes(pixel: 2)
        let first = try await fixture.coordinator.ingest(part10Data: old).record
        let second = try await fixture.coordinator.ingest(part10Data: new).record
        let reader = Task.detached {
            for _ in 0..<2_000 {
                let data = try Data(contentsOf: first.path)
                guard data == old || data == new else { throw DicomIngestError.contentChanged }
                await Task.yield()
            }
        }
        for _ in 0..<6 { _ = try await fixture.coordinator.promoteConflict(at: second.path, replacing: first.path) }
        try await reader.value
    }
}
