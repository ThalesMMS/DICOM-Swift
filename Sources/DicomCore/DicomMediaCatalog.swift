import Foundation
import ZIPFoundation

public enum DicomMediaCatalogSourceKind: String, Equatable, Sendable {
    case file
    case directory
    case dicomDirectory
    case zip
}

public struct DicomMediaCatalog: Equatable, Sendable {
    public var sourceURL: URL
    public var sourceKind: DicomMediaCatalogSourceKind
    public var instances: [DicomMediaCatalogInstance]
    public var temporaryDirectoryURL: URL?

    public init(sourceURL: URL,
                sourceKind: DicomMediaCatalogSourceKind,
                instances: [DicomMediaCatalogInstance],
                temporaryDirectoryURL: URL? = nil) {
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.instances = instances
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }
}

public struct DicomMediaCatalogInstance: Equatable, Sendable {
    public var fileURL: URL?
    public var patientName: String
    public var patientID: String
    public var studyInstanceUID: String
    public var studyDate: String
    public var studyDescription: String
    public var seriesInstanceUID: String
    public var seriesDescription: String
    public var modality: String
    public var sopClassUID: String
    public var sopInstanceUID: String
    public var instanceNumber: Int?
    public var fileSize: Int64
    public var hasRenderablePixels: Bool

    public init(fileURL: URL?,
                patientName: String,
                patientID: String,
                studyInstanceUID: String,
                studyDate: String,
                studyDescription: String,
                seriesInstanceUID: String,
                seriesDescription: String,
                modality: String,
                sopClassUID: String,
                sopInstanceUID: String,
                instanceNumber: Int?,
                fileSize: Int64,
                hasRenderablePixels: Bool) {
        self.fileURL = fileURL
        self.patientName = patientName
        self.patientID = patientID
        self.studyInstanceUID = studyInstanceUID
        self.studyDate = studyDate
        self.studyDescription = studyDescription
        self.seriesInstanceUID = seriesInstanceUID
        self.seriesDescription = seriesDescription
        self.modality = modality
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.instanceNumber = instanceNumber
        self.fileSize = fileSize
        self.hasRenderablePixels = hasRenderablePixels
    }

    public var isSpecialObject: Bool {
        Self.specialObjectSOPClassUIDs.contains(sopClassUID)
    }

    public var displayModality: String {
        modality.dicomMediaCatalogNonEmpty ?? objectKindLabel ?? "OT"
    }

    public var objectKindLabel: String? {
        switch sopClassUID {
        case DicomSegmentationBuilder.segmentationStorageSOPClassUID:
            return "SEG"
        case DicomRTStructureSet.storageSOPClassUID:
            return "RTSTRUCT"
        case DicomRTDoseVolume.storageSOPClassUID:
            return "RTDOSE"
        case DicomRTPlan.storageSOPClassUID:
            return "RTPLAN"
        case DicomSpatialRegistrationDocument.storageSOPClassUID:
            return "REG"
        case DicomParametricMap.storageSOPClassUID:
            return "Parametric Map"
        default:
            if DicomGrayscalePresentationState.supportedStorageSOPClassUIDs.contains(sopClassUID) {
                return "Presentation State"
            }
            if DicomSRDocument.structuredReportSOPClassUIDs.contains(sopClassUID) {
                return sopClassUID == DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID ? "KOS" : "SR"
            }
            if DicomEncapsulatedDocument.supportedStorageSOPClassUIDs.contains(sopClassUID) {
                return "Document"
            }
            if DicomWaveform.supportedStorageSOPClassUIDs.contains(sopClassUID) {
                return "Waveform"
            }
            if DicomVideo.supportedStorageSOPClassUIDs.contains(sopClassUID) {
                return "Video"
            }
            return nil
        }
    }

