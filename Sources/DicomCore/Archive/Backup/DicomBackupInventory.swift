import Foundation

public struct DicomObjectReference: Codable, Equatable, Sendable {
    public typealias Role = DicomStudyPackageManifest.Entry.Role
    public let studyInstanceUID: String
    public let seriesInstanceUID: String
    public let sopInstanceUID: String
    public let sopClassUID: String
    public let role: Role

    public init(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                sopClassUID: String, role: Role = .original) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.sopClassUID = sopClassUID
        self.role = role
    }

    public static func read(from url: URL, role: Role = .original) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard DicomPart10FileMetaParser.hasPart10Prefix(data) else {
            throw DicomStorageProviderError.integrity("Not a Part 10 object")
        }
        let meta = try DicomPart10FileMetaParser.parse(data)
        let decoder = try DCMDecoder(contentsOf: url)
        let sop = decoder.info(for: .sopInstanceUID)
        let sopClass = decoder.info(for: .sopClassUID)
        guard !sop.isEmpty, !sopClass.isEmpty, meta.mediaStorageSOPInstanceUID == sop,
              meta.mediaStorageSOPClassUID == sopClass else {
            throw DicomStorageProviderError.integrity("Part 10 identity mismatch")
        }
        return .init(studyInstanceUID: decoder.info(for: .studyInstanceUID),
                     seriesInstanceUID: decoder.info(for: .seriesInstanceUID), sopInstanceUID: sop,
                     sopClassUID: sopClass, role: role)
    }
}

/// A fixed selection: objects arriving after inventory creation are not included.
public struct DicomBackupInventory: Codable, Equatable, Sendable {
    public static let fileName = "inventory.json"
    public struct Object: Codable, Equatable, Sendable {
        public let objectKey: String
        public let sourceLocator: String
        public let byteCount: Int64
        public let sha256: String
        public let references: DicomObjectReference
        public init(objectKey: String, sourceLocator: String, byteCount: Int64, sha256: String,
                    references: DicomObjectReference) {
            self.objectKey = objectKey
            self.sourceLocator = sourceLocator
            self.byteCount = byteCount
            self.sha256 = sha256.lowercased()
            self.references = references
        }
    }
    public let inventoryID: String
    public let createdAt: Date
    public let producer: String
    public let objects: [Object]
    public init(inventoryID: String = UUID().uuidString, createdAt: Date = Date(), producer: String,
                objects: [Object]) {
        self.inventoryID = inventoryID
        self.createdAt = createdAt
        self.producer = producer
        self.objects = objects.sorted { $0.objectKey < $1.objectKey }
    }
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Self(inventoryID: inventoryID, createdAt: createdAt,
                                       producer: producer, objects: objects))
    }
    public var inventorySHA256: String { get throws { DicomStudyPackageManifest.digest(try encode()) } }

    func validate() throws {
        var keys: Set<String> = [Self.fileName.lowercased()]
        var total: Int64 = 0
        for object in objects {
            _ = try StoragePath.resolve(object.objectKey, root: FileManager.default.temporaryDirectory)
            _ = try StoragePath.resolve(object.sourceLocator, root: FileManager.default.temporaryDirectory)
            guard keys.insert(object.objectKey.lowercased()).inserted, object.byteCount >= 0,
                  object.byteCount <= Int64.max - total,
                  object.sha256.count == 64, object.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw DicomStorageProviderError.integrity("Invalid inventory")
            }
            total += object.byteCount
        }
    }
    var bytes: Int64 { objects.reduce(0) { $0 + $1.byteCount } }
}

/// Read-only A1 adapter; members retain their original package-relative locators.
public final class DicomStudyPackageBackupProvider: DicomStorageProvider {
    public let id: String
    public let tier: DicomStorageTier = .offline
    public let capabilities = DicomStorageCapabilities(randomAccess: false, atomicRename: false,
        checksumOnHead: true, latency: .archive, removable: false)
    private let reader: DicomStudyPackageReader
    public init(id: String, url: URL) throws { self.id = id; reader = try .init(url: url) }
    public func head(_ locator: String) async throws -> DicomStorageObjectInfo? {
        reader.members().first { $0.relativePath == locator }.map {
            .init(locator: locator, byteCount: $0.byteCount, sha256: $0.sha256)
        }
    }
    public func list(prefix: String) async throws -> [DicomStorageObjectInfo] {
        reader.members().filter { $0.relativePath.hasPrefix(prefix) }.map {
            .init(locator: $0.relativePath, byteCount: $0.byteCount, sha256: $0.sha256)
        }
    }
    public func reachability() async -> DicomProviderReachability { .reachable }
    public func put(_ source: URL, locator: String, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        throw DicomStorageProviderError.io("Read-only study package")
    }
    public func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        throw DicomStorageProviderError.deleteNotAuthorized
    }
    public func get(_ locator: String, to destination: URL, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        let fs = DicomLocalIngestFileSystem()
        let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        try fs.write(Data(), to: temp)
        defer { try? fs.remove(temp) }
        try reader.read(member: locator, consume: { try fs.write($0, to: temp, append: true) },
                        isCancelled: isCancelled)
        return try StoragePath.copy(temp, to: destination, locator: locator, expectedSHA256: expectedSHA256,
                                    fileSystem: fs, isCancelled: isCancelled)
    }
}
