import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class DicomIngestBatchTests: XCTestCase {
    func test_batch_publishesEveryItem_withSharedCommitsAndFlushes() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let journal = CountingJournal(base: fixture.journal)
        let fs = CountingFileSystem()
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs, journal: journal, registrar: fixture.registrar)
        let items = try (0..<20).map { try ingestBytes(uid: "2.25.5000\($0)", pixel: UInt8($0)) }
        let results = try await coordinator.ingest(part10Batch: items)
        XCTAssertEqual(results.count, items.count)
        for (index, result) in results.enumerated() {
            let ingested = try result.get()
            XCTAssertEqual(ingested.classification, .new)
            XCTAssertEqual(ingested.durability, .publishedAndRegistered)
            try assertIngestObject(ingested.record, bytes: items[index])
        }
        XCTAssertEqual(Set(results.compactMap { try? $0.get().record.path }).count, items.count)
        // Every item still carries the full stage history a lone ingest writes.
        let entries = try await fixture.journal.entries()
        for id in Set(entries.map(\.ingestID)) {
            let own = entries.filter { $0.ingestID == id }
            XCTAssertEqual(own.map(\.stage), DicomIngestStage.allCases.flatMap { [$0, $0] })
            XCTAssertEqual(own.map(\.phase), DicomIngestStage.allCases.flatMap { _ in [.intent, .done] })
        }
        let commits = await journal.batchAppends
        let singles = await journal.singleAppends
        XCTAssertEqual(commits, 6, "one commit per stage boundary for the whole batch")
        XCTAssertEqual(singles, 0)
        XCTAssertEqual(fs.synchronizeCalls.value, 2, "one flush for staging, one for publication")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".ingest").path)
            .contains { $0.hasSuffix(".part") })
    }

    func test_batch_duplicateRepeatAndConflict_matchLoneIngest() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let original = try ingestBytes(uid: "2.25.6001", pixel: 1)
        let changed = try ingestBytes(uid: "2.25.6001", pixel: 2)
        let other = try ingestBytes(uid: "2.25.6002", pixel: 3)
        let prior = try await fixture.coordinator.ingest(part10Data: other)
        let results = try await fixture.coordinator.ingest(part10Batch: [original, original, changed, other])
        let first = try results[0].get()
        XCTAssertEqual(first.classification, .new)
        try assertIngestObject(first.record, bytes: original)
        let repeated = try results[1].get()
        XCTAssertEqual(repeated.classification, .duplicate(identicalContent: first.record.contentSHA256))
        XCTAssertEqual(repeated.record.path, first.record.path)
        let conflict = try results[2].get()
        XCTAssertEqual(conflict.classification.representationConflict, .conflictingContent)
        XCTAssertTrue(conflict.record.isConflict)
        XCTAssertTrue(conflict.record.path.pathComponents.contains(".conflicts"))
        try assertIngestObject(conflict.record, bytes: changed)
        let duplicate = try results[3].get()
        XCTAssertEqual(duplicate.classification, .duplicate(identicalContent: prior.record.contentSHA256))
        XCTAssertEqual(duplicate.record.path, prior.record.path)
        let records = try await fixture.registrar.records()
        XCTAssertEqual(records.count, 3)
        try assertIngestObject(prior.record, bytes: other)
    }

    func test_batch_invalidItem_failsAloneAndNeverStages() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let good = try ingestBytes(uid: "2.25.7001")
        let results = try await fixture.coordinator.ingest(part10Batch: [good, Data("not dicom".utf8), try ingestBytes(uid: "2.25.7002")])
        XCTAssertNoThrow(try results[0].get())
        XCTAssertThrowsError(try results[1].get())
        XCTAssertNoThrow(try results[2].get())
        let records = try await fixture.registrar.records()
        XCTAssertEqual(records.count, 2)
        let entries = try await fixture.journal.entries()
        let identified = Set(entries.compactMap { $0.sopInstanceUID == nil ? nil : $0.ingestID })
        let failed = entries.filter { !identified.contains($0.ingestID) }
        XCTAssertEqual(failed.map(\.stage), [.received, .received, .validated])
        XCTAssertEqual(failed.map(\.phase), [.intent, .done, .intent])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".ingest").path)
            .contains { $0.hasSuffix(".part") })
    }

    func test_batch_expectedDigest_refusesChangedBytesAloneBeforeAnyDiskEffect() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let inspected = try ingestBytes(uid: "2.25.7101", pixel: 1)
        let changed = try ingestBytes(uid: "2.25.7101", pixel: 2)
        let other = try ingestBytes(uid: "2.25.7102")
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var timings = DicomIngestBatchTimings()
        // The second expectation is shorter than the batch on purpose: a missing entry expects nothing.
        let results = try await fixture.coordinator.ingest(
            part10Batch: [changed, other, inspected], expectedSHA256: [digest(inspected), nil], timings: &timings)
        XCTAssertThrowsError(try results[0].get()) { XCTAssertEqual($0 as? DicomIngestError, .contentChanged) }
        XCTAssertNoThrow(try results[1].get())
        XCTAssertEqual(try results[2].get().record.contentSHA256, digest(inspected))
        let records = try await fixture.registrar.records()
        XCTAssertEqual(Set(records.map(\.contentSHA256)), [digest(other), digest(inspected)])
        let matching = try await fixture.coordinator.ingest(
            part10Batch: [try ingestBytes(uid: "2.25.7103")], expectedSHA256: [digest(try ingestBytes(uid: "2.25.7103"))],
            timings: &timings)
        XCTAssertNoThrow(try matching[0].get())
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(".ingest").path)
            .contains { $0.hasSuffix(".part") })
    }

    func test_batch_capacityDenial_precedesStaging() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let items = try (0..<3).map { try ingestBytes(uid: "2.25.800\($0)", pixel: UInt8($0)) }
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal, registrar: fixture.registrar,
                                                capacity: Budget(limit: Int64(items[0].count * 2)))
        let results = try await coordinator.ingest(part10Batch: items)
        XCTAssertNoThrow(try results[0].get())
        XCTAssertNoThrow(try results[1].get())
        XCTAssertThrowsError(try results[2].get()) { error in
            guard case DicomIngestError.diskFull = error else { return XCTFail("\(error)") }
        }
    }

    func test_batch_crashAtEveryEffect_replaysWithoutPartialPublication() async throws {
        let boundaries: [(DicomFaultInjectingFileSystem.Operation, Int)] = [
            (.createDirectory, 1), (.createDirectory, 2), (.write, 1), (.write, 2), (.write, 3),
            (.fsyncFile, 1), (.fsyncFile, 3), (.fsyncDirectory, 1), (.fsyncDirectory, 3),
            (.read, 1), (.read, 2), (.read, 3), (.rename, 1), (.rename, 2), (.rename, 3),
            (.fsyncDirectory, 4), (.fsyncDirectory, 5), (.fsyncDirectory, 6)
        ]
        let items = try (0..<3).map { try ingestBytes(uid: "2.25.900\($0)", pixel: UInt8($0)) }
        for (kind, nth) in boundaries {
            for fault in [DicomFaultInjectingFileSystem.Fault.crashBefore, .crashAfter] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let fs = DicomFaultInjectingFileSystem(operation: kind, nth: nth, fault: fault)
                let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: fs,
                    journal: fixture.journal, registrar: fixture.registrar)
                do { _ = try await coordinator.ingest(part10Batch: items); XCTFail("Missing fault \(kind) \(nth)") }
                catch is DicomIngestCrash {}
                let restarted = try IngestFixture(root: fixture.root)
                let report = try await DicomIngestRecovery.replay(journal: restarted.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .loss || $0.outcome == .failed }, "\(kind) \(nth) \(fault)")
                let records = try await restarted.registrar.records()
                for record in records {
                    let expected = try XCTUnwrap(items.first { try DicomStoreRequest(part10Data: $0).sopInstanceUID == record.sopInstanceUID })
                    try assertIngestObject(record, bytes: expected)
                }
                for path in try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                    where path.pathExtension == "dcm" {
                    XCTAssertTrue(items.contains(try Data(contentsOf: path)), "\(kind) \(nth) \(fault)")
                }
                let entries = try await restarted.journal.entries()
                var latest: [UUID: DicomIngestJournalEntry] = [:]
                for entry in entries { latest[entry.ingestID] = entry }
                for entry in latest.values {
                    XCTAssertTrue((entry.stage == .registered && entry.phase == .done)
                        || (entry.disposition == .discarded && entry.phase == .done), "\(kind) \(nth) \(fault) \(entry.stage) \(entry.phase)")
                }
            }
        }
    }

    /// Issue #3080: staged bytes that do not hash to the validated bytes close the ingest as a
    /// refusal, and no later replay publishes them.
    func test_batch_stagedChecksumMismatch_closesAsRefusal_andReplayNeverPublishes() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let items = try (0..<3).map { try ingestBytes(uid: "2.25.3080\($0)", pixel: UInt8($0)) }
        let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: CorruptingFileSystem(corrupted: items[1]),
            journal: fixture.journal, registrar: fixture.registrar)
        let results = try await coordinator.ingest(part10Batch: items)
        XCTAssertNoThrow(try results[0].get())
        XCTAssertThrowsError(try results[1].get()) { error in
            guard case DicomIngestError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try results[2].get())

        let restarted = try IngestFixture(root: fixture.root)
        _ = try await DicomIngestRecovery.replay(journal: restarted.journal,
            fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
        try await assertRefused(items, refused: 1, root: fixture.root, journal: restarted.journal, registrar: restarted.registrar)
    }

    /// Issue #3080: a process stop between the read-back and the close still never publishes the
    /// bytes, whichever side of the checksum commit it falls on.
    func test_batch_crashAroundStagedChecksumMismatch_replayNeverPublishes() async throws {
        let items = try (0..<3).map { try ingestBytes(uid: "2.25.3081\($0)", pixel: UInt8($0)) }
        for after in [false, true] {
            let fixture = try IngestFixture()
            defer { fixture.clean() }
            // The third commit carries the checksum results.
            let journal = BatchFaultJournal(base: fixture.journal, nth: 3, after: after)
            let coordinator = DicomIngestCoordinator(root: fixture.root, fileSystem: CorruptingFileSystem(corrupted: items[1]),
                journal: journal, registrar: fixture.registrar)
            do { _ = try await coordinator.ingest(part10Batch: items); XCTFail("Missing fault \(after)") }
            catch is DicomIngestCrash {}
            let restarted = try IngestFixture(root: fixture.root)
            let report = try await DicomIngestRecovery.replay(journal: restarted.journal,
                fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
            XCTAssertFalse(report.items.contains { $0.outcome == .loss || $0.outcome == .failed }, "\(after)")
            try await assertRefused(items, refused: 1, root: fixture.root, journal: restarted.journal, registrar: restarted.registrar)
            let again = try await DicomIngestRecovery.replay(journal: restarted.journal,
                fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
            XCTAssertFalse(again.items.contains { $0.action != .none }, "\(after): the refusal is settled")
        }
    }

    private func assertRefused(_ items: [Data], refused: Int, root: URL, journal: any DicomIngestJournaling,
                               registrar: DicomJSONLIngestRegistrar, file: StaticString = #filePath, line: UInt = #line) async throws {
        let refusedUID = try DicomStoreRequest(part10Data: items[refused]).sopInstanceUID
        let records = try await registrar.records()
        XCTAssertFalse(records.contains { $0.sopInstanceUID == refusedUID }, "bytes that failed verification are never published",
                       file: file, line: line)
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where path.pathExtension == "dcm" {
            XCTAssertTrue(items.contains(try Data(contentsOf: path)), path.lastPathComponent, file: file, line: line)
        }
        let latest = try await journal.entries().last { $0.sopInstanceUID == refusedUID }
        XCTAssertEqual(latest?.disposition, .discarded, file: file, line: line)
        XCTAssertEqual(latest?.phase, .done, file: file, line: line)
        XCTAssertEqual(latest?.expectedChecksum, SHA256.hash(data: items[refused]).map { String(format: "%02x", $0) }.joined(),
                       "the refusal keeps the digest the bytes were expected to have", file: file, line: line)
        XCTAssertNil(latest?.checksum, file: file, line: line)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".ingest").path)
            .contains { $0.hasSuffix(".part") }, file: file, line: line)
    }

    func test_batch_journalCrash_leavesNoUnjournaledPublication() async throws {
        let items = try (0..<3).map { try ingestBytes(uid: "2.25.910\($0)", pixel: UInt8($0)) }
        for nth in 1...5 {
            for after in [false, true] {
                let fixture = try IngestFixture()
                defer { fixture.clean() }
                let journal = BatchFaultJournal(base: fixture.journal, nth: nth, after: after)
                let coordinator = DicomIngestCoordinator(root: fixture.root, journal: journal, registrar: fixture.registrar)
                do { _ = try await coordinator.ingest(part10Batch: items); XCTFail("Missing fault \(nth) \(after)") }
                catch is DicomIngestCrash {}
                let restarted = try IngestFixture(root: fixture.root)
                let report = try await DicomIngestRecovery.replay(journal: restarted.journal,
                    fileSystem: DicomLocalIngestFileSystem(), registrar: restarted.registrar)
                XCTAssertFalse(report.items.contains { $0.outcome == .loss || $0.outcome == .failed }, "\(nth) \(after)")
                for record in try await restarted.registrar.records() {
                    let expected = try XCTUnwrap(items.first { try DicomStoreRequest(part10Data: $0).sopInstanceUID == record.sopInstanceUID })
                    try assertIngestObject(record, bytes: expected)
                }
            }
        }
    }
}

