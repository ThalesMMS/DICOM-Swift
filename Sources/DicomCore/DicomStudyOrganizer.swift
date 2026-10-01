import Foundation

/// Metadata-only planning of a patient/study/series/instance folder layout for loose Part 10 files.
/// Planning never touches the file system beyond bounded header reads; `apply` copies or moves
/// only after an explicit call and refuses to overwrite anything.
public struct DicomStudyOrganizerPlan: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let source: String
        public let destination: String?
        public let studyInstanceUID: String?
        public let seriesInstanceUID: String?
        public let sopInstanceUID: String?
        public let skipReason: String?
    }
    /// Destination boundary; source files are the caller's explicitly selected inputs and may be elsewhere.
    public let root: String
    public let entries: [Entry]
    public var planned: [Entry] { entries.filter { $0.destination != nil } }
    public var skipped: [Entry] { entries.filter { $0.destination == nil } }
    public var studyCount: Int { Set(planned.compactMap(\.studyInstanceUID)).count }
}

public struct DicomStudyOrganizerResult: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public let source: String
        public let reason: String
    }
    public let applied: [DicomStudyOrganizerPlan.Entry]
    public let failures: [Failure]
    public let cancelled: Bool
}

public enum DicomStudyOrganizer {
    public enum Mode: String, Codable, Sendable { case copy, move }

    public struct Options: Sendable {
        public var maximumMetadataBytes: Int
        /// Folder layout: `patient/study/series` (default) or `study/series`.
        public var includePatientLevel: Bool
        public init(maximumMetadataBytes: Int = 4 * 1024 * 1024, includePatientLevel: Bool = true) {
            self.maximumMetadataBytes = maximumMetadataBytes
            self.includePatientLevel = includePatientLevel
        }
    }

    static func safeComponent(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        let allowed = value.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_") ? Character(scalar) : "_"
        }
        let component = String(allowed).prefix(64)
        return component == "." || component == ".." ? fallback : String(component)
    }

    public static func plan(files: [URL], into root: URL, options: Options = Options()) async -> DicomStudyOrganizerPlan {
        var entries: [DicomStudyOrganizerPlan.Entry] = []
        var claimed: Set<String> = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            do {
                let source = try await DicomByteSource.openFile(file, storage: .buffer)
                let metadata = try await DicomSourceMetadata.readPart10(from: source, maximumMetadataBytes: options.maximumMetadataBytes)
                let dataSet = metadata.dataSet
                let study = dataSet.string(for: .studyInstanceUID), series = dataSet.string(for: .seriesInstanceUID), sop = dataSet.string(for: .sopInstanceUID)
                guard let study, !study.isEmpty, let series, !series.isEmpty, let sop, !sop.isEmpty else {
                    entries.append(.init(source: file.path, destination: nil, studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: sop,
                                         skipReason: "missing Study/Series/SOP Instance UID"))
                    continue
                }
                var destination = root
                if options.includePatientLevel { destination.appendPathComponent(safeComponent(dataSet.string(for: .patientID), fallback: "unknown-patient")) }
                destination.appendPathComponent(safeComponent(study, fallback: "study"))
                destination.appendPathComponent(safeComponent(series, fallback: "series"))
                destination.appendPathComponent(safeComponent(sop, fallback: "instance") + ".dcm")
                guard !claimed.contains(destination.path) else {
                    entries.append(.init(source: file.path, destination: nil, studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: sop,
                                         skipReason: "duplicate SOP Instance UID in the input set"))
                    continue
                }
                claimed.insert(destination.path)
                entries.append(.init(source: file.path, destination: destination.path, studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: sop, skipReason: nil))
            } catch {
                entries.append(.init(source: file.path, destination: nil, studyInstanceUID: nil, seriesInstanceUID: nil, sopInstanceUID: nil,
                                     skipReason: "not readable as Part 10: \(error)"))
            }
        }
        return DicomStudyOrganizerPlan(root: root.path, entries: entries)
    }

    /// Applies a plan with caller-approved sources; decoded plans must be reviewed before applying.
    /// Destinations are confined to `root`, including symlink resolution. Never overwrites.
    public static func apply(_ plan: DicomStudyOrganizerPlan, mode: Mode, fileManager: FileManager = .default,
                             isCancelled: () -> Bool = { false }) -> DicomStudyOrganizerResult {
        var applied: [DicomStudyOrganizerPlan.Entry] = [], failures: [DicomStudyOrganizerResult.Failure] = []
        for entry in plan.planned {
            if isCancelled() { return DicomStudyOrganizerResult(applied: applied, failures: failures, cancelled: true) }
            guard let destination = entry.destination else { continue }
            do {
                let root = try canonicalURL(URL(fileURLWithPath: plan.root), fileManager: fileManager)
                let source = try canonicalURL(URL(fileURLWithPath: entry.source), fileManager: fileManager)
                let target = try canonicalURL(URL(fileURLWithPath: destination), fileManager: fileManager)
                guard target.pathComponents.count > root.pathComponents.count,
                      target.pathComponents.starts(with: root.pathComponents) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Destination is outside the plan root"])
                }
                guard !fileManager.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch mode {
                case .copy: try fileManager.copyItem(at: source, to: target)
                case .move: try fileManager.moveItem(at: source, to: target)
                }
                applied.append(entry)
            } catch {
                failures.append(.init(source: entry.source, reason: error.localizedDescription))
            }
        }
        return DicomStudyOrganizerResult(applied: applied, failures: failures, cancelled: false)
    }

    /// Resolve the existing ancestor before appending absent components: realpath alone cannot resolve
    /// a symlink in a destination whose final file or directory has not been created yet.
    private static func canonicalURL(_ url: URL, fileManager: FileManager) throws -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !fileManager.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/",
                  (try? fileManager.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }
}
