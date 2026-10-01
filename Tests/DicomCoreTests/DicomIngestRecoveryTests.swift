import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestRecoveryTests: XCTestCase {
    func test_startupCleanup_removesOnlyUnfinishedReceivedFiles() throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: fixture.registrar)
        let directory = coordinator.receivedFileDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["first.received", "second.received", "retained.staged", "journal.jsonl"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        try coordinator.removeIncompleteReceives()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["retained.staged", "journal.jsonl"])
    }

    func test_journalAppend_readsOnlyTailAndPreservesTornRecordRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("journal.jsonl")
        let fs = TailOnlyFileSystem()
        try DicomIngestJSONL.append("first", path: path, fileSystem: fs)
        try fs.write(Data("{partial".utf8), to: path, append: true)
        try DicomIngestJSONL.append("second", path: path, fileSystem: fs)
        let records = try DicomIngestJSONL.read(String.self, path: path, fileSystem: DicomLocalIngestFileSystem())
        XCTAssertEqual(records, ["first", "second"])
        let empty = directory.appendingPathComponent("empty")
        try fs.write(Data(), to: empty, append: false)
        XCTAssertNil(try fs.lastByte(empty))
    }

    func test_crashBeforeAndAfterEveryJournalBoundary_replaysAndReopensBytes() async throws {
        for nth in 1...12 {
            for after in [false, true] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let bytes = try ingestBytes()
                let journal = IngestFaultJournal(base: fixture.journal, nth: nth, after: after)
                let coordinator = DicomIngestCoordinator(root: fixture.root, journal: journal, registrar: fixture.registrar)
                do { _ = try await coordinator.ingest(part10Data: bytes); XCTFail("Expected crash \(nth) \(after)") }
                catch is DicomIngestCrash {}
                let restarted = try IngestFixture(root: fixture.root)
                let report = try await DicomIngestRecovery.replay(journal: restarted.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .failed || $0.outcome == .loss }, "\(nth) \(after)")
                let records = try await restarted.registrar.records()
                let shouldRecover = nth > 6 || (nth == 6 && after)
                XCTAssertEqual(records.count, shouldRecover ? 1 : 0, "\(nth) \(after)")
                for record in records { try assertIngestObject(record, bytes: bytes) }
                _ = try await DicomIngestRecovery.replay(journal: restarted.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
                let again = try await restarted.registrar.records()
                XCTAssertEqual(again, records)
            }
        }
    }

    func test_registerCrashBeforeAndAfterCommit_isIdempotent() async throws {
        for after in [false, true] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let bytes = try ingestBytes()
            let registrar = IngestFaultRegistrar(base: fixture.registrar, after: after, crash: true)
            let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: registrar)
            do { _ = try await coordinator.ingest(part10Data: bytes); XCTFail("Expected crash") } catch is DicomIngestCrash {}
            let restarted = try IngestFixture(root: fixture.root)
            _ = try await DicomIngestRecovery.replay(journal: restarted.journal,
                fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
            let records = try await restarted.registrar.records()
            XCTAssertEqual(records.count, 1)
            for record in records { try assertIngestObject(record, bytes: bytes) }
        }
    }

    func test_partialTemporaryWrite_isDiscardedAtRestart() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let fs = DicomFaultInjectingFileSystem(operation: .write, fault: .partialWrite(160))
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs, journal: fixture.journal, registrar: fixture.registrar)
        do { _ = try await coordinator.ingest(part10Data: ingestBytes()); XCTFail("Expected crash") } catch is DicomIngestCrash {}
        let entries = try await fixture.journal.entries()
        let temp = try XCTUnwrap(entries.last?.temporaryPath)
        XCTAssertEqual(try Data(contentsOf: temp).count, 160)
        let report = try await DicomIngestRecovery.replay(journal: fixture.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
        XCTAssertEqual(report.items.first?.outcome, .discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func test_publishedMissingBothNames_reportsLoss() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let fs = DicomFaultInjectingFileSystem(operation: .rename, fault: .crashBefore)
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs, journal: fixture.journal, registrar: fixture.registrar)
        do { _ = try await coordinator.ingest(part10Data: ingestBytes()); XCTFail("Expected crash") } catch is DicomIngestCrash {}
        let entries = try await fixture.journal.entries()
        try FileManager.default.removeItem(at: XCTUnwrap(entries.last?.temporaryPath))
        let report = try await DicomIngestRecovery.replay(journal: fixture.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
        XCTAssertEqual(report.items.first?.outcome, .loss)
    }

    func test_corruptedPublishedBytes_areQuarantinedNeverRegistered() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let journal = IngestFaultJournal(base: fixture.journal, nth: 10, after: true)
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: journal, registrar: fixture.registrar)
        do { _ = try await coordinator.ingest(part10Data: ingestBytes()); XCTFail("Expected crash") } catch is DicomIngestCrash {}
        let entries = try await fixture.journal.entries()
        let path = try XCTUnwrap(entries.last?.finalPath)
        let corrupt = try ingestBytes(pixel: 9)
        try corrupt.write(to: path)
        let report = try await DicomIngestRecovery.replay(journal: fixture.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
        XCTAssertEqual(report.items.first?.outcome, .quarantined)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(report.items.first?.path)), corrupt)
        let records = try await fixture.registrar.records()
        XCTAssertTrue(records.isEmpty)
    }

    func test_tornJournalTail_doesNotHidePriorIntentAndCanResumeAppending() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let fs = DicomFaultInjectingFileSystem(operation: .rename, fault: .crashAfter)
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs, journal: fixture.journal, registrar: fixture.registrar)
        let bytes = try ingestBytes()
        do { _ = try await coordinator.ingest(part10Data: bytes); XCTFail("Expected crash") } catch is DicomIngestCrash {}
        try DicomLocalIngestFileSystem().write(Data("{\"ingestID\":".utf8),
            to: fixture.root.appendingPathComponent(".ingest/journal.jsonl"), append: true)
        let restarted = try IngestFixture(root: fixture.root)
        _ = try await DicomIngestRecovery.replay(journal: restarted.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
        for record in try await restarted.registrar.records() { try assertIngestObject(record, bytes: bytes) }
        let entries = try await restarted.journal.entries()
        XCTAssertEqual(entries.last?.stage, .registered)
    }
}

