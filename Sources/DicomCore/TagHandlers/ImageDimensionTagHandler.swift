//
//  ImageDimensionTagHandler.swift
//  DicomCore
//
//  Handler for DICOM image dimension tags: Rows (0028,0010), Columns (0028,0011), and Bits
//  Allocated (0028,0100).  These tags specify the pixel dimensions and bit depth of the DICOM
//  image, which are critical for allocating pixel buffers and interpreting pixel data correctly.
//
//  Supported Tags:
//
//  - Rows (0028,0010): Image height in pixels - Columns (0028,0011): Image width in pixels - Bits
//  Allocated (0028,0100): Bits per pixel (8 or 16)
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the image dimension tags
//  are encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM image dimension tags (Rows, Columns, Bits Allocated).
/// Extracts pixel dimensions and bit depth from the DICOM stream and
/// updates the decoder context.
///
/// **Processing Steps:**
///
/// 1. Determines which dimension tag is being processed
/// 2. Reads a 16-bit short value from the DICOM stream
/// 3. Updates the appropriate context property:
///    - Rows → `context.height`
///    - Columns → `context.width`
///    - Bits Allocated → `context.bitDepth`
/// 4. Adds the value to the metadata dictionary for client access
///
/// **Value Ranges:**
///
/// - Rows/Columns: Typically 128-4096 pixels, maximum 65536
/// - Bits Allocated: Usually 8 or 16 bits per pixel
///
/// **Example DICOM Data:**
///
///     (0028,0010) US 512      # Rows (height)
///     (0028,0011) US 512      # Columns (width)
///     (0028,0100) US 16       # Bits Allocated
///
/// After processing, `context.width` will be 512, `context.height`
/// will be 512, and `context.bitDepth` will be 16.
internal final class ImageDimensionTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes an image dimension tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Rows, Columns, or Bits Allocated)
    ///   - reader: Binary reader for extracting the dimension value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with dimension values
    ///   - addInfo: Unused by this handler (uses addInfoInt instead)
    ///   - addInfoInt: Callback to add the dimension to the metadata dictionary
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
        // Read the 16-bit dimension value
        let value = Int(reader.readShort(location: &location))

        // Update the appropriate context property based on tag type
        switch tag {
        case Tag.rows.rawValue:
            context.height = value
        case Tag.columns.rawValue:
            context.width = value
        case Tag.bitsAllocated.rawValue:
            context.bitDepth = value
        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Add to metadata dictionary
        addInfoInt(tag, value)

        // Continue processing subsequent tags
        return true
    }
}
