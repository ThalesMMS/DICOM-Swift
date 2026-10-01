import Foundation

public struct DicomArchiveIntegrityRecord: Sendable {
    public let path: URL
    public let recordedSHA256: String?
    public let sopUID: String
    public init(path: URL, recordedSHA256: String?, sopUID: String) {
        self.path = path; self.recordedSHA256 = recordedSHA256; self.sopUID = sopUID
    }
}

public struct DicomArchiveIntegrityFinding: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case checksumMismatch, missingFile, unparseable, identityMismatch, unrecordedFile, unpublishedTemp, conflictFile
    }
    public let kind: Kind
    public let path: URL
    public let sopUID: String?
}

public enum DicomArchiveIntegrityScanner {
    /// Hashing uses bounded reads on the local filesystem. Optional reopen validates the Part 10 identity.
    public static func verify(records: [DicomArchiveIntegrityRecord], inventory: [URL] = [],
                              fileSystem: any DicomIngestFileSystem, reopen: Bool = true) -> [DicomArchiveIntegrityFinding] {
        var findings: [DicomArchiveIntegrityFinding] = []
        for record in records {
            do {
                guard try fileSystem.exists(record.path) else {
                    findings.append(.init(kind: .missingFile, path: record.path, sopUID: record.sopUID)); continue
                }
                let hash = try fileSystem.checksum(record.path)
                if record.recordedSHA256 == nil || record.recordedSHA256?.isEmpty == true || hash != record.recordedSHA256 {
                    findings.append(.init(kind: .checksumMismatch, path: record.path, sopUID: record.sopUID))
                }
                if reopen {
                    let request = try dicomIngestValidatedRequest(fileSystem.read(record.path))
                    if request.sopInstanceUID != record.sopUID {
                        findings.append(.init(kind: .identityMismatch, path: record.path, sopUID: record.sopUID))
                    }
                }
            } catch { findings.append(.init(kind: .unparseable, path: record.path, sopUID: record.sopUID)) }
        }
        let paths = Set(records.map { $0.path.standardizedFileURL })
        for path in inventory where !paths.contains(path.standardizedFileURL) {
            let kind: DicomArchiveIntegrityFinding.Kind = path.pathComponents.contains(".ingest") ? .unpublishedTemp
                : path.pathComponents.contains(".conflicts") ? .conflictFile : .unrecordedFile
            findings.append(.init(kind: kind, path: path, sopUID: nil))
        }
        return findings
    }
}
