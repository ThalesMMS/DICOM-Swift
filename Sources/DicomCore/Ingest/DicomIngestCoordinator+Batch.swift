import Foundation
import CryptoKit

/// Bulk ingestion for local imports. Every item keeps the single-instance journal contract, so a
/// crash anywhere replays exactly like a lone `ingest(part10Data:)`; what changes is that items
/// share one journal commit per stage boundary and one device flush per staging and publication
/// round instead of paying both per file. Ingesting 234 CT images this way costs about twelve
/// journal commits and four full flushes rather than roughly 1,400 and 468.
/// Wall-clock seconds spent in each stage of one batch, for host logs that need to say where an
/// import spends its time on a device the benchmark cannot reproduce.
public struct DicomIngestBatchTimings: Sendable {
    public var validate: TimeInterval = 0
    public var write: TimeInterval = 0
    public var stageSynchronize: TimeInterval = 0
    public var checksum: TimeInterval = 0
    public var classify: TimeInterval = 0
    public var rename: TimeInterval = 0
    public var publishSynchronize: TimeInterval = 0
    public var register: TimeInterval = 0
    public var journal: TimeInterval = 0
    public init() {}
    mutating func add(_ keyPath: WritableKeyPath<Self, TimeInterval>, since start: DispatchTime) {
        self[keyPath: keyPath] += Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

public extension DicomIngestCoordinator {
    /// Returns one result per input, in order. A journal failure aborts the whole batch, as it
    /// would abort a lone ingest; every other failure is confined to its own item.
    func ingest(part10Batch items: [Data]) async throws -> [Result<DicomIngestResult, any Error>] {
        var timings = DicomIngestBatchTimings()
        return try await ingest(part10Batch: items, timings: &timings)
    }

    func ingest(part10Batch items: [Data],
                timings: inout DicomIngestBatchTimings) async throws -> [Result<DicomIngestResult, any Error>] {
        try await ingest(part10Batch: items, expectedSHA256: [], timings: &timings)
    }

    /// `expectedSHA256` is index-parallel to `items` (shorter or `nil` entries expect nothing): the
    /// lowercase hex SHA-256 the caller took when it inspected the object. An item whose bytes hash
    /// to anything else fails with `contentChanged` before it has any disk effect, so what a caller
    /// catalogued from an earlier read can never be published over different bytes. The digest
    /// compared is the one the ingest computes anyway; nothing is hashed twice.
    func ingest(part10Batch items: [Data], expectedSHA256: [String?],
                timings: inout DicomIngestBatchTimings) async throws -> [Result<DicomIngestResult, any Error>] {
        guard !items.isEmpty else { return [] }
        await registrar.gate.acquire()
        let results: [Result<DicomIngestResult, any Error>]
        do {
            try await completePendingPromotions()
            results = try await receiveBatch(items, expectedSHA256: expectedSHA256, timings: &timings)
        } catch {
            await registrar.gate.release()
            throw DicomIngestError.mapped(error, path: root, required: Int64(items.reduce(0) { $0 + $1.count }))
        }
        await registrar.gate.release()
        return results.enumerated().map { index, result in
            result.mapError { DicomIngestError.mapped($0, path: root, required: Int64(items[index].count)) }
        }
    }
}

/// The SHA-256 and the validated store request of every item, computed concurrently. An item whose
/// digest is not the expected one fails with `contentChanged` without being parsed.
enum DicomIngestBatchInspection {
    static func inspect(_ items: [Data], expectedSHA256: [String?]) -> [Result<(DicomIngestValidatedObject, String), any Error>] {
        let results = Results(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let memoryHash = SHA256.hash(data: items[index]).map { String(format: "%02x", $0) }.joined()
            if index < expectedSHA256.count, let expected = expectedSHA256[index], expected != memoryHash {
                results.set(index, .failure(DicomIngestError.contentChanged))
                return
            }
            results.set(index, Result { (try dicomIngestValidatedRequest(items[index]), memoryHash) })
        }
        return results.values
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<(DicomIngestValidatedObject, String), any Error>?]
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Result<(DicomIngestValidatedObject, String), any Error>) { lock.withLock { storage[index] = value } }
        var values: [Result<(DicomIngestValidatedObject, String), any Error>] {
            lock.withLock { storage.map { $0 ?? .failure(DicomIngestError.invalidJournal) } }
        }
    }
}

