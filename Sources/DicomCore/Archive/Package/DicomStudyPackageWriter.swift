import Foundation
import CryptoKit
import ZIPFoundation

public final class DicomStudyPackageWriter: @unchecked Sendable {
    public struct Member: Sendable {
        public var sourceURL: URL
        public var relativePath: String
        public var role: DicomStudyPackageManifest.Entry.Role
        public var sopInstanceUID: String?
        public var sopClassUID: String?
        public var transferSyntaxUID: String?
        public var sourceRepresentation: String?
        public init(sourceURL: URL, relativePath: String, role: DicomStudyPackageManifest.Entry.Role = .original,
                    sopInstanceUID: String? = nil, sopClassUID: String? = nil, transferSyntaxUID: String? = nil,
                    sourceRepresentation: String? = nil) {
            self.sourceURL = sourceURL
            self.relativePath = relativePath
            self.role = role
            self.sopInstanceUID = sopInstanceUID
            self.sopClassUID = sopClassUID
            self.transferSyntaxUID = transferSyntaxUID
            self.sourceRepresentation = sourceRepresentation
        }
    }
    public struct Result: Sendable {
        public let packageURL: URL
        public let manifest: DicomStudyPackageManifest
        public let byteCount: Int64
    }
    private let fileSystem: any DicomIngestFileSystem
    private let limits: DicomArchiveLimits
    public init(fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem(), limits: DicomArchiveLimits = .default) {
        self.fileSystem = fileSystem
        self.limits = limits
    }

