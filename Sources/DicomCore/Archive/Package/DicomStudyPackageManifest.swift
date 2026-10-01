import Foundation
import CryptoKit

public struct DicomStudyPackageManifest: Codable, Sendable, Equatable {
    public static let manifestEntryName = "manifest.json"
    public struct StudyRef: Codable, Sendable, Equatable {
        public var studyInstanceUID: String
        public var series: [String: [String]]
        public init(studyInstanceUID: String, series: [String: [String]]) {
            self.studyInstanceUID = studyInstanceUID
            self.series = series
        }
    }
    public struct Entry: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable { case original, representation, dicomdir, other }
        public var relativePath: String
        public var role: Role
        public var sopInstanceUID: String?
        public var sopClassUID: String?
        public var transferSyntaxUID: String?
        public var byteCount: Int64
        public var sha256: String
        public var sourceRepresentation: String?
        public init(relativePath: String, role: Role, sopInstanceUID: String? = nil, sopClassUID: String? = nil,
                    transferSyntaxUID: String? = nil, byteCount: Int64, sha256: String,
                    sourceRepresentation: String? = nil) {
            self.relativePath = relativePath
            self.role = role
            self.sopInstanceUID = sopInstanceUID
            self.sopClassUID = sopClassUID
            self.transferSyntaxUID = transferSyntaxUID
            self.byteCount = byteCount
            self.sha256 = sha256
            self.sourceRepresentation = sourceRepresentation
        }
    }
    public struct Totals: Codable, Sendable, Equatable {
        public var entryCount: Int
        public var byteCount: Int64
        public init(entryCount: Int, byteCount: Int64) { self.entryCount = entryCount; self.byteCount = byteCount }
    }
    public var formatVersion: Int
    public var packageID: String
    public var createdAt: String
    public var producer: String
    public var studies: [StudyRef]
    public var entries: [Entry]
    /// Totals cover payload entries, including DICOMDIR, excluding the manifest itself.
    public var totals: Totals

    public init(formatVersion: Int = 1, packageID: String = UUID().uuidString,
                createdAt: String = ISO8601DateFormatter().string(from: Date()), producer: String,
                studies: [StudyRef], entries: [Entry], totals: Totals) {
        self.formatVersion = formatVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.producer = producer
        self.studies = studies
        self.entries = entries
        self.totals = totals
    }
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw DicomStudyPackageError.manifestInvalid("Invalid JSON manifest") }
    }
    public var manifestSHA256: String { get throws { Self.digest(try encode()) } }
    internal static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    internal static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
