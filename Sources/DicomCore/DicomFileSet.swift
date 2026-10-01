import Foundation

/// PS3.10 File-set mechanisms over `DicomDirectory`: the leaf record type of each SOP Class with its record
/// selection keys (PS3.3 F.5), a validator that resolves every reference inside the media root, and a builder
/// that publishes a media directory atomically (staging directory, then rename) without touching the sources.
public enum DicomFileSet {
    // MARK: - Record types

    /// PS3.3 F.4 leaf record type of a SOP Class, with the F.5 record selection keys it copies from the instance.
    public struct RecordProfile: Equatable, Sendable {
        public let recordType: String
        /// File ID directory component under which such instances are stored.
        public let directoryComponent: String
        /// Tags copied into the record as selection keys (Instance Number is always copied).
        public let keyTags: [Int]
    }

    private static let imageSOPClassUIDs: Set<String> = Set([
        "1", "2", "2.1", "2.2", "4", "4.1", "4.4", "7", "7.1", "7.2", "7.3", "7.4", "12.1.1", "30", "66.4", "66.7"
    ].map { "1.2.840.10008.5.1.4.1.1." + $0 })

    /// Explicit SOP Class subset for which directory record selection keys are implemented.
    public static let supportedSOPClassUIDs: Set<String> = imageSOPClassUIDs
        .union(DicomPresentationStateModules.Profile.allCases.map(\.rawValue))
        .union(DicomSRProfileConstraints.allCases.map(\.rawValue))
        .union(DicomWaveformModules.Profile.allCases.map(\.rawValue))
        .union(DicomEncapsulatedDocumentModules.Profile.allCases.map(\.rawValue))
        .union(["1.2.840.10008.5.1.4.1.1.88.11", "1.2.840.10008.5.1.4.1.1.66.1", "1.2.840.10008.5.1.4.1.1.66.5",
                "1.2.840.10008.5.1.4.1.1.481.2", "1.2.840.10008.5.1.4.1.1.481.3", "1.2.840.10008.5.1.4.1.1.481.5"])

    public static func recordProfile(forSOPClassUID uid: String) -> RecordProfile? {
        let ps = DicomPresentationStateModules.Profile(rawValue: uid) != nil
        if ps { return .init(recordType: "PRESENTATION", directoryComponent: "PS", keyTags: [0x00700082, 0x00700083, 0x00700080, 0x00700081, 0x00700084, 0x00081115, 0x00700402]) }
        switch uid {
        case "1.2.840.10008.5.1.4.1.1.88.59":
            return .init(recordType: "KEY OBJECT DOC", directoryComponent: "KO", keyTags: [0x00080023, 0x00080033, 0x0040A043])
        case "1.2.840.10008.5.1.4.1.1.481.2":
            return .init(recordType: "RT DOSE", directoryComponent: "RTDOSE", keyTags: [0x3004000A, 0x30040006])
        case "1.2.840.10008.5.1.4.1.1.481.3":
            return .init(recordType: "RT STRUCTURE SET", directoryComponent: "RTSTRUCT", keyTags: [0x30060002, 0x30060008, 0x30060009])
        case "1.2.840.10008.5.1.4.1.1.481.5":
            return .init(recordType: "RT PLAN", directoryComponent: "RTPLAN", keyTags: [0x300A0002, 0x300A0006, 0x300A0007])
        case "1.2.840.10008.5.1.4.1.1.66.1":
            return .init(recordType: "REGISTRATION", directoryComponent: "REG", keyTags: [0x00080023, 0x00080033, 0x00700080, 0x00700081, 0x00700084])
        case "1.2.840.10008.5.1.4.1.1.66.5":
            return .init(recordType: "SURFACE", directoryComponent: "SURFACE", keyTags: [0x00080023, 0x00080033, 0x00700080, 0x00700081, 0x00700084])
        default:
            break
        }
        if DicomSRProfileConstraints(rawValue: uid) != nil || uid == "1.2.840.10008.5.1.4.1.1.88.11" {
            return .init(recordType: "SR DOCUMENT", directoryComponent: "SR", keyTags: [0x0040A491, 0x0040A493, 0x00080023, 0x00080033, 0x0040A030, 0x0040A043])
        }
        if DicomWaveformModules.Profile(rawValue: uid) != nil {
            return .init(recordType: "WAVEFORM", directoryComponent: "WAVEFORM", keyTags: [0x00080023, 0x00080033])
        }
        if DicomEncapsulatedDocumentModules.Profile(rawValue: uid) != nil {
            return .init(recordType: "ENCAP DOC", directoryComponent: "DOCS", keyTags: [0x00080023, 0x00080033, 0x00420010, 0x0040E001, 0x0040A043, 0x00420012])
        }
        if imageSOPClassUIDs.contains(uid) {
            return .init(recordType: "IMAGE", directoryComponent: "IMAGES", keyTags: [])
        }
        return nil
    }

