import Foundation

public protocol DicomObjectStore: Sendable {
    func putObject(key: String, from source: URL, sha256: String) async throws -> DicomStorageObjectInfo
    /// Each attempt owns the supplied, initially absent file; failures may leave partial bytes there.
    func getObject(key: String, to destination: URL) async throws -> DicomStorageObjectInfo
    func headObject(key: String) async throws -> DicomStorageObjectInfo?
    func listObjects(prefix: String) async throws -> [DicomStorageObjectInfo]
    func deleteObject(key: String) async throws
}

public struct DicomObjectTransferPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let retryable: @Sendable (any Error) -> Bool

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.2, maxDelay: TimeInterval = 5,
                retryable: @escaping @Sendable (any Error) -> Bool = {
                    if case .unreachable = $0 as? DicomStorageProviderError { return true }
                    return false
                }) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay.isFinite ? max(0, baseDelay) : 0.2
        self.maxDelay = maxDelay.isFinite ? max(0, maxDelay) : 5
        self.retryable = retryable
    }
}

public final class DicomObjectStoreProvider: DicomStorageProvider {
    public let id: String
    public let tier: DicomStorageTier
    public let capabilities: DicomStorageCapabilities
    private let store: any DicomObjectStore
    private let policy: DicomObjectTransferPolicy
    private let fileSystem: any DicomIngestFileSystem

    public init(id: String, store: any DicomObjectStore, tier: DicomStorageTier = .offline,
                capabilities: DicomStorageCapabilities = .init(randomAccess: false, atomicRename: false,
                    checksumOnHead: false, latency: .archive, removable: false),
                policy: DicomObjectTransferPolicy = .init(),
                fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.id = id
        self.store = store
        self.tier = tier
        self.capabilities = capabilities
        self.policy = policy
        self.fileSystem = fileSystem
    }

    private func retry<T: Sendable>(isCancelled: @Sendable () -> Bool = { false },
                                    _ operation: () async throws -> T) async throws -> T {
        var delay = min(policy.baseDelay, policy.maxDelay)
        for attempt in 1...policy.maxAttempts {
            try StoragePath.checkCancellation(isCancelled)
            do { return try await operation() }
            catch {
                try StoragePath.checkCancellation(isCancelled)
                if error is CancellationError { throw DicomStorageProviderError.cancelled }
                if let error = error as? DicomStorageProviderError {
                    switch error {
                    case .integrity, .cancelled: throw error
                    default: break
                    }
                }
                guard attempt < policy.maxAttempts, policy.retryable(error) else { throw StoragePath.mapped(error) }
                // Short slices also observe caller cancellation during a long backoff.
                var remaining = delay
                while remaining > 0 {
                    try StoragePath.checkCancellation(isCancelled)
                    let slice = min(remaining, 0.05)
                    do { try await Task.sleep(for: .seconds(slice)) }
                    catch { throw DicomStorageProviderError.cancelled }
                    remaining -= slice
                }
                delay = min(policy.maxDelay, delay * 2)
            }
        }
        throw DicomStorageProviderError.io("Retry budget exhausted")
    }

    public func head(_ locator: String) async throws -> DicomStorageObjectInfo? {
        try await retry { try await store.headObject(key: locator) }
    }
    public func list(prefix: String) async throws -> [DicomStorageObjectInfo] {
        try await retry { try await store.listObjects(prefix: prefix) }
    }
    public func reachability() async -> DicomProviderReachability {
        do { _ = try await list(prefix: ""); return .reachable }
        catch { return .unreachable(String(describing: error)) }
    }
    public func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        guard !authorization.token.isEmpty else { throw DicomStorageProviderError.deleteNotAuthorized }
        try await retry { try await store.deleteObject(key: locator) }
    }
    public func put(_ source: URL, locator: String, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        try StoragePath.checkCancellation(isCancelled)
        let local = try StoragePath.info(source, locator: locator, fileSystem: fileSystem)
        guard local.sha256 == expectedSHA256.lowercased() else { throw DicomStorageProviderError.integrity(locator) }
        if let limit = capabilities.maxObjectBytes, local.byteCount > limit { throw DicomStorageProviderError.capacity }
        return try await retry(isCancelled: isCancelled) {
            let result = try await store.putObject(key: locator, from: source, sha256: expectedSHA256.lowercased())
            guard result.byteCount == local.byteCount,
                  result.sha256?.lowercased() == expectedSHA256.lowercased() else {
                throw DicomStorageProviderError.integrity(locator)
            }
            return result
        }
    }
    public func get(_ locator: String, to destination: URL, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        guard try !fileSystem.exists(destination), try !fileSystem.exists(partial) else {
            throw DicomStorageProviderError.destinationExists
        }
        // The remote adapter receives a unique attempt file; it cannot replace the final destination.
        let download = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
        var ownsPartial = false
        defer {
            try? fileSystem.remove(download)
            if ownsPartial { try? fileSystem.remove(partial) }
        }
        let info = try await retry(isCancelled: isCancelled) {
            if try fileSystem.exists(download) { try fileSystem.remove(download) }
            let reported = try await store.getObject(key: locator, to: download)
            let actual = try StoragePath.info(download, locator: locator, fileSystem: fileSystem)
            guard actual.sha256 == expectedSHA256.lowercased(), actual.byteCount == reported.byteCount else {
                throw DicomStorageProviderError.integrity(locator)
            }
            if let limit = capabilities.maxObjectBytes, actual.byteCount > limit { throw DicomStorageProviderError.capacity }
            return actual
        }
        try StoragePath.checkCancellation(isCancelled)
        try fileSystem.rename(download, to: partial)
        ownsPartial = true
        try fileSystem.fsyncFile(partial)
        try StoragePath.checkCancellation(isCancelled)
        try fileSystem.rename(partial, to: destination)
        try fileSystem.fsyncDirectory(destination.deletingLastPathComponent())
        return info
    }
}

/// A local witness for remote adapters. The caller creates and owns the root directory.
public final class DicomDirectoryObjectStore: DicomObjectStore {
    private let local: DicomLocalDiskProvider
    public init(root: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        local = .init(id: "directory-object-store", root: root, tier: .offline, fileSystem: fileSystem)
    }
    public func putObject(key: String, from source: URL, sha256: String) async throws -> DicomStorageObjectInfo {
        // Idempotent retry of an upload acknowledged ambiguously; never replace differing bytes.
        if let existing = try await local.head(key) {
            guard existing.sha256 == sha256.lowercased() else { throw DicomStorageProviderError.destinationExists }
            return existing
        }
        return try await local.put(source, locator: key, expectedSHA256: sha256)
    }
    public func getObject(key: String, to destination: URL) async throws -> DicomStorageObjectInfo {
        guard let info = try await local.head(key), let hash = info.sha256 else {
            throw DicomStorageProviderError.notFound(key)
        }
        return try await local.get(key, to: destination, expectedSHA256: hash)
    }
    public func headObject(key: String) async throws -> DicomStorageObjectInfo? { try await local.head(key) }
    public func listObjects(prefix: String) async throws -> [DicomStorageObjectInfo] { try await local.list(prefix: prefix) }
    public func deleteObject(key: String) async throws {
        try await local.delete(key, authorization: .init(token: "adapter", reason: "Authorized by provider caller"))
    }
}
