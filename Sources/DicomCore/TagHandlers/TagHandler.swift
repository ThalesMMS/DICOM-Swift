//
//  TagHandler.swift
//
//  Protocol abstraction for DICOM tag handlers using the Strategy
//  pattern.  Each handler implements processing logic for one or
//  more DICOM tags, extracting values from the binary stream and
//  updating decoder state accordingly.  This replaces the monolithic
//  switch statement in readFileInfo() with composable, testable
//  handler objects.
//
//  Architecture:
//
//  The TagHandler protocol defines a single handle() method that
//  processes a DICOM tag.  Concrete implementations (e.g.,
//  TransferSyntaxTagHandler, ImageDimensionTagHandler) encapsulate
//  the logic for specific tag groups.  The TagHandlerRegistry maps
//  tag IDs to handler instances, enabling lookup-based dispatch
//  instead of switch-based branching.
//
//  Adding New Handlers:
//
//  To add support for a new DICOM tag:
//  1. Create a new handler class conforming to TagHandler
//  2. Implement handle() to read the tag value and update context
//  3. Register the handler in TagHandlerRegistry for the tag ID(s)
//
//  Thread Safety:
//
//  Handlers must be thread-safe if DCMDecoder instances are shared
//  across threads.  However, the current design assumes each decoder
//  instance processes one file on a single thread, so handlers do
//  not require internal locking.
//

import Foundation
import simd

// MARK: - Decoder Context

/// Encapsulates mutable decoder state that tag handlers can modify.
/// This class is passed to each handler during tag processing,
/// allowing handlers to update image dimensions, windowing parameters,
/// geometry, and other metadata without directly coupling to
/// DCMDecoder's internal structure.
///
/// **Design Rationale:**
///
/// Tag handlers are separate objects that cannot directly access
/// DCMDecoder's private properties.  DecoderContext acts as a
/// data transfer object, providing controlled access to the subset
/// of decoder state that handlers need to modify.  Using a class
/// (reference type) instead of a struct avoids expensive copying
/// and allows in-place mutation.
///
/// **Lifecycle:**
///
/// A single DecoderContext instance is created per file parse
/// operation and passed to all handlers sequentially.  After tag
/// processing completes, DCMDecoder reads the final state from
/// the context.
internal final class DecoderContext {

    // MARK: - Image Dimensions

    /// Image width in pixels.  Updated by ImageDimensionTagHandler.
    var width: Int = 1

    /// Image height in pixels.  Updated by ImageDimensionTagHandler.
    var height: Int = 1

    /// Bit depth (8 or 16).  Updated by ImageDimensionTagHandler.
    var bitDepth: Int = 16

    // MARK: - Transfer Syntax

    /// Transfer syntax UID string.  Updated by TransferSyntaxTagHandler.
    var transferSyntaxUID: String = ""

    /// Flag indicating compressed transfer syntax.  Updated by TransferSyntaxTagHandler.
    var compressedImage: Bool = false

    /// Flag indicating big endian byte order.  Updated by TransferSyntaxTagHandler.
    var bigEndianTransferSyntax: Bool = false

    /// Character set used for textual metadata. Updated by SpecificCharacterSetTagHandler.
    var specificCharacterSet: DicomSpecificCharacterSet = .defaultCharacterSet

    // MARK: - Pixel Interpretation

    /// Samples per pixel (1 for grayscale, 3 for RGB).  Updated by PixelInterpretationTagHandler.
    var samplesPerPixel: Int = 1

    /// Photometric interpretation (MONOCHROME1, MONOCHROME2, RGB).  Updated by PixelInterpretationTagHandler.
    var photometricInterpretation: String = ""

    /// Pixel representation (0 = unsigned, 1 = two's complement).  Updated by PixelInterpretationTagHandler.
    var pixelRepresentation: Int = 0

    /// Planar configuration for RGB images.  Updated by PixelInterpretationTagHandler.
    var planarConfiguration: Int = 0

    // MARK: - Display Windowing

    /// Default window center for display.  Updated by WindowingTagHandler.
    var windowCenter: Double = 0.0

    /// Default window width for display.  Updated by WindowingTagHandler.
    var windowWidth: Double = 0.0

    // MARK: - Spatial Calibration

    /// Physical width of each pixel in millimeters.  Updated by SpatialCalibrationTagHandler.
    var pixelWidth: Double = 1.0

    /// Physical height of each pixel in millimeters.  Updated by SpatialCalibrationTagHandler.
    var pixelHeight: Double = 1.0

    /// Physical depth of each pixel (slice thickness) in millimeters.  Updated by SpatialCalibrationTagHandler.
    var pixelDepth: Double = 1.0

    // MARK: - Geometry