    /// A leaf record for a Part 10 instance (File ID assigned by the caller).
    public static func leafRecord(for dataSet: DicomDataSet, fileMeta: DicomPart10FileMetaParser.FileMeta, fileID: [String]) throws -> DicomDirectoryImage {
        guard let sopClass = fileMeta.mediaStorageSOPClassUID ?? dataSet.string(for: .sopClassUID),
              let profile = recordProfile(forSOPClassUID: sopClass) else {
            throw Error.unsupportedSOPClass(fileMeta.mediaStorageSOPClassUID ?? "")
        }
        let identityIssues = identityMismatches(in: dataSet, fileMeta: fileMeta, fileID: fileID)
        guard identityIssues.isEmpty else { throw Error.inconsistentFileSet(identityIssues) }
        var keys: [DicomDataElement] = []
        // Keys are stored without dictionary names so a record equals its reparsed form.
        for tag in profile.keyTags {
            if tag == 0x0040A030, profile.recordType == "SR DOCUMENT" {
                if let latest = latestVerificationDateTime(in: dataSet) {
                    keys.append(.init(tag: tag, vr: .DT, value: .strings([latest])))
                }
            } else if let element = dataSet[tag] { keys.append(DicomDataElement(tag: element.tag, vr: element.vr, value: element.value)) }
        }
        if let charset = dataSet[0x00080005], !keys.isEmpty { keys.append(DicomDataElement(tag: charset.tag, vr: charset.vr, value: charset.value)) }
        let record = DicomDirectoryImage(
            referencedFileID: fileID,
            referencedSOPClassUID: sopClass,
            referencedSOPInstanceUID: fileMeta.mediaStorageSOPInstanceUID ?? dataSet.string(for: .sopInstanceUID),
            referencedTransferSyntaxUID: fileMeta.transferSyntaxUID,
            instanceNumber: dataSet.integerString(for: .instanceNumber),
            recordType: profile.recordType,
            keys: keys
        )
        let issues = missingRecordKeys(record, profile: profile)
        guard issues.isEmpty else { throw Error.inconsistentFileSet(issues) }
        return record
    }

    private static func identityMismatches(in dataSet: DicomDataSet, fileMeta: DicomPart10FileMetaParser.FileMeta, fileID: [String]) -> [Issue] {
        let identities = [(DicomTag.sopClassUID, "SOP Class UID", fileMeta.mediaStorageSOPClassUID),
                          (.sopInstanceUID, "SOP Instance UID", fileMeta.mediaStorageSOPInstanceUID)]
        return identities.compactMap { tag, name, metaValue in
            guard let metaValue, let dataSetValue = dataSet.string(for: tag), metaValue != dataSetValue else { return nil }
            return Issue(code: .referenceMismatch, fileID: fileID, detail: "\(name) differs between the data set and file meta")
        }
    }

