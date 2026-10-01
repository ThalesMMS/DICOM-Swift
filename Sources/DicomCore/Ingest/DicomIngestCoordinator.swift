import CryptoKit
import Foundation

public struct DicomIngestCoordinator: Sendable {
    public let root: URL
    public let fileSystem: any DicomIngestFileSystem
    public let journal: any DicomIngestJournaling
    public let registrar: any DicomIngestRegistrar
    let lifecycle: (any DicomLifecycleEventEmitting)?
    let capacity: (any DicomIngestDiskCapacityChecking)?
    public init(root: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem(),
                journal: any DicomIngestJournaling, registrar: any DicomIngestRegistrar,
                capacity: (any DicomIngestDiskCapacityChecking)? = nil,
                lifecycle: (any DicomLifecycleEventEmitting)? = nil) {
        self.root = root; self.fileSystem = fileSystem; self.journal = journal
        self.registrar = registrar; self.capacity = capacity
        self.lifecycle = lifecycle
    }
    /// Where a receiver may write an incoming object as a Part 10 file for `ingest(_:)` to move into staging
    /// rather than write again (issue #2793): inside the root, so the move is a rename.
    public var receivedFileDirectory: URL { root.appendingPathComponent(".ingest") }

    /// Startup recovery only: call before receivers can create new incoming files.
    public func removeIncompleteReceives() throws {
        guard try fileSystem.exists(receivedFileDirectory) else { return }
        let incomplete = try fileSystem.contentsOf(receivedFileDirectory).filter { $0.pathExtension == "received" }
        for file in incomplete { try fileSystem.remove(file) }
        if !incomplete.isEmpty { try fileSystem.fsyncDirectory(receivedFileDirectory) }
    }

