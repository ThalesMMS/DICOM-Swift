import Foundation

public struct DicomArchiveLimits: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case entries, memberBytes, totalBytes, manifestBytes, pathLength }
    public var maxEntries: Int
    public var maxTotalBytes: Int64
    public var maxMemberBytes: Int64
    public var maxManifestBytes: Int64
    public var maxPathLength: Int
    public static let `default` = Self()

    public init(maxEntries: Int = 20_000, maxTotalBytes: Int64 = 8 * 1024 * 1024 * 1024,
                maxMemberBytes: Int64 = 4 * 1024 * 1024 * 1024, maxManifestBytes: Int64 = 4 * 1024 * 1024,
                maxPathLength: Int = 1024) {
        self.maxEntries = maxEntries
        self.maxTotalBytes = maxTotalBytes
        self.maxMemberBytes = maxMemberBytes
        self.maxManifestBytes = maxManifestBytes
        self.maxPathLength = maxPathLength
    }
}
