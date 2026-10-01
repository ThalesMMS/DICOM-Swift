import Foundation

public final class DicomLocalDiskProvider: DicomStorageProvider, StoragePartialCleaning {
    public let id: String
    public let tier: DicomStorageTier
    public let root: URL
    public let capabilities = DicomStorageCapabilities(randomAccess: true, atomicRename: true,
        checksumOnHead: true, latency: .local, removable: false)
    private let fileSystem: any DicomIngestFileSystem

    public init(id: String, root: URL, tier: DicomStorageTier = .online,
                fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.id = id
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.tier = tier
        self.fileSystem = fileSystem
    }

    public func reachability() async -> DicomProviderReachability {
        do { try checkRoot(); return .reachable }
        catch { return .unreachable(String(describing: error)) }
    }

    private func checkRoot() throws {
        do {
            guard try fileSystem.exists(root) else { throw DicomStorageProviderError.unreachable(id) }
            _ = try fileSystem.contentsOf(root)
        } catch { throw DicomStorageProviderError.unreachable(id) }
    }

    public func head(_ locator: String) async throws -> DicomStorageObjectInfo? {
        try checkRoot()
        do {
            let url = try StoragePath.resolve(locator, root: root)
            guard try fileSystem.exists(url) else { try checkRoot(); return nil }
            return try StoragePath.info(url, locator: locator, fileSystem: fileSystem)
        } catch { try checkRoot(); throw StoragePath.mapped(error) }
    }

    public func put(_ source: URL, locator: String, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        try checkRoot()
        do {
            let destination = try StoragePath.resolve(locator, root: root)
            try fileSystem.createDirectory(destination.deletingLastPathComponent())
            _ = try StoragePath.resolve(locator, root: root)
            return try StoragePath.copy(source, to: destination, locator: locator, expectedSHA256: expectedSHA256,
                                        fileSystem: fileSystem, isCancelled: isCancelled)
        } catch { try checkRoot(); throw StoragePath.mapped(error) }
    }

    public func get(_ locator: String, to destination: URL, expectedSHA256: String,
                    isCancelled: @Sendable () -> Bool = { false }) async throws -> DicomStorageObjectInfo {
        try checkRoot()
        do {
            let source = try StoragePath.resolve(locator, root: root)
            guard try fileSystem.exists(source) else { throw DicomStorageProviderError.notFound(locator) }
            return try StoragePath.copy(source, to: destination, locator: locator, expectedSHA256: expectedSHA256,
                                        fileSystem: fileSystem, isCancelled: isCancelled)
        } catch { try checkRoot(); throw StoragePath.mapped(error) }
    }

    public func list(prefix: String) async throws -> [DicomStorageObjectInfo] {
        try checkRoot()
        if !prefix.isEmpty {
            _ = try StoragePath.resolve(prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix, root: root)
        }
        do {
            var result: [DicomStorageObjectInfo] = []
            func scan(_ directory: URL, relativeDirectory: String = "") throws {
                for child in try fileSystem.contentsOf(directory).sorted(by: { $0.path < $1.path }) {
                    let locator = relativeDirectory + child.lastPathComponent
                    _ = try StoragePath.resolve(locator, root: root)
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw DicomStorageProviderError.io("Symbolic link") }
                    if values.isDirectory == true {
                        let branch = locator + "/"
                        guard prefix.isEmpty || branch.hasPrefix(prefix) || prefix.hasPrefix(branch) else { continue }
                        try scan(child, relativeDirectory: branch)
                    }
                    else if locator.hasPrefix(prefix) {
                        result.append(try StoragePath.info(child, locator: locator, fileSystem: fileSystem))
                    }
                }
            }
            try scan(root)
            return result
        } catch { try checkRoot(); throw StoragePath.mapped(error) }
    }

    func discardPartial(_ locator: String) async throws {
        try checkRoot()
        let partial = try StoragePath.resolve(locator + ".partial", root: root)
        if try fileSystem.exists(partial) { try fileSystem.remove(partial) }
    }

    public func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        guard !authorization.token.isEmpty else { throw DicomStorageProviderError.deleteNotAuthorized }
        try checkRoot()
        do {
            let url = try StoragePath.resolve(locator, root: root)
            guard try fileSystem.exists(url) else { throw DicomStorageProviderError.notFound(locator) }
            try fileSystem.remove(url)
            try fileSystem.fsyncDirectory(url.deletingLastPathComponent())
        } catch { try checkRoot(); throw StoragePath.mapped(error) }
    }
}

/// Shared file mechanics for the directory witnesses and verified downloads.
enum StoragePath {
    static func resolve(_ locator: String, root: URL) throws -> URL {
        let parts = locator.split(separator: "/", omittingEmptySubsequences: false)
        guard !locator.isEmpty, !locator.hasPrefix("/"), !locator.contains("\0"),
              !parts.contains(".."), !parts.contains("."), !parts.contains("") else {
            throw DicomStorageProviderError.io("Invalid relative locator")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var url = base
        // Check every existing ancestor, including dangling links. Foundation may leave a path
        // unresolved when its final component is absent; checking only the final URL is insufficient.
        for part in parts {
            url.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw DicomStorageProviderError.io("Symbolic link locator")
            }
        }
        guard url.standardizedFileURL.path.hasPrefix(base.path == "/" ? "/" : base.path + "/") else {
            throw DicomStorageProviderError.io("Locator escapes root")
        }
        return url
    }

    static func info(_ url: URL, locator: String, fileSystem: any DicomIngestFileSystem) throws -> DicomStorageObjectInfo {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw DicomStorageProviderError.io("Not a regular file") }
        return .init(locator: locator, byteCount: Int64(values.fileSize ?? 0),
                     sha256: try fileSystem.checksum(url), modifiedAt: values.contentModificationDate)
    }

    static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if Task.isCancelled || isCancelled() { throw DicomStorageProviderError.cancelled }
    }

    static func copy(_ source: URL, to destination: URL, locator: String, expectedSHA256: String,
                     fileSystem: any DicomIngestFileSystem, isCancelled: @Sendable () -> Bool) throws -> DicomStorageObjectInfo {
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        try checkCancellation(isCancelled)
        guard try !fileSystem.exists(destination), try !fileSystem.exists(partial) else {
            throw DicomStorageProviderError.destinationExists
        }
        try fileSystem.write(Data(), to: partial, append: false)
        defer { try? fileSystem.remove(partial) }
        try fileSystem.readChunks(source) { chunk in
            try checkCancellation(isCancelled)
            try fileSystem.write(chunk, to: partial, append: true)
        }
        let info = try self.info(partial, locator: locator, fileSystem: fileSystem)
        guard info.sha256 == expectedSHA256.lowercased() else { throw DicomStorageProviderError.integrity(locator) }
        try checkCancellation(isCancelled)
        try fileSystem.fsyncFile(partial)
        try fileSystem.rename(partial, to: destination)
        try fileSystem.fsyncDirectory(destination.deletingLastPathComponent())
        return info
    }

    static func mapped(_ error: any Error) -> DicomStorageProviderError {
        if let error = error as? DicomStorageProviderError { return error }
        if error is CancellationError { return .cancelled }
        return .io(String(describing: error))
    }
}

/// Resume-only cleanup of a destination publication interrupted before its atomic rename.
protocol StoragePartialCleaning: Sendable {
    func discardPartial(_ locator: String) async throws
}
