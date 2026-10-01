import Foundation

/// Every line repeats the complete recovery metadata. No dataset or patient attributes are stored.
public struct DicomIngestJournalEntry: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case intent, done }
    public enum Disposition: String, Codable, Sendable { case duplicate, quarantined, discarded }
    public var ingestID: UUID
    public var stage: DicomIngestStage
    public var phase: Phase
    public var root: URL
    public var temporaryPath: URL
    public var finalPath: URL?
    public var checksum: String?
    public var sopClassUID: String?
    public var sopInstanceUID: String?
    public var transferSyntaxUID: String?
    public var conflictSHA256: String?
    public var disposition: Disposition?
    // issue #2532: both pre-swap receipts make replay independent of the last acknowledged checkpoint.
    public var promotionCanonical: DicomIngestRecord?
    public var promotionConflict: DicomIngestRecord?
    public var timestamp: Date

    public init(ingestID: UUID = UUID(), root: URL) {
        self.ingestID = ingestID; self.root = root
        temporaryPath = root.appendingPathComponent(".ingest/\(ingestID.uuidString).part")
        stage = .received; phase = .intent; timestamp = Date()
    }
}

public protocol DicomIngestJournaling: Sendable {
    var isDurable: Bool { get }
    func append(_ entry: DicomIngestJournalEntry) async throws
    /// All entries must be durable on return; implementations may share one commit.
    func append(contentsOf entries: [DicomIngestJournalEntry]) async throws
    func entries() async throws -> [DicomIngestJournalEntry]
    /// What `DicomIngestRecovery.replay` has to look at. The default is the whole history; a journal
    /// that keeps history for years may return only the latest entry of every ingest that replay
    /// would act on or report, which leaves out the ones that ended `registered`/`done` or
    /// discarded/`done`.
    func replayCandidates() async throws -> [DicomIngestJournalEntry]
}

public extension DicomIngestJournaling {
    func replayCandidates() async throws -> [DicomIngestJournalEntry] { try await entries() }

    func append(contentsOf entries: [DicomIngestJournalEntry]) async throws {
        for entry in entries { try await append(entry) }
    }
}

public actor DicomInMemoryIngestJournal: DicomIngestJournaling {
    public nonisolated let isDurable = false
    private var log: [DicomIngestJournalEntry] = []
    public init() {}
    public func append(_ entry: DicomIngestJournalEntry) { log.append(entry) }
    public func entries() -> [DicomIngestJournalEntry] { log }
}

/// One owner per journal file. Torn final appends are ignored, then explicitly delimited on the next append.
public actor DicomJSONLIngestJournal: DicomIngestJournaling {
    public nonisolated let isDurable = true
    private let path: URL
    private let fileSystem: any DicomIngestFileSystem
    public init(path: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) throws {
        self.path = path; self.fileSystem = fileSystem
        try fileSystem.createDirectory(path.deletingLastPathComponent())
        try fileSystem.fsyncDirectory(path.deletingLastPathComponent().deletingLastPathComponent())
    }
    public func append(_ entry: DicomIngestJournalEntry) throws {
        try DicomIngestJSONL.append(entry, path: path, fileSystem: fileSystem)
    }
    public func entries() throws -> [DicomIngestJournalEntry] {
        try DicomIngestJSONL.read(DicomIngestJournalEntry.self, path: path, fileSystem: fileSystem)
    }
}

enum DicomIngestJSONL {
    static let tornMarker = Data("{\"discardedTail\":true}".utf8)
    static func append<T: Encodable>(_ value: T, path: URL, fileSystem: any DicomIngestFileSystem) throws {
        var data = Data()
        if try fileSystem.exists(path) {
            if let previous = try fileSystem.lastByte(path), previous != 10 {
                data.append(10); data.append(tornMarker); data.append(10)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        data.append(try encoder.encode(value)); data.append(10)
        try fileSystem.write(data, to: path, append: true)
        try fileSystem.fsyncFile(path)
        try fileSystem.fsyncDirectory(path.deletingLastPathComponent())
    }
    static func read<T: Decodable>(_ type: T.Type, path: URL, fileSystem: any DicomIngestFileSystem) throws -> [T] {
        guard try fileSystem.exists(path) else { return [] }
        let data = try fileSystem.read(path)
        let lines = Array(data).split(separator: UInt8(10), omittingEmptySubsequences: false).map { Data($0) }
        var result: [T] = []
        for (index, line) in lines.enumerated() where !line.isEmpty && line != tornMarker {
            // An unterminated record has no acknowledged append boundary.
            if index == lines.count - 1, data.last != 10 { break }
            if let value = try? JSONDecoder().decode(type, from: line) { result.append(value) }
            else if index + 1 < lines.count, lines[index + 1] == tornMarker { continue }
            else { throw DicomIngestError.invalidJournal }
        }
        return result
    }
}
