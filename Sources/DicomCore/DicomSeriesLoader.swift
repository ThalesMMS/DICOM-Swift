//
//  DicomSeriesLoader.swift
//
//  High-level helper to load a DICOM series from a directory,
//  order slices by Image Position (Patient), compute spacing/orientation,
//  and assemble a contiguous Int16 volume buffer.
//
//  This stays pure Swift and uses lightweight parallelism when
//  copying slices into the final buffer.
//

import Foundation
import simd

// MARK: - Error Handling

/// Errors that can occur during DICOM series loading operations.
///
/// These errors represent validation failures and inconsistencies detected
/// when loading and assembling multi-slice DICOM volumes.
public enum DicomSeriesLoaderError: Error {
    /// No valid DICOM files found in the specified directory
    case noDicomFiles

    /// The host allocator returned storage with an unexpected byte count.
    case invalidVoxelAllocationLength(expected: Int, actual: Int)

    /// Image has unsupported samples per pixel (only grayscale supported)
    /// - Parameter Int: The actual samples per pixel value
    case unsupportedSamplesPerPixel(Int)

    /// Image has unsupported bit depth (only 16-bit supported)
    /// - Parameter Int: The actual bit depth value
    case unsupportedBitDepth(Int)

    /// Transfer syntax is unsupported for the volume loading pipeline.
    ///
    /// The DICOM-Swift package can decode some compressed single-frame images,
    /// but the MTK volume pipeline currently only supports *uncompressed* pixel data
    /// for series assembly.
    ///
    /// - Parameter String: Transfer Syntax UID (0002,0010)
    case unsupportedTransferSyntax(String)

    /// Pixel metadata is outside the declared volume assembly support matrix.
    case unsupportedPixelFormat(DicomSeriesLoaderPixelFormat)

    /// Multi-frame image input is outside the declared volume assembly support matrix.
    case unsupportedMultiframe(DicomSeriesLoaderPixelFormat)

    /// The transfer syntax is outside the declared volume assembly support matrix.
    case unsupportedTransferSyntaxForVolume(DicomSeriesLoaderPixelFormat)

    /// An Enhanced multiframe object cannot be assembled; the context
    /// carries the SOP Class, frame count, transfer syntax, and the
    /// missing functional-group or shape reason.
    case unsupportedEnhancedMultiframe(EnhancedMultiframeContext)

    /// Slices have inconsistent dimensions (width/height mismatch)
    case inconsistentDimensions

    /// Slices have inconsistent orientation vectors.
    ///
    /// Thrown when:
    /// - `ImageOrientationPatient` differs across slices beyond tolerance, or
    /// - the derived row/column vectors are not sufficiently orthonormal (e.g. not unit length or not perpendicular).
    case inconsistentOrientation

    /// Slice orientation (IOP) is present but invalid (row/column vectors are degenerate or not orthogonal within tolerance).
    case invalidImageOrientation

    /// Slices have inconsistent pixel representation (signed/unsigned)
    case inconsistentPixelRepresentation

    /// Failed to decode a specific DICOM file
    /// - Parameter URL: The file URL that failed to decode
    case failedToDecode(URL)

    /// Two or more slices share the same IPP-projected position (duplicate slice locations).
    ///
    /// This is ambiguous for volume assembly and often indicates duplicated files in the series.
    case duplicateSlicePosition

    /// Slice spacing varies beyond supported tolerance.
    ///
    /// Indicates the series contains non-uniform slice spacing (e.g., missing slices,
    /// variable acquisition spacing) large enough that a single Z spacing would be
    /// misleading for reconstruction.
    /// - Parameters:
    ///   - median: The median inter-slice spacing measured from IPP projections (mm).
    ///   - maxDeviation: The maximum absolute deviation from the median (mm).
    case variableSliceSpacing(median: Double, maxDeviation: Double)
}

/// Pixel format context used by `DicomSeriesLoader` support checks and errors.
public struct DicomSeriesLoaderPixelFormat: Equatable, Sendable {
    /// Bits Allocated (0028,0100).
    public let bitsAllocated: Int

    /// Bits Stored (0028,0101).
    public let bitsStored: Int

    /// High Bit (0028,0102).
    public let highBit: Int

    /// Pixel Representation (0028,0103), where 0 means unsigned and 1 means signed.
    public let pixelRepresentation: Int

    /// Samples per Pixel (0028,0002).
    public let samplesPerPixel: Int

    /// Photometric Interpretation (0028,0004), normalized to uppercase.
    public let photometricInterpretation: String

    /// Planar Configuration (0028,0006), when present.
    public let planarConfiguration: Int?

    /// Number of Frames (0028,0008), defaulting to 1.
    public let numberOfFrames: Int

    /// Transfer Syntax UID (0002,0010), or `<unknown>` when absent.
    public let transferSyntaxUID: String

    /// Whether the decoder marks the pixel payload as compressed.
    public let isCompressed: Bool

    /// Creates a pixel format context.
    public init(
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        pixelRepresentation: Int,
        samplesPerPixel: Int,
        photometricInterpretation: String,
        planarConfiguration: Int?,
        numberOfFrames: Int,
        transferSyntaxUID: String,
        isCompressed: Bool
    ) {
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.samplesPerPixel = samplesPerPixel
        self.photometricInterpretation = photometricInterpretation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.planarConfiguration = planarConfiguration
        self.numberOfFrames = max(1, numberOfFrames)
        self.transferSyntaxUID = transferSyntaxUID.isEmpty ? "<unknown>" : transferSyntaxUID
        self.isCompressed = isCompressed
    }

