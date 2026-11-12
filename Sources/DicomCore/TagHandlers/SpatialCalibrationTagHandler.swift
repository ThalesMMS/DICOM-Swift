//
//  SpatialCalibrationTagHandler.swift
//  DicomCore
//
//  Handler for DICOM spatial calibration tags: Pixel Spacing (0028,0030), Slice Thickness
//  (0018,0050), and Spacing Between Slices (0018,0088).  These tags define the physical dimensions
//  of voxels, enabling accurate measurement and 3D reconstruction.
//
//  Supported Tags:
//
//  - Pixel Spacing (0028,0030): Physical spacing between pixel centers in millimeters (row
//  spacing\column spacing) - Slice Thickness (0018,0050): Nominal reconstructed slice thickness in
//  millimeters - Spacing Between Slices (0018,0088): Spacing between centers of adjacent slices in
//  millimeters
//
//  Physical Dimensions:
//
//  DICOM spatial calibration tags define the voxel dimensions: - pixelHeight: physical height of
//  each pixel (row spacing) - pixelWidth: physical width of each pixel (column spacing) -
//  pixelDepth: physical depth of each slice (slice thickness or spacing between slices)
//
//  Pixel Spacing format is "row\column" (backslash-separated), where row spacing corresponds to
//  pixel height and column spacing corresponds to pixel width.  This follows the DICOM standard
//  convention where rows run vertically (y-axis) and columns run horizontally (x-axis).
//
//  Slice Thickness vs Spacing Between Slices:
//
//  Slice Thickness defines the nominal slice thickness during acquisition, while Spacing Between
//  Slices defines the actual distance between slice centers.  For contiguous slices these are
//  equal, but for gapped acquisitions spacing is larger than thickness.  This handler uses
//  whichever tag is present, preferring Spacing Between Slices if both are available.
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the spatial calibration
//  tags are encountered during file parsing.  Client code does not interact with this class
//  directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM spatial calibration tags (Pixel Spacing,
/// Slice Thickness, Spacing Between Slices).  Extracts physical
/// voxel dimensions from the DICOM stream and updates the decoder
/// context with calibration values.
///
/// **Processing Steps:**
///
/// **Pixel Spacing (0028,0030):**
///
/// 1. Reads the string value containing 2 backslash-separated values
///    (format: "row\column")
/// 2. Splits the string by backslash separator
/// 3. Parses first value (row spacing) as pixelHeight
/// 4. Parses second value (column spacing) as pixelWidth
/// 5. Updates `context.pixelHeight` and `context.pixelWidth`
/// 6. Adds the original string to the metadata dictionary
///
/// **Slice Thickness (0018,0050) / Spacing Between Slices (0018,0088):**
///
/// 1. Reads the string value containing a single numeric value
/// 2. Parses the value as a Double
/// 3. Updates `context.pixelDepth` (defaults to existing value if
///    parsing fails)
/// 4. Adds the original string to the metadata dictionary
///
/// **Example DICOM Data:**
///
///     (0028,0030) DS [0.5\0.5]         # Pixel Spacing
///
/// This represents pixels with:
/// - Row spacing: 0.5 mm (pixelHeight)
/// - Column spacing: 0.5 mm (pixelWidth)
///
///     (0018,0050) DS [5.0]             # Slice Thickness
///
/// This represents slices with:
/// - Thickness: 5.0 mm (pixelDepth)
///
///     (0018,0088) DS [5.0]             # Spacing Between Slices
///
/// This represents slices with:
/// - Spacing: 5.0 mm (pixelDepth)
///
/// **Error Handling:**
///
/// If Pixel Spacing parsing fails (wrong format, non-numeric values),
/// the handler silently preserves the existing pixelWidth and
/// pixelHeight values (both default to 1.0).  This ensures graceful
/// degradation for malformed files.
internal final class SpatialCalibrationTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a spatial calibration tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Pixel Spacing, Slice Thickness, or
    ///          Spacing Between Slices)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with spatial calibration
    ///   - addInfo: Callback to add string metadata to the dictionary
    ///   - addInfoInt: Callback to add integer metadata to the dictionary
    ///
    /// - Returns: Always returns `true` to continue processing subsequent tags.
    func handle(
        tag: Int,
        reader: DCMBinaryReader,
        location: inout Int,
        parser: DCMTagParser,
        context: DecoderContext,
        addInfo: (Int, String?) -> Void,
        addInfoInt: (Int, Int) -> Void
    ) -> Bool {
        // Get element length from parser
        let elementLength = parser.currentElementLength

        // Read raw string value from DICOM stream
        let valueString = reader.readString(length: elementLength, location: &location)

        // Process based on specific tag type
        switch tag {
        case Tag.pixelSpacing.rawValue:
            // Pixel Spacing (0028,0030) - format: "row\column"
            applySpatialScale(valueString, context: context)
            addInfo(tag, valueString)

        case Tag.sliceThickness.rawValue, Tag.sliceSpacing.rawValue:
            // Slice Thickness (0018,0050) or Spacing Between Slices (0018,0088)
            if let depth = Double(valueString) {
                context.pixelDepth = depth
            }
            // Note: If parsing fails, preserve existing pixelDepth value
            addInfo(tag, valueString)

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }

    // MARK: - Helper Methods

    /// Parses the Pixel Spacing string into separate x and y scales
    /// and stores them in the decoder context.  The expected format
    /// is "row\column" (note the use of backslash).  If the parsing
    /// fails, the existing pixel dimensions are left unchanged.
    ///
    /// This method replicates the logic from DCMDecoder.applySpatialScale()
    /// to maintain handler independence.  Each handler is self-contained
    /// and does not rely on decoder internals.
    ///
    /// - Parameters:
    ///   - scale: The Pixel Spacing string (e.g., "0.5\0.5")
    ///   - context: Decoder context to update with parsed values
    ///
    /// **DICOM Standard Convention:**
    ///
    /// Pixel Spacing uses the format "row\column" where:
    /// - Row spacing (first value) → physical distance between row
    ///   centers → pixelHeight (y-axis)
    /// - Column spacing (second value) → physical distance between
    ///   column centers → pixelWidth (x-axis)
    ///
    /// **Example:**
    ///
    ///     applySpatialScale("0.5\\0.5", context: context)
    ///     // Sets: context.pixelHeight = 0.5, context.pixelWidth = 0.5
    ///
    ///     applySpatialScale("0.3\\0.4", context: context)
    ///     // Sets: context.pixelHeight = 0.3, context.pixelWidth = 0.4
    ///
    ///     applySpatialScale("invalid", context: context)
    ///     // No change - preserves existing pixelHeight and pixelWidth
    private func applySpatialScale(_ scale: String, context: DecoderContext) {
        // Split by backslash separator
        let components = scale.split(separator: "\\")

        // Expect exactly 2 components (row\column)
        guard components.count == 2,
              let y = Double(components[0]),  // row spacing → height
              let x = Double(components[1])   // column spacing → width
        else {
            // Parsing failed - preserve existing values
            return
        }

        // Update context with parsed values
        context.pixelHeight = y
        context.pixelWidth = x
    }
}
