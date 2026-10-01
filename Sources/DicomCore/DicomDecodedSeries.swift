import Foundation
import simd
import ZIPFoundation

public enum DicomSeriesSource: Sendable, Equatable {
    case directory(URL)
    case file(URL)
    case zip(URL)

    public static func source(for url: URL) throws -> DicomSeriesSource {
        guard url.isFileURL else {
            throw DicomSeriesSourceError.unsupportedURL(url)
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true || url.hasDirectoryPath {
            return .directory(url)
        }
        if url.pathExtension.lowercased() == "zip" {
            return .zip(url)
        }
        return .file(url)
    }
}

public enum DicomSeriesSourceError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedURL(URL)
    case archiveOpenFailed(URL)
    case pathTraversal(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let url):
            return "Unsupported DICOM source URL: \(url.absoluteString)"
        case .archiveOpenFailed(let url):
            return "Could not open DICOM ZIP archive: \(url.lastPathComponent)"
        case .pathTraversal:
            return "The ZIP archive contains an unsafe path."
        }
    }
}

public enum DicomPixelRepresentation: Sendable, Equatable {
    case signedInt16
    case unsignedInt16

    public var isSigned: Bool {
        switch self {
        case .signedInt16:
            return true
        case .unsignedInt16:
            return false
        }
    }
}

public struct DicomSeriesDimensions: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var depth: Int

    public init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    public var voxelCount: Int {
        width * height * depth
    }
}

public struct DicomDecodedSeriesWarning: Sendable, Hashable {
    public enum Code: String, Sendable, Hashable {
        case usedFallbackWindow
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

public enum DicomDecodedSeriesProgress: Sendable, Equatable {
    case started(totalSlices: Int)
    case reading(fraction: Double, slicesLoaded: Int)
}

public struct DicomDecodedSeries: Sendable {
    public let rawVoxels: Data
    public let modalityVoxels: Data
    public let sourcePixelRepresentation: DicomPixelRepresentation
    public let bitsAllocated: Int
    public let dimensions: DicomSeriesDimensions
    public let spacing: SIMD3<Double>
    public let orientation: simd_double3x3
    public let origin: SIMD3<Double>
    public let modalityIntensityRange: ClosedRange<Int32>
    public let recommendedWindow: ClosedRange<Int32>?
    public let patientName: String
    public let modality: String
    public let seriesDescription: String
    public let studyDescription: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let frameOfReferenceUID: String?
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    public let windowCenter: Double?
    public let windowWidth: Double?
    public let sliceVOIs: [DicomFrameVOI?]
    public let quantitativeValueProfile: DicomQuantitativeValueProfile
    public let sourceURL: URL
    public let imageInstances: [DicomSeriesImageInstance]
    public let keyObjectSelectionDocuments: [DicomSRDocument]
    public let warnings: [DicomDecodedSeriesWarning]

    public init(rawVoxels: Data,
                modalityVoxels: Data,
                sourcePixelRepresentation: DicomPixelRepresentation,
                bitsAllocated: Int,
                dimensions: DicomSeriesDimensions,
                spacing: SIMD3<Double>,
                orientation: simd_double3x3,
                origin: SIMD3<Double>,
                modalityIntensityRange: ClosedRange<Int32>,
                recommendedWindow: ClosedRange<Int32>?,
                patientName: String = "",
                modality: String,
                seriesDescription: String,
                studyDescription: String? = nil,
                studyInstanceUID: String?,
                seriesInstanceUID: String?,
                frameOfReferenceUID: String?,
                rescaleSlope: Double,
                rescaleIntercept: Double,
                windowCenter: Double?,
                windowWidth: Double?,
                sliceVOIs: [DicomFrameVOI?] = [],
                quantitativeValueProfile: DicomQuantitativeValueProfile = .empty,
                sourceURL: URL,
                imageInstances: [DicomSeriesImageInstance] = [],
                keyObjectSelectionDocuments: [DicomSRDocument] = [],
                warnings: [DicomDecodedSeriesWarning]) {
        self.rawVoxels = rawVoxels
        self.modalityVoxels = modalityVoxels
        self.sourcePixelRepresentation = sourcePixelRepresentation
        self.bitsAllocated = bitsAllocated
        self.dimensions = dimensions
        self.spacing = spacing
        self.orientation = orientation
        self.origin = origin
        self.modalityIntensityRange = modalityIntensityRange
        self.recommendedWindow = recommendedWindow
        self.patientName = patientName
        self.modality = modality
        self.seriesDescription = seriesDescription
        self.studyDescription = studyDescription
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.sliceVOIs = sliceVOIs
        self.quantitativeValueProfile = quantitativeValueProfile
        self.sourceURL = sourceURL
        self.imageInstances = imageInstances
        self.keyObjectSelectionDocuments = keyObjectSelectionDocuments
        self.warnings = warnings
    }
}

public extension DicomSeriesLoader {
    func loadDecodedSeries(from url: URL,
                           progress: (@Sendable (DicomDecodedSeriesProgress) -> Void)? = nil) throws -> DicomDecodedSeries {
        try loadDecodedSeries(from: DicomSeriesSource.source(for: url), progress: progress)
    }

