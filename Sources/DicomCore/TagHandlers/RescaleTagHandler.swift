//
//  RescaleTagHandler.swift
//  DicomCore
//
//  Handler for DICOM rescale tags: Rescale Intercept (0028,1052) and Rescale Slope (0028,1053).
//  These tags define the linear transformation for converting pixel values to modality units (e.g.,
//  Hounsfield Units for CT).  The formula is: modality_value = pixel_value * rescaleSlope +
//  rescaleIntercept
//
//  Supported Tags:
//
//  - Rescale Intercept (0028,1052): The b in y = mx + b - Rescale Slope (0028,1053): The m in y =
//  mx + b
//
//  Hounsfield Units:
//
//  In CT imaging, pixel values are typically stored as unsigned integers but represent Hounsfield
//  Units (HU), which are signed. The rescale parameters map stored pixel values to HU:
//
//  HU = pixel_value * rescaleSlope + rescaleIntercept
//
//  Typical values: - rescaleIntercept: -1024 (shifts stored values to HU range) - rescaleSlope: 1.0
//  (1:1 mapping)
//
//  For example, if a pixel has value 2048: HU = 2048 * 1.0 + (-1024) = 1024 HU (approximately bone
//  density)
//
//  Default Values:
//
//  If these tags are absent, the identity transformation is assumed: - rescaleIntercept: 0.0 (no
//  offset) - rescaleSlope: 1.0 (no scaling)
//
//  This means pixel values are already in modality units.
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the rescale tags are
//  encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM rescale tags (Rescale Intercept, Rescale Slope).
/// Extracts modality value transformation parameters from the DICOM
/// stream and updates the decoder context.
///
/// **Processing Steps:**
///
/// 1. Determines which rescale tag is being processed
/// 2. Reads the string value from the DICOM stream
/// 3. Converts the string to a Double:
///    - Rescale Intercept defaults to 0.0 if conversion fails
///    - Rescale Slope defaults to 1.0 if conversion fails
/// 4. Updates the corresponding context property:
///    - Rescale Intercept → `context.rescaleIntercept`
///    - Rescale Slope → `context.rescaleSlope`
/// 5. Adds the string value to the metadata dictionary for client access
///
/// **Example DICOM Data:**
///
///     (0028,1052) DS [-1024]           # Rescale Intercept
///     (0028,1053) DS [1]               # Rescale Slope
///
/// After processing, `context.rescaleIntercept` will be -1024.0 and
/// `context.rescaleSlope` will be 1.0.
///
/// To convert a pixel value to Hounsfield Units:
///
///     let hu = Double(pixelValue) * rescaleSlope + rescaleIntercept
///     // Example: 2048 * 1.0 + (-1024) = 1024 HU
///
/// **Error Handling:**
///
/// If string-to-double conversion fails (malformed value), the handler
/// uses safe defaults:
/// - Rescale Intercept: 0.0 (no offset)
/// - Rescale Slope: 1.0 (identity transformation)
///
/// This ensures pixel values can still be used as-is even if rescale
/// tags are corrupted.
internal final class RescaleTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a rescale tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Rescale Intercept or Rescale Slope)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with rescale parameters
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
        case Tag.rescaleIntercept.rawValue:
            // Convert string to Double, defaulting to 0.0 on failure
            let interceptValue = Double(valueString) ?? 0.0
            context.rescaleIntercept = interceptValue
            addInfo(tag, valueString)

        case Tag.rescaleSlope.rawValue:
            // Convert string to Double, defaulting to 1.0 on failure
            let slopeValue = Double(valueString) ?? 1.0
            context.rescaleSlope = slopeValue
            addInfo(tag, valueString)

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }
}