    private static func latestVerificationDateTime(in dataSet: DicomDataSet) -> String? {
        let dates = dataSet[0x0040A073]?.sequenceItems.compactMap { $0.dataSet.string(for: 0x0040A030) } ?? []
        let inheritedOffset = dataSet.string(for: 0x00080201).map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmssZ"
        var latest: (value: String, date: Date)?
        var hasKnownOffset: Bool?
        for value in dates {
            guard DicomTemporalValueValidator.valid(value, vr: .DT, query: false) else { return nil }
            var text = value.trimmingCharacters(in: .whitespaces)
            let explicitOffset = ["+", "-"].contains(text.suffix(5).first) ? String(text.suffix(5)) : nil
            if explicitOffset != nil { text.removeLast(5) }
            let offset = explicitOffset ?? inheritedOffset
            // A local DT and an absolute DT cannot be ordered without the local UTC offset.
            if let hasKnownOffset, hasKnownOffset != (offset != nil) { return nil }
            hasKnownOffset = offset != nil
            guard DicomTemporalValueValidator.valid("2000" + (offset ?? ""), vr: .DT, query: false) else { return nil }
            let parts = text.split(separator: ".")
            var digits = String(parts[0])
            digits += String("00000101000000".dropFirst(digits.count))
            let leapSecond = digits.hasSuffix("60")
            if leapSecond { digits.replaceSubrange(digits.index(digits.endIndex, offsetBy: -2)..., with: "59") }
            guard let date = formatter.date(from: digits + (offset ?? "+0000")) else { return nil }
            let fraction = parts.count == 2 ? (Double("0." + parts[1]) ?? 0) : 0
            let instant = date.addingTimeInterval(fraction + (leapSecond ? 1 : 0))
            if latest == nil || instant > latest!.date {
                latest = (text + (offset ?? ""), instant)
            }
        }
        return latest?.value
    }

    /// PS3.3 F.5 key requirements; Type 2 keys must exist but may have no value.
    private static func missingRecordKeys(_ record: DicomDirectoryImage, profile: RecordProfile) -> [Issue] {
        let dataSet = DicomDataSet(elements: record.keys)
        var missing: [Int] = record.instanceNumber == nil ? [0x00200013] : []
        for tag in profile.keyTags {
            if tag == 0x30040006 { continue } // Dose Comment is Type 3.
            if tag == 0x0040A030, dataSet.string(for: 0x0040A493)?.trimmingCharacters(in: .whitespaces) != "VERIFIED" { continue }
            let blending = record.referencedSOPClassUID == DicomPresentationStateModules.Profile.blending.rawValue
            if tag == 0x00081115, blending { continue }
            if tag == 0x00700402, !blending, !dataSet.contains(tag) { continue }
            if tag == 0x0040E001, record.referencedSOPClassUID != DicomEncapsulatedDocumentModules.Profile.cda.rawValue { continue }
            let type2 = [0x00700081, 0x00700084, 0x30060008, 0x30060009, 0x300A0006, 0x300A0007].contains(tag)
                || profile.recordType == "ENCAP DOC" && [0x00080023, 0x00080033, 0x00420010, 0x0040A043].contains(tag)
            guard let element = dataSet[tag] else { missing.append(tag); continue }
            if !type2 {
                let populated: Bool
                switch element.value {
                case .empty: populated = false
                case .strings(let values): populated = values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                case .sequence(let items): populated = !items.isEmpty
                case .bytes(let bytes): populated = !bytes.isEmpty
                case .signedIntegers(let values): populated = !values.isEmpty
                case .unsignedIntegers(let values): populated = !values.isEmpty
                case .floats(let values): populated = !values.isEmpty
                }
                if !populated { missing.append(tag) }
            }
        }
        return missing.map { .init(code: .missingRecordKey, fileID: record.referencedFileID, detail: String(format: "%08X", $0)) }
    }

    // MARK: - File IDs

    /// PS3.10 8.5: at most 8 components of 1–8 characters from A–Z, 0–9 and underscore.
    public static func isValidFileID(_ components: [String]) -> Bool {
        !components.isEmpty && components.count <= 8 && components.allSatisfy { component in
            (1...8).contains(component.count) && component.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        }
    }

