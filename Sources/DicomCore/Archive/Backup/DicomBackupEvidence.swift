import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DicomBackupEvidence: Codable, Equatable, Sendable {
    public struct Mark: Codable, Equatable, Sendable {
        public let at: Date
        public let byObjects: Int
        public let bytes: Int64
        public let detail: String
        init(at: Date = Date(), byObjects: Int, bytes: Int64, detail: String) {
            self.at = at; self.byObjects = byObjects; self.bytes = bytes; self.detail = detail
        }
    }
    public enum Status: String, Codable, Sendable { case none, copied, verified, restoreRehearsed, inconsistent }
    public let inventoryID: String
    public let destinationProviderID: String
    public private(set) var copied: Mark?
    public private(set) var verified: Mark?
    public private(set) var restoreRehearsed: Mark?
    private var inventorySHA256: String?

    public init(inventoryID: String, destinationProviderID: String) {
        self.inventoryID = inventoryID; self.destinationProviderID = destinationProviderID
    }
    public var status: Status {
        if (verified != nil && copied == nil) || (restoreRehearsed != nil && (copied == nil || verified == nil)) {
            return .inconsistent
        }
        if restoreRehearsed != nil { return .restoreRehearsed }
        if verified != nil { return .verified }
        return copied == nil ? .none : .copied
    }
    private mutating func bind(_ inventoryID: String, _ providerID: String, _ hash: String) throws {
        guard inventoryID == self.inventoryID, providerID == destinationProviderID,
              inventorySHA256 == nil || inventorySHA256 == hash else {
            throw DicomStorageProviderError.integrity("Evidence report identity mismatch")
        }
        inventorySHA256 = hash
    }
    public mutating func recordCopied(report: DicomBackupCopier.CopyReport) throws {
        guard report.complete, report.failed.isEmpty else {
            throw DicomStorageProviderError.integrity("Incomplete copy report")
        }
        try bind(report.inventoryID, report.destinationProviderID, report.inventorySHA256)
        copied = .init(byObjects: report.copied.count, bytes: report.bytes, detail: "Bytes transferred")
    }
    public mutating func recordVerified(report: DicomBackupVerifier.VerifyReport) throws {
        try bind(report.inventoryID, report.destinationProviderID, report.inventorySHA256)
        guard report.status == .verified else {
            verified = nil
            restoreRehearsed = nil
            throw DicomStorageProviderError.integrity("Failed verification report")
        }
        verified = .init(byObjects: report.verifiedObjects, bytes: report.bytes, detail: "Independent re-read and SHA-256")
    }
    /// Additive async recording boundary; the synchronous API remains available to existing hosts.
    public mutating func recordVerified(report: DicomBackupVerifier.VerifyReport,
                                        lifecycle: (any DicomLifecycleEventEmitting)?) async throws {
        let previous = verified
        try recordVerified(report: report)
        if previous == nil, status == .verified, let lifecycle {
            let event = try DicomLifecycleEvent(kind: .archived,
                subject: .init(objectCount: report.verifiedObjects), sourceKind: "backup",
                sourceRef: inventoryID, occurredAt: verified!.at)
            await lifecycle.emit(event)
        }
    }
    public mutating func recordRehearsed(report: DicomRestoreRehearsal.RehearsalReport) throws {
        guard report.status == .ok else { throw DicomStorageProviderError.integrity("Failed rehearsal report") }
        try bind(report.inventoryID, report.destinationProviderID, report.inventorySHA256)
        restoreRehearsed = .init(byObjects: report.reopened, bytes: report.bytes, detail: "Restored and reopened Part 10 objects")
    }
}

/// One owner per directory. JSON is historical evidence, not an authenticated authorization credential.
public final class DicomBackupEvidenceStore: @unchecked Sendable {
    public let directory: URL
    private let fileSystem: any DicomIngestFileSystem
    private let lock = NSLock()
    public init(directory: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.directory = directory; self.fileSystem = fileSystem
    }
    private func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw DicomStorageProviderError.io("Invalid inventory ID") }
        return try StoragePath.resolve(id + ".json", root: directory)
    }
    public func load(inventoryID: String) throws -> DicomBackupEvidence {
        lock.lock(); defer { lock.unlock() }
        let result = try JSONDecoder().decode(DicomBackupEvidence.self, from: fileSystem.read(url(inventoryID)))
        guard result.inventoryID == inventoryID else { throw DicomStorageProviderError.integrity("Evidence ID mismatch") }
        return result
    }
    public func save(_ evidence: DicomBackupEvidence) throws {
        lock.lock(); defer { lock.unlock() }
        let destination = try url(evidence.inventoryID)
        try fileSystem.createDirectory(directory)
        let temp = directory.appendingPathComponent(UUID().uuidString + ".partial")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fileSystem.write(encoder.encode(evidence), to: temp, append: false)
        defer { try? fileSystem.remove(temp) }
        try fileSystem.fsyncFile(temp)
        if try fileSystem.exists(destination) {
            // Ingest rename is exclusive; use atomic replacement, as in the A2 journal.
            #if canImport(Darwin)
            let result = Darwin.rename(temp.path, destination.path)
            #else
            let result = Glibc.rename(temp.path, destination.path)
            #endif
            guard result == 0 else { throw DicomStorageProviderError.io("Evidence atomic replacement failed") }
        } else { try fileSystem.rename(temp, to: destination) }
        try fileSystem.fsyncDirectory(directory)
    }
}