    static let defaultGrayscale16 = DicomSeriesLoaderPixelFormat(
        bitsAllocated: 16,
        bitsStored: 16,
        highBit: 15,
        pixelRepresentation: 0,
        samplesPerPixel: 1,
        photometricInterpretation: "MONOCHROME2",
        planarConfiguration: nil,
        numberOfFrames: 1,
        transferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
        isCompressed: false
    )
}

/// Declares the volume assembly scope supported by `DicomSeriesLoader`.
public struct DicomSeriesLoaderSupportMatrix: Equatable, Sendable {
    /// Supported Bits Allocated values.
    public let supportedBitsAllocated: Set<Int>

    /// Supported Bits Stored values; a format must also store no more bits than it allocates, from bit 0
    /// (High Bit = Bits Stored − 1).
    public let supportedBitsStored: Set<Int>

    /// Supported Pixel Representation values.
    public let supportedPixelRepresentations: Set<Int>

    /// Supported Samples per Pixel values.
    public let supportedSamplesPerPixel: Set<Int>

    /// Supported Photometric Interpretation values.
    public let supportedPhotometricInterpretations: Set<String>

    /// Supported Planar Configuration values when present.
    public let supportedPlanarConfigurations: Set<Int>

    /// Whether absent Planar Configuration is accepted.
    public let supportsAbsentPlanarConfiguration: Bool

    /// Whether multi-frame image inputs are assembled by this loader.
    public let supportsMultiframe: Bool

    /// Whether compressed transfer syntaxes are assembled by this loader.
    public let supportsCompressedTransferSyntaxes: Bool

    /// Scalar type stored in `DicomSeriesVolume.voxels`.
    public let outputVoxelScalarType: String

    /// How rescale metadata is preserved.
    public let rescaleBehavior: String

    /// How spacing metadata is preserved.
    public let spacingBehavior: String

    /// How orientation metadata is preserved.
    public let orientationBehavior: String

    /// Ordered slice sorting rules used by the loader.
    public let sliceOrderingBehavior: [String]

    /// Standard package-only loader scope. Compressed single-frame
    /// grayscale slices assemble through the production decoded-frame
    /// reader (#1233) when the transfer syntax has an active decode
    /// backend; syntaxes without a backend fail typed per slice.
    public static let standard = DicomSeriesLoaderSupportMatrix(
        supportedBitsAllocated: [8, 16, 32],
        // Issue #2781: any width up to the allocation — 10, 12 and 14 bits are most CT and MR.
        supportedBitsStored: Set(1...32),
        supportedPixelRepresentations: [0, 1],
        supportedSamplesPerPixel: [1],
        supportedPhotometricInterpretations: ["MONOCHROME1", "MONOCHROME2"],
        supportedPlanarConfigurations: [],
        supportsAbsentPlanarConfiguration: true,
        supportsMultiframe: false,
        supportsCompressedTransferSyntaxes: true,
        outputVoxelScalarType: "Int16",
        rescaleBehavior: "Per-slice slope/intercept are preserved; voxels remain stored-value Int16.",
        spacingBehavior: "X/Y from Pixel Spacing, Z from IPP projection delta when available.",
        orientationBehavior: "ImageOrientationPatient row/column vectors are normalized and validated.",
        sliceOrderingBehavior: [
            "ImagePositionPatient projected onto the slice normal",
            "InstanceNumber",
            "Filename localized standard order"
        ]
    )

    /// Returns true when the pixel format fits the declared support matrix.
    public func supports(_ format: DicomSeriesLoaderPixelFormat) -> Bool {
        guard supportedBitsAllocated.contains(format.bitsAllocated),
              supportedBitsStored.contains(format.bitsStored),
              format.bitsStored <= format.bitsAllocated,
              format.highBit == format.bitsStored - 1,
              supportedPixelRepresentations.contains(format.pixelRepresentation),
              supportedSamplesPerPixel.contains(format.samplesPerPixel),
              supportedPhotometricInterpretations.contains(format.photometricInterpretation),
              supportsCompressedTransferSyntaxes || !format.isCompressed,
              supportsMultiframe || format.numberOfFrames == 1 else {
            return false
        }
        if let planarConfiguration = format.planarConfiguration {
            return supportedPlanarConfigurations.contains(planarConfiguration)
        }
        return supportsAbsentPlanarConfiguration
    }
}

// MARK: - Volume Data Structure

/// Rescale parameters for a single decoded slice in sorted volume order.
public struct DicomSliceRescaleParameters: Sendable, Equatable {
    public let slope: Double
    public let intercept: Double

    public init(slope: Double, intercept: Double) {
        self.slope = slope
        self.intercept = intercept
    }
}

/// Represents a loaded DICOM volume assembled from a directory of slices.
///
/// Contains the assembled voxel data buffer along with geometric metadata required
/// for 3D reconstruction, measurement, and visualization. The volume is assembled
/// from individual 2D slices ordered by their Image Position (Patient) coordinates.
///
/// ## Usage Example
/// ```swift
/// let loader = DicomSeriesLoader()
/// let volume = try loader.loadSeries(in: seriesDirectory) { progress, sliceCount, _, _ in
///     print("Loading: \(Int(progress * 100))% - \(sliceCount) slices")
/// }
/// print("Volume: \(volume.width)×\(volume.height)×\(volume.depth)")
/// print("Spacing: \(volume.spacing) mm")
/// ```
public struct DicomSeriesVolume: Sendable {
    /// Raw voxel data as contiguous 16-bit signed integers
    public let voxels: Data

    /// Volume width in pixels (X dimension)
    public let width: Int

