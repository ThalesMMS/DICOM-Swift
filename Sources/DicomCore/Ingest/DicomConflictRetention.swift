import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum DicomConflictRetention {
    /// Issue #2530: one byte budget per .conflicts directory, shared by DIMSE and DICOMweb on all platforms.
    public static let maximumBytes: Int64 = 512 * 1024 * 1024

    /// Issue #2530: maintenance must never turn a durably stored conflict into a failed arrival.
    /// Call under the storage writer's gate, protecting every file published in the current round.
    public static func enforce(in directory: URL, preserving files: Set<URL>,
                               fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        do {
            try trim(in: directory, preserving: files, fileSystem: fileSystem)
        } catch {
            let failure = error as NSError
            // Issue #2530: report actionable failure codes without exposing paths or DICOM identifiers.
            let message = "Conflict retention cleanup failed (issue #2530, \(failure.domain):\(failure.code)); "
                + "incoming conflict preserved; .conflicts may exceed its byte limit."
            #if canImport(OSLog)
            Logger(subsystem: "com.dicomswift", category: "ConflictRetention").error("\(message, privacy: .public)")
            #endif
            FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
        }
    }

    private static func trim(in directory: URL, preserving files: Set<URL>,
                             fileSystem: any DicomIngestFileSystem) throws {
        let protected = Set(files.map(\.standardizedFileURL))
        var candidates: [(path: URL, bytes: Int64, created: Date)] = []
        var total: Int64 = 0
        for path in try fileSystem.contentsOf(directory) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let size = attributes[.size] as? NSNumber,
                  // Issue #2530: birth time orders arrivals; mtime is only a fallback on filesystems without it.
                  let created = (attributes[.creationDate] ?? attributes[.modificationDate]) as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            total += size.int64Value
            if !protected.contains(path.standardizedFileURL) {
                candidates.append((path, size.int64Value, created))
            }
        }
        candidates.sort {
            $0.created == $1.created ? $0.path.path < $1.path.path : $0.created < $1.created
        }
        for candidate in candidates where total > maximumBytes {
            try fileSystem.remove(candidate.path)
            total -= candidate.bytes
        }
        // Issue #2530: even an oversized arrival survives its own round; report the unmet budget instead.
        if total > maximumBytes { throw CocoaError(.fileWriteOutOfSpace) }
    }
}
