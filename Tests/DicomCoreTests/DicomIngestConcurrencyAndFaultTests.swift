import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestConcurrencyAndFaultTests: XCTestCase {
    func test_twoCoordinatorsSameUID_serializeAndKeepBothContents() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let a = fixture.coordinator
        let b = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: fixture.registrar)
        let first = try ingestBytes(pixel: 1), second = try ingestBytes(pixel: 2)
        async let x = a.ingest(part10Data: first)
        async let y = b.ingest(part10Data: second)
        let results = try await [x, y]
        XCTAssertEqual(Set(results.map { $0.record.path }).count, 2)
        XCTAssertEqual(results.filter { $0.record.isConflict }.count, 1)
        try assertIngestObject(results[0].record, bytes: first)
        try assertIngestObject(results[1].record, bytes: second)
    }

    func test_concurrentIdenticalBytes_discardOnlyVerifiedDuplicate() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let bytes = try ingestBytes()
        async let a = fixture.coordinator.ingest(part10Data: bytes)
        async let b = fixture.coordinator.ingest(part10Data: bytes)
        let results = try await [a, b]
        XCTAssertEqual(results[0].record.path, results[1].record.path)
        let records = try await fixture.registrar.records()
        XCTAssertEqual(records.count, 1)
        for record in records { try assertIngestObject(record, bytes: bytes) }
    }

    func test_concurrentIngestWithRenameFailure_doesNotOverwriteWinner() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let fs = DicomFaultInjectingFileSystem(operation: .rename, fault: .fail(EIO))
        let bad = DicomIngestCoordinator(root: fixture.root, fileSystem: fs, journal: fixture.journal, registrar: fixture.registrar)
        let bytes = try ingestBytes()
        async let failed: Void = expectIngestFailure(bad, bytes: bytes)
        async let good = fixture.coordinator.ingest(part10Data: ingestBytes(pixel: 3))
        let (_, result) = try await (failed, good)
        try assertIngestObject(result.record, bytes: ingestBytes(pixel: 3))
        _ = try await DicomIngestRecovery.replay(journal: fixture.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: fixture.registrar)
        try assertIngestObject(result.record, bytes: ingestBytes(pixel: 3))
    }

    func test_filesystemCrashBeforeAndAfterStageEffects_restartsWithoutPartialPublication() async throws {
        let boundaries: [(DicomFaultInjectingFileSystem.Operation, Int)] = [
            (.createDirectory, 1), (.createDirectory, 2), (.write, 1), (.fsyncFile, 1),
            (.fsyncDirectory, 1), (.fsyncDirectory, 2), (.fsyncDirectory, 3),
            (.read, 1), (.read, 2), (.rename, 1),
            (.fsyncDirectory, 4), (.fsyncDirectory, 5), (.fsyncDirectory, 6)
        ]
        for (kind, nth) in boundaries {
            for fault in [DicomFaultInjectingFileSystem.Fault.crashBefore, .crashAfter] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let fs = DicomFaultInjectingFileSystem(operation: kind, nth: nth, fault: fault)
                let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                    journal: fixture.journal, registrar: fixture.registrar)
                let bytes = try ingestBytes()
                do { _ = try await coordinator.ingest(part10Data: bytes); XCTFail("Missing fault \(kind) \(nth)") }
                catch is DicomIngestCrash {}
                let restarted = try IngestFixture(root: fixture.root)
                let report = try await DicomIngestRecovery.replay(journal: restarted.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .loss || $0.outcome == .failed }, "\(kind) \(nth)")
                for record in try await restarted.registrar.records() { try assertIngestObject(record, bytes: bytes) }
                for path in try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                    where path.pathExtension == "dcm" {
                    XCTAssertEqual(try Data(contentsOf: path), bytes)
                    _ = try DicomStoreRequest(part10FileAt: path)
                }
            }
        }
    }

    func test_writeSyncRenameJournalAndRegisterFailures_doNotReportSuccess() async throws {
        for kind in [DicomFaultInjectingFileSystem.Operation.write, .fsyncFile, .rename, .fsyncDirectory] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let fs = DicomFaultInjectingFileSystem(operation: kind, fault: .fail(EIO))
            let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                journal: fixture.journal, registrar: fixture.registrar)
            await expectIngestFailure(coordinator, bytes: try ingestBytes())
        }
        for nth in 1...12 {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            let journal = IngestFaultJournal(base: fixture.journal, nth: nth, after: false, crash: false)
            let coordinator = DicomIngestCoordinator(root: fixture.root, journal: journal, registrar: fixture.registrar)
            await expectIngestFailure(coordinator, bytes: try ingestBytes())
        }
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: IngestFaultRegistrar(base: fixture.registrar))
        await expectIngestFailure(coordinator, bytes: try ingestBytes())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("2.25.2356001.dcm").path))
        let quarantined = try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent(".quarantine"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantined.first)), try ingestBytes())
    }

    func test_diskFullAndPermissionDenied_areTypedAndNeverPublish() async throws {
        for code in [ENOSPC, EACCES] {
            for kind in [DicomFaultInjectingFileSystem.Operation.write, .fsyncFile, .rename] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let fs = DicomFaultInjectingFileSystem(operation: kind, fault: .fail(code))
                let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                    journal: fixture.journal, registrar: fixture.registrar)
                do { _ = try await coordinator.ingest(part10Data: ingestBytes()); XCTFail("Expected typed failure") }
                catch let error as DicomIngestError {
                    if code == ENOSPC { XCTAssertEqual(error.storageStatus, 0xA700) }
                    else {
                        guard case .permissionDenied = error else { return XCTFail("\(error)") }
                        XCTAssertEqual(error.storageStatus, 0xC000)
                    }
                }
                let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                XCTAssertFalse(files.contains { $0.pathExtension == "dcm" })
            }
        }
    }

    func test_capacityDenial_precedesStaging() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: fixture.registrar, capacity: IngestNoCapacity())
        await expectIngestFailure(coordinator, bytes: try ingestBytes())
        let entries = try await fixture.journal.entries()
        XCTAssertEqual(entries.last?.stage, .validated)
    }
}

private struct IngestNoCapacity: DicomIngestDiskCapacityChecking {
    func checkCapacity(required: Int64, at root: URL) throws { throw DicomIngestError.diskFull(required: required, available: 0) }
}

func expectIngestFailure(_ coordinator: DicomIngestCoordinator, bytes: Data) async {
    do { _ = try await coordinator.ingest(part10Data: bytes); XCTFail("Expected ingest failure") } catch {}
}
