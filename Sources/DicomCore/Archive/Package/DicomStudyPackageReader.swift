import Foundation
import CryptoKit
import ZIPFoundation

public final class DicomStudyPackageReader: @unchecked Sendable {
    public struct VerificationReport: Sendable {
        public enum Status: Sendable { case verified, failed }
        public let verifiedEntries: Int
        public let failures: [(relativePath: String, reason: DicomStudyPackageError)]
        public var status: Status { failures.isEmpty ? .verified : .failed }
    }
    public let manifest: DicomStudyPackageManifest
    private let archive: Archive
    private let entriesByPath: [String: DicomStudyPackageManifest.Entry]
    private let zipEntriesByPath: [String: ZIPFoundation.Entry]
    private let limits: DicomArchiveLimits
    // ZIPFoundation uses a shared seek position. Serialize access, including callbacks.
    private let lock = NSRecursiveLock()
    internal static let bufferSize = 64 * 1024

    public init(url: URL, limits: DicomArchiveLimits = .default) throws {
        typealias E = DicomStudyPackageError
        self.limits = limits
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw E.corruptArchive("Cannot open ZIP") }
        var zipEntries: [String: ZIPFoundation.Entry] = [:]
        var seen: Set<String> = []
        var first: String?
        for entry in archive {
            if first == nil { first = entry.path }
            guard zipEntries.count < limits.maxEntries else { throw E.limitExceeded(.entries) }
            if entry.type == .symlink { throw E.symlinkEntry(entry.path) }
            guard entry.type == .file else { throw E.unexpectedEntry(entry.path) }
            try StudyPackagePath.insert(entry.path, into: &seen, limits: limits)
            zipEntries[entry.path] = entry
        }
        guard let manifestEntry = zipEntries[DicomStudyPackageManifest.manifestEntryName] else { throw E.manifestMissing }
        guard first == DicomStudyPackageManifest.manifestEntryName else { throw E.manifestNotFirst }
        // The local header must also start with the manifest (central-directory ordering alone is insufficient).
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 30) ?? Data()
            guard header.count == 30, Array(header.prefix(4)) == [0x50, 0x4b, 3, 4] else { throw E.corruptArchive("Invalid first local header") }
            let length = Int(header[26]) | Int(header[27]) << 8
            let name = try handle.read(upToCount: length)
            guard name == Data(DicomStudyPackageManifest.manifestEntryName.utf8) else { throw E.manifestNotFirst }
        } catch let error as E { throw error }
        catch { throw E.corruptArchive("Cannot read first local header") }
        guard limits.maxManifestBytes >= 0, manifestEntry.uncompressedSize <= UInt64(limits.maxManifestBytes) else {
            throw E.limitExceeded(.manifestBytes)
        }
        var data = Data()
        do {
            let crc = try archive.extract(manifestEntry, bufferSize: Self.bufferSize) { chunk in
                guard Int64(chunk.count) <= limits.maxManifestBytes - Int64(data.count) else { throw E.limitExceeded(.manifestBytes) }
                data.append(chunk)
            }
            guard crc == manifestEntry.checksum else { throw E.corruptArchive("Manifest CRC mismatch") }
        } catch let error as E { throw error }
        catch { throw E.corruptArchive("Cannot extract manifest") }
        guard UInt64(data.count) == manifestEntry.uncompressedSize else { throw E.sizeMismatch("manifest.json") }
        manifest = try DicomStudyPackageManifest.decode(data)
        guard manifest.formatVersion == 1 else { throw E.unsupportedFormatVersion(manifest.formatVersion) }
        let dateParser = ISO8601DateFormatter()
        let date = dateParser.date(from: manifest.createdAt)
        dateParser.formatOptions.insert(.withFractionalSeconds)
        guard UUID(uuidString: manifest.packageID) != nil,
              date != nil || dateParser.date(from: manifest.createdAt) != nil else { throw E.manifestInvalid("Invalid package identity or date") }
        seen = ["manifest.json"]
        var entriesByPath: [String: DicomStudyPackageManifest.Entry] = [:]
        var total: Int64 = 0
        for entry in manifest.entries {
            if StudyPackagePath.key(entry.relativePath) == "manifest.json" { throw E.reservedName(entry.relativePath) }
            if StudyPackagePath.key(entry.relativePath) == "dicomdir" {
                guard entry.relativePath == "DICOMDIR", entry.role == .dicomdir else { throw E.reservedName(entry.relativePath) }
            } else if entry.role == .dicomdir { throw E.reservedName(entry.relativePath) }
            try StudyPackagePath.insert(entry.relativePath, into: &seen, limits: limits)
            entriesByPath[entry.relativePath] = entry
            guard entry.byteCount >= 0 else { throw E.manifestInvalid("Negative byte count") }
            guard entry.byteCount <= limits.maxMemberBytes else { throw E.limitExceeded(.memberBytes) }
            guard total <= limits.maxTotalBytes, entry.byteCount <= limits.maxTotalBytes - total else { throw E.limitExceeded(.totalBytes) }
            total += entry.byteCount
            guard entry.sha256.utf8.count == 64, entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw E.manifestInvalid("Invalid SHA-256")
            }
            guard let stored = zipEntries[entry.relativePath] else { throw E.entryMissing(entry.relativePath) }
            guard stored.uncompressedSize == UInt64(entry.byteCount) else { throw E.sizeMismatch(entry.relativePath) }
        }
        for path in zipEntries.keys where path != "manifest.json" && entriesByPath[path] == nil {
            throw E.unexpectedEntry(path)
        }
        guard manifest.totals.entryCount == manifest.entries.count, manifest.totals.byteCount == total else { throw E.manifestInvalid("Totals mismatch") }
        self.entriesByPath = entriesByPath
        self.zipEntriesByPath = zipEntries
    }

    public func members() -> [DicomStudyPackageManifest.Entry] { manifest.entries }

    public func read(member relativePath: String, consume: (Data) throws -> Void,
                     isCancelled: () -> Bool = { false }) throws {
        typealias E = DicomStudyPackageError
        lock.lock()
        defer { lock.unlock() }
        if isCancelled() { throw E.cancelled }
        guard let declared = entriesByPath[relativePath],
              let entry = zipEntriesByPath[relativePath] else { throw E.entryMissing(relativePath) }
        var count: Int64 = 0
        var hash = SHA256()
        var consumerError: (any Error)?
        do {
            _ = try archive.extract(entry, bufferSize: Self.bufferSize, skipCRC32: true) { chunk in
                if isCancelled() { throw E.cancelled }
                guard Int64(chunk.count) <= declared.byteCount - count else { throw E.sizeMismatch(relativePath) }
                count += Int64(chunk.count)
                hash.update(data: chunk)
                do { try consume(chunk) } catch { consumerError = error; throw error }
            }
        } catch {
            if let consumerError { throw consumerError }
            if let error = error as? E { throw error }
            throw E.corruptArchive(relativePath)
        }
        if isCancelled() { throw E.cancelled }
        guard count == declared.byteCount else { throw E.sizeMismatch(relativePath) }
        guard DicomStudyPackageManifest.hex(hash.finalize()) == declared.sha256 else { throw E.checksumMismatch(relativePath) }
    }

    public func data(for relativePath: String) throws -> Data {
        var result = Data()
        try read(member: relativePath) { result.append($0) }
        return result
    }

    public func verify(isCancelled: () -> Bool = { false }) throws -> VerificationReport {
        var verified = 0
        var failures: [(relativePath: String, reason: DicomStudyPackageError)] = []
        for entry in manifest.entries {
            do {
                try read(member: entry.relativePath, consume: { _ in }, isCancelled: isCancelled)
                verified += 1
            } catch DicomStudyPackageError.cancelled { throw DicomStudyPackageError.cancelled }
            catch let error as DicomStudyPackageError { failures.append((entry.relativePath, error)) }
            catch { failures.append((entry.relativePath, .corruptArchive(entry.relativePath))) }
        }
        if isCancelled() { throw DicomStudyPackageError.cancelled }
        return VerificationReport(verifiedEntries: verified, failures: failures)
    }

    public func extract(members: [String]? = nil, to directory: URL,
                        isCancelled: () -> Bool = { false }) throws -> [URL] {
        let fs = DicomLocalIngestFileSystem()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var selected: [(String, URL)] = []
        var seen: Set<String> = []
        for path in members ?? manifest.entries.map(\.relativePath) {
            try StudyPackagePath.insert(path, into: &seen, limits: limits)
            guard entriesByPath[path] != nil else { throw DicomStudyPackageError.entryMissing(path) }
            let target = root.appendingPathComponent(path).standardizedFileURL
            guard target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).standardizedFileURL.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                throw DicomStudyPackageError.invalidRelativePath(path)
            }
            if try fs.exists(target) { throw DicomStudyPackageError.destinationExists }
            selected.append((path, target))
        }
        var output: [URL] = []
        var createdDirectories: [URL] = []
        var success = false
        defer {
            if !success {
                for url in output.reversed() { try? fs.remove(url) }
                // Remove only empty directories created by this invocation.
                for url in createdDirectories.reversed() {
                    if (try? fs.contentsOf(url).isEmpty) == true { try? fs.remove(url) }
                }
            }
        }
        for (path, target) in selected {
            if isCancelled() { throw DicomStudyPackageError.cancelled }
            var missing: [URL] = []
            var parent = target.deletingLastPathComponent()
            while try !fs.exists(parent) { missing.append(parent); parent.deleteLastPathComponent() }
            for folder in missing.reversed() {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                createdDirectories.append(folder)
            }
            guard target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).standardizedFileURL.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                throw DicomStudyPackageError.invalidRelativePath(path)
            }
            try fs.write(Data(), to: target, append: false)
            output.append(target)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try read(member: path, consume: { try handle.write(contentsOf: $0) }, isCancelled: isCancelled)
        }
        if isCancelled() { throw DicomStudyPackageError.cancelled }
        success = true
        return output
    }
}
