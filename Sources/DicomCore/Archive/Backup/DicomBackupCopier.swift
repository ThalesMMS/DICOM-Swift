import Foundation

public actor DicomBackupCopier {
    public struct CopyReport: Sendable {
        public let copied: [String]
        public let failed: [(objectKey: String, reason: String)]
        public let inventoryID: String
        public let destinationProviderID: String
        let inventorySHA256: String
        let bytes: Int64
        let complete: Bool
    }
    public init() {}

    /// At most two objects transfer concurrently. Provider atomic publication leaves no partial object;
    /// already completed objects remain on cancellation and are never silently deleted.
    public func copy(inventory: DicomBackupInventory, from source: any DicomStorageProvider,
                     to destination: any DicomStorageProvider,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> CopyReport {
        try inventory.validate()
        let fs = DicomLocalIngestFileSystem()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fs.createDirectory(scratch)
        defer { try? fs.remove(scratch) }
        var copied: [String] = []
        var failed: [(objectKey: String, reason: String)] = []
        for start in stride(from: 0, to: inventory.objects.count, by: 2) {
            try StoragePath.checkCancellation(isCancelled)
            let batch = inventory.objects[start..<min(start + 2, inventory.objects.count)]
            let results = await withTaskGroup(of: (String, String?).self) { group in
                for object in batch {
                    group.addTask {
                        let temp = scratch.appendingPathComponent(UUID().uuidString)
                        defer { try? fs.remove(temp) }
                        do {
                            _ = try await source.get(object.sourceLocator, to: temp,
                                expectedSHA256: object.sha256, isCancelled: isCancelled)
                            let info = try StoragePath.info(temp, locator: object.objectKey, fileSystem: fs)
                            guard info.byteCount == object.byteCount, info.sha256 == object.sha256 else {
                                throw DicomStorageProviderError.integrity(object.objectKey)
                            }
                            try await Self.putIfNeeded(temp, locator: object.objectKey, sha256: object.sha256,
                                byteCount: object.byteCount, to: destination, isCancelled: isCancelled)
                            return (object.objectKey, nil)
                        } catch { return (object.objectKey, String(describing: error)) }
                    }
                }
                var results: [(String, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (key, error) in results {
                if let error { failed.append((key, error)) } else { copied.append(key) }
            }
        }
        try StoragePath.checkCancellation(isCancelled)
        let hash = try inventory.inventorySHA256
        let temp = scratch.appendingPathComponent(DicomBackupInventory.fileName)
        try fs.write(inventory.encode(), to: temp)
        // The inventory is the final publication, even for a report containing failed members.
        try await Self.putIfNeeded(temp, locator: DicomBackupInventory.fileName, sha256: hash,
            byteCount: Int64(try inventory.encode().count), to: destination, isCancelled: isCancelled)
        return .init(copied: copied.sorted(), failed: failed.sorted { $0.objectKey < $1.objectKey },
            inventoryID: inventory.inventoryID, destinationProviderID: destination.id,
            inventorySHA256: hash, bytes: inventory.bytes, complete: failed.isEmpty)
    }

    private static func putIfNeeded(_ source: URL, locator: String, sha256: String, byteCount: Int64,
                                    to destination: any DicomStorageProvider,
                                    isCancelled: @Sendable () -> Bool) async throws {
        try StoragePath.checkCancellation(isCancelled)
        if let existing = try await destination.head(locator) {
            guard existing.sha256 == sha256, existing.byteCount == byteCount else {
                throw DicomStorageProviderError.integrity(locator)
            }
            return
        }
        _ = try await destination.put(source, locator: locator, expectedSHA256: sha256, isCancelled: isCancelled)
    }
}
