//
//  DicomDecoderProtocol.swift
//
//  Protocol abstraction for DICOM decoder implementations.
//  Defines the public API for parsing DICOM files, extracting
//  metadata, and accessing pixel data.  Implementations must
//  support 8-bit and 16-bit grayscale images as well as 24-bit
//  RGB images, handle both little and big endian byte order,
//  and provide thread-safe access to all methods and properties.
//
//  Thread Safety:
//
//  All protocol methods and properties must be thread-safe and
//  support concurrent access from multiple threads without
//  requiring external synchronization.
//

import Foundation
import simd

/// Protocol defining the public API for DICOM file decoding.
///
/// ## Overview
///
/// ``DicomDecoderProtocol`` abstracts the core functionality for parsing and decoding DICOM medical
/// imaging files. Implementations must handle various DICOM transfer syntaxes (uncompressed and
/// compressed), extract metadata via DICOM tags, and provide pixel data in appropriate formats
/// (8-bit, 16-bit grayscale, or 24-bit RGB).
///
/// The protocol enables dependency injection and testability by allowing mock implementations
/// for testing without requiring actual DICOM files. The primary implementation is ``DCMDecoder``,
/// which provides full DICOM parsing capabilities.
///
/// ## Thread Safety
///
/// This protocol conforms to the `Sendable` protocol, indicating that conforming types can be
/// safely shared across concurrency boundaries. All implementations must provide comprehensive
/// thread-safety guarantees:
///
/// 1. **Protocol is Sendable**: The protocol inherits from `Sendable`, ensuring conforming types
///    can be safely passed between actors and async contexts without data races.
///
/// 2. **All methods are thread-safe**: Every method and computed property in this protocol must
///    be safe to call from multiple threads simultaneously. Implementations should use internal
///    synchronization mechanisms (e.g., locks, actors, or serial queues) to protect shared mutable
///    state.
///
/// 3. **Concurrent access is supported**: Multiple threads can read metadata, access pixel data,
///    and query properties concurrently without external synchronization. The implementation
///    guarantees data consistency and prevents race conditions internally.
///
/// Clients can safely use decoder instances from multiple threads without additional locking:
///
/// ```swift
/// let decoder = try DCMDecoder(contentsOf: url)
///
/// // Safe: Concurrent reads from multiple threads
/// DispatchQueue.global().async {
///     let patientName = decoder.info(for: .patientName)
/// }
///
/// DispatchQueue.global().async {
///     let pixels = decoder.getPixels16()
/// }
/// ```
///
/// ## Usage
///
/// Create a decoder instance using throwing initializers:
///
/// ```swift
/// // Protocol-based usage
/// let decoder: DicomDecoderProtocol = try DCMDecoder(contentsOf: url)
/// let width = decoder.width
/// let patientName = decoder.info(for: .patientName)
/// ```
///
/// Use protocol abstraction for dependency injection:
///
/// ```swift
/// class ImageProcessor {
///     private let decoder: DicomDecoderProtocol
///
///     init(decoder: DicomDecoderProtocol) {
///         self.decoder = decoder
///     }
///
///     func process() {
///         guard let pixels = decoder.getPixels16() else { return }
///         // Process pixel data
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Decoder
///
/// - ``init(contentsOf:)``
/// - ``init(contentsOfFile:)``
/// - ``load(from:)``
/// - ``load(fromFile:)``
///
/// ### Image Properties
///
/// - ``bitDepth``
/// - ``width``
/// - ``height``
/// - ``offset``
/// - ``nImages``
/// - ``samplesPerPixel``
/// - ``photometricInterpretation``
///
/// ### Spatial Properties
///
/// - ``pixelDepth``
/// - ``pixelWidth``
/// - ``pixelHeight``
/// - ``imageOrientation``
/// - ``imagePosition``
///
/// ### Display Properties
///
/// - ``windowCenter``
/// - ``windowWidth``
///
/// ### Status Properties
///
/// - ``dicomFound``
/// - ``compressedImage``
/// - ``signedImage``
/// - ``pixelRepresentationTagValue``
/// - ``isSignedPixelRepresentation``
///
/// ### Validation Methods
///
/// - ``validateDICOMFile(_:)``
/// - ``isValid()``
/// - ``getValidationStatus()``
///
/// ### Metadata Access
///
/// - ``info(for:)``
/// - ``intValue(for:)``
/// - ``doubleValue(for:)``
/// - ``windowSettingsV2``
/// - ``pixelSpacingV2``
/// - ``rescaleParametersV2``
///
/// ### Pixel Data Access
///
/// - ``getPixels16()``
/// - ``getPixels8()``
/// - ``getPixels24()``
public protocol DicomDecoderProtocol: AnyObject, Sendable {