    /// Direction cosines for image rows and columns (0020,0037).  Updated by GeometryTagHandler.
    var imageOrientation: (row: SIMD3<Double>, column: SIMD3<Double>)?

    /// Patient-space origin for the top-left voxel (0020,0032).  Updated by GeometryTagHandler.
    var imagePosition: SIMD3<Double>?

    // MARK: - Rescale Parameters

    /// Rescale intercept for modality value mapping.  Updated by RescaleTagHandler.
    var rescaleIntercept: Double = 0.0

    /// Rescale slope for modality value mapping.  Updated by RescaleTagHandler.
    var rescaleSlope: Double = 1.0

    // MARK: - Palette Color

    /// Red palette lookup table.  Updated by PaletteTagHandler.
    var reds: [UInt8]? = nil

    /// Red palette lookup table descriptor. Updated by PaletteTagHandler.
    var redPaletteDescriptor: DicomLUTDescriptor? = nil

    /// Green palette lookup table.  Updated by PaletteTagHandler.
    var greens: [UInt8]? = nil

    /// Green palette lookup table descriptor. Updated by PaletteTagHandler.
    var greenPaletteDescriptor: DicomLUTDescriptor? = nil

    /// Blue palette lookup table.  Updated by PaletteTagHandler.
    var blues: [UInt8]? = nil

    /// Blue palette lookup table descriptor. Updated by PaletteTagHandler.
    var bluePaletteDescriptor: DicomLUTDescriptor? = nil

    // MARK: - Pixel Data Location

    /// Byte offset to pixel data.  Updated by PixelDataTagHandler.
    var offset: Int = 0

    /// Value Representation of the Pixel Data element as encoded in the file (OB or OW; `implicitRaw`
    /// under an implicit VR syntax).  Updated by PixelDataTagHandler.  Under Explicit VR Big Endian an
    /// OW element holds 16-bit words even when Bits Allocated is 8 (PS3.5 §7.6.1.1.1), so the bytes of
    /// every word pair are swapped on disk; readers need the VR to undo that.
    var pixelDataVR: DicomVR? = nil

    /// Number of frames in multi-frame images.  Updated by ModalityTagHandler.
    var nImages: Int = 1

    /// Modality string (CT, MR, XR, etc.).  Temporary storage during parsing.
    var modality: String? = nil

    // MARK: - Control Flags

    /// Flag to terminate tag decoding loop.  Set to true by PixelDataTagHandler
    /// to stop processing after finding the pixel data tag.
    var shouldStopDecoding: Bool = false

    // MARK: - Initialization

    /// Creates a new decoder context with default values.
    /// Called once per file parse operation in readFileInfoUnsafe().
    init() {
        // All properties have default values
    }
}

// MARK: - Tag Handler Protocol

/// Protocol defining the interface for DICOM tag handlers using the Strategy pattern.
/// Each handler processes one or more related DICOM tags, extracting values from
/// the binary stream and updating the decoder context accordingly.  Handlers are
/// registered in TagHandlerRegistry and invoked via lookup-based dispatch during
/// DICOM file parsing.
///
/// **Purpose:**
///
/// The TagHandler protocol enables modular, testable tag processing by replacing
/// the monolithic switch statement in DCMDecoder.readFileInfo() with composable
/// handler objects.  Each handler encapsulates the logic for a specific tag group
/// (e.g., image dimensions, windowing parameters, geometry), making the code easier
/// to understand, test, and extend.
///
/// **Implementation Contract:**
///
/// Implementations must adhere to the following requirements to ensure correct
/// DICOM stream parsing and decoder state consistency:
///
/// 1. **Stream Synchronization:** Handlers must read exactly `parser.currentElementLength`
///    bytes from the stream to keep the `location` cursor in sync.  Failure to consume
///    the correct number of bytes will cause subsequent tags to be misaligned, corrupting
///    the parse operation.
///
/// 2. **Metadata Population:** Handlers should call the `addInfo` or `addInfoInt` callbacks
///    to populate the metadata dictionary, making tag values accessible via `DCMDecoder.info(for:)`.
///    This enables client code to query arbitrary DICOM tags without coupling to handler internals.
///
/// 3. **Control Flow:** Handlers that detect the pixel data tag (0x7FE00010) should set
///    `context.shouldStopDecoding = true` and return `false` to terminate the parsing loop.
///    All other handlers should return `true` to continue processing subsequent tags.
///
/// 4. **Error Handling:** Handlers must not throw exceptions.  Malformed or unexpected
///    tag values should be handled gracefully by logging warnings, using fallback values,
///    and continuing parsing.  This ensures robust behavior with non-conformant DICOM files.
///
/// 5. **State Updates:** Handlers update decoder state via the `context` parameter, not
///    by directly accessing DCMDecoder properties.  This decouples handlers from the decoder's
///    internal structure and enables testing without a full DCMDecoder instance.
///
/// **Thread Safety:**
///
/// Handlers do not require internal locking under the current design, which assumes
/// each DCMDecoder instance processes one file on a single thread.  If DCMDecoder
/// instances are shared across threads in future revisions, handler implementations
/// must ensure thread-safe access to shared state.
///
/// **Usage Example:**
///
/// This example shows a handler that processes the Window Center tag (0x00281050):
///
/// ```swift
/// final class WindowCenterHandler: TagHandler {
///     func handle(
///         tag: Int,
///         reader: DCMBinaryReader,
///         location: inout Int,
///         parser: DCMTagParser,
///         context: DecoderContext,
///         addInfo: (Int, String?) -> Void,
///         addInfoInt: (Int, Int) -> Void
///     ) -> Bool {
///         // Read the tag value as a string
///         let elementLength = parser.currentElementLength
///         var centerStr = reader.readString(length: elementLength, location: &location)
///
///         // Handle DICOM multiplicity (backslash-separated values)
///         if let backslashIndex = centerStr.firstIndex(of: "\\") {
///             // Take the first value if multiple are present
///             centerStr = String(centerStr[..<backslashIndex])
///         }
///
///         // Parse and update context
///         let centerValue = Double(centerStr.trimmingCharacters(in: .whitespaces)) ?? 0.0
///         context.windowCenter = centerValue
///
///         // Add to metadata dictionary for client access
///         addInfo(tag, centerStr)
///
///         // Continue processing subsequent tags
///         return true
///     }
/// }
/// ```
///
/// **Adding New Handlers:**
///
/// To add support for a new DICOM tag or tag group:
///
/// 1. Create a new class conforming to `TagHandler`
/// 2. Implement the `handle()` method following the contract above
/// 3. Register the handler in `TagHandlerRegistry.init()` for each relevant tag ID
/// 4. Add unit tests verifying correct parsing and context updates
///
internal protocol TagHandler: AnyObject {

