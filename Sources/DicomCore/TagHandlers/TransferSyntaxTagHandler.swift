//
//  TransferSyntaxTagHandler.swift
//  DicomCore
//
//  Handler for Transfer Syntax UID tag (0002,0010).  This tag specifies the encoding rules for the
//  DICOM file, including byte ordering (little vs big endian), VR encoding (explicit vs implicit),
//  and pixel data compression format (uncompressed, JPEG, JPEG 2000, etc.).  The handler sets
//  decoder flags to control subsequent parsing and pixel data decompression.
//
//  Supported Transfer Syntaxes:
//
//  - Uncompressed: Implicit/Explicit VR Little Endian, Explicit VR Big Endian - JPEG: Baseline
//  (Process 1), Extended (Process 2 & 4), Lossless (Process 14) - JPEG-LS: Lossless and
//  Near-Lossless - JPEG 2000: Lossless and Lossy - RLE: Lossless compression
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when the Transfer Syntax UID tag is
//  encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Handler for DICOM Transfer Syntax UID tag (0002,0010).
/// Extracts the transfer syntax identifier and sets compression
/// and byte-order flags in the decoder context.
///
/// **Processing Steps:**
///
/// 1. Reads the transfer syntax UID string from the DICOM stream
/// 2. Stores the UID in decoder context for reference
/// 3. Attempts to match the UID to a known DicomTransferSyntax enum value
/// 4. Sets `compressedImage` flag if the syntax requires decompression
/// 5. Sets `bigEndianTransferSyntax` flag if big-endian byte order is used
/// 6. Adds the UID to the metadata dictionary for client access
///
/// **Default Behavior:**
///
/// If the transfer syntax UID is not recognized, the handler assumes:
/// - Uncompressed pixel data (`compressedImage = false`)
/// - Little-endian byte ordering (`bigEndianTransferSyntax = false`)
///
/// This ensures parsing continues even for proprietary or future
/// transfer syntaxes. Note that higher-level consumers (such as volume
/// assembly) may still choose to treat unknown or compressed transfer
/// syntaxes as unsupported to avoid silently producing incorrect results.
///
/// **Example DICOM Data:**
///
///     (0002,0010) UI [1.2.840.10008.1.2.1]  # Explicit VR Little Endian
///
/// After processing, `context.transferSyntaxUID` will contain
/// "1.2.840.10008.1.2.1", `compressedImage` will be false, and
/// `bigEndianTransferSyntax` will be false.
internal final class TransferSyntaxTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes the Transfer Syntax UID tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (should be 0x00020010)
    ///   - reader: Binary reader for extracting the UID string
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with transfer syntax flags
    ///   - addInfo: Callback to add the UID to the metadata dictionary
    ///   - addInfoInt: Unused by this handler
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
        // Read the transfer syntax UID string
        let elementLength = parser.currentElementLength
        let uid = reader.readString(length: elementLength, location: &location)

        // Store in context for reference
        context.transferSyntaxUID = uid

        // Add to metadata dictionary
        addInfo(tag, uid)

        // Detect compressed syntaxes and byte ordering using DicomTransferSyntax enum
        if let syntax = DicomTransferSyntax(uid: uid) {
            context.compressedImage = syntax.isCompressed && !syntax.usesDataSetDeflate
            context.bigEndianTransferSyntax = syntax.isBigEndian
        } else {
            // Unknown transfer syntax - assume uncompressed and little endian
            // This allows parsing to continue for proprietary or future syntaxes
            context.compressedImage = false
            context.bigEndianTransferSyntax = false
        }

        // Continue processing subsequent tags
        return true
    }
}