    public func ingest(part10Data: Data) async throws -> DicomIngestResult {
        try await ingest(part10Data: part10Data, stagingFrom: nil)
    }
    /// `file`, when given, holds `part10Data` and is renamed into staging instead of written.
    private func ingest(part10Data: Data, stagingFrom file: URL?) async throws -> DicomIngestResult {
        await registrar.gate.acquire()
        do {
            try await completePendingPromotions()
            let result = try await receive(part10Data, stagingFrom: file)
            await registrar.gate.release()
            return result
        } catch {
            await registrar.gate.release()
            throw DicomIngestError.mapped(error, path: root, required: Int64(part10Data.count))
        }
    }
    public func ingest(_ instance: DicomStorageReceivedInstance) async throws -> DicomIngestResult {
        let bytes: Data
        if let file = instance.part10FileURL {
            bytes = try fileSystem.read(file)
        } else if let raw = instance.rawDataSetData {
            bytes = try DicomDataSetWriter.part10Data(fromEncodedDataSet: raw, transferSyntax: instance.transferSyntax,
                mediaStorageSOPClassUID: instance.sopClassUID, mediaStorageSOPInstanceUID: instance.sopInstanceUID)
        } else {
            bytes = try DicomDataSetWriter.part10Data(from: instance.dataSet,
                options: .init(transferSyntax: instance.transferSyntax, mediaStorageSOPClassUID: instance.sopClassUID,
                               mediaStorageSOPInstanceUID: instance.sopInstanceUID))
        }
        let request = try dicomIngestValidatedRequest(bytes)
        guard request.sopInstanceUID == instance.sopInstanceUID, request.sopClassUID == instance.sopClassUID,
              request.transferSyntax == instance.transferSyntax else { throw DicomIngestError.invalidIdentity }
        return try await ingest(part10Data: bytes, stagingFrom: instance.part10FileURL)
    }
    private func receive(_ bytes: Data, stagingFrom file: URL?) async throws -> DicomIngestResult {
        var entry = DicomIngestJournalEntry(root: root)
        var checkpoints = [checkpoint(&entry, .received, .intent),
                           checkpoint(&entry, .received, .done),
                           checkpoint(&entry, .validated, .intent)]
        let request: DicomIngestValidatedObject
        do {
            request = try dicomIngestValidatedRequest(bytes)
            entry.sopClassUID = request.sopClassUID; entry.sopInstanceUID = request.sopInstanceUID
            entry.transferSyntaxUID = request.transferSyntax.rawValue
            checkpoints.append(checkpoint(&entry, .validated, .done))
            try Task.checkCancellation()
            try capacity?.checkCapacity(required: Int64(bytes.count), at: root)
        } catch {
            try await journal.append(contentsOf: checkpoints)
            throw error
        }
        checkpoints.append(checkpoint(&entry, .staged, .intent))
        // Validation has no disk effects. Commit its checkpoints together before staging any bytes.
        try await journal.append(contentsOf: checkpoints)
        try fileSystem.createDirectory(root)
        try fileSystem.createDirectory(entry.temporaryPath.deletingLastPathComponent())
        if let file { try fileSystem.rename(file, to: entry.temporaryPath) }
        else { try fileSystem.write(bytes, to: entry.temporaryPath, append: false) }
        try fileSystem.synchronize(files: [entry.temporaryPath], directories: [
            root.deletingLastPathComponent(), root, entry.temporaryPath.deletingLastPathComponent()
        ])
        // Staging completion is durable before the read-back: a crash or read error while hashing
        // must replay as a rehash of the synced bytes, not as a partial stage to discard.
        try await journal.append(contentsOf: [checkpoint(&entry, .staged, .done),
                                              checkpoint(&entry, .checksummed, .intent)])
        entry.checksum = try fileSystem.checksum(entry.temporaryPath)
        try await mark(&entry, .checksummed, .done)
        return try await finish(&entry, subject: lifecycle == nil ? nil : lifecycleSubject(request))
    }
    func checkpoint(_ entry: inout DicomIngestJournalEntry, _ stage: DicomIngestStage,
                    _ phase: DicomIngestJournalEntry.Phase) -> DicomIngestJournalEntry {
        entry.stage = stage; entry.phase = phase; entry.timestamp = Date()
        return entry
    }
    func mark(_ entry: inout DicomIngestJournalEntry, _ stage: DicomIngestStage,
              _ phase: DicomIngestJournalEntry.Phase) async throws {
        try await journal.append(checkpoint(&entry, stage, phase))
    }
    /// Called under the registrar gate, including during replay.
    func finish(_ entry: inout DicomIngestJournalEntry,
                subject suppliedSubject: DicomLifecycleEvent.Subject? = nil,
                preservingConflicts: Set<URL> = []) async throws -> DicomIngestResult {
        var subject = suppliedSubject
        if lifecycle != nil, subject == nil {
            // A published intent may still have only staged bytes, or its proposed final name may be occupied.
            let path = (try? fileSystem.exists(entry.temporaryPath)) == true
                ? entry.temporaryPath : entry.finalPath ?? entry.temporaryPath
            if let bytes = try? fileSystem.read(path), let request = try? dicomIngestValidatedRequest(bytes) {
                subject = lifecycleSubject(request)
            }
        }
        if entry.checksum == nil {
            try await mark(&entry, .checksummed, .intent)
            entry.checksum = try fileSystem.checksum(entry.temporaryPath)
            try await mark(&entry, .checksummed, .done)
        }
        guard let hash = entry.checksum, !hash.isEmpty, let uid = entry.sopInstanceUID,
              let sopClass = entry.sopClassUID, let syntax = entry.transferSyntaxUID else {
            throw DicomIngestError.invalidJournal
        }
        let classification = try await registrar.classify(sopInstanceUID: uid, contentSHA256: hash)
        let wasPublished = entry.finalPath != nil && (entry.stage == .published || entry.stage == .registered)
        var stagedVerified = false
        if !wasPublished {
            try verify(entry.temporaryPath, entry: entry)
            stagedVerified = true
            if case .duplicate(let identical) = classification, identical == hash,
               let prior = try await registrar.records(sopInstanceUID: uid).first(where: { $0.sopInstanceUID == uid && $0.contentSHA256 == hash }) {
                try verify(prior.path, entry: entry)
                entry.disposition = .duplicate; entry.finalPath = prior.path
                try await mark(&entry, .registered, .intent)
                try fileSystem.remove(entry.temporaryPath)
                try fileSystem.fsyncDirectory(entry.temporaryPath.deletingLastPathComponent())
                try await mark(&entry, .registered, .done)
                await emitLifecycle(.available, entry: entry, subject: subject, durability: achieved)
                return .init(record: prior, classification: classification, durability: achieved)
            }
            let conflict: Bool
            if case .conflict(let existing) = classification { conflict = true; entry.conflictSHA256 = existing ?? "unknown" }
            else { conflict = false }
            entry.finalPath = try uniquePath(uid: uid, hash: hash, conflict: conflict)
            try await mark(&entry, .published, .intent)
        }
        guard let final = entry.finalPath else { throw DicomIngestError.invalidJournal }
        var receivedEmitted = false
        var registrationConfirmed = false
        var ownsFinal = entry.stage == .registered || (entry.stage == .published && entry.phase == .done)
        do {
            if try fileSystem.exists(final) {
                if !ownsFinal, try fileSystem.exists(entry.temporaryPath),
                   try fileSystem.checksum(final) != hash {
                    // A previous failed rename can be followed by another arrival taking the free name.
                    // Reclassify our still-staged bytes; the existing destination is not ours to quarantine.
                    entry.finalPath = nil
                    entry.stage = .checksummed
                    entry.phase = .done
                    return try await finish(&entry, subject: subject, preservingConflicts: preservingConflicts)
                }
                try verify(final, entry: entry)
            } else {
                guard try fileSystem.exists(entry.temporaryPath) else { throw DicomIngestError.missingFile(path: final.path) }
                // Replayed publication intents verify here; the in-process path verified the staged file above.
                if !stagedVerified { try verify(entry.temporaryPath, entry: entry) }
                try fileSystem.createDirectory(final.deletingLastPathComponent())
                try fileSystem.rename(entry.temporaryPath, to: final)
                ownsFinal = true
            }
            try fileSystem.synchronize(files: [], directories: [
                root, final.deletingLastPathComponent(), entry.temporaryPath.deletingLastPathComponent()
            ])
            // Publication completion and registration intent have no disk effect between them.
            try await journal.append(contentsOf: [checkpoint(&entry, .published, .done),
                                                  checkpoint(&entry, .registered, .intent)])
            await emitLifecycle(.received, entry: entry, subject: subject, durability: .fileSynced)
            receivedEmitted = true
            var record = DicomIngestRecord(ingestID: entry.ingestID, sopClassUID: sopClass, sopInstanceUID: uid,
                transferSyntaxUID: syntax, path: final, contentSHA256: hash, isConflict: entry.conflictSHA256 != nil)
            let registration = try await registrar.register(record)
            if case .conflict = registration, !record.isConflict {
                try await quarantine(&entry)
                record = .init(ingestID: entry.ingestID, sopClassUID: sopClass, sopInstanceUID: uid,
                    transferSyntaxUID: syntax, path: entry.finalPath!, contentSHA256: hash, isConflict: true)
                _ = try await registrar.register(record)
            }
            registrationConfirmed = true
            try await mark(&entry, .registered, .done)
            await emitLifecycle(.available, entry: entry, subject: subject, durability: achieved)
            if record.isConflict {
                DicomConflictRetention.enforce(in: record.path.deletingLastPathComponent(),
                                              preserving: preservingConflicts.union([record.path]), fileSystem: fileSystem)
            }
            return .init(record: record, classification: classification, durability: achieved)
        } catch {
            if receivedEmitted {
                let classified = DicomIngestError.mapped(error, path: root)
                await emitLifecycle(.error, entry: entry, subject: subject, durability: .fileSynced,
                                    error: lifecycleError(classified))
            }
            if ownsFinal, !registrationConfirmed, !(error is DicomIngestCrash), (try? fileSystem.exists(final)) == true {
                try? await quarantine(&entry)
            }
            throw error
        }
    }
    func lifecycleSubject(_ request: DicomIngestValidatedObject) -> DicomLifecycleEvent.Subject {
        .init(studyInstanceUID: request.dataSet.string(for: .studyInstanceUID),
              seriesInstanceUID: request.dataSet.string(for: .seriesInstanceUID),
              sopInstanceUID: request.sopInstanceUID, objectCount: 1)
    }

