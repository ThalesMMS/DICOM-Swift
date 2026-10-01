import Foundation

public actor DicomBackupVerifier {
    public struct VerifyReport: Sendable {
        public enum Status: String, Sendable { case verified, failed }
        public let verifiedObjects: Int
        public let mismatched: [String]
        public let missing: [String]
        public let unexpected: [String]
        public let inventoryID: String
        public let destinationProviderID: String
        let inventorySHA256: String
        let bytes: Int64
        public var status: Status {
            mismatched.isEmpty && missing.isEmpty && unexpected.isEmpty ? .verified : .failed
        }
    }
    public init() {}
    /// The provider root is the inventory's destination prefix. Head checks do not earn verification.
    public func verify(inventory: DicomBackupInventory, at destination: any DicomStorageProvider,
                       scratch: URL, isCancelled: @Sendable () -> Bool = { false }) async throws -> VerifyReport {
        try inventory.validate()
        let fs = DicomLocalIngestFileSystem()
        let work = scratch.appendingPathComponent(UUID().uuidString)
        try fs.createDirectory(work)
        defer { try? fs.remove(work) }
        var verified = 0
        var mismatched: [String] = []
        var missing: [String] = []
        let inventorySHA256 = try inventory.inventorySHA256
        let files = inventory.objects.map {
            (objectKey: $0.objectKey, byteCount: $0.byteCount, sha256: $0.sha256)
        } + [(objectKey: DicomBackupInventory.fileName, byteCount: Int64(try inventory.encode().count),
              sha256: inventorySHA256)]
        for object in files {
            try StoragePath.checkCancellation(isCancelled)
            let temp = work.appendingPathComponent(UUID().uuidString)
            defer { try? fs.remove(temp) }
            do {
                guard try await destination.head(object.objectKey) != nil else {
                    missing.append(object.objectKey); continue
                }
                _ = try await destination.get(object.objectKey, to: temp, expectedSHA256: object.sha256,
                                              isCancelled: isCancelled)
                let info = try StoragePath.info(temp, locator: object.objectKey, fileSystem: fs)
                guard info.byteCount == object.byteCount, info.sha256 == object.sha256 else {
                    throw DicomStorageProviderError.integrity(object.objectKey)
                }
                if object.objectKey != DicomBackupInventory.fileName { verified += 1 }
            } catch DicomStorageProviderError.cancelled { throw DicomStorageProviderError.cancelled }
            catch DicomStorageProviderError.notFound { missing.append(object.objectKey) }
            catch { mismatched.append(object.objectKey) }
        }
        let expected = Set(inventory.objects.map(\.objectKey) + [DicomBackupInventory.fileName])
        var unexpected: [String] = []
        for info in try await destination.list(prefix: "") where !expected.contains(info.locator) {
            try StoragePath.checkCancellation(isCancelled)
            if try await destination.head(info.locator) != nil { unexpected.append(info.locator) }
        }
        try StoragePath.checkCancellation(isCancelled)
        return .init(verifiedObjects: verified, mismatched: mismatched, missing: missing,
            unexpected: unexpected.sorted(), inventoryID: inventory.inventoryID,
            destinationProviderID: destination.id, inventorySHA256: inventorySHA256,
            bytes: inventory.bytes)
    }
}
