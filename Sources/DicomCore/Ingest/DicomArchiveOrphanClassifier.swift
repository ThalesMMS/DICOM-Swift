import Foundation

public enum DicomArchiveOrphanClassifier {
    public enum Kind: String, Sendable { case original, unpublishedTemp, conflict, confirmedDuplicate }
    public enum Action: String, Sendable { case quarantine, preserveConflict, deleteConfirmedDuplicate }
    public struct Plan: Sendable {
        public let path: URL
        public let kind: Kind
        public let action: Action
    }
    /// Pure plan only. Deletion requires explicit per-file confirmation from the caller.
    public static func classify(files: [URL], records: [DicomArchiveIntegrityRecord],
                                confirmedDuplicate: (URL) -> Bool = { _ in false }) -> [Plan] {
        let known = Set(records.map { $0.path.standardizedFileURL })
        return files.filter { !known.contains($0.standardizedFileURL) }.map { path in
            if confirmedDuplicate(path) { return .init(path: path, kind: .confirmedDuplicate, action: .deleteConfirmedDuplicate) }
            if path.pathComponents.contains(".conflicts") { return .init(path: path, kind: .conflict, action: .preserveConflict) }
            return .init(path: path, kind: path.pathComponents.contains(".ingest") ? .unpublishedTemp : .original, action: .quarantine)
        }
    }
}