    func emitLifecycle(_ kind: DicomLifecycleEvent.Kind, entry: DicomIngestJournalEntry,
                               subject: DicomLifecycleEvent.Subject?, durability: DicomDurabilityLevel,
                               error: DicomLifecycleEvent.ErrorInfo? = nil) async {
        guard let lifecycle else { return }
        let subject = subject ?? DicomLifecycleEvent.Subject(sopInstanceUID: entry.sopInstanceUID, objectCount: 1)
        let event = try! DicomLifecycleEvent(kind: kind, subject: subject, sourceKind: "ingest",
            sourceRef: entry.ingestID.uuidString, durability: durability, error: error)
        await lifecycle.emit(event)
    }
    func lifecycleError(_ error: Error) -> DicomLifecycleEvent.ErrorInfo {
        let classification: String
        switch error {
        case DicomIngestError.diskFull: classification = "diskFull"
        case DicomIngestError.permissionDenied: classification = "permissionDenied"
        case DicomIngestError.invalidIdentity: classification = "invalidIdentity"
        case DicomIngestError.checksumMismatch: classification = "checksumMismatch"
        case DicomIngestError.contentChanged: classification = "contentChanged"
        case DicomIngestError.missingFile: classification = "missingFile"
        case DicomIngestError.invalidJournal: classification = "invalidJournal"
        case DicomIngestError.insufficientDurability: classification = "insufficientDurability"
        case is DicomIngestCrash: classification = "interrupted"
        case is CancellationError: classification = "cancelled"
        default: classification = "ingestFailure"
        }
        return .init(class: classification, message: "Ingest failed after publication")
    }
    var achieved: DicomDurabilityLevel { journal.isDurable ? registrar.durability : .fileSynced }
    func verify(_ path: URL, entry: DicomIngestJournalEntry) throws {
        // One read serves both the hash and the parse.
        let bytes = try fileSystem.read(path)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard checksum == entry.checksum else { throw DicomIngestError.checksumMismatch(path: path.path) }
        let request = try dicomIngestValidatedRequest(bytes)
        guard request.sopInstanceUID == entry.sopInstanceUID, request.sopClassUID == entry.sopClassUID,
              request.transferSyntax.rawValue == entry.transferSyntaxUID else { throw DicomIngestError.invalidIdentity }
    }
    /// `reserved` names are treated as occupied: a batch claims final paths before any rename lands.
    func uniquePath(uid: String, hash: String, conflict: Bool, reserved: Set<URL> = []) throws -> URL {
        let directory = conflict ? root.appendingPathComponent(".conflicts") : root
        let base = String(DicomFileStorageCache.fileName(for: uid).dropLast(4))
        let occupied = { (path: URL) throws -> Bool in try reserved.contains(path) || fileSystem.exists(path) }
        var path = directory.appendingPathComponent(conflict ? "\(base)~\(hash.prefix(8)).dcm" : "\(base).dcm")
        if try occupied(path) { path = directory.appendingPathComponent("\(base)~\(hash.prefix(8)).dcm") }
        while try occupied(path) {
            path = directory.appendingPathComponent("\(base)~\(hash.prefix(8))~\(UUID().uuidString).dcm")
        }
        return path
    }
    func quarantine(_ entry: inout DicomIngestJournalEntry) async throws {
        guard let source = entry.finalPath else { return }
        let destination = root.appendingPathComponent(".quarantine/\(entry.ingestID.uuidString).dcm")
        entry.disposition = .quarantined
        try await mark(&entry, .published, .intent)
        try fileSystem.createDirectory(destination.deletingLastPathComponent())
        try fileSystem.fsyncDirectory(root)
        if source != destination, try fileSystem.exists(source) { try fileSystem.rename(source, to: destination) }
        guard try fileSystem.exists(destination) else { throw DicomIngestError.missingFile(path: destination.path) }
        try fileSystem.fsyncDirectory(source.deletingLastPathComponent())
        try fileSystem.fsyncDirectory(destination.deletingLastPathComponent())
        entry.finalPath = destination
        try await mark(&entry, .published, .done)
    }
}