private struct DicomIngestBatchItem {
    let bytes: Data
    var entry: DicomIngestJournalEntry
    var request: DicomIngestValidatedObject?
    var memoryHash: String?
    var subject: DicomLifecycleEvent.Subject?
    var classification: DicomIngestClassification = .new
    var failure: (any Error)?
    var result: DicomIngestResult?
    var receivedEmitted = false
    var ownsFinal = false
    var registrationConfirmed = false
    var isPending: Bool { failure == nil && result == nil }
}

private extension DicomIngestCoordinator {
    func receiveBatch(_ items: [Data], expectedSHA256: [String?],
                      timings: inout DicomIngestBatchTimings) async throws -> [Result<DicomIngestResult, any Error>] {
        var batch = items.map { DicomIngestBatchItem(bytes: $0, entry: DicomIngestJournalEntry(root: root)) }
        var checkpoints: [DicomIngestJournalEntry] = []
        var reservedBytes: Int64 = 0

        // Validation has no disk effects: every item's receipt, validation and staging intent commit together.
        var clock = DispatchTime.now()
        // Hashing and parsing an item touch nothing but its own bytes, so the items of a batch are
        // inspected on every core; the checkpoints below still follow the items' order.
        let inspected = DicomIngestBatchInspection.inspect(items, expectedSHA256: expectedSHA256)
        for index in batch.indices {
            checkpoints.append(checkpoint(&batch[index].entry, .received, .intent))
            checkpoints.append(checkpoint(&batch[index].entry, .received, .done))
            checkpoints.append(checkpoint(&batch[index].entry, .validated, .intent))
            do {
                let (request, memoryHash) = try inspected[index].get()
                batch[index].entry.sopClassUID = request.sopClassUID
                batch[index].entry.sopInstanceUID = request.sopInstanceUID
                batch[index].entry.transferSyntaxUID = request.transferSyntax.rawValue
                checkpoints.append(checkpoint(&batch[index].entry, .validated, .done))
                try Task.checkCancellation()
                reservedBytes += Int64(batch[index].bytes.count)
                try capacity?.checkCapacity(required: reservedBytes, at: root)
                checkpoints.append(checkpoint(&batch[index].entry, .staged, .intent))
                batch[index].request = request
                batch[index].memoryHash = memoryHash
                batch[index].subject = lifecycle == nil ? nil : lifecycleSubject(request)
            } catch {
                try fail(&batch[index], error)
            }
        }
        timings.add(\.validate, since: clock)
        clock = DispatchTime.now()
        try await journal.append(contentsOf: checkpoints)
        timings.add(\.journal, since: clock)

        // Staging: write every accepted item, then flush the device once for all of them.
        clock = DispatchTime.now()
        let stagingDirectory = batch[0].entry.temporaryPath.deletingLastPathComponent()
        if batch.contains(where: \.isPending) {
            do {
                try fileSystem.createDirectory(root)
                try fileSystem.createDirectory(stagingDirectory)
            } catch {
                for index in batch.indices where batch[index].isPending { try fail(&batch[index], error) }
            }
        }
        var written: [URL] = []
        for index in batch.indices where batch[index].isPending {
            do {
                try fileSystem.write(batch[index].bytes, to: batch[index].entry.temporaryPath, append: false)
                written.append(batch[index].entry.temporaryPath)
            } catch {
                try fail(&batch[index], error)
            }
        }
        timings.add(\.write, since: clock)
        clock = DispatchTime.now()
        if !written.isEmpty {
            do {
                try fileSystem.synchronize(files: written, directories: [root.deletingLastPathComponent(), root, stagingDirectory])
            } catch {
                for index in batch.indices where batch[index].isPending { try fail(&batch[index], error) }
            }
        }
        timings.add(\.stageSynchronize, since: clock)
        // Staging completion is durable before the read-back: a crash or read error while hashing
        // must replay as a rehash of the synced bytes, not as a partial stage to discard.
        checkpoints = []
        for index in batch.indices where batch[index].isPending {
            checkpoints.append(checkpoint(&batch[index].entry, .staged, .done))
            checkpoints.append(checkpoint(&batch[index].entry, .checksummed, .intent))
        }
        clock = DispatchTime.now()
        try await journal.append(contentsOf: checkpoints)
        timings.add(\.journal, since: clock)
        checkpoints = []
        clock = DispatchTime.now()
        for index in batch.indices where batch[index].isPending {
            do {
                let checksum = try fileSystem.checksum(batch[index].entry.temporaryPath)
                // The synced bytes must be the validated bytes. This replaces the lone ingest's
                // re-read, re-hash and re-parse of the staging file before publication.
                guard checksum == batch[index].memoryHash else {
                    throw DicomIngestError.checksumMismatch(path: batch[index].entry.temporaryPath.path)
                }
                batch[index].entry.checksum = checksum
                checkpoints.append(checkpoint(&batch[index].entry, .checksummed, .done))
            } catch {
                try fail(&batch[index], error)
            }
        }
        timings.add(\.checksum, since: clock)
        clock = DispatchTime.now()
        try await journal.append(contentsOf: checkpoints)
        timings.add(\.journal, since: clock)

        try await publishBatch(&batch, timings: &timings)
        return batch.map { item in
            if let result = item.result { return .success(result) }
            return .failure(item.failure ?? DicomIngestError.invalidJournal)
        }
    }

