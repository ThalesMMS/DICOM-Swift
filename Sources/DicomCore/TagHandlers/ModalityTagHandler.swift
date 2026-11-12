//
//  ModalityTagHandler.swift
//  DicomCore
//
//  Handler for DICOM modality and multi-frame tags: Modality (0008,0060) and Number of Frames
//  (0028,0008).  These tags provide metadata about the imaging modality (CT, MR, XR, etc.) and the
//  number of frames in multi-frame images.
//
//  Supported Tags:
//
//  - Modality (0008,0060): Imaging modality identifier (e.g., "CT", "MR", "XR") - Number of Frames
//  (0028,0008): Frame count for multi-frame images (default: 1)
//
//  Modality Values:
//
//  Common modality codes defined in DICOM Part 3, Annex C.7.3.1.1.1: - CT: Computed Tomography -
//  MR: Magnetic Resonance - XR: X-Ray Radiography - US: Ultrasound - CR: Computed Radiography - DX:
//  Digital Radiography - MG: Mammography - PT: Positron Emission Tomography - NM: Nuclear Medicine
//
//  Multi-Frame Images:
//
//  Some DICOM files contain multiple frames (slices) in a single file rather than storing each
//  slice as a separate file.  The Number of Frames tag specifies how many frames are present.  If
//  absent or 1, the image is single-frame.
//
//  Default Values:
//
//  If these tags are absent: - modality: nil (remains unset) - nImages: 1 (single-frame assumption)
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when modality or frame count tags are
//  encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM modality and multi-frame tags.
/// Extracts modality identifier and frame count from the DICOM
/// stream and updates the decoder context.
///
/// **Processing Steps:**
///
/// For Modality (0008,0060):
/// 1. Reads the modality string from the DICOM stream
/// 2. Stores the value in `context.modality` for reference
/// 3. Adds the modality to the metadata dictionary for client access
///
/// For Number of Frames (0028,0008):
/// 1. Reads the frame count as a string from the DICOM stream
/// 2. Converts the string to a Double, then to Int if > 1
/// 3. Updates `context.nImages` with the frame count (remains 1 if ≤ 1)
/// 4. Adds the string value to the metadata dictionary for client access
///
/// **Example DICOM Data:**
///
///     (0008,0060) CS [CT]              # Modality
///     (0028,0008) IS [24]              # Number of Frames
///
/// After processing, `context.modality` will be "CT" and
/// `context.nImages` will be 24.
///
/// **Error Handling:**
///
/// If Number of Frames string-to-double conversion fails or the value
/// is ≤ 1, `context.nImages` retains its default value of 1 (single-frame).
internal final class ModalityTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a modality or multi-frame tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Modality or Number of Frames)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with modality and frame count
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

        // Process based on specific tag type
        switch tag {
        case Tag.modality.rawValue:
            // Read modality string (e.g., "CT", "MR", "XR")
            let modalityString = reader.readString(length: elementLength, location: &location)
            context.modality = modalityString
            addInfo(tag, modalityString)

        case Tag.numberOfFrames.rawValue:
            // Read frame count as string and convert to integer
            let framesString = reader.readString(length: elementLength, location: &location)
            addInfo(tag, framesString)

            // Parse frame count and update context if > 1
            if let frames = Double(framesString), frames > 1.0 {
                context.nImages = Int(frames)
            }

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }
}
