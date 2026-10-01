import Foundation

public enum DicomStudyPackageError: Error, Equatable, Sendable {
    case destinationExists
    case invalidRelativePath(String), duplicateRelativePath(String), reservedName(String), unreadableMember(String)
    case limitExceeded(DicomArchiveLimits.Kind)
    case manifestMissing, manifestNotFirst, manifestInvalid(String), unsupportedFormatVersion(Int)
    case entryMissing(String), unexpectedEntry(String), symlinkEntry(String), sizeMismatch(String)
    case checksumMismatch(String), corruptArchive(String), cancelled, directoryBuildFailed(String)
}

/// Shared portable path rules, including collisions on case-insensitive filesystems.
internal enum StudyPackagePath {
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    static func validate(_ path: String, limits: DicomArchiveLimits) throws {
        guard path.utf8.count <= limits.maxPathLength else { throw DicomStudyPackageError.limitExceeded(.pathLength) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DicomStudyPackageError.invalidRelativePath(path)
        }
    }

    static func insert(_ path: String, into seen: inout Set<String>, limits: DicomArchiveLimits) throws {
        try validate(path, limits: limits)
        let normalized = key(path)
        guard !seen.contains(normalized), !seen.contains(where: {
            $0.hasPrefix(normalized + "/") || normalized.hasPrefix($0 + "/")
        }) else { throw DicomStudyPackageError.duplicateRelativePath(path) }
        seen.insert(normalized)
    }
}