    /// Classification, publication and registration for the staged items. Duplicates and repeated
    /// UIDs inside the batch take the lone path under the gate the batch already holds, so the
    /// registrar sees each arrival in order.
    func publishBatch(_ batch: inout [DicomIngestBatchItem], timings: inout DicomIngestBatchTimings) async throws {
        var reserved = Set<URL>()
        var seenUIDs = Set<String>()
        var deferred: [Int] = []
        var publishing: [Int] = []
        var checkpoints: [DicomIngestJournalEntry] = []
        var clock = DispatchTime.now()
        for index in batch.indices where batch[index].isPending {
            guard let uid = batch[index].entry.sopInstanceUID, let hash = batch[index].entry.checksum else {
                try fail(&batch[index], DicomIngestError.invalidJournal)
                continue
            }
            guard seenUIDs.insert(uid).inserted else { deferred.append(index); continue }
            do {
                let classification = try await registrar.classify(sopInstanceUID: uid, contentSHA256: hash)
                batch[index].classification = classification
                switch classification {
                case .duplicate(let identical) where identical == hash:
                    deferred.append(index)
                    continue
                case .conflict(let existing):
                    batch[index].entry.conflictSHA256 = existing ?? "unknown"
                    batch[index].entry.finalPath = try uniquePath(uid: uid, hash: hash, conflict: true, reserved: reserved)
                case .new, .duplicate:
                    batch[index].entry.finalPath = try uniquePath(uid: uid, hash: hash, conflict: false, reserved: reserved)
                }
                reserved.insert(batch[index].entry.finalPath!)
                checkpoints.append(checkpoint(&batch[index].entry, .published, .intent))
                publishing.append(index)
            } catch {
                try fail(&batch[index], error)
            }
        }
        timings.add(\.classify, since: clock)
        clock = DispatchTime.now()
        try await journal.append(contentsOf: checkpoints)
        timings.add(\.journal, since: clock)

        var renamed: [Int] = []
        var directories: Set<URL> = [root]
        clock = DispatchTime.now()
        for index in publishing {
            let final = batch[index].entry.finalPath!
            do {
                try fileSystem.createDirectory(final.deletingLastPathComponent())
                try fileSystem.rename(batch[index].entry.temporaryPath, to: final)
                batch[index].ownsFinal = true
                renamed.append(index)
                directories.insert(final.deletingLastPathComponent())
                directories.insert(batch[index].entry.temporaryPath.deletingLastPathComponent())
            } catch {
                try await fail(&batch[index], error, quarantining: true)
            }
        }
        timings.add(\.rename, since: clock)
        clock = DispatchTime.now()
        if !renamed.isEmpty {
            do {
                try fileSystem.synchronize(files: [], directories: Array(directories))
            } catch {
                for index in renamed { try await fail(&batch[index], error, quarantining: true) }
                renamed = []
            }
        }
        timings.add(\.publishSynchronize, since: clock)

        // Publication completion and registration intent have no disk effect between them.
        checkpoints = []
        for index in renamed {
            checkpoints.append(checkpoint(&batch[index].entry, .published, .done))
            checkpoints.append(checkpoint(&batch[index].entry, .registered, .intent))
        }
        clock = DispatchTime.now()
        do {
            try await journal.append(contentsOf: checkpoints)
        } catch {
            for index in renamed { try? await quarantine(&batch[index].entry) }
            throw error
        }
        timings.add(\.journal, since: clock)
        for index in renamed {
            await emitLifecycle(.received, entry: batch[index].entry, subject: batch[index].subject, durability: .fileSynced)
            batch[index].receivedEmitted = true
        }

        var registered: [Int] = []
        var records: [Int: DicomIngestRecord] = [:]
        // One registrar commit for the batch; registration is idempotent by ingestID, so a crash
        // after the store commit and before `registered.done` replays to the same rows.
        let pendingRecords = renamed.map { index -> DicomIngestRecord in
            let entry = batch[index].entry
            return DicomIngestRecord(ingestID: entry.ingestID, sopClassUID: entry.sopClassUID!,
                sopInstanceUID: entry.sopInstanceUID!, transferSyntaxUID: entry.transferSyntaxUID!,
                path: entry.finalPath!, contentSHA256: entry.checksum!, isConflict: entry.conflictSHA256 != nil)
        }
        let registrations: [DicomIngestClassification]
        clock = DispatchTime.now()
        do {
            registrations = try await registrar.register(contentsOf: pendingRecords)
        } catch {
            for index in renamed { try await fail(&batch[index], error, quarantining: true) }
            registrations = []
        }
        for (offset, index) in renamed.enumerated() where offset < registrations.count {
            var record = pendingRecords[offset]
            do {
                if case .conflict = registrations[offset], !record.isConflict {
                    try await quarantine(&batch[index].entry)
                    record = .init(ingestID: record.ingestID, sopClassUID: record.sopClassUID,
                        sopInstanceUID: record.sopInstanceUID, transferSyntaxUID: record.transferSyntaxUID,
                        path: batch[index].entry.finalPath!, contentSHA256: record.contentSHA256, isConflict: true)
                    _ = try await registrar.register(record)
                }
                batch[index].registrationConfirmed = true
                records[index] = record
                registered.append(index)
            } catch {
                try await fail(&batch[index], error, quarantining: true)
            }
        }
        timings.add(\.register, since: clock)
        checkpoints = []
        for index in registered { checkpoints.append(checkpoint(&batch[index].entry, .registered, .done)) }
        clock = DispatchTime.now()
        try await journal.append(contentsOf: checkpoints)
        timings.add(\.journal, since: clock)
        for index in registered {
            await emitLifecycle(.available, entry: batch[index].entry, subject: batch[index].subject, durability: achieved)
            batch[index].result = .init(record: records[index]!, classification: batch[index].classification, durability: achieved)
        }
        var conflicts = Set(records.values.filter(\.isConflict).map(\.path))
        if !conflicts.isEmpty {
            // Issue #2530: all conflicts published together must survive this batch's retention round.
            DicomConflictRetention.enforce(in: root.appendingPathComponent(".conflicts"),
                                          preserving: conflicts, fileSystem: fileSystem)
        }

        for index in deferred {
            do {
                let result = try await finish(&batch[index].entry, subject: batch[index].subject,
                                              preservingConflicts: conflicts)
                batch[index].result = result
                if result.record.isConflict { conflicts.insert(result.record.path) }
            } catch {
                try fail(&batch[index], error)
            }
        }
    }

    /// A crash is a process stop: nothing after it may run, so it leaves the batch immediately.
    func fail(_ item: inout DicomIngestBatchItem, _ error: any Error) throws {
        if error is DicomIngestCrash { throw error }
        item.failure = error
    }

    func fail(_ item: inout DicomIngestBatchItem, _ error: any Error, quarantining: Bool) async throws {
        try fail(&item, error)
        if item.receivedEmitted {
            await emitLifecycle(.error, entry: item.entry, subject: item.subject, durability: .fileSynced,
                                error: lifecycleError(DicomIngestError.mapped(error, path: root)))
        }
        if quarantining, item.ownsFinal, !item.registrationConfirmed, let final = item.entry.finalPath,
           (try? fileSystem.exists(final)) == true {
            try? await quarantine(&item.entry)
        }
    }
}