    /// Volume height in pixels (Y dimension)
    public let height: Int

    /// Volume depth in slices (Z dimension)
    public let depth: Int

    /// Physical spacing between voxels in millimeters (X, Y, Z)
    public let spacing: SIMD3<Double>

    /// 3×3 orientation matrix defining anatomical axes
    public let orientation: simd_double3x3

    /// 3D origin position in patient coordinate system (mm)
    public let origin: SIMD3<Double>

    /// Rescale slope for converting to modality units (e.g., Hounsfield Units)
    public let rescaleSlope: Double

    /// Rescale intercept for converting to modality units
    public let rescaleIntercept: Double

    /// Bits allocated per pixel (typically 16)
    public let bitsAllocated: Int

    /// Whether pixel values are signed integers
    public let isSignedPixel: Bool

    /// DICOM person name for the loaded subject, when present
    public let patientName: String

    /// Human-readable series description
    public let seriesDescription: String

    /// Human-readable study description, when present
    public let studyDescription: String?

    /// Imaging modality from DICOM metadata, when present
    public let modality: String

    /// Window center from DICOM metadata, when present
    public let windowCenter: Double?

    /// Window width from DICOM metadata, when present
    public let windowWidth: Double?

    /// Study Instance UID (0020,000D), when present.
    public let studyInstanceUID: String?

    /// Series Instance UID (0020,000E), when present.
    public let seriesInstanceUID: String?

    /// Frame of Reference UID (0020,0052), when present.
    public let frameOfReferenceUID: String?

    /// Decoder-owned quantitative value profile for RWV and PET SUV metadata.
    public let quantitativeValueProfile: DicomQuantitativeValueProfile

    /// Image SOP instances that were loaded into the volume, in slice order.
    public let imageInstances: [DicomSeriesImageInstance]

    /// Per-slice rescale parameters in the same order as the assembled voxel buffer.
    public let sliceRescaleParameters: [DicomSliceRescaleParameters]

    /// Per-slice Frame VOI values in the same order as the assembled voxel buffer.
    public let sliceVOIs: [DicomFrameVOI?]

    /// Original Enhanced object/frame identities, in voxel slice order.
    public let enhancedFrameReferences: [DicomEnhancedFrameCollection.Reference]

    public init(voxels: Data,
                width: Int,
                height: Int,
                depth: Int,
                spacing: SIMD3<Double>,
                orientation: simd_double3x3,
                origin: SIMD3<Double>,
                rescaleSlope: Double,
                rescaleIntercept: Double,
                bitsAllocated: Int,
                isSignedPixel: Bool,
                patientName: String = "",
                seriesDescription: String,
                studyDescription: String? = nil,
                modality: String = "",
                windowCenter: Double? = nil,
                windowWidth: Double? = nil,
                studyInstanceUID: String? = nil,
                seriesInstanceUID: String? = nil,
                frameOfReferenceUID: String? = nil,
                quantitativeValueProfile: DicomQuantitativeValueProfile = .empty,
                imageInstances: [DicomSeriesImageInstance] = [],
                sliceRescaleParameters: [DicomSliceRescaleParameters] = [],
                sliceVOIs: [DicomFrameVOI?] = [],
                enhancedFrameReferences: [DicomEnhancedFrameCollection.Reference] = []) {
        self.voxels = voxels
        self.width = width
        self.height = height
        self.depth = depth
        self.spacing = spacing
        self.orientation = orientation
        self.origin = origin
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.bitsAllocated = bitsAllocated
        self.isSignedPixel = isSignedPixel
        self.patientName = patientName
        self.seriesDescription = seriesDescription
        self.studyDescription = studyDescription
        self.modality = modality
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.quantitativeValueProfile = quantitativeValueProfile
        self.imageInstances = imageInstances
        self.sliceRescaleParameters = sliceRescaleParameters
        self.sliceVOIs = sliceVOIs
        self.enhancedFrameReferences = enhancedFrameReferences
    }
}

public struct DicomSeriesImageInstance: Equatable, Hashable, Sendable {
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let sopClassUID: String?
    public let sopInstanceUID: String
    public let sliceIndex: Int
    public let instanceNumber: Int?

    public init(studyInstanceUID: String?,
                seriesInstanceUID: String?,
                sopClassUID: String?,
                sopInstanceUID: String,
                sliceIndex: Int,
                instanceNumber: Int? = nil) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.sliceIndex = max(sliceIndex, 0)
        self.instanceNumber = instanceNumber
    }
}

struct SliceMeta {
    let url: URL
    let position: SIMD3<Double>?
    let instanceNumber: Int?
    let projection: Double?
    let windowCenter: Double?
    let windowWidth: Double?
    let studyInstanceUID: String?
    let seriesInstanceUID: String?
    let sopClassUID: String?
    let sopInstanceUID: String?
    let rescaleSlope: Double
    let rescaleIntercept: Double
    let pixelFormat: DicomSeriesLoaderPixelFormat

    init(url: URL,
         position: SIMD3<Double>?,
         instanceNumber: Int?,
         projection: Double?,
         windowCenter: Double? = nil,
         windowWidth: Double? = nil,
         studyInstanceUID: String? = nil,
         seriesInstanceUID: String? = nil,
         sopClassUID: String? = nil,
         sopInstanceUID: String? = nil,
         rescaleSlope: Double = 1,
         rescaleIntercept: Double = 0,
         pixelFormat: DicomSeriesLoaderPixelFormat = .defaultGrayscale16) {
        self.url = url
        self.position = position
        self.instanceNumber = instanceNumber
        self.projection = projection
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.pixelFormat = pixelFormat
    }
}

