import Foundation

public final class DicomNetworkVolumeProvider: DicomStorageProvider, StoragePartialCleaning {
    public var id: String { local.id }
    public var tier: DicomStorageTier { local.tier }
    public let capabilities = DicomStorageCapabilities(randomAccess: true, atomicRename: true,
        checksumOnHead: true, latency: .network, removable: true)
    private let local: DicomLocalDiskProvider
    private let fileSystem: any DicomIngestFileSystem

    public init(id: String, root: URL, tier: DicomStorageTier = .nearline,
                fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.local = .init(id: id, root: root, tier: tier, fileSystem: fileSystem)
        self.fileSystem = fileSystem
    }

    public func reachability() async -> DicomProviderReachability {
        do {
            guard try fileSystem.exists(local.root) else { return .unreachable(id) }
            _ = try fileSystem.contentsOf(local.root)
            return .reachable
        } catch { return .unreachable(id) }
    }

    private func checked<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        guard await reachability() == .reachable else { throw DicomStorageProviderError.unreachable(id) }
        do { return try await operation() }
        catch {
            guard await reachability() == .reachable else { throw DicomStorageProviderError.unreachable(id) }
            // Transport/I/O failures never establish object absence.
            if case .io = error as? DicomStorageProviderError { throw DicomStorageProviderError.unreachable(id) }
            throw error
        }
    }

    public func head(_ locator: String) async throws -> DicomStorageObjectInfo? {
        try await checked { try await local.head(locator) }
    }
    public func put(_ source: URL, locator: String, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        try await checked { try await local.put(source, locator: locator, expectedSHA256: expectedSHA256, isCancelled: isCancelled) }
    }
    public func get(_ locator: String, to destination: URL, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        try await checked { try await local.get(locator, to: destination, expectedSHA256: expectedSHA256, isCancelled: isCancelled) }
    }
    public func list(prefix: String) async throws -> [DicomStorageObjectInfo] {
        try await checked { try await local.list(prefix: prefix) }
    }
    func discardPartial(_ locator: String) async throws {
        try await checked { try await local.discardPartial(locator) }
    }
    public func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        try await checked { try await local.delete(locator, authorization: authorization) }
    }
}
