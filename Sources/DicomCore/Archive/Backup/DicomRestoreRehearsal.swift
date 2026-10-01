import Foundation

public actor DicomRestoreRehearsal {
    public struct RehearsalReport: Sendable {
        public enum Status: String, Sendable { case ok, failed }
        public let reopened: Int
        public let failed: [(objectKey: String, reason: String)]
        public let inventoryID: String
        public let destinationProviderID: String
        let inventorySHA256: String
        let bytes: Int64
        public var status: Status { failed.isEmpty ? .ok : .failed }
    }
    public init() {}
    public func rehearse(inventory: DicomBackupInventory, from destination: any DicomStorageProvider,
                         into cleanDirectory: URL, removeAfter: Bool = false,
                         isCancelled: @Sendable () -> Bool = { false }) async throws -> RehearsalReport {
        try inventory.validate()
        let fs = DicomLocalIngestFileSystem()
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: cleanDirectory.path)) == nil else {
            throw DicomStorageProviderError.io("Symbolic link rehearsal directory")
        }
        if try fs.exists(cleanDirectory), try !fs.contentsOf(cleanDirectory).isEmpty {
            throw DicomStorageProviderError.destinationExists
        }
        try fs.createDirectory(cleanDirectory)
        defer { if removeAfter { try? fs.remove(cleanDirectory) } }
        var reopened = 0
        var failed: [(objectKey: String, reason: String)] = []
        for object in inventory.objects {
            try StoragePath.checkCancellation(isCancelled)
            do {
                let ref = object.references
                let locator: String
                if ref.role == .representation {
                    let key = DicomStudyPackageManifest.digest(Data(object.objectKey.utf8))
                    locator = "Representations/\(key).dcm"
                } else {
                    locator = !ref.studyInstanceUID.isEmpty && !ref.seriesInstanceUID.isEmpty && !ref.sopInstanceUID.isEmpty
                        ? "\(ref.studyInstanceUID)/\(ref.seriesInstanceUID)/\(ref.sopInstanceUID).dcm" : object.sourceLocator
                }
                let target = try StoragePath.resolve(locator, root: cleanDirectory)
                try fs.createDirectory(target.deletingLastPathComponent())
                // Download against the observed hash so a different valid Part 10 identity can be diagnosed
                // before the final comparison to the inventory's expected hash.
                guard let observed = try await destination.head(object.objectKey) else {
                    throw DicomStorageProviderError.notFound(object.objectKey)
                }
                _ = try await destination.get(object.objectKey, to: target,
                    expectedSHA256: observed.sha256 ?? object.sha256, isCancelled: isCancelled)
                let actual = try DicomObjectReference.read(from: target, role: ref.role)
                guard actual == ref else { throw DicomStorageProviderError.integrity("identity mismatch") }
                let info = try StoragePath.info(target, locator: locator, fileSystem: fs)
                guard info.sha256 == object.sha256, info.byteCount == object.byteCount else {
                    throw DicomStorageProviderError.integrity("byte mismatch")
                }
                reopened += 1
            } catch DicomStorageProviderError.cancelled { throw DicomStorageProviderError.cancelled }
            catch { failed.append((object.objectKey, String(describing: error))) }
        }
        try StoragePath.checkCancellation(isCancelled)
        return .init(reopened: reopened, failed: failed, inventoryID: inventory.inventoryID,
            destinationProviderID: destination.id, inventorySHA256: try inventory.inventorySHA256,
            bytes: inventory.bytes)
    }
}
