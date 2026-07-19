//
//  DCMDecoder.swift
//
//  This class parses DICOM files
//  encoded with little or big endian explicit or implicit VR and
//  extracts metadata and pixel data.  The decoder handles 8‑bit
//  and 16‑bit grayscale images as well as 24‑bit RGB images
//  (common for ultrasound).  Compressed transfer syntaxes including
//  JPEG Lossless, RLE, JPEG Baseline, JPEG 2000, and JPEG‑LS are
//  supported via native decoders, runtime codec bridges, and ImageIO
//  fallback.  See the original Objective‑C code for a one‑to‑one algorithmic
//  reference; this port emphasises clarity, safety and Swift
//  idioms while maintaining the same public API.
//
//  Thread Safety:
//
//  DCMDecoder is fully thread‑safe.  Instances can be safely
//  accessed from multiple threads concurrently.  All public
//  methods are protected by internal locking mechanisms that
//  ensure data consistency without requiring external
//  synchronization.  This enables concurrent image loading for
//  responsive UIs in modern iOS applications.
//
//  Usage:
//
//    let decoder = DCMDecoder()
//    decoder.setDicomFilename(url.path)
//    if decoder.dicomFileReadSuccess {
//        let pixels = decoder.getPixels16()
//        // process pixels
//    }
//

import Foundation
import CoreGraphics
import ImageIO
import simd

/// Backward compatibility alias to centralized DICOM tag constants.
/// All tag references now point to the public DicomTag enum defined
/// in DicomConstants.swift.
private typealias Tag = DicomTag

/// Backward compatibility alias to centralized Value Representation constants.
/// All VR references now point to the public DicomVR enum defined
/// in DicomConstants.swift.
private typealias VR = DicomVR

// MARK: - Main Decoder Class