/// Only for pre-existing blocking DIMSE/storage workers. Async hosts call ingest directly.
final class DicomIngestBlockingResult<T: Sendable>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    static func run(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = DicomIngestBlockingResult<T>()
        Task.detached {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            box.semaphore.signal()
        }
        box.semaphore.wait()
        return try box.result!.get()
    }
}


final class DicomIngestStorageAdapter: DicomStorageInstanceStoring {
    let ingest: DicomIngestCoordinator
    init(ingest: DicomIngestCoordinator) { self.ingest = ingest }
    var receivedFileDirectory: URL? { ingest.receivedFileDirectory }
    func store(_ instance: DicomStorageReceivedInstance) throws -> DicomStoredInstance {
        let result = try DicomIngestBlockingResult.run { [ingest] in try await ingest.ingest(instance) }
        return .init(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                     transferSyntax: instance.transferSyntax, fileURL: result.record.path,
                     isConflict: result.record.isConflict)
    }
}


/// Parses the dataset where it lies in `bytes`: a mapped file is validated without being copied (issue #2793).
func dicomIngestValidatedRequest(_ bytes: Data) throws -> DicomIngestValidatedObject {
    let header = try DicomStoreRequest.part10Header(of: bytes)
    guard !header.sopClassUID.isEmpty else { throw DicomStoreRequestError.missingSOPClassUID }
    guard !header.sopInstanceUID.isEmpty else { throw DicomStoreRequestError.missingSOPInstanceUID }
    let set = try DicomDataSetParser.dataSet(from: bytes, startingAt: header.dataSetOffset,
                                             transferSyntax: header.transferSyntax)
    // Only an absent identity may defer to the file meta. A present UID must be
    // readable and match, including when its encoded VR is unknown to the parser.
    guard !set.contains(.sopClassUID) || set.string(for: .sopClassUID) == header.sopClassUID,
          !set.contains(.sopInstanceUID) || set.string(for: .sopInstanceUID) == header.sopInstanceUID else {
        throw DicomIngestError.invalidIdentity
    }
    return .init(sopClassUID: header.sopClassUID, sopInstanceUID: header.sopInstanceUID,
                 transferSyntax: header.transferSyntax, dataSet: set)
}