    // MARK: - Image Properties

    /// Bit depth of the decoded pixels (8 or 16).
    var bitDepth: Int { get }

    /// Image width in pixels.
    var width: Int { get }

    /// Image height in pixels.
    var height: Int { get }

    /// Byte offset from the start of file data to pixel data.
    var offset: Int { get }

    /// Number of frames in a multi-frame image. Defaults to 1.
    var nImages: Int { get }

    /// Number of samples per pixel. 1 for grayscale, 3 for RGB.
    var samplesPerPixel: Int { get }

    /// Photometric interpretation (MONOCHROME1, MONOCHROME2, RGB, etc.)
    var photometricInterpretation: String { get }

    // MARK: - Spatial Properties

    /// Physical depth of each pixel (slice thickness) in millimeters.
    var pixelDepth: Double { get }

    /// Physical width of each pixel in millimeters.
    var pixelWidth: Double { get }

    /// Physical height of each pixel in millimeters.
    var pixelHeight: Double { get }

    /// Direction cosines for image rows and columns (0020,0037).
    /// Defines orientation in patient coordinate system.
    var imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)? { get }

    /// Patient-space origin for the top-left voxel (0020,0032).
    var imagePosition: SIMD3<Double>? { get }

    // MARK: - Display Properties

    /// Default window center for display.
    var windowCenter: Double { get }

    /// Default window width for display.
    var windowWidth: Double { get }

    // MARK: - Status Properties

    /// True if file contains DICM signature at offset 128.
    var dicomFound: Bool { get }

    /// True if file uses a compressed transfer syntax.
    var compressedImage: Bool { get }

    /// True if pixel data uses two's complement representation.
    var signedImage: Bool { get }

    /// Raw pixel representation flag (0 = unsigned, 1 = two's complement).
    var pixelRepresentationTagValue: Int { get }

    /// Convenience accessor for signed pixel representation.
    var isSignedPixelRepresentation: Bool { get }

    // MARK: - Validation Methods

    /// Validates DICOM file structure and required tags.
    /// - Parameter filename: Path to the DICOM file
    /// - Returns: Validation result with detailed issues if any
    func validateDICOMFile(_ filename: String) -> (isValid: Bool, issues: [String])

    /// Checks if the decoder has successfully read and parsed the DICOM file.
    /// - Returns: True if file is loaded and valid
    func isValid() -> Bool

    /// Returns detailed validation status of the loaded DICOM file.
    /// - Returns: Tuple with validation status, dimensions, pixel availability, and compression status
    func getValidationStatus() -> (isValid: Bool, width: Int, height: Int, hasPixels: Bool, isCompressed: Bool)

    // MARK: - File Loading Methods

    // MARK: Throwing Initializers (Recommended)

    /// Creates a new decoder instance and loads a DICOM file from a URL.
    /// This is the recommended initialization method for Swift code.
    ///
    /// - Parameter url: URL pointing to the DICOM file
    /// - Throws: `DICOMError.fileNotFound` if the file does not exist
    /// - Throws: `DICOMError.invalidDICOMFormat` if the file is not a valid DICOM file
    ///
    /// - Example:
    /// ```swift
    /// do {
    ///     let decoder = try DCMDecoder(contentsOf: fileURL)
    ///     let width = decoder.width
    ///     let height = decoder.height
    /// } catch {
    ///     print("Failed to load DICOM file: \(error)")
    /// }
    /// ```
    init(contentsOf url: URL) throws

    /// Creates a new decoder instance and loads a DICOM file from a file path.
    /// This is the recommended initialization method for String path workflows.
    ///
    /// - Parameter path: File system path to the DICOM file
    /// - Throws: `DICOMError.fileNotFound` if the file does not exist
    /// - Throws: `DICOMError.invalidDICOMFormat` if the file is not a valid DICOM file
    ///
    /// - Example:
    /// ```swift
    /// do {
    ///     let decoder = try DCMDecoder(contentsOfFile: "/path/to/file.dcm")
    ///     let pixels = decoder.getPixels16()
    /// } catch {
    ///     print("Failed to load DICOM file: \(error)")
    /// }
    /// ```
    init(contentsOfFile path: String) throws

    // MARK: Static Factory Methods

    /// Loads a DICOM file from a URL and returns a decoder instance.
    /// This static factory method is an alternative to the throwing initializer.
    ///
    /// - Parameter url: URL pointing to the DICOM file
    /// - Returns: A fully initialized decoder instance
    /// - Throws: `DICOMError.fileNotFound` if the file does not exist
    /// - Throws: `DICOMError.invalidDICOMFormat` if the file is not a valid DICOM file
    ///
    /// - Example:
    /// ```swift
    /// do {
    ///     let decoder = try DCMDecoder.load(from: fileURL)
    ///     let modality = decoder.info(for: 0x00080060)
    /// } catch {
    ///     print("Failed to load DICOM file: \(error)")
    /// }
    /// ```
    static func load(from url: URL) throws -> Self

    /// Loads a DICOM file from a file path and returns a decoder instance.
    /// This static factory method is an alternative to the throwing initializer.
    ///
    /// - Parameter path: File system path to the DICOM file
    /// - Returns: A fully initialized decoder instance
    /// - Throws: `DICOMError.fileNotFound` if the file does not exist
    /// - Throws: `DICOMError.invalidDICOMFormat` if the file is not a valid DICOM file
    ///
    /// - Example:
    /// ```swift
    /// do {
    ///     let decoder = try DCMDecoder.load(fromFile: "/path/to/file.dcm")
    ///     let patientName = decoder.info(for: 0x00100010)
    /// } catch {
    ///     print("Failed to load DICOM file: \(error)")
    /// }
    /// ```
    static func load(fromFile path: String) throws -> Self

    // MARK: - Pixel Data Access Methods

    /// Returns the 8-bit pixel buffer if the image is grayscale and
    /// encoded with eight bits per sample.  Returns nil if not available.
    /// Array length is width × height.
    /// - Returns: 8-bit pixel buffer or nil
    func getPixels8() -> [UInt8]?

    /// Returns the 16-bit pixel buffer if the image is grayscale and
    /// encoded with sixteen bits per sample.  Returns nil if not available.
    /// Array length is width × height.
    /// - Returns: 16-bit pixel buffer or nil
    func getPixels16() -> [UInt16]?

    /// Returns the 8-bit interleaved RGB pixel buffer if the image
    /// has three samples per pixel.  Returns nil if not available.
    /// Array length is width × height × 3.
    /// - Returns: 24-bit RGB pixel buffer or nil
    func getPixels24() -> [UInt8]?

    /// Returns a downsampled 16-bit pixel buffer for thumbnail generation.
    /// This method reads only every Nth pixel to dramatically speed up
    /// thumbnail creation.
    /// - Parameter maxDimension: Maximum dimension for the thumbnail (default 150)
    /// - Returns: Tuple with downsampled pixels and dimensions, or nil if not available
    func getDownsampledPixels16(maxDimension: Int) -> (pixels: [UInt16], width: Int, height: Int)?

    /// Returns a downsampled 8-bit pixel buffer for thumbnail generation.
    /// This method reads only every Nth pixel to dramatically speed up
    /// thumbnail creation for 8-bit grayscale images.
    /// - Parameter maxDimension: Maximum dimension for the thumbnail (default 150)
    /// - Returns: Tuple with downsampled pixels and dimensions, or nil if not available
    func getDownsampledPixels8(maxDimension: Int) -> (pixels: [UInt8], width: Int, height: Int)?

    /// Descriptor for native pixel data layout and frame byte offsets.
    var pixelDataDescriptor: DicomPixelDataDescriptor? { get }

    /// Returns one native uncompressed frame without decoding the full pixel buffer.
    /// - Parameter index: Zero-based frame index.
    /// - Returns: Raw frame bytes and layout metadata, or nil when unavailable.
    func getFrame(_ index: Int) -> DicomPixelFrame?

    /// Returns native uncompressed frames in a zero-based half-open range.
    /// - Parameter range: Frame range to retrieve.
    /// - Returns: Raw frame bytes and layout metadata, or nil when unavailable.
    func getFrames(_ range: Range<Int>) -> [DicomPixelFrame]?

    /// Returns all native uncompressed frames without using the decoded pixel cache.
    /// - Returns: Raw frame bytes and layout metadata, or nil when unavailable.
    func getAllFrames() -> [DicomPixelFrame]?

    /// Native color interpretation metadata needed by rendering layers for color images and CLUTs.
    var nativeColorMetadata: DicomNativeColorMetadata { get }

    /// Returns a display-ready interleaved 8-bit RGB buffer for one frame.
    /// The `frame` argument is a zero-based frame index.
    func displayRGBPixelBuffer(frame: Int) throws -> DicomDisplayPixelBuffer

    /// Parsed Enhanced Multi-frame Functional Groups, when present.
    var enhancedMultiframeFunctionalGroups: DicomEnhancedMultiframeFunctionalGroups? { get }

    /// Returns resolved Enhanced Multi-frame geometry for one zero-based frame.
    /// - Parameter index: Zero-based frame index.
    func enhancedFrameGeometry(at index: Int) -> DicomFrameGeometry?

    /// Parsed DICOM Segmentation object, when the instance is SEG.
    var segmentation: DicomSegmentation? { get }

    /// Parsed RT Structure Set object, when the instance is RTSTRUCT.
    var rtStructureSet: DicomRTStructureSet? { get }

    /// Parsed RT Dose volume, when the instance is RTDOSE.
    var rtDose: DicomRTDoseVolume? { get }

    /// Parsed RT Plan object, when the instance is RTPLAN.
    var rtPlan: DicomRTPlan? { get }

    /// Parsed Spatial Registration Storage document, when present and structurally valid.
    var spatialRegistration: DicomSpatialRegistrationDocument? { get }

    /// Parsed Parametric Map object, when the instance is Parametric Map Storage.
    var parametricMap: DicomParametricMap? { get }

    /// Parsed Structured Report document, including Key Object Selection documents.
    var structuredReport: DicomSRDocument? { get }

    /// Parsed Key Object Selection document, when the instance is KOS.
    var keyObjectSelection: DicomSRDocument? { get }

    /// Parsed Secondary Capture image metadata and source references.
    var secondaryCaptureImage: DicomSecondaryCaptureImage? { get }

    /// Parsed Grayscale Softcopy Presentation State annotations, when present.
    var grayscalePresentationState: DicomGrayscalePresentationState? { get }

    /// Parsed Encapsulated Document object, when the instance stores PDF/CDA/STL payloads.
    var encapsulatedDocument: DicomEncapsulatedDocument? { get }

    /// Parsed Waveform object, when the instance stores ECG or related temporal signal samples.
    var waveform: DicomWaveform? { get }

    /// Parsed Video object, when the instance stores MPEG/H.264/H.265 visible-light video.
    var video: DicomVideo? { get }

    /// Centralized DICOM display transform profile for modality, VOI, and presentation mapping.
    var displayTransformProfile: DicomDisplayTransformProfile { get }

    /// Returns one stored sample value from native Pixel Data without applying modality transforms.
    /// - Parameters:
    ///   - pixelIndex: Zero-based pixel index within the frame.
    ///   - frame: Zero-based frame index.
    ///   - sample: Zero-based sample index for multi-sample pixels.
    func storedPixelValue(at pixelIndex: Int, frame: Int, sample: Int) -> Int?

    /// Returns one stored sample converted through the decoder-owned modality transform.
    /// - Parameters:
    ///   - pixelIndex: Zero-based pixel index within the frame.
    ///   - frame: Zero-based frame index.
    ///   - sample: Zero-based sample index for multi-sample pixels.
    func modalityPixelValue(at pixelIndex: Int, frame: Int, sample: Int) -> Double?

    /// Calculates an auto-window from percentile bounds after modality transformation.
    /// - Parameters:
    ///   - lower: Lower percentile in the inclusive range 0...1.
    ///   - upper: Upper percentile in the inclusive range 0...1.
    func calculatePercentileWindow(lower: Double, upper: Double) -> WindowSettings?

    /// Quantitative profile for Real World Value mappings and PET SUV metadata.
    var quantitativeValueProfile: DicomQuantitativeValueProfile { get }

    /// Returns one pixel as raw stored, modality-transformed, and optional physical value.
    /// - Parameters:
    ///   - pixelIndex: Zero-based pixel index within the frame.
    ///   - frame: Zero-based frame index.
    ///   - sample: Zero-based sample index for multi-sample pixels.
    ///   - preferredRealWorldValueMapLabel: Optional Real World Value map label to prefer.
    ///   - suvType: Optional SUV normalization to calculate from PET activity concentration.
    func quantitativeValue(at pixelIndex: Int,
                           frame: Int,
                           sample: Int,
                           preferredRealWorldValueMapLabel: String?,
                           suvType: DicomSUVType?) -> DicomQuantitativeValue?

    // MARK: - Range-Based Pixel Data Access Methods

    /// Returns a subset of 8-bit pixel data specified by a range of pixel indices.
    /// This method enables streaming access for large images without loading the
    /// entire pixel buffer into memory.  Pixel indices are in row-major order.
    /// - Parameter range: Range of pixel indices to retrieve (0..<width*height)
    /// - Returns: 8-bit pixel buffer for the specified range or nil
    func getPixels8(range: Range<Int>) -> [UInt8]?

    /// Returns a subset of 16-bit pixel data specified by a range of pixel indices.
    /// This method enables streaming access for large images without loading the
    /// entire pixel buffer into memory.  Pixel indices are in row-major order.
    /// - Parameter range: Range of pixel indices to retrieve (0..<width*height)
    /// - Returns: 16-bit pixel buffer for the specified range or nil
    func getPixels16(range: Range<Int>) -> [UInt16]?

    /// Returns a subset of 24-bit RGB pixel data specified by a range of pixel indices.
    /// This method enables streaming access for large images without loading the
    /// entire pixel buffer into memory.  Pixel indices are in row-major order.
    /// The returned array contains interleaved RGB values (3 bytes per pixel).
    /// - Parameter range: Range of pixel indices to retrieve (0..<width*height)
    /// - Returns: 24-bit RGB pixel buffer for the specified range or nil
    func getPixels24(range: Range<Int>) -> [UInt8]?

    // MARK: - Metadata Access Methods

    /// Retrieves the value of a parsed header as a string.
    /// Returns an empty string if the tag was not found.
    /// - Parameter tag: DICOM tag identifier (e.g., 0x00100010)
    /// - Returns: Tag value as string
    func info(for tag: Int) -> String

    /// Retrieves an integer value for a DICOM tag.
    /// - Parameter tag: The DICOM tag to retrieve
    /// - Returns: Integer value or nil if not found or cannot be parsed
    func intValue(for tag: Int) -> Int?

    /// Retrieves a double value for a DICOM tag.
    /// - Parameter tag: The DICOM tag to retrieve
    /// - Returns: Double value or nil if not found or cannot be parsed
    func doubleValue(for tag: Int) -> Double?

    /// Returns all available DICOM tags as a dictionary.
    /// - Returns: Dictionary of tag hex string to value
    func getAllTags() -> [String: String]

    /// Returns patient demographics in a structured format.
    /// - Returns: Dictionary with patient information (Name, ID, Sex, Age)
    func getPatientInfo() -> [String: String]

    /// Returns study information in a structured format.
    /// - Returns: Dictionary with study information (StudyInstanceUID, StudyID, StudyDate, etc.)
    func getStudyInfo() -> [String: String]

    /// Returns series information in a structured format.
    /// - Returns: Dictionary with series information (SeriesInstanceUID, SeriesNumber, etc.)
    func getSeriesInfo() -> [String: String]

    // MARK: - Convenience Properties

    /// Quick check if this is a valid grayscale image.
    var isGrayscale: Bool { get }

    /// Quick check if this is a color/RGB image.
    var isColorImage: Bool { get }

    /// Quick check if this is a multi-frame image.
    var isMultiFrame: Bool { get }

    /// Returns image dimensions as a tuple.
    var imageDimensions: (width: Int, height: Int) { get }

    // MARK: - Type-Safe Value Properties (V2 APIs)

    /// Returns pixel spacing as a type-safe struct
    ///
    /// This property provides physical pixel spacing in all three dimensions (x, y, z)
    /// as millimeters per pixel. Use the `isValid` property to check if spacing values
    /// are physically meaningful (all positive).
    ///
    /// ## Example
    /// ```swift
    /// let spacing = decoder.pixelSpacingV2
    /// if spacing.isValid {
    ///     print("Pixel spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")
    /// }
    /// ```
    var pixelSpacingV2: PixelSpacing { get }

    /// Returns window settings as a type-safe struct
    ///
    /// This property provides the default window center and width for display.
    /// Window settings control the mapping of pixel values to display brightness.
    /// Use the `isValid` property to check if settings have a positive width.
    ///
    /// ## Example
    /// ```swift
    /// let settings = decoder.windowSettingsV2
    /// if settings.isValid {
    ///     // Apply windowing with settings.center and settings.width
    /// }
    /// ```
    var windowSettingsV2: WindowSettings { get }

    /// Returns rescale parameters as a type-safe struct
    ///
    /// This property provides the rescale slope and intercept for converting stored
    /// pixel values to modality units (e.g., Hounsfield Units for CT).
    /// Use the `isIdentity` property to check if rescaling is needed.
    ///
    /// ## Example
    /// ```swift
    /// let rescale = decoder.rescaleParametersV2
    /// if !rescale.isIdentity {
    ///     let hounsfieldValue = rescale.apply(to: pixelValue)
    /// }
    /// ```
    var rescaleParametersV2: RescaleParameters { get }

    // MARK: - Utility Methods

    /// Applies rescale slope and intercept to a pixel value.
    /// - Parameter pixelValue: Raw pixel value
    /// - Returns: Rescaled value (Hounsfield Units for CT, etc.)
    func applyRescale(to pixelValue: Double) -> Double

    /// Calculates optimal window/level based on pixel data statistics (V2 API)
    ///
    /// Analyzes pixel data to determine optimal window center and width for display.
    /// This method calculates statistics from the 16-bit pixel buffer and returns
    /// type-safe WindowSettings that can be used with windowing processors.
    ///
    /// - Returns: WindowSettings with optimal center and width, or nil if no pixel data
    ///
    /// ## Example
    /// ```swift
    /// if let settings = decoder.calculateOptimalWindowV2() {
    ///     if settings.isValid {
    ///         // Apply optimal windowing
    ///         let displayPixels = DCMWindowingProcessor.applyWindowLevel(
    ///             pixels16: pixels,
    ///             center: settings.center,
    ///             width: settings.width
    ///         )
    ///     }
    /// }
    /// ```
    func calculateOptimalWindowV2() -> WindowSettings?

    /// Returns image quality metrics.
    /// - Returns: Dictionary with quality metrics or nil if no pixel data
    func getQualityMetrics() -> [String: Double]?
}