/// Primary decoder for DICOM medical imaging files.
///
/// ## Overview
///
/// ``DCMDecoder`` parses DICOM files encoded with little or big endian explicit or implicit VR
/// and extracts metadata and pixel data. The decoder handles 8-bit and 16-bit grayscale images
/// as well as 24-bit RGB images (common for ultrasound). Compressed transfer syntaxes including
/// JPEG Lossless, RLE, JPEG Baseline, JPEG 2000, and JPEG-LS are supported via native decoders,
/// runtime codec bridges, and ImageIO fallback.
///
/// The public API mirrors the original Objective-C implementation but uses Swift properties
/// and modern error handling. Pixel buffers are returned as optional arrays and remain `nil`
/// until file loading succeeds.
///
/// ## Usage
///
/// Create a decoder instance using throwing initializers (recommended):
///
/// ```swift
/// do {
///     let decoder = try DCMDecoder(contentsOf: url)
///     print("Image: \(decoder.width) × \(decoder.height)")
///     if let pixels = decoder.getPixels16() {
///         // Process 16-bit grayscale pixel data
///     }
/// } catch DICOMError.fileNotFound(let path) {
///     print("File not found: \(path)")
/// } catch DICOMError.invalidDICOMFormat(let path, let reason) {
///     print("Invalid DICOM: \(reason)")
/// } catch {
///     print("Error: \(error)")
/// }
/// ```
///
/// Access metadata using type-safe ``DicomTag`` enum:
///
/// ```swift
/// let patientName = decoder.info(for: .patientName)
/// let modality = decoder.info(for: .modality)
/// let windowSettings = decoder.windowSettingsV2
/// ```
///
/// For non-blocking file loading, use async variants:
///
/// ```swift
/// Task {
///     let decoder = try await DCMDecoder(contentsOf: url)
///     // Process asynchronously
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a Decoder
///
/// - ``init()``
/// - ``init(contentsOf:)``
/// - ``init(contentsOfFile:)``
/// - ``init(data:)``
/// - ``load(from:)``
/// - ``load(fromFile:)``
///
/// ### Loading Files (Legacy)
///
/// - ``setDicomFilename(_:)``
/// - ``loadDICOMFileAsync(filename:)``
/// - ``dicomFileReadSuccess``
/// - ``dicomFound``
///
/// ### Accessing Metadata
///
/// - ``info(for:)``
/// - ``intValue(for:)``
/// - ``doubleValue(for:)``
/// - ``windowSettingsV2``
/// - ``pixelSpacingV2``
/// - ``rescaleParametersV2``
/// - ``windowSettings``
/// - ``pixelSpacing``
/// - ``rescaleParameters``
///
/// ### Accessing Pixel Data
///
/// - ``getPixels16()``
/// - ``getPixels8()``
/// - ``getPixels24()``
///
/// ### Image Properties
///
/// - ``width``
/// - ``height``
/// - ``bitDepth``
/// - ``samplesPerPixel``
/// - ``photometricInterpretation``
/// - ``pixelDepth``
/// - ``pixelWidth``
/// - ``pixelHeight``
///
/// ### Geometric Properties
///
/// - ``imageOrientation``
/// - ``imagePosition``
///
/// ### Display Properties
///
/// - ``windowCenter``
/// - ``windowWidth``
///
/// ### Validation
///
/// - ``validateDICOMFile(_:)``
/// - ``isValid()``
/// - ``getValidationStatus()``
///
/// ### Status Properties
///
/// - ``compressedImage``
/// - ``signedImage``
/// - ``pixelRepresentationTagValue``
/// - ``isSignedPixelRepresentation``
///
/// ### Multi-Frame Support
///
/// - ``offset``
/// - ``nImages``
///
/// ## Thread Safety
///
/// This class is fully thread-safe. All public methods and properties can be safely accessed
/// from multiple threads concurrently. Internal lock-based synchronization protects all mutable
/// state, ensuring safe concurrent operations without data races. Performance impact is minimal
/// (<10%) due to the I/O-bound nature of DICOM decoding operations.
///
/// ## Metadata Parsing Strategy
///
/// DCMDecoder uses a hybrid lazy/eager parsing strategy to optimize memory usage and performance.
/// DICOM files can contain 100+ metadata tags, but typical applications access only 10-15 tags
/// (PatientName, Modality, WindowCenter, etc.). Parsing all tags upfront creates unnecessary
/// string allocations and dictionary operations.
///
/// ### Eager Parsing (Critical Tags)
///
/// Tags that affect decoder behavior or are frequently accessed are parsed immediately during
/// file loading (``setDicomFilename(_:)`` or ``loadDICOMFileAsync(filename:)``):
///
/// - **Parsing Control:** `transferSyntaxUID`, `pixelData` — determine compression handling
///   and pixel data location
/// - **Image Dimensions:** `rows`, `columns`, `bitsAllocated` — validated immediately to catch
///   malformed files early
/// - **Pixel Interpretation:** `samplesPerPixel`, `photometricInterpretation`,
///   `pixelRepresentation` — control pixel buffer allocation and data interpretation
/// - **Display Windowing:** `windowCenter`, `windowWidth` — frequently accessed for image display
/// - **Geometry:** `imageOrientation`, `imagePosition` — used for 3D reconstruction and series
///   ordering
/// - **Spatial Calibration:** `pixelSpacing`, `sliceThickness` — physical measurement conversion
/// - **Value Mapping:** `rescaleIntercept`, `rescaleSlope` — Hounsfield unit conversion
/// - **Palette Color:** `redPalette`, `greenPalette`, `bluePalette` — color lookup tables
/// - **Multi-frame:** `numberOfFrames`, `planarConfiguration` — frame handling
/// - **Modality:** `modality` — frequently accessed identifier
///
/// ### Lazy Parsing (Metadata-Only Tags)
///
/// All other tags (patient demographics, study information, private tags, etc.) are stored as
/// raw metadata during file loading:
///
/// 1. File parsing stores tag metadata (tag ID, file offset, VR, length) in an internal cache
///    without reading values
/// 2. First call to ``info(for:)`` triggers on-demand parsing which reads and formats the tag
///    value from the file
/// 3. Parsed value is cached for fast subsequent access
///
/// ### Performance Benefits
///
/// - **Reduced Memory:** Files with 100+ tags only allocate strings for accessed tags
///   (~32 bytes metadata vs ~100+ bytes string)
/// - **Faster Loading:** File parsing skips string formatting for unused tags
/// - **Maintained Speed:** Cached values ensure no performance penalty for repeated access
///   (<0.1ms per tag)
///
/// This strategy mirrors the existing lazy pixel loading pattern: pixel data is not decoded
/// until ``getPixels16()`` or ``getPixels8()`` is called. Both optimizations ensure that
/// DCMDecoder only performs expensive operations when actually needed.
public final class DCMDecoder: DicomDecoderProtocol, @unchecked Sendable {
    