    /// Processes a DICOM tag, extracting its value from the binary stream and
    /// updating decoder state via the provided context.  Handlers are invoked
    /// during DICOM file parsing for each registered tag ID.
    ///
    /// **Implementation Requirements:**
    ///
    /// - Must read exactly `parser.currentElementLength` bytes to maintain stream alignment
    /// - Should call `addInfo` or `addInfoInt` to populate the metadata dictionary
    /// - Must handle malformed values gracefully without throwing exceptions
    /// - Should return `false` only when stopping the decoding loop (e.g., after pixel data)
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID in integer form (e.g., `0x00280010` for Rows tag).
    ///          Handlers registered for this tag are responsible for extracting and
    ///          interpreting its value according to the DICOM standard.
    ///   - reader: Binary reader providing methods to extract typed values from the
    ///             DICOM stream.  Supports reading integers, floats, strings, and byte
    ///             arrays with automatic endianness handling based on transfer syntax.
    ///   - location: Current byte offset in the DICOM file.  This parameter is `inout`
    ///               and must be advanced by read operations to keep the stream cursor
    ///               synchronized.  Read operations automatically update this value.
    ///   - parser: Tag parser containing metadata about the current tag, including
    ///             Value Representation (VR) and element length.  Use `parser.currentElementLength`
    ///             to determine how many bytes to read from the stream.
    ///   - context: Mutable decoder context for updating image dimensions, windowing
    ///              parameters, geometry, and other state.  Changes to this object are
    ///              reflected in the final DCMDecoder state after parsing completes.
    ///   - addInfo: Callback to add string-based metadata to the info dictionary.
    ///              Pass the tag ID and string value.  The value will be accessible
    ///              via `DCMDecoder.info(for:)` after parsing.  Use `nil` for tags
    ///              that should be registered but have no displayable value.
    ///   - addInfoInt: Callback to add integer-based metadata to the info dictionary.
    ///                 Pass the tag ID and integer value.  The value will be accessible
    ///                 via `DCMDecoder.intValue(for:)` after parsing.
    ///
    /// - Returns: `true` to continue processing subsequent tags in the DICOM stream,
    ///            `false` to terminate the tag decoding loop immediately.  Most handlers
    ///            return `true`.  Only `PixelDataTagHandler` returns `false` after
    ///            locating the pixel data tag, as no further tags need to be processed.
    ///
    /// - Note: This method must not throw exceptions.  Parse errors should be handled
    ///         internally by using fallback values and logging warnings.  This ensures
    ///         robust behavior when processing non-conformant DICOM files.
    ///
    func handle(
        tag: Int,
        reader: DCMBinaryReader,
        location: inout Int,
        parser: DCMTagParser,
        context: DecoderContext,
        addInfo: (Int, String?) -> Void,
        addInfoInt: (Int, Int) -> Void
    ) -> Bool
}
