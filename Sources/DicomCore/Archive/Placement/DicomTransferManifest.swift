import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DicomTransferManifest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case recall, prefetch, migrate, backup }
    public enum RecallState: Codable, Equatable, Hashable, Sendable {
        case pending, inFlight, verified, failed(String)
    }
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var objectKey: String
        public var sourceLocator: String
        public var destinationLocator: String
        public var byteCount: Int64
        public var sha256: String
        public var state: RecallState
        public init(objectKey: String, sourceLocator: String, destinationLocator: String,
                    byteCount: Int64, sha256: String, state: RecallState = .pending) {
            self.objectKey = objectKey
            self.sourceLocator = sourceLocator
            self.destinationLocator = destinationLocator
            self.byteCount = byteCount
            self.sha256 = sha256.lowercased()
            self.state = state
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(objectKey: try values.decode(String.self, forKey: .objectKey),
                sourceLocator: try values.decode(String.self, forKey: .sourceLocator),
                destinationLocator: try values.decode(String.self, forKey: .destinationLocator),
                byteCount: try values.decode(Int64.self, forKey: .byteCount),
                sha256: try values.decode(String.self, forKey: .sha256),
                state: try values.decode(RecallState.self, forKey: .state))
        }
    }
    public struct Totals: Codable, Equatable, Sendable {
        public let itemCount: Int
        public let byteCount: Int64
        public let verifiedItems: Int
        public let verifiedBytes: Int64
    }
    public var transferID: String
    public var kind: Kind
    public var createdAt: Date
    public var sourceProviderID: String
    public var destinationProviderID: String
    public var items: [Item]
    public var totals: Totals {
        .init(itemCount: items.count, byteCount: sum(items), verifiedItems: items.filter { $0.state == .verified }.count,
              verifiedBytes: sum(items.filter { $0.state == .verified }))
    }
    private func sum(_ items: [Item]) -> Int64 {
        items.reduce(0) { total, item in
            let (value, overflow) = total.addingReportingOverflow(max(0, item.byteCount))
            return overflow ? Int64.max : value
        }
    }
    public init(transferID: String = UUID().uuidString, kind: Kind = .recall, createdAt: Date = Date(),
                sourceProviderID: String, destinationProviderID: String, items: [Item]) {
        self.transferID = transferID
        self.kind = kind
        self.createdAt = createdAt
        self.sourceProviderID = sourceProviderID
        self.destinationProviderID = destinationProviderID
        self.items = items
    }
    private enum CodingKeys: String, CodingKey {
        case transferID, kind, createdAt, sourceProviderID, destinationProviderID, items, totals
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transferID = try values.decode(String.self, forKey: .transferID)
        kind = try values.decode(Kind.self, forKey: .kind)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourceProviderID = try values.decode(String.self, forKey: .sourceProviderID)
        destinationProviderID = try values.decode(String.self, forKey: .destinationProviderID)
        items = try values.decode([Item].self, forKey: .items)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(transferID, forKey: .transferID)
        try values.encode(kind, forKey: .kind)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(sourceProviderID, forKey: .sourceProviderID)
        try values.encode(destinationProviderID, forKey: .destinationProviderID)
        try values.encode(items, forKey: .items)
        try values.encode(totals, forKey: .totals)
    }
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// One JSON file per transfer. Callers must use one journal owner per directory at a time.
public final class DicomTransferJournal: @unchecked Sendable {
    public let directory: URL
    private let fileSystem: any DicomIngestFileSystem
    private let lock = NSRecursiveLock()

    public init(directory: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.directory = directory.standardizedFileURL
        self.fileSystem = fileSystem
    }
    private func url(_ transferID: String) throws -> URL {
        guard UUID(uuidString: transferID) != nil else { throw DicomPlacementError.journal("Invalid transfer ID") }
        return directory.appendingPathComponent(transferID + ".json")
    }
    public func save(_ manifest: DicomTransferManifest) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let destination = try url(manifest.transferID)
            try fileSystem.createDirectory(directory)
            let temp = directory.appendingPathComponent(UUID().uuidString + ".partial")
            try fileSystem.write(manifest.encode(), to: temp, append: false)
            defer { try? fileSystem.remove(temp) }
            try fileSystem.fsyncFile(temp)
            if try fileSystem.exists(destination) {
                // Ingest.rename is intentionally exclusive. Journal replacement needs POSIX atomic replacement,
                // preserving the previous complete JSON if publication fails (never remove then rename).
                #if canImport(Darwin)
                let result = Darwin.rename(temp.path, destination.path)
                #else
                let result = Glibc.rename(temp.path, destination.path)
                #endif
                guard result == 0 else { throw DicomPlacementError.journal("Atomic replacement failed") }
            } else { try fileSystem.rename(temp, to: destination) }
            try fileSystem.fsyncDirectory(directory)
        } catch { throw DicomPlacementError.journal(String(describing: error)) }
    }
    public func load(transferID: String) throws -> DicomTransferManifest {
        lock.lock()
        defer { lock.unlock() }
        do {
            let manifest = try JSONDecoder().decode(DicomTransferManifest.self, from: fileSystem.read(url(transferID)))
            guard manifest.transferID == transferID else { throw DicomPlacementError.journal("Transfer ID mismatch") }
            return manifest
        } catch { throw DicomPlacementError.journal(String(describing: error)) }
    }
    public func pending() throws -> [DicomTransferManifest] {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard try fileSystem.exists(directory) else { return [] }
            return try fileSystem.contentsOf(directory).filter { $0.pathExtension == "json" }
                .map { try load(transferID: $0.deletingPathExtension().lastPathComponent) }
                .filter { $0.items.contains { $0.state == .pending || $0.state == .inFlight } }
                .sorted { ($0.createdAt, $0.transferID) < ($1.createdAt, $1.transferID) }
        } catch { throw DicomPlacementError.journal(String(describing: error)) }
    }
}