    // MARK: - Properties

    // MARK: - Safety Constants

    /// Maximum allowed image dimension (width or height) in pixels.
    /// Prevents excessive memory allocation from malformed headers.
    static let maxImageDimension: Int = 65536

    /// Maximum allowed size for pixel buffer allocation (2 GB).
    /// Protects against memory bombs from unrealistic image dimensions.
    static let maxPixelBufferSize: Int64 = 2 * 1024 * 1024 * 1024

    /// Dictionary used to translate tags to human readable names.  The
    /// original code stored a strong pointer to ``DCMDictionary``.
    let dict = DCMDictionary()

    let logger: LoggerProtocol = DicomLogger.make(subsystem: "com.dicomviewer", category: "DCMDecoder")

    /// Lock for thread-safe access to decoder state.
    /// Protects all mutable properties and ensures safe concurrent access.
    private let lock = DicomLock()
    
    /// Per-instance key for tracking lock recursion in the current thread dictionary.
    /// Allows synchronized accessors to avoid deadlocking when called from already
    /// synchronized code paths on the same decoder instance.
    private var synchronizationDepthKey: String {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let token = String(UInt(bitPattern: pointer), radix: 16)
        return "DCMDecoder.syncDepth.\(token)"
    }

    /// Tag handler registry for strategy-based tag processing.
    /// Maps DICOM tag IDs to specialized handler implementations.
    lazy var handlerRegistry = TagHandlerRegistry()

    /// Raw filename used to open the file.  Kept for reference but
    /// never exposed directly.
    var dicomFileName: String = ""

    /// Raw DICOM file contents. Large files may be memory-mapped into this
    /// `Data` value; keeping it alive preserves the mapping lifetime.
    /// All reads into this data respect the current ``location`` cursor.
    var dicomData: Data = Data()
    var fileSize: Int = 0

    /// Cursor into ``dicomData`` used for sequential reading.
    var location: Int = 0

    /// Binary reader for low-level DICOM data access
    var reader: DCMBinaryReader?

    /// Tag parser for DICOM tag parsing and metadata extraction
    var tagParser: DCMTagParser?

    /// Pixel representation: 0 for unsigned, 1 for two's complement
    /// signed data.  This affects how 16‑bit pixel data are
    /// normalised.
    var pixelRepresentation: Int = 0

    /// Minimum values used for mapping signed pixel data into
    /// unsigned representation.  ``min8`` is unused in this port
    /// but retained to mirror the original design.  ``min16`` is
    /// used when converting 16‑bit two's complement data into
    /// unsigned ranges.
    var min8: Int = 0
    var min16: Int = Int(Int16.min)

    /// Flags controlling how the decoder behaves when encountering
    /// certain structures in the file.
    var bigEndianTransferSyntax: Bool = false
    var isExplicitVRTransferSyntax: Bool = true
    var littleEndian: Bool = true

    /// Rescale intercept and slope.  These values are stored in
    /// DICOM headers and may be used to map pixel intensities to
    /// physical values.  This implementation does not apply them
    /// automatically but exposes them for clients to use as
    /// appropriate.
    var rescaleIntercept: Double = 0.0
    var rescaleSlope: Double = 1.0

    /// Colour lookup tables for palette‑based images.  These are
    /// rarely used in modern imaging but are included for
    /// completeness.  When present the decoder will populate them
    /// with one byte per entry, representing the high eight bits of
    /// the 16‑bit LUT values.  Clients may combine these into
    /// colour images as desired.
    var reds: [UInt8]? = nil
    var redPaletteDescriptor: DicomLUTDescriptor? = nil
    var greens: [UInt8]? = nil
    var greenPaletteDescriptor: DicomLUTDescriptor? = nil
    var blues: [UInt8]? = nil
    var bluePaletteDescriptor: DicomLUTDescriptor? = nil