// MARK: - DicomTag Convenience Methods

/// Protocol extension providing type-safe DicomTag overloads for metadata access.
/// These methods delegate to the existing Int-based methods for backward compatibility.
public extension DicomDecoderProtocol {
    var pixelDataDescriptor: DicomPixelDataDescriptor? {
        nil
    }

    func getFrame(_ index: Int) -> DicomPixelFrame? {
        nil
    }

    func getFrames(_ range: Range<Int>) -> [DicomPixelFrame]? {
        nil
    }

    func getAllFrames() -> [DicomPixelFrame]? {
        nil
    }

    var enhancedMultiframeFunctionalGroups: DicomEnhancedMultiframeFunctionalGroups? {
        nil
    }

    func enhancedFrameGeometry(at index: Int) -> DicomFrameGeometry? {
        nil
    }

    var segmentation: DicomSegmentation? {
        nil
    }

    var rtStructureSet: DicomRTStructureSet? {
        nil
    }

    var rtDose: DicomRTDoseVolume? {
        nil
    }

    var rtPlan: DicomRTPlan? {
        nil
    }

    var spatialRegistration: DicomSpatialRegistrationDocument? {
        nil
    }

    var parametricMap: DicomParametricMap? {
        nil
    }

    var structuredReport: DicomSRDocument? {
        nil
    }