    public static let specialObjectSOPClassUIDs: Set<String> = Set([
        DicomSegmentationBuilder.segmentationStorageSOPClassUID,
        DicomRTStructureSet.storageSOPClassUID,
        DicomRTDoseVolume.storageSOPClassUID,
        DicomRTPlan.storageSOPClassUID,
        DicomSpatialRegistrationDocument.storageSOPClassUID,
        DicomParametricMap.storageSOPClassUID
    ])
    .union(DicomGrayscalePresentationState.supportedStorageSOPClassUIDs)
    .union(DicomSRDocument.structuredReportSOPClassUIDs)
    .union(DicomEncapsulatedDocument.supportedStorageSOPClassUIDs)
    .union(DicomWaveform.supportedStorageSOPClassUIDs)
    .union(DicomVideo.supportedStorageSOPClassUIDs)
}

public final class DicomMediaCatalogBuilder {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func catalog(from url: URL) async throws -> DicomMediaCatalog {
        try catalogSynchronously(from: url)
    }

    public func catalogSynchronously(from url: URL) throws -> DicomMediaCatalog {
        guard url.isFileURL else {
            throw DicomSeriesSourceError.unsupportedURL(url)
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            throw DICOMError.fileNotFound(path: url.path)
        }

        if isDirectory.boolValue || url.hasDirectoryPath {
            let dicomDirectoryURL = url.appendingPathComponent("DICOMDIR", isDirectory: false)
            if fileManager.fileExists(atPath: dicomDirectoryURL.path) {
                return try catalogFromDICOMDirectory(dicomDirectoryURL: dicomDirectoryURL,
                                                     mediaRootURL: url,
                                                     sourceURL: url,
                                                     sourceKind: .dicomDirectory,
                                                     temporaryDirectoryURL: nil)
            }
            return try catalogFromDirectory(url, sourceURL: url, sourceKind: .directory, temporaryDirectoryURL: nil)
        }

        if url.lastPathComponent.caseInsensitiveCompare("DICOMDIR") == .orderedSame {
            return try catalogFromDICOMDirectory(dicomDirectoryURL: url,
                                                 mediaRootURL: url.deletingLastPathComponent(),
                                                 sourceURL: url,
                                                 sourceKind: .dicomDirectory,
                                                 temporaryDirectoryURL: nil)
        }

        if url.pathExtension.lowercased() == "zip" {
            let prepared = try unzipMediaArchive(url)
            let dicomDirectoryURL = prepared.directory.appendingPathComponent("DICOMDIR", isDirectory: false)
            if fileManager.fileExists(atPath: dicomDirectoryURL.path) {
                return try catalogFromDICOMDirectory(dicomDirectoryURL: dicomDirectoryURL,
                                                     mediaRootURL: prepared.directory,
                                                     sourceURL: url,
                                                     sourceKind: .zip,
                                                     temporaryDirectoryURL: prepared.cleanupRoot)
            }
            return try catalogFromDirectory(prepared.directory,
                                            sourceURL: url,
                                            sourceKind: .zip,
                                            temporaryDirectoryURL: prepared.cleanupRoot)
        }

        let instance = try decodedInstance(from: url)
        return DicomMediaCatalog(sourceURL: url, sourceKind: .file, instances: [instance])
    }

    private func catalogFromDirectory(_ directoryURL: URL,
                                      sourceURL: URL,
                                      sourceKind: DicomMediaCatalogSourceKind,
                                      temporaryDirectoryURL: URL?) throws -> DicomMediaCatalog {
        let urls = try candidateFileURLs(in: directoryURL)
        let instances = sortedInstances(urls.compactMap { try? decodedInstance(from: $0) })
        return DicomMediaCatalog(sourceURL: sourceURL,
                                 sourceKind: sourceKind,
                                 instances: instances,
                                 temporaryDirectoryURL: temporaryDirectoryURL)
    }

    private func catalogFromDICOMDirectory(dicomDirectoryURL: URL,
                                           mediaRootURL: URL,
                                           sourceURL: URL,
                                           sourceKind: DicomMediaCatalogSourceKind,
                                           temporaryDirectoryURL: URL?) throws -> DicomMediaCatalog {
        let directory = try DicomDirectoryReader.read(from: dicomDirectoryURL)
        var instances: [DicomMediaCatalogInstance] = []

        for patient in directory.patients {
            for study in patient.studies {
                for series in study.series {
                    for image in series.images {
                        let fileURL = try? image.resolvedFileURL(relativeTo: mediaRootURL)
                        let decoded = fileURL.flatMap { try? decodedInstance(from: $0) }
                        instances.append(mergedInstance(decoded,
                                                        patient: patient,
                                                        study: study,
                                                        series: series,
                                                        image: image,
                                                        fileURL: fileURL))
                    }
                }
            }
        }

        return DicomMediaCatalog(sourceURL: sourceURL,
                                 sourceKind: sourceKind,
                                 instances: sortedInstances(instances),
                                 temporaryDirectoryURL: temporaryDirectoryURL)
    }