    /// Buffers for pixel data.  Only one of these will be non‑nil
    /// depending on ``samplesPerPixel`` and ``bitDepth``.  Grayscale
    /// 8‑bit data uses ``pixels8``, grayscale 16‑bit data uses
    /// ``pixels16`` and colour (3 samples per pixel) uses
    /// ``pixels24``.
    var pixels8: [UInt8]? = nil
    var pixels16: [UInt16]? = nil
    var pixels24: [UInt8]? = nil
    /// True after metadata parsing when pixel payload exists but has not yet
    /// been decoded into in-memory buffers.
    private var _pixelsNotLoaded: Bool = true
    var pixelsNotLoaded: Bool {
        get { synchronized { _pixelsNotLoaded } }
        set { synchronized { _pixelsNotLoaded = newValue } }
    }

    /// Dictionary of parsed metadata keyed by raw tag integer.
    /// Values consist of the VR description followed by a colon and
    /// the value.  For unknown tags the description may be
    /// ``"---"`` indicating a private tag.  Clients should use
    /// ``info(for:)`` to extract the value portion cleanly.
    var dicomInfoDict: [Int: String] = [:]

    /// Active character set for textual metadata.
    var activeCharacterSet: DicomSpecificCharacterSet = .defaultCharacterSet

    /// Specific Character Set terms declared by the loaded DICOM object.
    public var specificCharacterSet: [String] {
        synchronized { activeCharacterSet.definedTerms }
    }
    
    /// OPTIMIZATION: Cache for frequently accessed parsed values to avoid string processing
    var cachedInfo: [Int: String] = [:]

    /// OPTIMIZATION: Lazy tag metadata cache for deferred tag value parsing.
    /// Stores raw tag information (offset, VR, length) without parsing to strings.
    /// Used to implement lazy parsing where tag values are only extracted when
    /// first accessed via ``info(for:)``, reducing memory allocations for files
    /// with many unused tags.
    var tagMetadataCache: [Int: TagMetadata] = [:]

    /// Frequently accessed DICOM tags that benefit from caching
    static let frequentTags: Set<Int> = [
        DicomTag.rescaleSlope.rawValue,
        DicomTag.rescaleIntercept.rawValue,
        DicomTag.protocolName.rawValue,
        DicomTag.seriesDescription.rawValue,
        DicomTag.acquisitionProtocolName.rawValue,
        DicomTag.rows.rawValue,
        DicomTag.columns.rawValue,
        DicomTag.bitsAllocated.rawValue,
        DicomTag.bitsStored.rawValue,
        DicomTag.highBit.rawValue,
        DicomTag.pixelRepresentation.rawValue
    ]

    /// Transfer Syntax UID detected in the header.  Used to
    /// determine whether the image data is compressed and which
    /// decoder to use.  Stored when the `TRANSFER_SYNTAX_UID` tag
    /// is encountered in ``readFileInfo``.
    var transferSyntaxUID: String = ""

    // MARK: - Public properties

    /// Bit depth of the decoded pixels (8 or 16).  Defaults to
    /// 16 until parsed from the header.  Read‑only outside the
    /// class.
    private var _bitDepth: Int = 16
    public internal(set) var bitDepth: Int {
        get { synchronized { _bitDepth } }
        set { synchronized { _bitDepth = newValue } }
    }

    /// Image dimensions in pixels.  Defaults to 1×1 until parsed.
    private var _width: Int = 1
    private var _height: Int = 1
    public internal(set) var width: Int {
        get { synchronized { _width } }
        set { synchronized { _width = newValue } }
    }
    public internal(set) var height: Int {
        get { synchronized { _height } }
        set { synchronized { _height = newValue } }
    }

    /// Byte offset from the start of ``dicomData`` to the
    /// beginning of ``pixelData``.  Useful for debugging.  Not
    /// currently used elsewhere in this class.
    private var _offset: Int = 1
    public internal(set) var offset: Int {
        get { synchronized { _offset } }
        set { synchronized { _offset = newValue } }
    }

    /// Number of frames in a multi‑frame image.  Defaults to 1.
    private var _nImages: Int = 1
    public internal(set) var nImages: Int {
        get { synchronized { _nImages } }
        set { synchronized { _nImages = newValue } }
    }

    /// Number of samples per pixel.  1 for grayscale, 3 for RGB.  If
    /// other values are encountered the decoder will still parse the
    /// metadata but the pixel data may not be interpretable by
    /// ``Dicom2DView``.  Defaults to 1.
    private var _samplesPerPixel: Int = 1
    public internal(set) var samplesPerPixel: Int {
        get { synchronized { _samplesPerPixel } }
        set { synchronized { _samplesPerPixel = newValue } }
    }
    
