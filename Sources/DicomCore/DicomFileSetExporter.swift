import Foundation
import ZIPFoundation

/// Creates a General Purpose DICOM ZIP File-set while preserving the selected
/// Part 10 instances byte-for-byte.
public final class DicomFileSetExporter: @unchecked Sendable {
    /// Named DICOM Media Storage Application Profile implemented by this exporter.
    public static let applicationProfile = "STD-GEN-ZIP-MAIL"

    /// Storage SOP Classes accepted by the implementation-specific profile subset.
    public static let supportedSOPClassUIDs = DicomFileSet.supportedSOPClassUIDs

    /// Transfer syntaxes accepted and preserved byte-for-byte by the profile subset.
    public static let supportedTransferSyntaxUIDs: Set<String> = [
        DicomTransferSyntax.implicitVRLittleEndian.rawValue,
        DicomTransferSyntax.explicitVRLittleEndian.rawValue,
        DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue,
        DicomTransferSyntax.jpegBaseline.rawValue,
        DicomTransferSyntax.jpegExtended.rawValue,
        DicomTransferSyntax.jpegLossless.rawValue,
        DicomTransferSyntax.jpegLosslessFirstOrder.rawValue,
        DicomTransferSyntax.jpegLSLossless.rawValue,
        DicomTransferSyntax.jpegLSNearLossless.rawValue,
        DicomTransferSyntax.jpeg2000Lossless.rawValue,
        DicomTransferSyntax.jpeg2000.rawValue,
        DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue,
        DicomTransferSyntax.jpeg2000Part2Multicomponent.rawValue,
        DicomTransferSyntax.rleLossless.rawValue,
        DicomTransferSyntax.deflatedImageFrameCompression.rawValue
    ]

    /// Stable validation and destination failures reported before publishing an archive.
    public enum ExportError: LocalizedError, Equatable, Sendable {
        case emptySelection
        case invalidFileSetID(String)
        case sourceIsNotPart10(String)
        case missingAttribute(file: String, attribute: String)
        case unsupportedSOPClass(file: String, uid: String)
        case unsupportedTransferSyntax(file: String, uid: String)
        case duplicateSOPInstanceUID(String)
        case inconsistentHierarchy(String)
        case tooManyInstances(Int)
        case destinationExists(String)
        case insufficientSpace(required: Int64, available: Int64)
        case generatedDirectoryInvalid