private struct Budget: DicomIngestDiskCapacityChecking {
    let limit: Int64
    func checkCapacity(required: Int64, at root: URL) throws {
        if required > limit { throw DicomIngestError.diskFull(required: required, available: limit) }
    }
}

private actor CountingJournal: DicomIngestJournaling {
    nonisolated let isDurable = true
    let base: any DicomIngestJournaling
    var singleAppends = 0
    var batchAppends = 0
    init(base: any DicomIngestJournaling) { self.base = base }
    func append(_ entry: DicomIngestJournalEntry) async throws { singleAppends += 1; try await base.append(entry) }
    func append(contentsOf entries: [DicomIngestJournalEntry]) async throws {
        batchAppends += 1
        try await base.append(contentsOf: entries)
    }
    func entries() async throws -> [DicomIngestJournalEntry] { try await base.entries() }
}

private actor BatchFaultJournal: DicomIngestJournaling {
    nonisolated let isDurable = true
    let base: any DicomIngestJournaling
    let nth: Int
    let after: Bool
    var count = 0
    init(base: any DicomIngestJournaling, nth: Int, after: Bool) { self.base = base; self.nth = nth; self.after = after }
    func append(_ entry: DicomIngestJournalEntry) async throws { try await append(contentsOf: [entry]) }
    func append(contentsOf entries: [DicomIngestJournalEntry]) async throws {
        count += 1
        if count == nth, !after { throw DicomIngestCrash() }
        try await base.append(contentsOf: entries)
        if count == nth, after { throw DicomIngestCrash() }
    }
    func entries() async throws -> [DicomIngestJournalEntry] { try await base.entries() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private struct CountingFileSystem: DicomIngestFileSystem {
    let base = DicomLocalIngestFileSystem()
    let synchronizeCalls = Counter()
    func createDirectory(_ path: URL) throws { try base.createDirectory(path) }
    func write(_ data: Data, to path: URL, append: Bool) throws { try base.write(data, to: path, append: append) }
    func fsyncFile(_ path: URL) throws { try base.fsyncFile(path) }
    func fsyncDirectory(_ path: URL) throws { try base.fsyncDirectory(path) }
    func synchronize(files: [URL], directories: [URL]) throws {
        synchronizeCalls.increment()
        try base.synchronize(files: files, directories: directories)
    }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func remove(_ path: URL) throws { try base.remove(path) }
    func exists(_ path: URL) throws -> Bool { try base.exists(path) }
    func read(_ path: URL) throws -> Data { try base.read(path) }
    func lastByte(_ path: URL) throws -> UInt8? { try base.lastByte(path) }
    func contentsOf(_ directory: URL) throws -> [URL] { try base.contentsOf(directory) }
    func readChunks(_ path: URL, consume: (Data) throws -> Void) throws { try base.readChunks(path, consume: consume) }
}

/// Stages every item, except that the bytes of `corrupted` reach the disk with their last byte changed.
private struct CorruptingFileSystem: DicomIngestFileSystem {
    let base = DicomLocalIngestFileSystem()
    let corrupted: Data
    func createDirectory(_ path: URL) throws { try base.createDirectory(path) }
    func write(_ data: Data, to path: URL, append: Bool) throws {
        guard data == corrupted else { return try base.write(data, to: path, append: append) }
        var changed = data
        changed[changed.index(before: changed.endIndex)] ^= 0xFF
        try base.write(changed, to: path, append: append)
    }
    func fsyncFile(_ path: URL) throws { try base.fsyncFile(path) }
    func fsyncDirectory(_ path: URL) throws { try base.fsyncDirectory(path) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func remove(_ path: URL) throws { try base.remove(path) }
    func exists(_ path: URL) throws -> Bool { try base.exists(path) }
    func read(_ path: URL) throws -> Data { try base.read(path) }
    func contentsOf(_ directory: URL) throws -> [URL] { try base.contentsOf(directory) }
}