    public func write(members: [Member], to destination: URL, producer: String, includeDICOMDIR: Bool,
                      isCancelled: () -> Bool = { false }) throws -> Result {
        typealias E = DicomStudyPackageError
        let staging = URL(fileURLWithPath: destination.path + ".partial")
        guard try !fileSystem.exists(destination), try !fileSystem.exists(staging) else { throw E.destinationExists }
        guard members.count + (includeDICOMDIR ? 2 : 1) <= limits.maxEntries else { throw E.limitExceeded(.entries) }
        var seen: Set<String> = ["manifest.json", "dicomdir"]
        for member in members {
            if ["manifest.json", "dicomdir"].contains(StudyPackagePath.key(member.relativePath)) {
                throw E.reservedName(member.relativePath)
            }
            try StudyPackagePath.insert(member.relativePath, into: &seen, limits: limits)
            guard member.role != .dicomdir else { throw E.reservedName(member.relativePath) }
        }
        var entries: [DicomStudyPackageManifest.Entry] = []
        var studies: [String: [String: [String]]] = [:]
        var directory = DicomDirectory(fileSetID: "DICOM", patients: [])
        var total: Int64 = 0
        func checkSize(_ size: Int64) throws {
            guard size >= 0, size <= limits.maxMemberBytes else { throw E.limitExceeded(.memberBytes) }
            guard total <= limits.maxTotalBytes, size <= limits.maxTotalBytes - total else { throw E.limitExceeded(.totalBytes) }
        }
        for member in members {
            if isCancelled() { throw E.cancelled }
            let values = try member.sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw E.symlinkEntry(member.relativePath) }
            guard values.isRegularFile == true else { throw E.unreadableMember(member.relativePath) }
            try checkSize(Int64(values.fileSize ?? 0))
            var hash = SHA256()
            var size: Int64 = 0
            try fileSystem.readChunks(member.sourceURL) { chunk in
                if isCancelled() { throw E.cancelled }
                guard Int64(chunk.count) <= limits.maxMemberBytes - size else { throw E.limitExceeded(.memberBytes) }
                size += Int64(chunk.count)
                try checkSize(size)
                hash.update(data: chunk)
            }
            var sop = member.sopInstanceUID
            var sopClass = member.sopClassUID
            var syntax = member.transferSyntaxUID
            do {
                let data = try Data(contentsOf: member.sourceURL, options: .alwaysMapped)
                guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw E.unreadableMember(member.relativePath) }
                let meta = try DicomPart10FileMetaParser.parse(data)
                let decoder = try DCMDecoder(contentsOf: member.sourceURL)
                sop = sop ?? meta.mediaStorageSOPInstanceUID
                sopClass = sopClass ?? meta.mediaStorageSOPClassUID
                syntax = syntax ?? meta.transferSyntaxUID
                let study = decoder.info(for: .studyInstanceUID)
                let series = decoder.info(for: .seriesInstanceUID)
                if !study.isEmpty, !series.isEmpty, let sop {
                    studies[study, default: [:]][series, default: []].append(sop)
                }
                if includeDICOMDIR, member.role == .original || member.role == .representation {
                    let fileID = member.relativePath.components(separatedBy: "/")
                    guard DicomFileSet.isValidFileID(fileID) else { throw E.directoryBuildFailed("Invalid File ID") }
                    let leaf = try DicomFileSet.leafRecord(for: decoder.dataSet, fileMeta: meta, fileID: fileID)
                    let patientID = decoder.info(for: .patientID)
                    let p = directory.patients.firstIndex { $0.patientID == patientID } ?? directory.patients.count
                    if p == directory.patients.count { directory.patients.append(.init(patientID: patientID, studies: [])) }
                    let s = directory.patients[p].studies.firstIndex { $0.studyInstanceUID == study } ?? directory.patients[p].studies.count
                    if s == directory.patients[p].studies.count { directory.patients[p].studies.append(.init(studyInstanceUID: study, series: [])) }
                    let r = directory.patients[p].studies[s].series.firstIndex { $0.seriesInstanceUID == series } ?? directory.patients[p].studies[s].series.count
                    if r == directory.patients[p].studies[s].series.count { directory.patients[p].studies[s].series.append(.init(seriesInstanceUID: series, images: [])) }
                    directory.patients[p].studies[s].series[r].images.append(leaf)
                }
            } catch {
                if includeDICOMDIR, member.role == .original || member.role == .representation {
                    throw E.directoryBuildFailed("Unable to build member record")
                }
                if member.role != .other { throw E.unreadableMember(member.relativePath) }
            }
            total += size
            entries.append(.init(relativePath: member.relativePath, role: member.role, sopInstanceUID: sop,
                                 sopClassUID: sopClass, transferSyntaxUID: syntax, byteCount: size,
                                 sha256: DicomStudyPackageManifest.hex(hash.finalize()), sourceRepresentation: member.sourceRepresentation))
        }
        var directoryData: Data?
        if includeDICOMDIR {
            do { directoryData = try DicomDirectoryWriter.part10Data(from: directory) }
            catch { throw E.directoryBuildFailed("Unable to encode DICOMDIR") }
            let data = directoryData!
            try checkSize(Int64(data.count))
            total += Int64(data.count)
            entries.append(.init(relativePath: "DICOMDIR", role: .dicomdir, byteCount: Int64(data.count), sha256: DicomStudyPackageManifest.digest(data)))
        }
        let manifest = DicomStudyPackageManifest(producer: producer,
            studies: studies.keys.sorted().map { .init(studyInstanceUID: $0, series: studies[$0]!) }, entries: entries,
            totals: .init(entryCount: entries.count, byteCount: total))
        let manifestData = try manifest.encode()
        guard Int64(manifestData.count) <= limits.maxManifestBytes else { throw E.limitExceeded(.manifestBytes) }
        if isCancelled() { throw E.cancelled }
        var published = false
        var ownsStaging = false
        defer { if ownsStaging && !published { try? fileSystem.remove(staging) } }
        do {
            // ZIPFoundation creates the backing file exclusively.
            let archive = try Archive(url: staging, accessMode: .create)
            ownsStaging = true
            func add(_ data: Data, path: String) throws {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) {
                    position, count in data.subdata(in: Int(position)..<(Int(position) + count))
                }
            }
            try add(manifestData, path: DicomStudyPackageManifest.manifestEntryName)
            for (member, entry) in zip(members, entries) {
                if isCancelled() { throw E.cancelled }
                let handle = try FileHandle(forReadingFrom: member.sourceURL)
                defer { try? handle.close() }
                var hash = SHA256()
                try archive.addEntry(with: entry.relativePath, type: .file, uncompressedSize: entry.byteCount,
                                     compressionMethod: member.role == .other ? .deflate : .none) { _, count in
                    if isCancelled() { throw E.cancelled }
                    let chunk = try handle.read(upToCount: count) ?? Data()
                    guard chunk.count == count else { throw E.sizeMismatch(entry.relativePath) }
                    hash.update(data: chunk)
                    return chunk
                }
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw E.sizeMismatch(entry.relativePath) }
                guard DicomStudyPackageManifest.hex(hash.finalize()) == entry.sha256 else { throw E.checksumMismatch(entry.relativePath) }
            }
            if let directoryData { try add(directoryData, path: "DICOMDIR") }
        }
        if isCancelled() { throw E.cancelled }
        try fileSystem.fsyncFile(staging)
        try fileSystem.rename(staging, to: destination)
        published = true
        try fileSystem.fsyncDirectory(destination.deletingLastPathComponent())
        return Result(packageURL: destination, manifest: manifest,
                      byteCount: Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    }
}