private struct TailOnlyFileSystem: DicomIngestFileSystem {
    private let base = DicomLocalIngestFileSystem()
    func createDirectory(_ path: URL) throws { try base.createDirectory(path) }
    func write(_ data: Data, to path: URL, append: Bool) throws { try base.write(data, to: path, append: append) }
    func fsyncFile(_ path: URL) throws { try base.fsyncFile(path) }
    func fsyncDirectory(_ path: URL) throws { try base.fsyncDirectory(path) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func remove(_ path: URL) throws { try base.remove(path) }
    func exists(_ path: URL) throws -> Bool { try base.exists(path) }
    func read(_ path: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func lastByte(_ path: URL) throws -> UInt8? { try base.lastByte(path) }
    func contentsOf(_ directory: URL) throws -> [URL] { try base.contentsOf(directory) }
}

extension DicomIngestRecoveryTests {
    func test_registrarQueriesReuseLoadedUIDIndex() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let result = try await fixture.coordinator.ingest(part10Data: ingestBytes())
        let fileSystem = DicomFaultInjectingFileSystem(operation: .read, nth: 2, fault: .fail(EIO))
        let registrar = try DicomJSONLIngestRegistrar(path: fixture.root.appendingPathComponent(".ingest/registry.jsonl"),
                                                     fileSystem: fileSystem)
        for _ in 0..<10 {
            let records = try await registrar.records(sopInstanceUID: result.record.sopInstanceUID)
            XCTAssertEqual(records, [result.record])
            let classification = try await registrar.classify(sopInstanceUID: result.record.sopInstanceUID,
                                                                contentSHA256: result.record.contentSHA256)
            XCTAssertEqual(classification, .duplicate(identicalContent: result.record.contentSHA256))
        }
        let missing = try await registrar.records(sopInstanceUID: "unknown")
        XCTAssertTrue(missing.isEmpty)
    }

    func test_registrarRetryAfterFailedSyncDoesNotAppendTwice() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let path = fixture.root.appendingPathComponent(".ingest/retry-registry.jsonl")
        let registrar = try DicomJSONLIngestRegistrar(path: path,
            fileSystem: DicomFaultInjectingFileSystem(operation: .fsyncFile, fault: .fail(EIO)))
        let record = DicomIngestRecord(ingestID: UUID(), sopClassUID: "1", sopInstanceUID: "2",
            transferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            path: fixture.root.appendingPathComponent("object"), contentSHA256: String(repeating: "a", count: 64))
        do { _ = try await registrar.register(record); XCTFail("Expected sync failure") } catch {}
        _ = try await registrar.register(record)
        let cached = try await registrar.records(sopInstanceUID: record.sopInstanceUID)
        let reopened = try DicomJSONLIngestRegistrar(path: path)
        let persisted = try await reopened.records()
        XCTAssertEqual(cached, [record])
        XCTAssertEqual(persisted, [record])
    }
}