// MARK: - Batch Loading Result

/// Result of loading a single DICOM file in batch operations.
///
/// Represents the outcome of loading an individual DICOM file, containing either
/// a successfully loaded decoder instance or an error that occurred during loading.
/// Used by ``DicomSeriesLoader/batchLoadFiles(urls:maxConcurrency:)`` for concurrent
/// file loading operations.
///
/// ## Usage Example
/// ```swift
/// let urls = [url1, url2, url3]
/// let results = await loader.batchLoadFiles(urls: urls, maxConcurrency: 4)
/// for result in results {
///     if result.success {
///         print("Loaded: \(result.decoder!.width) × \(result.decoder!.height)")
///     } else {
///         print("Failed to load \(result.url): \(result.error!)")
///     }
/// }
/// ```
public struct DicomFileResult: Sendable {
    /// The file URL that was processed
    public let url: URL

    /// The successfully loaded decoder, or nil if loading failed
    public let decoder: (any DicomDecoderProtocol)?

    /// The typed DICOM error that occurred, or nil if loading succeeded
    public let error: DICOMError?

    /// Whether the file loaded successfully
    public var success: Bool { decoder != nil }

    /// Creates a result representing a successful file load
    /// - Parameters:
    ///   - url: The file URL
    ///   - decoder: The successfully loaded decoder
    public init(url: URL, decoder: any DicomDecoderProtocol) {
        self.url = url
        self.decoder = decoder
        self.error = nil
    }

    /// Creates a result representing a failed file load
    /// - Parameters:
    ///   - url: The file URL
    ///   - error: The DICOM error that occurred
    public init(url: URL, error: DICOMError) {
        self.url = url
        self.decoder = nil
        self.error = error
    }
}

// MARK: - Series Loader

/// High-level DICOM series loader with automatic slice ordering and volume assembly.
///
/// ## Overview
///
/// ``DicomSeriesLoader`` loads and assembles multi-slice DICOM volumes from directories.
/// It automatically orders slices by Image Position (Patient) coordinates, validates
/// geometric consistency, computes 3D spacing, and assembles a contiguous voxel buffer.
///
/// The loader uses protocol-based dependency injection for ``DicomDecoderProtocol``,
/// enabling testability and customization. Slices are validated for consistency in
/// dimensions, orientation, and pixel representation. The final volume includes complete
/// geometric metadata for 3D reconstruction.
///
/// **Key Features:**
/// - Automatic slice ordering by anatomical position
/// - Geometric validation across slices
/// - Computed Z-spacing from slice positions
/// - Progress callbacks during assembly
/// - Lightweight parallelism for buffer copying
/// - Async/await support for non-blocking loading
///
/// ## Usage
///
/// Basic series loading:
///
/// ```swift
/// let loader = DicomSeriesLoader()
/// do {
///     let volume = try loader.loadSeries(in: seriesDirectory)
///     print("Loaded \(volume.depth) slices: \(volume.width)×\(volume.height)")
/// } catch DicomSeriesLoaderError.noDicomFiles {
///     print("No DICOM files found")
/// } catch {
///     print("Loading failed: \(error)")
/// }
/// ```
///
/// Loading with progress tracking:
///
/// ```swift
/// let loader = DicomSeriesLoader()
/// let volume = try loader.loadSeries(in: seriesDirectory) { progress, sliceCount, _, _ in
///     DispatchQueue.main.async {
///         progressView.progress = Float(progress)
///         statusLabel.text = "Loading slice \(sliceCount)"
///     }
/// }
/// ```
///
/// Async loading with progress stream:
///
/// ```swift
/// Task {
///     for try await progress in loader.loadSeriesWithProgress(in: seriesDirectory) {
///         print("Progress: \(Int(progress.fractionComplete * 100))%")
///     }
/// }
/// ```
///
/// Custom decoder injection for testing:
///
/// ```swift
/// let loader = DicomSeriesLoader(decoderFactory: { _ in MockDicomDecoder() })
/// let volume = try loader.loadSeries(in: testDirectory)
/// ```
///
/// ## Topics
///
/// ### Creating a Loader
///
/// - ``init()``
///
/// ### Loading Series
///
/// - ``loadSeries(in:progress:)-17egi``
/// - ``loadSeries(in:progress:)-7i914``
/// - ``loadSeriesWithProgress(in:)``
/// - ``ProgressHandler``
///
/// ### Volume Data
///
/// - ``DicomSeriesVolume``
/// - ``SeriesLoadProgress``
///
/// ### Error Handling
///
/// - ``DicomSeriesLoaderError``
///
public final class DicomSeriesLoader: DicomSeriesLoaderProtocol, Sendable {
    /// Progress callback invoked during volume assembly.
    ///
    /// - Parameters:
    ///   - progress: Fraction complete (0.0 to 1.0)
    ///   - sliceCount: Number of slices copied so far
    ///   - intermediateData: Reserved for future use (currently nil)
    ///   - volume: Partial volume descriptor with metadata
    public typealias ProgressHandler = @Sendable (Double, Int, Data?, DicomSeriesVolume) -> Void

    // MARK: - Properties

    let decoderFactory: @Sendable (String) throws -> DicomDecoderProtocol
    let logger: LoggerProtocol
    let allocateVoxelData: @Sendable (Int) throws -> Data

    // MARK: - Initialization