    var keyObjectSelection: DicomSRDocument? {
        nil
    }

    var secondaryCaptureImage: DicomSecondaryCaptureImage? {
        nil
    }

    var grayscalePresentationState: DicomGrayscalePresentationState? {
        nil
    }

    var encapsulatedDocument: DicomEncapsulatedDocument? {
        nil
    }

    var waveform: DicomWaveform? {
        nil
    }

    var video: DicomVideo? {
        nil
    }

    var displayTransformProfile: DicomDisplayTransformProfile {
        .identity
    }

    func storedPixelValue(at pixelIndex: Int, frame: Int, sample: Int) -> Int? {
        nil
    }

    func storedPixelValue(at pixelIndex: Int) -> Int? {
        storedPixelValue(at: pixelIndex, frame: 0, sample: 0)
    }

    func modalityPixelValue(at pixelIndex: Int, frame: Int, sample: Int) -> Double? {
        nil
    }

    func modalityPixelValue(at pixelIndex: Int) -> Double? {
        modalityPixelValue(at: pixelIndex, frame: 0, sample: 0)
    }

    func calculatePercentileWindow(lower: Double, upper: Double) -> WindowSettings? {
        nil
    }

    func calculatePercentileWindow() -> WindowSettings? {
        calculatePercentileWindow(lower: 0.01, upper: 0.99)
    }