    private func mergedInstance(_ decoded: DicomMediaCatalogInstance?,
                                patient: DicomDirectoryPatient,
                                study: DicomDirectoryStudy,
                                series: DicomDirectorySeries,
                                image: DicomDirectoryImage,
                                fileURL: URL?) -> DicomMediaCatalogInstance {
        let sopClassUID = decoded?.sopClassUID.dicomMediaCatalogNonEmpty ??
            image.referencedSOPClassUID?.dicomMediaCatalogNonEmpty ?? ""
        let hasRenderablePixels = decoded?.hasRenderablePixels ??
            !DicomMediaCatalogInstance.specialObjectSOPClassUIDs.contains(sopClassUID)

        return DicomMediaCatalogInstance(
            fileURL: decoded?.fileURL ?? fileURL,
            patientName: decoded?.patientName.dicomMediaCatalogNonEmpty ??
                patient.patientName?.dicomMediaCatalogNonEmpty ?? "Unknown",
            patientID: decoded?.patientID.dicomMediaCatalogNonEmpty ??
                patient.patientID?.dicomMediaCatalogNonEmpty ?? "",
            studyInstanceUID: decoded?.studyInstanceUID.dicomMediaCatalogNonEmpty ??
                study.studyInstanceUID?.dicomMediaCatalogNonEmpty ?? "dicomdir-study-\(study.studyID ?? "unknown")",
            studyDate: decoded?.studyDate.dicomMediaCatalogNonEmpty ??
                study.studyDate?.dicomMediaCatalogNonEmpty ?? "",
            studyDescription: decoded?.studyDescription.dicomMediaCatalogNonEmpty ?? "",
            seriesInstanceUID: decoded?.seriesInstanceUID.dicomMediaCatalogNonEmpty ??
                series.seriesInstanceUID?.dicomMediaCatalogNonEmpty ?? "dicomdir-series-\(series.seriesNumber ?? 0)",
            seriesDescription: decoded?.seriesDescription.dicomMediaCatalogNonEmpty ?? "",
            modality: decoded?.modality.dicomMediaCatalogNonEmpty ??
                series.modality?.dicomMediaCatalogNonEmpty ?? "OT",
            sopClassUID: sopClassUID,
            sopInstanceUID: decoded?.sopInstanceUID.dicomMediaCatalogNonEmpty ??
                image.referencedSOPInstanceUID?.dicomMediaCatalogNonEmpty ?? fileURL?.lastPathComponent ?? UUID().uuidString,
            instanceNumber: decoded?.instanceNumber ?? image.instanceNumber,
            fileSize: decoded?.fileSize ?? fileSize(of: fileURL),
            hasRenderablePixels: hasRenderablePixels
        )
    }

