import Foundation

public enum DicomIngestClassification: Equatable, Sendable {
    case new
    case duplicate(identicalContent: String)
    case conflict(existingSHA256: String?)

    public var representationConflict: DicomRepresentationConflict? {
        switch self {
        case .new: return nil
        case .duplicate: return .identicalBytes
        case .conflict: return .conflictingContent
        }
    }
}

public struct DicomIngestRecord: Codable, Equatable, Sendable {
    public let ingestID: UUID
    public let sopClassUID: String
    public let sopInstanceUID: String
    public let transferSyntaxUID: String
    public let path: URL
    public let contentSHA256: String
    public let isConflict: Bool
    public init(ingestID: UUID, sopClassUID: String, sopInstanceUID: String, transferSyntaxUID: String,
                path: URL, contentSHA256: String, isConflict: Bool = false) {
        self.ingestID = ingestID; self.sopClassUID = sopClassUID; self.sopInstanceUID = sopInstanceUID
        self.transferSyntaxUID = transferSyntaxUID; self.path = path
        self.contentSHA256 = contentSHA256; self.isConflict = isConflict
    }
}

/// Shared by every coordinator using a registrar. Held across classification, publication and registration.
public actor DicomIngestGate {
    private var busy = false
    private(set) var hasPendingPromotion = false
    func beginPromotion() { hasPendingPromotion = true }
    func endPromotion() { hasPendingPromotion = false }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

public protocol DicomIngestRegistrar: Sendable {
    var gate: DicomIngestGate { get }
    var supportsPromotion: Bool { get }
    /// Memory registrars return fileSynced; retentionConfirmed requires a host retention contract.
    var durability: DicomDurabilityLevel { get }
    func classify(sopInstanceUID: String, contentSHA256: String) async throws -> DicomIngestClassification
    /// Must be idempotent by ingestID, serialize writers and never replace a prior arrival.
    func register(_ record: DicomIngestRecord) async throws -> DicomIngestClassification
    /// Registers `records` in order with the same contract as `register(_:)`, returning one
    /// classification per record; durable stores may share one commit for the whole batch.
    func register(contentsOf records: [DicomIngestRecord]) async throws -> [DicomIngestClassification]
    func promote(canonical: DicomIngestRecord, conflict: DicomIngestRecord) async throws
    func records() async throws -> [DicomIngestRecord]
    func records(sopInstanceUID: String) async throws -> [DicomIngestRecord]
}

public extension DicomIngestRegistrar {
    var supportsPromotion: Bool { false }
    // issue #2532: registrars without replacement semantics must refuse rather than register a second original.
    func promote(canonical: DicomIngestRecord, conflict: DicomIngestRecord) async throws {
        throw DicomIngestError.invalidJournal
    }

    func records(sopInstanceUID: String) async throws -> [DicomIngestRecord] {
        try await records().filter { $0.sopInstanceUID == sopInstanceUID }
    }

    func register(contentsOf records: [DicomIngestRecord]) async throws -> [DicomIngestClassification] {
        var classifications: [DicomIngestClassification] = []
        classifications.reserveCapacity(records.count)
        for record in records { classifications.append(try await register(record)) }
        return classifications
    }
}

func dicomIngestClassify(_ records: [DicomIngestRecord], uid: String, hash: String) -> DicomIngestClassification {
    let existing = records.filter { $0.sopInstanceUID == uid }
    if let same = existing.first(where: { !$0.contentSHA256.isEmpty && $0.contentSHA256 == hash }), !hash.isEmpty {
        return .duplicate(identicalContent: same.contentSHA256)
    }
    if let first = existing.first { return .conflict(existingSHA256: first.contentSHA256.isEmpty ? nil : first.contentSHA256) }
    return .new
}

public actor DicomInMemoryIngestRegistrar: DicomIngestRegistrar {
    public nonisolated let gate = DicomIngestGate()
    public nonisolated let supportsPromotion = true
    public nonisolated let durability = DicomDurabilityLevel.fileSynced
    private var objects: [DicomIngestRecord] = []
    public init() {}
    public func classify(sopInstanceUID: String, contentSHA256: String) -> DicomIngestClassification {
        dicomIngestClassify(records(), uid: sopInstanceUID, hash: contentSHA256)
    }
    public func register(_ record: DicomIngestRecord) throws -> DicomIngestClassification {
        if let previous = objects.first(where: { $0.ingestID == record.ingestID }) {
            guard previous == record else { throw DicomIngestError.invalidJournal }
            return record.isConflict ? .conflict(existingSHA256: nil) : .new
        }
        let classification = classify(sopInstanceUID: record.sopInstanceUID, contentSHA256: record.contentSHA256)
        if case .duplicate = classification { return classification }
        if case .conflict = classification, !record.isConflict { return classification }
        objects.append(record)
        return classification
    }
    public func promote(canonical: DicomIngestRecord, conflict: DicomIngestRecord) throws {
        try dicomApplyPromotion(canonical: canonical, conflict: conflict, to: &objects)
    }
    public func records() -> [DicomIngestRecord] {
        // Issue #2530: historical conflict receipts must not make an evicted arrival a live duplicate.
        objects.filter { !$0.isConflict || FileManager.default.fileExists(atPath: $0.path.path) }
    }
}

/// One owner per registry file. Reopen this object at process restart before journal replay.
public actor DicomJSONLIngestRegistrar: DicomIngestRegistrar {
    public nonisolated let gate = DicomIngestGate()
    public nonisolated let supportsPromotion = true
    public nonisolated let durability = DicomDurabilityLevel.publishedAndRegistered
    private let path: URL
    private let fileSystem: any DicomIngestFileSystem
    private var objects: [DicomIngestRecord]?
    private var byUID: [String: [DicomIngestRecord]] = [:]
    private var byID: [UUID: DicomIngestRecord] = [:]
    public init(path: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) throws {
        self.path = path; self.fileSystem = fileSystem
        try fileSystem.createDirectory(path.deletingLastPathComponent())
        try fileSystem.fsyncDirectory(path.deletingLastPathComponent().deletingLastPathComponent())
    }
    private func loadIfNeeded() throws {
        guard objects == nil else { return }
        var loaded = try DicomIngestJSONL.read(DicomIngestRecord.self, path: path, fileSystem: fileSystem)
        // issue #2532: each pair is one durable append, so a torn tail cannot replace only one receipt.
        for pair in try DicomIngestJSONL.read([DicomIngestRecord].self,
            path: path.appendingPathExtension("promotions"), fileSystem: fileSystem) {
            guard pair.count == 2 else { throw DicomIngestError.invalidJournal }
            try dicomApplyPromotion(canonical: pair[0], conflict: pair[1], to: &loaded)
        }
        objects = loaded
        byUID = Dictionary(grouping: loaded, by: \.sopInstanceUID)
        byID = Dictionary(loaded.map { ($0.ingestID, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public func promote(canonical: DicomIngestRecord, conflict: DicomIngestRecord) throws {
        try loadIfNeeded()
        var updated = objects ?? []
        try dicomApplyPromotion(canonical: canonical, conflict: conflict, to: &updated)
        do {
            try DicomIngestJSONL.append([canonical, conflict],
                path: path.appendingPathExtension("promotions"), fileSystem: fileSystem)
        } catch { objects = nil; throw error }
        objects = updated
        byUID = Dictionary(grouping: updated, by: \.sopInstanceUID)
        byID = Dictionary(updated.map { ($0.ingestID, $0) }, uniquingKeysWith: { _, last in last })
    }
    public func records() throws -> [DicomIngestRecord] {
        try loadIfNeeded()
        return try retained(objects ?? [])
    }
    public func records(sopInstanceUID: String) throws -> [DicomIngestRecord] {
        try loadIfNeeded()
        return try retained(byUID[sopInstanceUID] ?? [])
    }
    private func retained(_ records: [DicomIngestRecord]) throws -> [DicomIngestRecord] {
        // Issue #2530: preserve the append-only history while excluding conflicts discarded by retention.
        try records.filter {
            guard $0.isConflict else { return true }
            return try fileSystem.exists($0.path)
        }
    }
    public func classify(sopInstanceUID: String, contentSHA256: String) throws -> DicomIngestClassification {
        dicomIngestClassify(try records(sopInstanceUID: sopInstanceUID), uid: sopInstanceUID, hash: contentSHA256)
    }
    public func register(_ record: DicomIngestRecord) throws -> DicomIngestClassification {
        try loadIfNeeded()
        if let previous = byID[record.ingestID] {
            guard previous == record else { throw DicomIngestError.invalidJournal }
            // Retry may follow a failed synchronization of an otherwise complete append.
            try fileSystem.fsyncFile(path)
            try fileSystem.fsyncDirectory(path.deletingLastPathComponent())
            return record.isConflict ? .conflict(existingSHA256: nil) : .new
        }
        let classification = try classify(sopInstanceUID: record.sopInstanceUID, contentSHA256: record.contentSHA256)
        if case .duplicate = classification { return classification }
        if case .conflict = classification, !record.isConflict { return classification }
        do { try DicomIngestJSONL.append(record, path: path, fileSystem: fileSystem) }
        catch {
            // The write may have completed before fsync failed; reload before an idempotent retry.
            objects = nil
            throw error
        }
        objects?.append(record)
        byUID[record.sopInstanceUID, default: []].append(record)
        byID[record.ingestID] = record
        return classification
    }
}

// issue #2532: accepting either orientation permits registrar retry after a commit with a lost acknowledgement.
private func dicomApplyPromotion(canonical: DicomIngestRecord, conflict: DicomIngestRecord,
                                 to records: inout [DicomIngestRecord]) throws {
    let pairs = [(canonical, canonical.replacingContent(with: conflict)),
                 (conflict, conflict.replacingContent(with: canonical))]
    let indices = try pairs.map { before, after in
        guard let index = records.firstIndex(where: { $0.ingestID == before.ingestID }),
              records[index] == before || records[index] == after else { throw DicomIngestError.invalidJournal }
        return index
    }
    for (index, pair) in zip(indices, pairs) { records[index] = pair.1 }
}
