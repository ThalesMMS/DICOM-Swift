//
//  PixelDataTagHandler.swift
//
//  Handler for Pixel Data tag (7FE0,0010).  This tag marks the
//  beginning of the actual image pixel data in the DICOM file.
//  When encountered, the handler records the file offset and
//  terminates tag parsing.  Pixel data is not loaded immediately;
//  it remains lazily parsed until getPixels16() or getPixels8()
//  is called by the client.
//
//  Processing Strategy:
//
//  Unlike other tags which extract and parse values, the pixel
//  data handler only records the file offset where pixel data
//  begins.  This serves two purposes:
//
//  1. Memory Efficiency: Medical images can be hundreds of
//     megabytes.  Loading pixel data during header parsing would
//     waste memory for applications that only need metadata.
//
//  2. Parse Performance: Once pixel data is located, there are no
//     more tags to parse in standard DICOM files.  Stopping early
//     avoids unnecessary processing.
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each
//  DCMDecoder instance processes one file on a single thread.  No
//  internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when
//  the Pixel Data tag is encountered during file parsing.  Client
//  code does not interact with this class directly.  After this
//  handler executes, DCMDecoder's pixel loading methods
//  (getPixels16, getPixels8) will use the stored offset to read
//  pixel data on demand.
//

import Foundation

/// Handler for DICOM Pixel Data tag (7FE0,0010).
/// Records the byte offset to pixel data and terminates tag parsing.
///
/// **Processing Steps:**
///
/// 1. Records current file location as the pixel data offset
/// 2. Adds the offset to the metadata dictionary for client access
/// 3. Sets the `shouldStopDecoding` flag to terminate parsing
/// 4. Returns `false` to signal the tag processing loop to exit
///
/// **Termination Logic:**
///
/// The pixel data tag is typically the last tag in a DICOM file
/// (standard DICOM structure places it after all metadata).
/// Continuing to parse after this point would only consume CPU
/// cycles and memory with no benefit, so the handler explicitly
/// stops the decoding loop.
///
/// **Lazy Loading:**
///
/// Pixel data is NOT read or decompressed by this handler.  Only
/// the file offset is recorded.  Actual pixel loading occurs later
/// when the client calls getPixels16() or getPixels8().  This
/// design enables fast metadata-only parsing for applications that
/// don't need pixel data (e.g., DICOM directory browsers, PACS
/// query tools).
///
/// **Example DICOM Data:**
///
///     (7FE0,0010) OB (pixel data)  # 524288 bytes
///
/// After processing, `context.offset` will point to the first byte
/// of pixel data, and `context.shouldStopDecoding` will be true.
/// The tag parsing loop will terminate immediately after this
/// handler returns.
internal final class PixelDataTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes the Pixel Data tag by recording its offset and
    /// terminating tag parsing.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (should be 0x7FE00010)
    ///   - reader: Binary reader (unused - pixel data not loaded yet)
    ///   - location: Current read position (the start of pixel data)
    ///   - parser: Tag parser (unused - no value extraction needed)
    ///   - context: Decoder context to update with pixel data offset
    ///   - addInfo: Callback (unused - offset added via addInfoInt)
    ///   - addInfoInt: Callback to add the offset to metadata dictionary
    ///
    /// - Returns: Always returns `false` to terminate the tag decoding loop.
    ///            This is the only handler that returns false; all others
    ///            return true to continue processing.
    func handle(
        tag: Int,
        reader: DCMBinaryReader,
        location: inout Int,
        parser: DCMTagParser,
        context: DecoderContext,
        addInfo: (Int, String?) -> Void,
        addInfoInt: (Int, Int) -> Void
    ) -> Bool {
        // Record the file offset where pixel data begins
        // This enables lazy loading when getPixels16() or getPixels8() is called
        context.offset = location
        context.pixelDataVR = parser.currentVR

        // Add offset to metadata dictionary for client access via info(for:)
        addInfoInt(tag, location)

        // Set flag to terminate the tag decoding loop
        // Standard DICOM files have no more tags after pixel data
        context.shouldStopDecoding = true

        // Return false to signal that tag processing should stop
        // This is the only handler that returns false
        return false
    }
}