    var quantitativeValueProfile: DicomQuantitativeValueProfile {
        .empty
    }

    func quantitativeValue(at pixelIndex: Int,
                           frame: Int = 0,
                           sample: Int = 0,
                           preferredRealWorldValueMapLabel: String? = nil,
                           suvType: DicomSUVType? = nil) -> DicomQuantitativeValue? {
        nil
    }

    /// Retrieves the value of a parsed header as a string using a DicomTag enum.
    /// Returns an empty string if the tag was not found.
    ///
    /// This is the recommended approach for accessing standard DICOM tags:
    /// ```swift
    /// let patientName = decoder.info(for: .patientName)  // Preferred
    /// let patientName = decoder.info(for: 0x00100010)    // Legacy approach
    /// ```
    ///
    /// - Parameter tag: DICOM tag from DicomTag enum (e.g., .patientName, .studyDate)
    /// - Returns: Tag value as string, or empty string if not found
    func info(for tag: DicomTag) -> String {
        return info(for: tag.rawValue)
    }

    /// Retrieves an integer value for a DICOM tag using a DicomTag enum.
    ///
    /// This is the recommended approach for accessing standard DICOM integer tags:
    /// ```swift
    /// let rows = decoder.intValue(for: .rows)       // Preferred
    /// let rows = decoder.intValue(for: 0x00280010)  // Legacy approach
    /// ```
    ///
    /// - Parameter tag: DICOM tag from DicomTag enum (e.g., .rows, .columns)
    /// - Returns: Integer value or nil if not found or cannot be parsed
    func intValue(for tag: DicomTag) -> Int? {
        return intValue(for: tag.rawValue)
    }

    /// Retrieves a double value for a DICOM tag using a DicomTag enum.
    ///
    /// This is the recommended approach for accessing standard DICOM floating-point tags:
    /// ```swift
    /// let windowCenter = decoder.doubleValue(for: .windowCenter)  // Preferred
    /// let windowCenter = decoder.doubleValue(for: 0x00281050)     // Legacy approach
    /// ```
    ///
    /// - Parameter tag: DICOM tag from DicomTag enum (e.g., .windowCenter, .windowWidth)
    /// - Returns: Double value or nil if not found or cannot be parsed
    func doubleValue(for tag: DicomTag) -> Double? {
        return doubleValue(for: tag.rawValue)
    }
}