        /// User-facing description of the rejected selection or destination.
        public var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "Select at least one DICOM instance."
            case .invalidFileSetID(let value):
                return "The File-set ID \(value) must contain 1–16 uppercase letters, digits, or underscores."
            case .sourceIsNotPart10(let file):
                return "\(file) is not a DICOM Part 10 file."
            case .missingAttribute(let file, let attribute):
                return "\(file) is missing the required \(attribute)."
            case .unsupportedSOPClass(let file, let uid):
                return "\(file) uses SOP Class \(uid), which is not supported by " +
                    "\(DicomFileSetExporter.applicationProfile)."
            case .unsupportedTransferSyntax(let file, let uid):
                return "\(file) uses transfer syntax \(uid), which is not supported by " +
                    "\(DicomFileSetExporter.applicationProfile)."
            case .duplicateSOPInstanceUID(let uid):
                return "The selection contains duplicate SOP Instance UID \(uid)."
            case .inconsistentHierarchy(let reason):
                return "The selected DICOM hierarchy is inconsistent: \(reason)."
            case .tooManyInstances(let count):
                return "The selection contains \(count) instances; this File-set supports at most 9,999,999."
            case .destinationExists(let file):
                return "The export destination already exists: \(file)."
            case .insufficientSpace(let required, let available):
                return "The export needs \(required) bytes, but only \(available) bytes are available."
            case .generatedDirectoryInvalid:
                return "The generated DICOMDIR could not be reopened."
            }
        }
    }

    /// Description of a successfully published DICOM ZIP File-set.
    public struct Result: Equatable, Sendable {
        /// Final archive URL.
        public let archiveURL: URL
        /// Named profile used to create the archive.
        public let applicationProfile: String
        /// Number of referenced Part 10 instances.
        public let instanceCount: Int

        /// Creates a successful export result.
        public init(archiveURL: URL, applicationProfile: String, instanceCount: Int) {
            self.archiveURL = archiveURL
            self.applicationProfile = applicationProfile
            self.instanceCount = instanceCount
        }
    }

    private struct Source {
        let url: URL
        let fileSize: Int64
        let patientID: String
        let patientName: String
        let studyInstanceUID: String
        let studyID: String?
        let studyDate: String?
        let studyTime: String?
        let studyDescription: String?
        let accessionNumber: String?
        let seriesInstanceUID: String
        let modality: String
        let seriesNumber: Int?
        let sopClassUID: String
        let sopInstanceUID: String
        let transferSyntaxUID: String
        let instanceNumber: Int?
        var referencedFileID: [String]
        /// Leaf record with the PS3.3 F.5 keys of the instance's record type.
        let record: DicomDirectoryImage
    }

    private let fileManager: FileManager
    private let availableCapacity: @Sendable (URL) throws -> Int64?

    /// Creates a File-set exporter.
    /// - Parameters:
    ///   - fileManager: File manager used for source and destination operations.
    ///   - availableCapacity: Capacity probe for the destination volume.
    public init(
        fileManager: FileManager = .default,
        availableCapacity: @escaping @Sendable (URL) throws -> Int64? = { url in
            try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    ) {
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
    }

    /// Validates and exports Part 10 instances as a root `DICOM.ZIP` File-set.
    /// - Parameters:
    ///   - files: Selected Part 10 instance URLs.
    ///   - destinationURL: Nonexistent destination URL for the final ZIP archive.
    ///   - fileSetID: Restricted DICOM File-set ID written to `DICOMDIR`.
    /// - Returns: The published archive description.
    public func export(
        files: [URL],
        to destinationURL: URL,
        fileSetID: String = "ISIS_EXPORT"
    ) async throws -> Result {
        try Task.checkCancellation()
        guard !files.isEmpty else { throw ExportError.emptySelection }
        guard Self.isValidFileSetID(fileSetID) else { throw ExportError.invalidFileSetID(fileSetID) }
        guard files.count <= 9_999_999 else { throw ExportError.tooManyInstances(files.count) }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ExportError.destinationExists(destinationURL.lastPathComponent)
        }

        var sources = try files.map(parseSource)
        try validateHierarchy(sources)
        sources.sort(by: Self.sourceOrder)
        var counters: [String: Int] = [:]
        for index in sources.indices {
            let component = DicomFileSet.recordProfile(forSOPClassUID: sources[index].sopClassUID)?.directoryComponent ?? "IMAGES"
            let number = (counters[component] ?? 0) + 1
            counters[component] = number
            sources[index].referencedFileID = [component, String(format: "%@%07d", String(component.prefix(1)), number)]
        }

        let directory = Self.makeDirectory(fileSetID: fileSetID, sources: sources)
        let directoryData = try DicomDirectoryWriter.part10Data(
            from: directory,
            mediaStorageSOPInstanceUID: Self.makeUID()
        )
        guard try DicomDirectoryReader.read(data: directoryData) == directory else {
            throw ExportError.generatedDirectoryInvalid
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let requiredCapacity = sources.reduce(Int64(directoryData.count) + 1_048_576) {
            $0 + $1.fileSize + 512
        }
        if let capacity = try availableCapacity(parentURL), capacity < requiredCapacity {
            throw ExportError.insufficientSpace(required: requiredCapacity, available: capacity)
        }

        let stagingURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }

        let archive = try Archive(url: stagingURL, accessMode: .create)
        try archive.addEntry(
            with: "DICOMDIR",
            type: .file,
            uncompressedSize: Int64(directoryData.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return directoryData.subdata(in: start..<(start + size))
        }

        for source in sources {
            try Task.checkCancellation()
            try archive.addEntry(
                with: source.referencedFileID.joined(separator: "/"),
                fileURL: source.url,
                compressionMethod: .deflate
            )
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: stagingURL, to: destinationURL)

        return Result(
            archiveURL: destinationURL,
            applicationProfile: Self.applicationProfile,
            instanceCount: sources.count
        )
    }

    private func parseSource(_ url: URL) throws -> Source {
        try Task.checkCancellation()
        let fileName = url.lastPathComponent
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 132) ?? Data()
        guard header.count == 132, String(data: header[128..<132], encoding: .ascii) == "DICM" else {
            throw ExportError.sourceIsNotPart10(fileName)
        }

        let decoder = try DCMDecoder(contentsOf: url)
        func required(_ tag: DicomTag, _ name: String) throws -> String {
            let value = decoder.info(for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw ExportError.missingAttribute(file: fileName, attribute: name)
            }
            return value
        }
        func optional(_ tag: DicomTag) -> String? {
            let value = decoder.info(for: tag).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let sopClassUID = try required(.sopClassUID, "SOP Class UID")
        guard Self.supportedSOPClassUIDs.contains(sopClassUID) else {
            throw ExportError.unsupportedSOPClass(file: fileName, uid: sopClassUID)
        }
        let fileMeta = try DicomPart10FileMetaParser.parse(try Data(contentsOf: url, options: .mappedIfSafe))
        let record: DicomDirectoryImage
        do {
            record = try DicomFileSet.leafRecord(for: try DicomPart10PixelDataPreserver.dataSet(from: decoder), fileMeta: fileMeta, fileID: [])
        } catch DicomFileSet.Error.unsupportedSOPClass(let uid) {
            throw ExportError.unsupportedSOPClass(file: fileName, uid: uid)
        } catch DicomFileSet.Error.inconsistentFileSet(let issues) {
            throw ExportError.inconsistentHierarchy(issues.map { "\($0.code.rawValue): \($0.detail)" }.joined(separator: "; "))
        }
        let transferSyntaxUID = try required(.transferSyntaxUID, "Transfer Syntax UID")
        guard Self.supportedTransferSyntaxUIDs.contains(transferSyntaxUID) else {
            throw ExportError.unsupportedTransferSyntax(file: fileName, uid: transferSyntaxUID)
        }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0

        return Source(
            url: url,
            fileSize: fileSize,
            patientID: try required(.patientID, "Patient ID"),
            patientName: optional(.patientName) ?? "",
            studyInstanceUID: try required(.studyInstanceUID, "Study Instance UID"),
            studyID: optional(.studyID),
            studyDate: optional(.studyDate),
            studyTime: optional(.studyTime),
            studyDescription: optional(.studyDescription),
            accessionNumber: optional(.accessionNumber),
            seriesInstanceUID: try required(.seriesInstanceUID, "Series Instance UID"),
            modality: try required(.modality, "Modality"),
            seriesNumber: decoder.intValue(for: .seriesNumber),
            sopClassUID: sopClassUID,
            sopInstanceUID: try required(.sopInstanceUID, "SOP Instance UID"),
            transferSyntaxUID: transferSyntaxUID,
            instanceNumber: decoder.intValue(for: .instanceNumber),
            referencedFileID: [],
            record: record
        )
    }

    private func validateHierarchy(_ sources: [Source]) throws {
        var seenSOPInstanceUIDs: Set<String> = []
        var patientByStudy: [String: String] = [:]
        var studyBySeries: [String: String] = [:]
        var seriesByInstance: [String: String] = [:]
        var directoryValues: [String: String] = [:]

        for source in sources {
            guard seenSOPInstanceUIDs.insert(source.sopInstanceUID).inserted else {
                throw ExportError.duplicateSOPInstanceUID(source.sopInstanceUID)
            }
            try Self.assign(source.patientID, to: source.studyInstanceUID, in: &patientByStudy, label: "study")
            try Self.assign(source.studyInstanceUID, to: source.seriesInstanceUID, in: &studyBySeries, label: "series")
            try Self.assign(
                source.seriesInstanceUID,
                to: source.sopInstanceUID,
                in: &seriesByInstance,
                label: "instance"
            )
            try Self.validateDirectoryValue(
                source.patientName,
                field: "Patient Name",
                scope: source.patientID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.studyID,
                field: "Study ID",
                scope: source.studyInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.studyDate,
                field: "Study Date",
                scope: source.studyInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.studyTime,
                field: "Study Time",
                scope: source.studyInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.studyDescription,
                field: "Study Description",
                scope: source.studyInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.accessionNumber,
                field: "Accession Number",
                scope: source.studyInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.modality,
                field: "Modality",
                scope: source.seriesInstanceUID,
                values: &directoryValues
            )
            try Self.validateDirectoryValue(
                source.seriesNumber.map(String.init),
                field: "Series Number",
                scope: source.seriesInstanceUID,
                values: &directoryValues
            )
        }
    }

    private static func validateDirectoryValue(
        _ value: String?,
        field: String,
        scope: String,
        values: inout [String: String]
    ) throws {
        guard let value, !value.isEmpty else { return }
        let key = "\(scope)\u{1F}\(field)"
        if let existing = values[key], existing != value {
            throw ExportError.inconsistentHierarchy("\(scope) has conflicting \(field) values")
        }
        values[key] = value
    }

    private static func assign(
        _ parent: String,
        to identifier: String,
        in relationships: inout [String: String],
        label: String
    ) throws {
        if let existing = relationships[identifier], existing != parent {
            throw ExportError.inconsistentHierarchy("\(label) \(identifier) has more than one parent")
        }
        relationships[identifier] = parent
    }

    private static func makeDirectory(fileSetID: String, sources: [Source]) -> DicomDirectory {
        let patients = Dictionary(grouping: sources, by: \.patientID).keys.sorted().map { patientID in
            let patientSources = sources.filter { $0.patientID == patientID }
            let studies = Dictionary(grouping: patientSources, by: \.studyInstanceUID).keys.sorted().map { studyUID in
                let studySources = patientSources.filter { $0.studyInstanceUID == studyUID }
                let seriesKeys = Dictionary(grouping: studySources, by: \.seriesInstanceUID).keys.sorted()
                let series = seriesKeys.map { seriesUID in
                    let seriesSources = studySources.filter { $0.seriesInstanceUID == seriesUID }
                    let first = seriesSources[0]
                    return DicomDirectorySeries(
                        seriesInstanceUID: seriesUID,
                        modality: first.modality,
                        seriesNumber: first.seriesNumber,
                        images: seriesSources.map {
                            DicomDirectoryImage(
                                referencedFileID: $0.referencedFileID,
                                referencedSOPClassUID: $0.sopClassUID,
                                referencedSOPInstanceUID: $0.sopInstanceUID,
                                referencedTransferSyntaxUID: $0.transferSyntaxUID,
                                instanceNumber: $0.instanceNumber,
                                recordType: $0.record.recordType,
                                keys: $0.record.keys
                            )
                        }
                    )
                }
                let first = studySources[0]
                return DicomDirectoryStudy(
                    studyInstanceUID: studyUID,
                    studyID: first.studyID,
                    studyDate: first.studyDate,
                    studyTime: first.studyTime,
                    studyDescription: first.studyDescription,
                    accessionNumber: first.accessionNumber,
                    series: series
                )
            }
            return DicomDirectoryPatient(
                patientID: patientID,
                patientName: patientSources[0].patientName,
                studies: studies
            )
        }
        return DicomDirectory(fileSetID: fileSetID, patients: patients)
    }

    private static func sourceOrder(_ lhs: Source, _ rhs: Source) -> Bool {
        let left = [lhs.patientID, lhs.studyInstanceUID, lhs.seriesInstanceUID, lhs.sopInstanceUID]
        let right = [rhs.patientID, rhs.studyInstanceUID, rhs.seriesInstanceUID, rhs.sopInstanceUID]
        return left.lexicographicallyPrecedes(right)
    }

    private static func isValidFileSetID(_ value: String) -> Bool {
        guard (1...16).contains(value.count) else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    private static func makeUID() -> String {
        var uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        var digits = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = digits[index] * 256 + carry
                digits[index] = value % 10
                carry = value / 10
            }
            while carry > 0 {
                digits.append(carry % 10)
                carry /= 10
            }
        }
        return "2.25." + digits.reversed().map(String.init).joined()
    }
}