    /// Required protocol initializer - uses default DCMDecoder.
    public convenience init() {
        self.init(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) })
    }

    /// Host allocation boundary for the final CPU volume. The allocator must return
    /// zero-initialized storage of exactly the requested length and retain its accounting.
    public convenience init(allocateVoxelData: @escaping @Sendable (Int) throws -> Data) {
        self.init(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) },
                  logger: DicomLogger.make(subsystem: "com.dicomcore", category: "series-loader"),
                  allocateVoxelData: allocateVoxelData)
    }

    /// Required protocol initializer with injected logging.
    public convenience init(logger: LoggerProtocol) {
        self.init(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) },
                  logger: logger)
    }

    /// Dependency injection initializer for testing and customization.
    /// - Parameter decoderFactory: Factory closure that creates DicomDecoderProtocol instances from a file path
    public convenience init(decoderFactory: @escaping @Sendable (String) throws -> DicomDecoderProtocol) {
        self.init(decoderFactory: decoderFactory,
                  logger: DicomLogger.make(subsystem: "com.dicomcore", category: "series-loader"))
    }

    /// Dependency injection initializer for testing and customization.
    /// - Parameters:
    ///   - decoderFactory: Factory closure that creates DicomDecoderProtocol instances from a file path.
    ///   - logger: Logger used for diagnostics emitted during series loading.
    public init(decoderFactory: @escaping @Sendable (String) throws -> DicomDecoderProtocol,
                logger: LoggerProtocol,
                allocateVoxelData: @escaping @Sendable (Int) throws -> Data = { Data(count: $0) }) {
        self.decoderFactory = decoderFactory
        self.logger = logger
        self.allocateVoxelData = { byteCount in
            let data = try allocateVoxelData(byteCount)
            guard data.count == byteCount else {
                throw DicomSeriesLoaderError.invalidVoxelAllocationLength(expected: byteCount, actual: data.count)
            }
            return data
        }
    }

    /// Backward-compatible dependency injection initializer.
    /// - Parameter decoderFactory: Factory closure that creates decoders without a path argument.
    @available(*, deprecated, message: "Use init(decoderFactory: (String) throws -> DicomDecoderProtocol) instead.")
    public convenience init(decoderFactory: @escaping @Sendable () -> DicomDecoderProtocol) {
        self.init(decoderFactory: { path in
            let decoder = decoderFactory()
            decoder.setDicomFilename(path)
            return decoder
        })
    }

    /// Loads a DICOM series from a directory and assembles all slices into a single Int16 volume.
    /// - Parameters:
    ///   - directory: URL of the directory containing the DICOM files to load.
    ///   - progress: Optional callback invoked after each decoded slice with the fraction complete, the 1-based slice index, the decoded slice voxel `Data`, and a lightweight `DicomSeriesVolume` descriptor for the series.
    /// - Returns: A `DicomSeriesVolume` containing the assembled contiguous Int16 voxel buffer and associated geometry, spacing, orientation, origin, rescale parameters, pixel format, and series description.
    /// - Throws:
    ///   - `DicomSeriesLoaderError.noDicomFiles` if no valid DICOM files are found or no valid slices could be loaded.
    ///   - `DicomSeriesLoaderError.unsupportedPixelFormat(_)` if a decoded file is outside the support matrix.
    ///   - `DicomSeriesLoaderError.unsupportedMultiframe(_)` if a decoded file reports multiple frames.
    ///   - `DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(_)` if a decoded file is compressed.
    ///   - `DicomSeriesLoaderError.inconsistentDimensions` if slice widths/heights differ across the series.
    ///   - `DicomSeriesLoaderError.inconsistentOrientation` if slice row/column orientation vectors differ across the series.
    ///   - `DicomSeriesLoaderError.inconsistentPixelRepresentation` if `pixelRepresentation` differs across slices.
    ///   - `DicomSeriesLoaderError.failedToDecode(_)` if decoding any slice's pixel data fails during assembly.
    ///   - `CancellationError` if the calling task was cancelled during loading.
    public func loadSeries(in directory: URL,
                           progress: ProgressHandler? = nil) throws -> DicomSeriesVolume {
        let decoderCacheLock = DicomLock()
        var decoderCache: [URL: DicomDecoderProtocol] = [:]

        func cachedDecoder(for url: URL) -> DicomDecoderProtocol? {
            decoderCacheLock.withLock {
                decoderCache[url]
            }
        }

        func cacheDecoder(_ decoder: DicomDecoderProtocol, for url: URL) {
            decoderCacheLock.withLock {
                decoderCache[url] = decoder
            }
        }

        if Task.isCancelled {
            throw CancellationError()
        }

        let fileURLs = try listDicomFiles(in: directory)
        guard !fileURLs.isEmpty else {
            throw DicomSeriesLoaderError.noDicomFiles
        }

        // First pass: read headers to collect geometry and ordering data.
        var firstDecoder: DicomDecoderProtocol?
        var orientation: (row: SIMD3<Double>, column: SIMD3<Double>)?
        var origin: SIMD3<Double>?
        var rescaleSlope: Double = 1.0
        var rescaleIntercept: Double = 0.0
        var pixelRepresentation: Int = 0
        var seriesDescription = directory.lastPathComponent
        var studyDescription: String?
        var patientName = ""
        var modality = ""
        var windowCenter: Double?
        var windowWidth: Double?
        var studyInstanceUID: String?
        var seriesInstanceUID: String?
        var frameOfReferenceUID: String?
        var quantitativeValueProfile: DicomQuantitativeValueProfile = .empty

        var width = 0
        var height = 0
        var bitsAllocated = 0
        var spacing = SIMD3<Double>(1, 1, 1)
        var baselinePixelFormat: DicomSeriesLoaderPixelFormat?

        var slices: [SliceMeta] = []

        for url in fileURLs {
            if Task.isCancelled {
                throw CancellationError()
            }

            // Try to load DICOM file using factory
            let decoder: DicomDecoderProtocol
            do {
                decoder = try decoderFactory(url.path)
            } catch {
                // Skip files that fail to load
                continue
            }

            // Non-image clinical objects are valid DICOM instances, but they are not image-volume slices.
            let sopClassUID = decoder.info(for: .sopClassUID)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            let decoderModality = decoder.info(for: .modality)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            let hasWaveformSequence: Bool
            if let concreteDecoder = decoder as? DCMDecoder {
                hasWaveformSequence = concreteDecoder.dataSet.contains(.waveformSequence)
            } else {
                hasWaveformSequence = false
            }
            if DicomSRDocument.structuredReportSOPClassUIDs.contains(sopClassUID) ||
                sopClassUID == DicomSpatialRegistrationDocument.storageSOPClassUID ||
                DicomGrayscalePresentationState.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                DicomEncapsulatedDocument.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                DicomWaveform.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                DicomVideo.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
                decoderModality == "DOC" ||
                hasWaveformSequence {
                continue
            }

            let pixelFormat = pixelFormat(from: decoder)
            try validatePixelFormat(pixelFormat)

            // Cache the validated decoder for reuse in second pass
            cacheDecoder(decoder, for: url)

            // Capture baseline geometry from the first valid slice.
            if firstDecoder == nil {
                firstDecoder = decoder
                width = decoder.width
                height = decoder.height
                bitsAllocated = decoder.bitDepth
                spacing = SIMD3<Double>(decoder.pixelWidth, decoder.pixelHeight, decoder.pixelDepth)

                // Validate and normalize ImageOrientationPatient (IOP) when present.
                // We tolerate minor floating-point drift but reject degenerate/non-orthogonal vectors.
                if let candidate = decoder.imageOrientation {
                    orientation = try validatedOrientation(from: candidate)
                } else {
                    orientation = nil
                }

                origin = decoder.imagePosition
                // Issue #2813: Secondary Capture, NM and US spacing follows their SOP Class's own attributes.
                if let dataSet = (decoder as? DCMDecoder)?.dataSet,
                   let geometry = DicomSOPClassGeometry(dataSet: dataSet, sopClassUID: sopClassUID) {
                    spacing = geometry.spacing
                }
                rescaleSlope = decoder.rescaleParametersV2.slope
                rescaleIntercept = decoder.rescaleParametersV2.intercept
                pixelRepresentation = decoder.pixelRepresentationTagValue
                let description = decoder.getSeriesInfo()["SeriesDescription"] ?? ""
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    seriesDescription = description
                }
                studyDescription = nonEmpty(decoder.info(for: .studyDescription))
                patientName = decoder.info(for: .patientName)
                modality = decoder.info(for: .modality)
                studyInstanceUID = nonEmpty(decoder.info(for: DicomTag.studyInstanceUID.rawValue))
                seriesInstanceUID = nonEmpty(decoder.info(for: DicomTag.seriesInstanceUID.rawValue))
                frameOfReferenceUID = nonEmpty(decoder.info(for: 0x0020_0052))
                quantitativeValueProfile = decoder.quantitativeValueProfile
                baselinePixelFormat = pixelFormat
            } else {
                // Check consistency across slices.
                guard decoder.width == width, decoder.height == height else {
                    throw DicomSeriesLoaderError.inconsistentDimensions
                }
                if let candidateRaw = decoder.imageOrientation {
                    let candidate = try validatedOrientation(from: candidateRaw)
                    if let baseline = orientation {
                        if !isApproximatelyEqual(baseline.row, candidate.row) ||
                            !isApproximatelyEqual(baseline.column, candidate.column) {
                            throw DicomSeriesLoaderError.inconsistentOrientation
                        }
                    } else {
                        orientation = candidate
                    }
                }
                if decoder.pixelRepresentationTagValue != pixelRepresentation {
                    throw DicomSeriesLoaderError.inconsistentPixelRepresentation
                }
                if let baselinePixelFormat,
                   !hasConsistentPixelFormat(pixelFormat, comparedTo: baselinePixelFormat) {
                    throw DicomSeriesLoaderError.unsupportedPixelFormat(pixelFormat)
                }
            }

            let normal = orientation.flatMap { simd_normalize(simd_cross($0.row, $0.column)) }
            let projection: Double?
            if let ipp = decoder.imagePosition, let normal {
                projection = simd_dot(ipp, normal)
            } else {
                projection = nil
            }
            let instance = decoder.intValue(for: .instanceNumber)

            let window = windowCenterWidth(from: decoder)
            let sliceRescale = decoder.rescaleParametersV2
            slices.append(SliceMeta(url: url,
                                    position: decoder.imagePosition,
                                    instanceNumber: instance,
                                    projection: projection,
                                    windowCenter: window?.center,
                                    windowWidth: window?.width,
                                    studyInstanceUID: nonEmpty(decoder.info(for: .studyInstanceUID)) ?? studyInstanceUID,
                                    seriesInstanceUID: nonEmpty(decoder.info(for: .seriesInstanceUID)) ?? seriesInstanceUID,
                                    sopClassUID: nonEmpty(decoder.info(for: .sopClassUID)),
                                    sopInstanceUID: nonEmpty(decoder.info(for: .sopInstanceUID)),
                                    rescaleSlope: sliceRescale.slope,
                                    rescaleIntercept: sliceRescale.intercept,
                                    pixelFormat: pixelFormat))
        }

        guard !slices.isEmpty, firstDecoder != nil else {
            throw DicomSeriesLoaderError.noDicomFiles
        }

        // Sort slices by projection on the normal; fallback to Instance Number then filename.
        //
        // Ordering rule (documented):
        // 1) Prefer ImagePositionPatient projected onto the slice normal derived from IOP.
        // 2) If IPP projection is unavailable for either slice, fall back to InstanceNumber.
        // 3) If still tied, fall back to filename.
        //
        // Additionally, detect duplicate positions (same projection within epsilon), which are
        // ambiguous for volume assembly and usually indicate a malformed/duplicated series.
        let normal = orientation.flatMap { simd_normalize(simd_cross($0.row, $0.column)) } ?? SIMD3<Double>(0, 0, 1)
        slices.sort { lhs, rhs in
            if let lp = lhs.projection, let rp = rhs.projection, lp != rp {
                return lp < rp
            }
            if let li = lhs.instanceNumber, let ri = rhs.instanceNumber, li != ri {
                return li < ri
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }

        // Duplicate-projection check.
        // Use a small epsilon in mm to allow for floating point decode noise while still
        // catching truly duplicated slice locations.
        let duplicateProjectionEpsilon = 1e-3
        let projectedPositions = slices.compactMap(\.projection)
        if projectedPositions.count >= 2 {
            for i in 1..<projectedPositions.count {
                if abs(projectedPositions[i - 1] - projectedPositions[i]) <= duplicateProjectionEpsilon {
                    throw DicomSeriesLoaderError.duplicateSlicePosition
                }
            }
        }

        if let windowedSlice = slices.first(where: { $0.windowCenter != nil && $0.windowWidth != nil }) {
            windowCenter = windowedSlice.windowCenter
            windowWidth = windowedSlice.windowWidth
        }
        if let firstSlice = slices.first {
            rescaleSlope = firstSlice.rescaleSlope
            rescaleIntercept = firstSlice.rescaleIntercept
        }

        let sliceRescaleParameters = slices.map {
            DicomSliceRescaleParameters(slope: $0.rescaleSlope,
                                        intercept: $0.rescaleIntercept)
        }

        let imageInstances = slices.enumerated().compactMap { index, slice -> DicomSeriesImageInstance? in
            guard let sopInstanceUID = slice.sopInstanceUID else { return nil }
            return DicomSeriesImageInstance(
                studyInstanceUID: slice.studyInstanceUID,
                seriesInstanceUID: slice.seriesInstanceUID,
                sopClassUID: slice.sopClassUID,
                sopInstanceUID: sopInstanceUID,
                sliceIndex: index,
                instanceNumber: slice.instanceNumber
            )
        }

        // Compute Z spacing from IPP deltas when available. For volume reconstruction,
        // ImagePositionPatient gives the actual center-to-center slice distance in patient space.
        // Tag-derived Z spacing may come from SliceThickness or SpacingBetweenSlices and can be
        // absent, nominal, or inconsistent with the real reconstructed slice positions.
        let computedZ = try computeZSpacing(from: slices, normal: normal)
        spacing = SIMD3<Double>(spacing.x, spacing.y, computedZ ?? spacing.z)

        let depth = slices.count
        let sliceVoxelCount = width * height
        var voxelData = try allocateVoxelData(sliceVoxelCount * depth * MemoryLayout<Int16>.size)

        // Provide a lightweight volume descriptor for progress callbacks.
        let originForVolume = slices.first?.position ?? origin ?? SIMD3<Double>(repeating: 0)
        let orientationMatrix: simd_double3x3
        if let ori = orientation {
            let normalVec = simd_normalize(simd_cross(ori.row, ori.column))
            orientationMatrix = simd_double3x3(columns: (ori.row, ori.column, normalVec))
        } else {
            orientationMatrix = matrix_identity_double3x3
        }

        let progressVolume = DicomSeriesVolume(voxels: Data(),
                                               width: width,
                                               height: height,
                                               depth: depth,
                                               spacing: spacing,
                                               orientation: orientationMatrix,
                                               origin: originForVolume,
                                               rescaleSlope: rescaleSlope,
                                               rescaleIntercept: rescaleIntercept,
                                               bitsAllocated: bitsAllocated,
                                               isSignedPixel: pixelRepresentation == 1,
                                               patientName: patientName,
                                               seriesDescription: seriesDescription,
                                               studyDescription: studyDescription,
                                               modality: modality,
                                               windowCenter: windowCenter,
                                               windowWidth: windowWidth,
                                               studyInstanceUID: studyInstanceUID,
                                               seriesInstanceUID: seriesInstanceUID,
                                               frameOfReferenceUID: frameOfReferenceUID,
                                               quantitativeValueProfile: quantitativeValueProfile,
                                               imageInstances: imageInstances,
                                               sliceRescaleParameters: sliceRescaleParameters)

        var loadError: Error?

        // Acquire a single pooled buffer for reuse across all slices
        var sliceBuffer = BufferPool.shared.acquire(type: [Int16].self, count: sliceVoxelCount)
        var didReport32BitClamp = false
        defer {
            BufferPool.shared.release(sliceBuffer)
        }

        // Ensure buffer is large enough (pool uses bucketing, may return larger buffer)
        if sliceBuffer.count < sliceVoxelCount {
            // Shouldn't happen, but handle gracefully by extending buffer
            sliceBuffer.append(contentsOf: repeatElement(Int16(0), count: sliceVoxelCount - sliceBuffer.count))
        }

        // Allocate voxel buffer and copy slices sequentially for safety.
        voxelData.withUnsafeMutableBytes { rawBuffer in
            let dest = rawBuffer.bindMemory(to: Int16.self)
            for (index, slice) in slices.enumerated() {
                if Task.isCancelled {
                    loadError = CancellationError()
                    break
                }

                // Decode directly into reused buffer
                let pixelCount = try? self.decodeSliceIntoBuffer(
                    at: slice.url,
                    buffer: &sliceBuffer,
                    expectedWidth: width,
                    expectedHeight: height,
                    pixelFormat: slice.pixelFormat,
                    cachedDecoder: cachedDecoder(for:),
                    cacheDecoder: cacheDecoder(_:for:),
                    report32BitClamp: {
                        self.report32BitClampIfNeeded(
                            reported: &didReport32BitClamp,
                            pixelFormat: slice.pixelFormat,
                            url: slice.url
                        )
                    }
                )

                guard let pixelCount, pixelCount == sliceVoxelCount else {
                    loadError = DicomSeriesLoaderError.failedToDecode(slice.url)
                    break
                }

                let base = dest.baseAddress!.advanced(by: index * sliceVoxelCount)
                base.update(from: sliceBuffer, count: sliceVoxelCount)

                if let progress {
                    let fraction = Double(index + 1) / Double(depth)
                    let sliceData = Data(bytes: sliceBuffer, count: sliceVoxelCount * MemoryLayout<Int16>.size)
                    progress(fraction, index + 1, sliceData, progressVolume)
                }
            }
        }

        if let error = loadError {
            throw error
        }

        let volume = DicomSeriesVolume(voxels: voxelData,
                                       width: width,
                                       height: height,
                                       depth: depth,
                                       spacing: spacing,
                                       orientation: orientationMatrix,
                                       origin: originForVolume,
                                       rescaleSlope: rescaleSlope,
                                       rescaleIntercept: rescaleIntercept,
                                       bitsAllocated: bitsAllocated,
                                       isSignedPixel: pixelRepresentation == 1,
                                       patientName: patientName,
                                       seriesDescription: seriesDescription,
                                       studyDescription: studyDescription,
                                       modality: modality,
                                       windowCenter: windowCenter,
                                       windowWidth: windowWidth,
                                       studyInstanceUID: studyInstanceUID,
                                       seriesInstanceUID: seriesInstanceUID,
                                       frameOfReferenceUID: frameOfReferenceUID,
                                       quantitativeValueProfile: quantitativeValueProfile,
                                       imageInstances: imageInstances,
                                       sliceRescaleParameters: sliceRescaleParameters)

        return volume
    }
}

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func pixelFormat(from decoder: any DicomDecoderProtocol) -> DicomSeriesLoaderPixelFormat {
    let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
    let highBit = decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1)
    let transferSyntaxUID = decoder.info(for: .transferSyntaxUID)
    let transferSyntaxIsCompressed = DicomTransferSyntax(uid: transferSyntaxUID)?.isCompressed ?? false

    return DicomSeriesLoaderPixelFormat(
        bitsAllocated: decoder.bitDepth,
        bitsStored: bitsStored,
        highBit: highBit,
        pixelRepresentation: decoder.pixelRepresentationTagValue,
        samplesPerPixel: decoder.samplesPerPixel,
        photometricInterpretation: decoder.photometricInterpretation.isEmpty
            ? "MONOCHROME2"
            : decoder.photometricInterpretation,
        planarConfiguration: decoder.intValue(for: .planarConfiguration),
        numberOfFrames: decoder.nImages,
        transferSyntaxUID: transferSyntaxUID,
        isCompressed: decoder.compressedImage || transferSyntaxIsCompressed
    )
}