    func loadDecodedSeries(from source: DicomSeriesSource,
                           progress: (@Sendable (DicomDecodedSeriesProgress) -> Void)? = nil) throws -> DicomDecodedSeries {
        let prepared = try prepareDirectory(from: source)
        defer {
            if let cleanupRoot = prepared.cleanupRoot {
                try? FileManager.default.removeItem(at: cleanupRoot)
            }
        }

        let started = DicomSynchronousResult<Void>()
        let volume = try loadSeries(in: prepared.directory) { fraction, slicesCopied, sliceData, volume in
            if started.resolve(.success(())) {
                progress?(.started(totalSlices: volume.depth))
            }
            progress?(.reading(fraction: fraction, slicesLoaded: slicesCopied))
            _ = sliceData
        }

        return try DicomDecodedSeries(
            volume: volume,
            sourceURL: prepared.sourceURL,
            keyObjectSelectionDocuments: keyObjectSelectionDocuments(in: prepared.directory)
        )
    }
}

private struct PreparedSeriesDirectory {
    let directory: URL
    let cleanupRoot: URL?
    let sourceURL: URL
}

private extension DicomSeriesLoader {
    func keyObjectSelectionDocuments(in directory: URL) -> [DicomSRDocument] {
        guard let urls = try? listDicomFiles(in: directory) else { return [] }
        return urls.compactMap { url in
            guard let decoder = try? DCMDecoder(contentsOf: url) else { return nil }
            return decoder.keyObjectSelection
        }
    }

    func prepareDirectory(from source: DicomSeriesSource) throws -> PreparedSeriesDirectory {
        switch source {
        case .directory(let url):
            return PreparedSeriesDirectory(directory: url, cleanupRoot: nil, sourceURL: url)
        case .file(let url):
            return PreparedSeriesDirectory(directory: url.deletingLastPathComponent(),
                                           cleanupRoot: nil,
                                           sourceURL: url)
        case .zip(let url):
            let prepared = try unzipSeriesArchive(url)
            return PreparedSeriesDirectory(directory: prepared.directory,
                                           cleanupRoot: prepared.cleanupRoot,
                                           sourceURL: url)
        }
    }

    func unzipSeriesArchive(_ url: URL) throws -> (directory: URL, cleanupRoot: URL) {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        var shouldCleanupTemporaryDirectory = true
        defer {
            if shouldCleanupTemporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw DicomSeriesSourceError.archiveOpenFailed(url)
        }

        for entry in archive {
            switch try Self.extractionDisposition(for: entry.path) {
            case .skip:
                continue
            case .extract(let sanitizedPath):
                let destinationURL = temporaryDirectory.appendingPathComponent(sanitizedPath)
                let destinationDirectory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destinationURL)
            }
        }

        let contents = try FileManager.default.contentsOfDirectory(at: temporaryDirectory,
                                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])
        shouldCleanupTemporaryDirectory = false
        if contents.count == 1,
           (try contents.first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return (contents[0], temporaryDirectory)
        }
        return (temporaryDirectory, temporaryDirectory)
    }

    enum ZipEntryExtractionDisposition {
        case extract(String)
        case skip
    }

    static func extractionDisposition(for entryPath: String) throws -> ZipEntryExtractionDisposition {
        guard !entryPath.hasPrefix("/") else {
            throw DicomSeriesSourceError.pathTraversal(entryPath)
        }

        let components = entryPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw DicomSeriesSourceError.pathTraversal(entryPath)
        }

        if components.contains("..") {
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
}

extension DicomDecodedSeries {
    public init(volume: DicomSeriesVolume,
                sourceURL: URL,
                keyObjectSelectionDocuments: [DicomSRDocument] = []) throws {
        let representation: DicomPixelRepresentation = volume.isSignedPixel ? .signedInt16 : .unsignedInt16
        let conversion = try Self.makeModalityVoxels(
            rawVoxels: volume.voxels,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            representation: representation,
            defaultSlope: volume.rescaleSlope,
            defaultIntercept: volume.rescaleIntercept,
            sliceRescaleParameters: volume.sliceRescaleParameters,
            sourceURL: sourceURL
        )
        let window = Self.recommendedWindow(
            center: volume.windowCenter,
            width: volume.windowWidth,
            modality: volume.modality,
            intensityRange: conversion.range
        )

        self.init(
            rawVoxels: volume.voxels,
            modalityVoxels: conversion.data,
            sourcePixelRepresentation: representation,
            bitsAllocated: volume.bitsAllocated,
            dimensions: DicomSeriesDimensions(width: volume.width, height: volume.height, depth: volume.depth),
            spacing: volume.spacing,
            orientation: volume.orientation,
            origin: volume.origin,
            modalityIntensityRange: conversion.range,
            recommendedWindow: window.recommendedWindow,
            patientName: volume.patientName,
            modality: volume.modality,
            seriesDescription: volume.seriesDescription,
            studyDescription: volume.studyDescription,
            studyInstanceUID: volume.studyInstanceUID,
            seriesInstanceUID: volume.seriesInstanceUID,
            frameOfReferenceUID: volume.frameOfReferenceUID,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept,
            windowCenter: volume.windowCenter,
            windowWidth: volume.windowWidth,
            sliceVOIs: volume.sliceVOIs,
            quantitativeValueProfile: volume.quantitativeValueProfile,
            sourceURL: sourceURL,
            imageInstances: volume.imageInstances,
            keyObjectSelectionDocuments: keyObjectSelectionDocuments,
            warnings: window.warnings
        )
    }