    public static func isValidFileSetID(_ id: String) -> Bool {
        (1...16).contains(id.count) && id.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == " " }
    }

    // MARK: - Errors

    public enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedSOPClass(String)
        case sourceIsNotPart10(String)
        case sourceIsSymbolicLink(String)
        case invalidFileSetID(String)
        case destinationExists(String)
        case destinationOutsideParent(String)
        case duplicateSOPInstanceUID(String)
        case inconsistentFileSet([Issue])
        case missingDICOMDIR(String)
        case tooManyInstances(Int)
    }

    // MARK: - Validation

    public struct Issue: Equatable, Sendable {
        public enum Code: String, Sendable {
            case structural
            case invalidFileID
            case invalidFileSetID
            case referenceEscapesRoot
            case referencedFileMissing
            case referencedFileIsSymbolicLink
            case referencedFileNotPart10
            case referenceMismatch
            case duplicateSOPInstanceUID
            case unsupportedRecordType
            case missingRecordKey
            case unreferencedFile
        }

        public let code: Code
        public let fileID: [String]
        public let detail: String

        public init(code: Code, fileID: [String] = [], detail: String) { self.code = code; self.fileID = fileID; self.detail = detail }
    }

    public struct ValidationReport: Equatable, Sendable {
        public let directory: DicomDirectory
        public let issues: [Issue]
        public let referencedInstanceCount: Int
        /// True when every reference resolves inside the root to a matching Part 10 instance and the structure is sound.
        public var isConsistent: Bool { issues.allSatisfy { $0.code == .unreferencedFile } }
    }

    /// Validates the DICOMDIR at `directoryFileURL` against the media rooted at its parent directory.
    public static func validate(directoryFileURL: URL, fileManager: FileManager = .default) throws -> ValidationReport {
        try validate(directoryFileURL: directoryFileURL, root: directoryFileURL.deletingLastPathComponent(),
                     stagedFiles: [:], fileManager: fileManager)
    }

    private static func validate(directoryFileURL: URL, root: URL, stagedFiles: [String: URL],
                                 fileManager: FileManager) throws -> ValidationReport {
        let read = try DicomDirectoryReader.readWithDiagnostics(from: directoryFileURL)
        var issues = read.diagnostics.map { Issue(code: .structural, detail: "\($0.code.rawValue): \($0.detail)") }
        if let id = read.directory.fileSetID, !id.isEmpty, !isValidFileSetID(id) { issues.append(.init(code: .invalidFileSetID, detail: id)) }
        var seenInstances: Set<String> = []
        var referencedPaths: Set<String> = []
        var count = 0
        for patient in read.directory.patients {
            for study in patient.studies {
                for series in study.series {
                    for leaf in series.images {
                        count += 1
                        try Task.checkCancellation()
                        // An escaping reference is reported as such even though it is also an invalid File ID.
                        let fileURL: URL
                        do { fileURL = try leaf.resolvedFileURL(relativeTo: root) } catch {
                            issues.append(.init(code: .referenceEscapesRoot, fileID: leaf.referencedFileID, detail: leaf.referencedFileID.joined(separator: "/"))); continue
                        }
                        guard isValidFileID(leaf.referencedFileID) else {
                            issues.append(.init(code: .invalidFileID, fileID: leaf.referencedFileID, detail: leaf.referencedFileID.joined(separator: "/"))); continue
                        }
                        guard DicomDirectoryReader.leafRecordTypes.contains(leaf.recordType) else {
                            issues.append(.init(code: .unsupportedRecordType, fileID: leaf.referencedFileID, detail: leaf.recordType)); continue
                        }
                        if let sop = leaf.referencedSOPInstanceUID, !seenInstances.insert(sop).inserted {
                            issues.append(.init(code: .duplicateSOPInstanceUID, fileID: leaf.referencedFileID, detail: sop))
                        }
                        for (name, value) in [("Referenced SOP Instance UID", leaf.referencedSOPInstanceUID),
                                              ("Referenced SOP Class UID", leaf.referencedSOPClassUID),
                                              ("Referenced Transfer Syntax UID", leaf.referencedTransferSyntaxUID)] {
                            if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                                issues.append(.init(code: .missingRecordKey, fileID: leaf.referencedFileID, detail: name))
                            }
                        }
                        if let uid = leaf.referencedSOPClassUID {
                            if let profile = recordProfile(forSOPClassUID: uid) {
                                issues += missingRecordKeys(leaf, profile: profile)
                                if profile.recordType != leaf.recordType {
                                    issues.append(.init(code: .unsupportedRecordType, fileID: leaf.referencedFileID, detail: "\(leaf.recordType) for a \(profile.recordType) SOP Class"))
                                }
                            } else {
                                issues.append(.init(code: .unsupportedRecordType, fileID: leaf.referencedFileID, detail: uid))
                            }
                        }
                        referencedPaths.insert(fileURL.standardizedFileURL.path)
                        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                            issues.append(.init(code: .referencedFileIsSymbolicLink, fileID: leaf.referencedFileID, detail: fileURL.lastPathComponent)); continue
                        }
                        guard isContained(fileURL, in: root) else {
                            issues.append(.init(code: .referenceEscapesRoot, fileID: leaf.referencedFileID, detail: fileURL.lastPathComponent)); continue
                        }
                        let readableURL = stagedFiles[fileURL.standardizedFileURL.path] ?? fileURL
                        guard fileManager.fileExists(atPath: readableURL.path) else {
                            issues.append(.init(code: .referencedFileMissing, fileID: leaf.referencedFileID, detail: fileURL.lastPathComponent)); continue
                        }
                        guard let data = try? Data(contentsOf: readableURL, options: .mappedIfSafe), DicomPart10FileMetaParser.hasPart10Prefix(data),
                              let meta = try? DicomPart10FileMetaParser.parse(data) else {
                            issues.append(.init(code: .referencedFileNotPart10, fileID: leaf.referencedFileID, detail: fileURL.lastPathComponent)); continue
                        }
                        if let expected = leaf.referencedSOPInstanceUID, expected != meta.mediaStorageSOPInstanceUID {
                            issues.append(.init(code: .referenceMismatch, fileID: leaf.referencedFileID, detail: "SOP Instance UID differs from the file meta"))
                        }
                        if let expected = leaf.referencedSOPClassUID, expected != meta.mediaStorageSOPClassUID {
                            issues.append(.init(code: .referenceMismatch, fileID: leaf.referencedFileID, detail: "SOP Class UID differs from the file meta"))
                        }
                        if let expected = leaf.referencedTransferSyntaxUID, expected != meta.transferSyntaxUID {
                            issues.append(.init(code: .referenceMismatch, fileID: leaf.referencedFileID, detail: "Transfer Syntax UID differs from the file meta"))
                        }
                        guard let decoder = try? DCMDecoder(data: data) else {
                            issues.append(.init(code: .structural, fileID: leaf.referencedFileID, detail: "Referenced data set could not be read")); continue
                        }
                        let identity = DicomDataSet(elements: [DicomTag.sopClassUID, .sopInstanceUID].compactMap { decoder.dataElement(for: $0) })
                        issues += identityMismatches(in: identity, fileMeta: meta, fileID: leaf.referencedFileID)
                    }
                }
            }
        }
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.lastPathComponent != "DICOMDIR" else { continue }
                if !referencedPaths.contains(url.standardizedFileURL.path) {
                    issues.append(.init(code: .unreferencedFile, detail: url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1).description))
                }
            }
        }
        return ValidationReport(directory: read.directory, issues: issues, referencedInstanceCount: count)
    }

    // MARK: - Building and updating

    public struct BuildResult: Equatable, Sendable {
        public let rootURL: URL
        public let directoryFileURL: URL
        public let instanceCount: Int
        public let recordTypes: [String: Int]
    }

    /// Publishes a new file-set directory at `destination` (which must not exist) with a DICOMDIR and one copy of
    /// every instance; staging happens in a hidden sibling directory renamed into place at the end.
    public static func build(files: [URL], destination: URL, fileSetID: String, fileManager: FileManager = .default,
                             maximumInstances: Int = 100_000) async throws -> BuildResult {
        guard isValidFileSetID(fileSetID) else { throw Error.invalidFileSetID(fileSetID) }
        guard !fileManager.fileExists(atPath: destination.path) else { throw Error.destinationExists(destination.path) }
        guard files.count <= maximumInstances else { throw Error.tooManyInstances(files.count) }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: staging) } }
        let entries = try await stage(files: files, into: staging, existing: [], fileManager: fileManager)
        let directory = assemble(entries: entries, fileSetID: fileSetID)
        try DicomDirectoryWriter.write(directory, to: staging.appendingPathComponent("DICOMDIR"))
        let report = try validate(directoryFileURL: staging.appendingPathComponent("DICOMDIR"), fileManager: fileManager)
        guard report.isConsistent else { throw Error.inconsistentFileSet(report.issues) }
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: destination)
        committed = true
        return BuildResult(rootURL: destination, directoryFileURL: destination.appendingPathComponent("DICOMDIR"),
                           instanceCount: entries.count, recordTypes: Dictionary(entries.map { ($0.record.recordType, 1) }, uniquingKeysWith: +))
    }

    /// Adds instances to an existing file-set: files are staged beside the root, the DICOMDIR is rewritten in a
    /// temporary file and swapped atomically; on any failure the existing file-set is left as it was.
    public static func add(files: [URL], toFileSetAt root: URL, fileManager: FileManager = .default) async throws -> BuildResult {
        let directoryFileURL = root.appendingPathComponent("DICOMDIR")
        guard fileManager.fileExists(atPath: directoryFileURL.path) else { throw Error.missingDICOMDIR(directoryFileURL.path) }
        let existingReport = try validate(directoryFileURL: directoryFileURL, fileManager: fileManager)
        guard existingReport.isConsistent else { throw Error.inconsistentFileSet(existingReport.issues) }
        let existing = existingReport.directory
        let existingLeaves = existing.patients.flatMap { $0.studies.flatMap { $0.series.flatMap(\.images) } }
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        // The staging directory holds nothing after publication (files moved, DICOMDIR swapped) and is always removed.
        defer { try? fileManager.removeItem(at: staging) }
        let entries = try await stage(files: files, into: staging, existing: existingLeaves, fileManager: fileManager)
        var merged = existing
        for entry in entries { merged = inserting(entry, into: merged) }
        let temporaryDirectory = staging.appendingPathComponent("DICOMDIR")
        try DicomDirectoryWriter.write(merged, to: temporaryDirectory)
        var destinations: [URL] = []
        var stagedFiles: [String: URL] = [:]
        for entry in entries {
            let final = try DicomDirectoryPathResolver.resolve(entry.record.referencedFileID, relativeTo: root)
            guard isContained(final, in: root) else { throw Error.destinationOutsideParent(final.path) }
            guard !fileManager.fileExists(atPath: final.path) else { throw Error.destinationExists(final.path) }
            destinations.append(final)
            stagedFiles[final.standardizedFileURL.path] = entry.stagedURL
        }
        let report = try validate(directoryFileURL: temporaryDirectory, root: root, stagedFiles: stagedFiles, fileManager: fileManager)
        guard report.isConsistent else { throw Error.inconsistentFileSet(report.issues) }
        try Task.checkCancellation()
        var published: [URL] = [], createdDirectories: [URL] = []
        do {
            for (entry, final) in zip(entries, destinations) {
                try Task.checkCancellation()
                guard isContained(final, in: root) else { throw Error.destinationOutsideParent(final.path) }
                let parent = final.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: false)
                    createdDirectories.append(parent)
                }
                try fileManager.moveItem(at: entry.stagedURL, to: final)
                published.append(final)
            }
            try Task.checkCancellation()
            _ = try fileManager.replaceItemAt(directoryFileURL, withItemAt: temporaryDirectory)
        } catch {
            for url in published.reversed() { try? fileManager.removeItem(at: url) }
            for url in createdDirectories.reversed() { try? fileManager.removeItem(at: url) }
            throw error
        }
        return BuildResult(rootURL: root, directoryFileURL: directoryFileURL, instanceCount: report.referencedInstanceCount,
                           recordTypes: Dictionary(entries.map { ($0.record.recordType, 1) }, uniquingKeysWith: +))
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/")
    }

    struct StagedEntry {
        let record: DicomDirectoryImage
        let patient: DicomDirectoryPatient
        let study: DicomDirectoryStudy
        let series: DicomDirectorySeries
        let stagedURL: URL
    }

    private static func stage(files: [URL], into staging: URL, existing: [DicomDirectoryImage], fileManager: FileManager) async throws -> [StagedEntry] {
        var seen = Set(existing.compactMap(\.referencedSOPInstanceUID))
        var counters: [String: Int] = [:]
        for leaf in existing where leaf.referencedFileID.count == 2 {
            let number = Int(leaf.referencedFileID[1].drop { !$0.isNumber }) ?? 0
            counters[leaf.referencedFileID[0]] = max(counters[leaf.referencedFileID[0]] ?? 0, number)
        }
        var entries: [StagedEntry] = []
        for file in files {
            try Task.checkCancellation()
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Error.sourceIsSymbolicLink(file.lastPathComponent) }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw Error.sourceIsNotPart10(file.lastPathComponent) }
            let meta = try DicomPart10FileMetaParser.parse(data)
            let decoder = try DCMDecoder(data: data)
            let dataSet = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
            guard let sop = meta.mediaStorageSOPInstanceUID ?? dataSet.string(for: .sopInstanceUID), seen.insert(sop).inserted else {
                throw Error.duplicateSOPInstanceUID(meta.mediaStorageSOPInstanceUID ?? file.lastPathComponent)
            }
            guard let profile = recordProfile(forSOPClassUID: meta.mediaStorageSOPClassUID ?? "") else { throw Error.unsupportedSOPClass(meta.mediaStorageSOPClassUID ?? "") }
            let number = (counters[profile.directoryComponent] ?? 0) + 1
            counters[profile.directoryComponent] = number
            let fileID = [profile.directoryComponent, String(format: "%@%07d", String(profile.directoryComponent.prefix(1)), number)]
            let record = try leafRecord(for: dataSet, fileMeta: meta, fileID: fileID)
            let stagedURL = try DicomDirectoryPathResolver.resolve(fileID, relativeTo: staging)
            try fileManager.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: stagedURL)
            entries.append(StagedEntry(
                record: record,
                patient: DicomDirectoryPatient(patientID: dataSet.string(for: .patientID), patientName: dataSet.string(for: .patientName), studies: []),
                study: DicomDirectoryStudy(studyInstanceUID: dataSet.string(for: .studyInstanceUID), studyID: dataSet.string(for: .studyID),
                                           studyDate: dataSet.string(for: .studyDate), studyTime: dataSet.string(for: .studyTime),
                                           studyDescription: dataSet.string(for: .studyDescription), accessionNumber: dataSet.string(for: .accessionNumber), series: []),
                series: DicomDirectorySeries(seriesInstanceUID: dataSet.string(for: .seriesInstanceUID), modality: dataSet.string(for: .modality),
                                             seriesNumber: dataSet.integerString(for: .seriesNumber), images: []),
                stagedURL: stagedURL))
        }
        return entries
    }

    private static func assemble(entries: [StagedEntry], fileSetID: String) -> DicomDirectory {
        var directory = DicomDirectory(fileSetID: fileSetID, patients: [])
        for entry in entries { directory = inserting(entry, into: directory) }
        return directory
    }

    private static func inserting(_ entry: StagedEntry, into directory: DicomDirectory) -> DicomDirectory {
        var directory = directory
        let patientIndex = directory.patients.firstIndex { $0.patientID == entry.patient.patientID && $0.patientName == entry.patient.patientName }
            ?? { directory.patients.append(entry.patient); return directory.patients.count - 1 }()
        let studyIndex = directory.patients[patientIndex].studies.firstIndex { $0.studyInstanceUID == entry.study.studyInstanceUID }
            ?? { directory.patients[patientIndex].studies.append(entry.study); return directory.patients[patientIndex].studies.count - 1 }()
        let seriesIndex = directory.patients[patientIndex].studies[studyIndex].series.firstIndex { $0.seriesInstanceUID == entry.series.seriesInstanceUID }
            ?? { directory.patients[patientIndex].studies[studyIndex].series.append(entry.series); return directory.patients[patientIndex].studies[studyIndex].series.count - 1 }()
        directory.patients[patientIndex].studies[studyIndex].series[seriesIndex].images.append(entry.record)
        return directory
    }
}