private func validatePixelFormat(_ pixelFormat: DicomSeriesLoaderPixelFormat) throws {
    let matrix = DicomSeriesLoaderSupportMatrix.standard
    if pixelFormat.isCompressed {
        guard matrix.supportsCompressedTransferSyntaxes else {
            throw DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(pixelFormat)
        }
        // Volume assembly only accepts compressed syntaxes whose decode
        // backend is active in this build; the typed error carries the
        // transfer syntax UID plus the slice's pixel metadata.
        let decision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: DicomTransferSyntax(uid: pixelFormat.transferSyntaxUID),
            requestedBitDepth: pixelFormat.bitsAllocated,
            samplesPerPixel: pixelFormat.samplesPerPixel,
            photometricInterpretation: pixelFormat.photometricInterpretation,
            bitsStored: pixelFormat.bitsStored
        )
        switch decision.backend {
        case .unsupported, .legacyImageIO:
            throw DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(pixelFormat)
        default:
            break
        }
    }
    if !matrix.supportsMultiframe, pixelFormat.numberOfFrames > 1 {
        throw DicomSeriesLoaderError.unsupportedMultiframe(pixelFormat)
    }
    guard matrix.supports(pixelFormat) else {
        throw DicomSeriesLoaderError.unsupportedPixelFormat(pixelFormat)
    }
}

private func hasConsistentPixelFormat(
    _ lhs: DicomSeriesLoaderPixelFormat,
    comparedTo rhs: DicomSeriesLoaderPixelFormat
) -> Bool {
    lhs.bitsAllocated == rhs.bitsAllocated &&
        lhs.bitsStored == rhs.bitsStored &&
        lhs.highBit == rhs.highBit &&
        lhs.pixelRepresentation == rhs.pixelRepresentation &&
        lhs.samplesPerPixel == rhs.samplesPerPixel &&
        lhs.photometricInterpretation == rhs.photometricInterpretation &&
        lhs.planarConfiguration == rhs.planarConfiguration
}