    /// Photometric interpretation (MONOCHROME1 or MONOCHROME2).
    /// MONOCHROME1 means white is zero (common for X-rays)
    /// MONOCHROME2 means black is zero (standard grayscale)
    private var _photometricInterpretation: String = ""
    public internal(set) var photometricInterpretation: String {
        get { synchronized { _photometricInterpretation } }
        set { synchronized { _photometricInterpretation = newValue } }
    }

    /// Physical dimensions of the pixel spacing.  These values are
    /// derived from the ``PIXEL_SPACING`` and ``SLICE_THICKNESS``
    /// tags and may be used by clients to compute aspect ratios or
    /// volumetric measurements.
    private var _pixelDepth: Double = 1.0
    private var _pixelWidth: Double = 1.0
    private var _pixelHeight: Double = 1.0
    public internal(set) var pixelDepth: Double {
        get { synchronized { _pixelDepth } }
        set { synchronized { _pixelDepth = newValue } }
    }
    public internal(set) var pixelWidth: Double {
        get { synchronized { _pixelWidth } }
        set { synchronized { _pixelWidth = newValue } }
    }
    public internal(set) var pixelHeight: Double {
        get { synchronized { _pixelHeight } }
        set { synchronized { _pixelHeight = newValue } }
    }
    /// Direction cosines for the image rows/columns (0020,0037)
    private var _imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)?
    public internal(set) var imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)? {
        get { synchronized { _imageOrientation } }
        set { synchronized { _imageOrientation = newValue } }
    }
    /// Patient-space origin for the top-left voxel (0020,0032)
    private var _imagePosition: SIMD3<Double>?
    public internal(set) var imagePosition: SIMD3<Double>? {
        get { synchronized { _imagePosition } }
        set { synchronized { _imagePosition = newValue } }
    }

    /// Default window centre and width for display.  These come
    /// from the ``WINDOW_CENTER`` and ``WINDOW_WIDTH`` tags when
    /// present.  If absent they default to zero, leaving it to
    /// the viewer to choose appropriate values based on the image
    /// histogram.
    private var _windowCenter: Double = 0.0
    private var _windowWidth: Double = 0.0
    public internal(set) var windowCenter: Double {
        get { synchronized { _windowCenter } }
        set { synchronized { _windowCenter = newValue } }
    }
    public internal(set) var windowWidth: Double {
        get { synchronized { _windowWidth } }
        set { synchronized { _windowWidth = newValue } }
    }

    /// Flags indicating the status of the decoder.  `dicomFound`
    /// becomes true if the file begins with ``"DICM"`` at offset
    /// 128.  `dicomFileReadSuccess` indicates whether the header
    /// parsed successfully and pixels were read.  `compressedImage`
    /// becomes true if an unsupported transfer syntax is detected.
    /// `signedImage` indicates whether the pixel data originally used
    /// two's complement representation.
    private var _dicomFound: Bool = false
    public internal(set) var dicomFound: Bool {
        get { synchronized { _dicomFound } }
        set { synchronized { _dicomFound = newValue } }
    }

    /// **Note:** This property is part of the legacy API. When using the new throwing
    /// initializers (`init(contentsOf:)` or `init(contentsOfFile:)`), successful
    /// initialization guarantees this will be `true`, and failure throws an error instead.
    private var _dicomFileReadSuccess: Bool = false
    @available(*, deprecated, message: "When using throwing initializers (init(contentsOf:) or init(contentsOfFile:)), successful initialization guarantees validity. Check for thrown errors instead of this property.")
    public internal(set) var dicomFileReadSuccess: Bool {
        get { synchronized { _dicomFileReadSuccess } }
        set { synchronized { _dicomFileReadSuccess = newValue } }
    }

    /// Internal, non-deprecated view of the legacy read-success flag so
    /// internal code stays warning-free while the deprecated public
    /// `dicomFileReadSuccess` remains available for compatibility.
    var fileReadSucceeded: Bool {
        get { synchronized { _dicomFileReadSuccess } }
        set { synchronized { _dicomFileReadSuccess = newValue } }
    }
    private var _compressedImage: Bool = false
    public internal(set) var compressedImage: Bool {
        get { synchronized { _compressedImage } }
        set { synchronized { _compressedImage = newValue } }
    }
    private var _signedImage: Bool = false
    public internal(set) var signedImage: Bool {
        get { synchronized { _signedImage } }
        set { synchronized { _signedImage = newValue } }
    }
    /// Raw pixel representation flag (0 = unsigned, 1 = two's complement)
    public var pixelRepresentationTagValue: Int {
        synchronized { pixelRepresentation }
    }
    /// Convenience accessor for signed pixel representation
    public var isSignedPixelRepresentation: Bool {
        synchronized { pixelRepresentation == 1 }
    }

    // MARK: - Initialization

    /// Creates a new DICOM decoder instance.  The default initializer
    /// creates an empty decoder with no file loaded.  Use
    /// ``init(contentsOf:)`` or ``setDicomFilename(_:)`` to load a
    /// DICOM file.
    public init() {
        // All properties have default values, no explicit initialization needed
    }

    #if DEBUG
    /// Logs a performance-related debug message.
    /// - Parameters:
    ///   - message: The text to record at debug level.
    func debugPerfLog(_ message: String) {
        logger.debug(message)
    }
    #else
    /// Log a performance-related debug message.