    private static func makeModalityVoxels(rawVoxels: Data,
                                           width: Int,
                                           height: Int,
                                           depth: Int,
                                           representation: DicomPixelRepresentation,
                                           defaultSlope: Double,
                                           defaultIntercept: Double,
                                           sliceRescaleParameters: [DicomSliceRescaleParameters],
                                           sourceURL: URL) throws -> (data: Data, range: ClosedRange<Int32>) {
        let voxelCount = width * height * depth
        let expectedBytes = voxelCount * MemoryLayout<Int16>.size
        guard rawVoxels.count == expectedBytes else {
            throw DicomSeriesLoaderError.failedToDecode(sourceURL)
        }

        let sliceVoxelCount = width * height
        let useSliceRescaleParameters = sliceRescaleParameters.count == depth
        var converted = Data(count: expectedBytes)
        var minimum = Int32.max
        var maximum = Int32.min

        rawVoxels.withUnsafeBytes { sourceBuffer in
            converted.withUnsafeMutableBytes { destinationBuffer in
                let destination = destinationBuffer.bindMemory(to: Int16.self)
                switch representation {
                case .signedInt16:
                    let source = sourceBuffer.bindMemory(to: Int16.self)
                    for slice in 0..<depth {
                        let parameters = useSliceRescaleParameters
                            ? sliceRescaleParameters[slice]
                            : DicomSliceRescaleParameters(slope: defaultSlope, intercept: defaultIntercept)
                        let base = slice * sliceVoxelCount
                        for localIndex in 0..<sliceVoxelCount {
                            let index = base + localIndex
                            let value = convertedModalityValue(raw: Double(source[index]),
                                                               slope: parameters.slope,
                                                               intercept: parameters.intercept)
                            minimum = min(minimum, value.int32)
                            maximum = max(maximum, value.int32)
                            destination[index] = value.int16
                        }
                    }
                case .unsignedInt16:
                    let source = sourceBuffer.bindMemory(to: UInt16.self)
                    for slice in 0..<depth {
                        let parameters = useSliceRescaleParameters
                            ? sliceRescaleParameters[slice]
                            : DicomSliceRescaleParameters(slope: defaultSlope, intercept: defaultIntercept)
                        let base = slice * sliceVoxelCount
                        for localIndex in 0..<sliceVoxelCount {
                            let index = base + localIndex
                            let value = convertedModalityValue(raw: Double(source[index]),
                                                               slope: parameters.slope,
                                                               intercept: parameters.intercept)
                            minimum = min(minimum, value.int32)
                            maximum = max(maximum, value.int32)
                            destination[index] = value.int16
                        }
                    }
                }
            }
        }

        if minimum > maximum {
            minimum = Int32(Int16.min)
            maximum = Int32(Int16.max)
        }
        return (converted, minimum...maximum)
    }

    private static func convertedModalityValue(raw: Double,
                                               slope: Double,
                                               intercept: Double) -> (int16: Int16, int32: Int32) {
        let rounded = lround(raw * slope + intercept)
        let clamped = max(Int(Int16.min), min(Int(Int16.max), rounded))
        return (Int16(clamped), Int32(clamped))
    }

    private static func recommendedWindow(center: Double?,
                                          width: Double?,
                                          modality: String,
                                          intensityRange: ClosedRange<Int32>) -> (recommendedWindow: ClosedRange<Int32>?,
                                                                                  warnings: [DicomDecodedSeriesWarning]) {
        if let center, let width {
            let bounds = windowBounds(width: width, center: center)
            return (Int32(floor(bounds.lower))...Int32(ceil(bounds.upper)), [])
        }

        if modality.uppercased() == "MR" {
            return (intensityRange, [
                DicomDecodedSeriesWarning(
                    code: .usedFallbackWindow,
                    message: "WindowCenter/WindowWidth not found; using full intensity range for MR."
                )
            ])
        }

        let settings = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)
        let bounds = windowBounds(width: settings.width, center: settings.center)
        return (Int32(floor(bounds.lower))...Int32(ceil(bounds.upper)), [
            DicomDecodedSeriesWarning(
                code: .usedFallbackWindow,
                message: "WindowCenter/WindowWidth not found; using DICOM-Swift soft tissue window."
            )
        ])
    }

    private static func windowBounds(width: Double, center: Double) -> (lower: Double, upper: Double) {
        let clampedWidth = max(width, 1)
        let halfSpan = (clampedWidth - 1) * 0.5
        return (center - 0.5 - halfSpan, center - 0.5 + halfSpan)
    }
}
