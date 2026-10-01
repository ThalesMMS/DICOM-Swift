import Foundation

public struct DicomStorageCapabilities: Codable, Equatable, Sendable {
    public enum Latency: String, Codable, Sendable { case local, network, archive }
    public var randomAccess: Bool
    public var atomicRename: Bool
    public var checksumOnHead: Bool
    public var latency: Latency
    public var removable: Bool
    public var maxObjectBytes: Int64?

    public init(randomAccess: Bool, atomicRename: Bool, checksumOnHead: Bool, latency: Latency,
                removable: Bool, maxObjectBytes: Int64? = nil) {
        self.randomAccess = randomAccess
        self.atomicRename = atomicRename
        self.checksumOnHead = checksumOnHead
        self.latency = latency
        self.removable = removable
        self.maxObjectBytes = maxObjectBytes
    }
}

public struct DicomStorageObjectInfo: Codable, Equatable, Sendable {
    public var locator: String
    public var byteCount: Int64
    public var sha256: String?
    public var modifiedAt: Date?

    public init(locator: String, byteCount: Int64, sha256: String? = nil, modifiedAt: Date? = nil) {
        self.locator = locator
        self.byteCount = byteCount
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
    }
}

public struct DicomDeleteAuthorization: Sendable {
    public let token: String
    public let reason: String
    public init(token: String, reason: String) { self.token = token; self.reason = reason }
}

public enum DicomProviderReachability: Equatable, Sendable {
    case reachable
    case unreachable(String)
}

public enum DicomStorageProviderError: Error, Equatable, Sendable {
    case unreachable(String), notFound(String), integrity(String)
    case destinationExists, capacity, deleteNotAuthorized, cancelled, io(String)
}

public protocol DicomStorageProvider: Sendable {
    var id: String { get }
    var tier: DicomStorageTier { get }
    var capabilities: DicomStorageCapabilities { get }
    /// Nil means the provider was reachable and verified the object's absence.
    func head(_ locator: String) async throws -> DicomStorageObjectInfo?
    func put(_ source: URL, locator: String, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo
    /// Publish only after verifying a partial sibling. Never replace an existing destination.
    func get(_ locator: String, to destination: URL, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo
    func list(prefix: String) async throws -> [DicomStorageObjectInfo]
    func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws
    func reachability() async -> DicomProviderReachability
}