/// - Parameter message: A human-readable message describing the performance event or measurement.
func debugPerfLog(_ message: String) {}
    #endif

    /// Executes a block of code with thread-safe synchronization.
    /// - Parameter block: The closure to execute while holding the lock
    /// Executes `block` while holding the decoder's synchronization lock, allowing nested calls on the same thread to re-enter without deadlocking.
    /// - Parameters:
    ///   - block: The closure to execute under synchronization.
    /// - Returns: The value returned by `block`.
    func synchronized<T>(_ block: () -> T) -> T {
        let key = synchronizationDepthKey
        let threadDict = Thread.current.threadDictionary
        let currentDepth = (threadDict[key] as? Int) ?? 0

        if currentDepth > 0 {
            threadDict[key] = currentDepth + 1
            defer {
                let depth = ((threadDict[key] as? Int) ?? 1) - 1
                if depth == 0 {
                    threadDict.removeObject(forKey: key)
                } else {
                    threadDict[key] = depth
                }
            }
            return block()
        }

        return lock.withLock {
            threadDict[key] = 1
            defer {
                threadDict.removeObject(forKey: key)
            }
            return block()
        }
    }

    /// Executes a throwing block of code with thread-safe synchronization.
    /// - Parameter block: The throwing closure to execute while holding the lock
    /// - Returns: The value returned by the closure
    /// Executes `block` while holding the instance lock, with safe reentrancy for the calling thread.
    ///
    /// Executes the provided closure under the decoder's lock. If the calling thread already holds the lock (detected via a per-thread recursion depth counter stored in `Thread.current.threadDictionary`), the closure is executed directly while the recursion depth is incremented to avoid deadlock; otherwise the lock is acquired for the duration of the closure. This preserves thread safety while allowing reentrant calls on the same thread.
    ///
    /// - Parameter block: The closure to run while synchronized.
    /// - Returns: The value returned by `block`.
    /// Execute `block` while holding the decoder's synchronization lock, allowing re-entrant calls on the same thread without deadlock.
    /// 
    /// If the current thread has already entered a synchronized region, this call increments a per-thread recursion depth counter and executes `block` without acquiring the lock again. Otherwise the function acquires the lock, records the recursion depth, executes `block`, and releases the lock when done.
    ///
    /// - Parameters:
    ///   - block: Closure to execute under synchronization.
    /// - Returns: The value produced by `block`.
    /// - Throws: Rethrows any error thrown by `block`.
    func synchronized<T>(_ block: () throws -> T) rethrows -> T {
        let key = synchronizationDepthKey
        let threadDict = Thread.current.threadDictionary
        let currentDepth = (threadDict[key] as? Int) ?? 0

        if currentDepth > 0 {
            threadDict[key] = currentDepth + 1
            defer {
                let depth = ((threadDict[key] as? Int) ?? 1) - 1
                if depth == 0 {
                    threadDict.removeObject(forKey: key)
                } else {
                    threadDict[key] = depth
                }
            }
            return try block()
        }

        return try lock.withLock {
            threadDict[key] = 1
            defer {
                threadDict.removeObject(forKey: key)
            }
            return try block()
        }
    }

}