    private func decodedInstance(from url: URL) throws -> DicomMediaCatalogInstance {
        let decoder = try DCMDecoder(contentsOf: url)
        let sopClassUID = decoder.info(for: .sopClassUID).dicomMediaCatalogNonEmpty ?? ""
        let hasRenderablePixels = decoder.width > 0 &&
            decoder.height > 0 &&
            !DicomMediaCatalogInstance.specialObjectSOPClassUIDs.contains(sopClassUID)

        let studyUID = decoder.info(for: .studyInstanceUID).dicomMediaCatalogNonEmpty ?? "file-study-\(url.path)"
        let seriesUID = decoder.info(for: .seriesInstanceUID).dicomMediaCatalogNonEmpty ?? "file-series-\(url.path)"
        let sopUID = decoder.info(for: .sopInstanceUID).dicomMediaCatalogNonEmpty ?? "file-instance-\(url.path)"

        return DicomMediaCatalogInstance(
            fileURL: url,
            patientName: decoder.info(for: .patientName).dicomMediaCatalogNonEmpty ?? "Unknown",
            patientID: decoder.info(for: .patientID).dicomMediaCatalogNonEmpty ?? "",
            studyInstanceUID: studyUID,
            studyDate: decoder.info(for: .studyDate).dicomMediaCatalogNonEmpty ?? "",
            studyDescription: decoder.info(for: .studyDescription).dicomMediaCatalogNonEmpty ?? "",
            seriesInstanceUID: seriesUID,
            seriesDescription: decoder.info(for: .seriesDescription).dicomMediaCatalogNonEmpty ?? "",
            modality: decoder.info(for: .modality).dicomMediaCatalogNonEmpty ?? "OT",
            sopClassUID: sopClassUID,
            sopInstanceUID: sopUID,
            instanceNumber: decoder.intValue(for: .instanceNumber),
            fileSize: fileSize(of: url),
            hasRenderablePixels: hasRenderablePixels
        )
    }

    private func candidateFileURLs(in directoryURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(at: directoryURL,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            throw DICOMError.fileReadError(path: directoryURL.path, underlyingError: "Unable to enumerate directory")
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent.caseInsensitiveCompare("DICOMDIR") == .orderedSame {
                continue
            }
            urls.append(fileURL)
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func unzipMediaArchive(_ url: URL) throws -> (directory: URL, cleanupRoot: URL) {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("dicom-media-catalog-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        var shouldCleanupTemporaryDirectory = true
        defer {
            if shouldCleanupTemporaryDirectory {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw DicomSeriesSourceError.archiveOpenFailed(url)
        }

        for entry in archive {
            switch try zipEntryDisposition(for: entry.path) {
            case .skip:
                continue
            case .extract(let sanitizedPath):
                let destinationURL = temporaryDirectory.appendingPathComponent(sanitizedPath)
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destinationURL)
            }
        }

        let contents = try fileManager.contentsOfDirectory(at: temporaryDirectory,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        shouldCleanupTemporaryDirectory = false
        if contents.count == 1,
           (try contents.first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return (contents[0], temporaryDirectory)
        }
        return (temporaryDirectory, temporaryDirectory)
    }

    private enum ZipEntryDisposition {
        case extract(String)
        case skip
    }

    private func zipEntryDisposition(for entryPath: String) throws -> ZipEntryDisposition {
        guard !entryPath.hasPrefix("/") else {
            throw DicomSeriesSourceError.pathTraversal(entryPath)
        }

        let components = entryPath.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("..") else {
            throw DicomSeriesSourceError.pathTraversal(entryPath)
        }

        let sanitizedComponents = components.filter { $0 != "." }
        guard !sanitizedComponents.isEmpty else {
            throw DicomSeriesSourceError.pathTraversal(entryPath)
        }

        if sanitizedComponents.contains("__MACOSX") ||
            sanitizedComponents.contains(where: { $0.hasPrefix(".") }) {
            return .skip
        }
        return .extract(sanitizedComponents.joined(separator: "/"))
    }

    private func sortedInstances(_ instances: [DicomMediaCatalogInstance]) -> [DicomMediaCatalogInstance] {
        instances.sorted { lhs, rhs in
            let left = [
                lhs.patientName,
                lhs.studyDate,
                lhs.studyInstanceUID,
                lhs.seriesInstanceUID,
                lhs.instanceNumber.map { String(format: "%08d", $0) } ?? "",
                lhs.fileURL?.path ?? lhs.sopInstanceUID
            ]
            let right = [
                rhs.patientName,
                rhs.studyDate,
                rhs.studyInstanceUID,
                rhs.seriesInstanceUID,
                rhs.instanceNumber.map { String(format: "%08d", $0) } ?? "",
                rhs.fileURL?.path ?? rhs.sopInstanceUID
            ]
            return left.lexicographicallyPrecedes(right)
        }
    }

    private func fileSize(of url: URL?) -> Int64 {
        guard let url else { return 0 }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private extension String {
    var dicomMediaCatalogNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
