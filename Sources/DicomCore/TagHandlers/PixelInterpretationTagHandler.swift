//
//  PixelInterpretationTagHandler.swift
//  DicomCore
//
//  Handler for DICOM pixel interpretation tags: Samples per Pixel (0028,0002), Photometric
//  Interpretation (0028,0004), Pixel Representation (0028,0103), and Planar Configuration
//  (0028,0006). These tags specify how pixel data should be interpreted, including color space,
//  data type (signed/unsigned), and channel organization for RGB images.
//
//  Supported Tags:
//
//  - Samples per Pixel (0028,0002): Number of color channels (1 for grayscale, 3 for RGB) -
//  Photometric Interpretation (0028,0004): Color space (MONOCHROME1, MONOCHROME2, RGB, etc.) -
//  Pixel Representation (0028,0103): Data type (0 = unsigned, 1 = two's complement) - Planar
//  Configuration (0028,0006): RGB data organization (0 = interleaved, 1 = planar)
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the pixel interpretation
//  tags are encountered during file parsing. Client code does not interact with this class
//  directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM pixel interpretation tags (Samples per Pixel,
/// Photometric Interpretation, Pixel Representation, Planar Configuration).
/// Extracts pixel interpretation metadata from the DICOM stream and
/// updates the decoder context.
///
/// **Processing Steps:**
///
/// 1. Determines which interpretation tag is being processed
/// 2. Reads the appropriate value (short or string) from the DICOM stream
/// 3. Updates the corresponding context property:
///    - Samples per Pixel → `context.samplesPerPixel`
///    - Photometric Interpretation → `context.photometricInterpretation`
///    - Pixel Representation → `context.pixelRepresentation`
///    - Planar Configuration → `context.planarConfiguration`
/// 4. Adds the value to the metadata dictionary for client access
///
/// **Value Meanings:**
///
/// - Samples per Pixel: 1 (grayscale), 3 (RGB), 4 (RGBA)
/// - Photometric Interpretation: "MONOCHROME1" (inverted), "MONOCHROME2" (normal), "RGB", etc.
/// - Pixel Representation: 0 (unsigned integers), 1 (two's complement signed integers)
/// - Planar Configuration: 0 (RGBRGBRGB...), 1 (RRR...GGG...BBB...)
///
/// **Example DICOM Data:**
///
///     (0028,0002) US 3                     # Samples per Pixel
///     (0028,0004) CS [RGB]                 # Photometric Interpretation
///     (0028,0103) US 0                     # Pixel Representation (unsigned)
///     (0028,0006) US 0                     # Planar Configuration (interleaved)
///
/// After processing, `context.samplesPerPixel` will be 3,
/// `context.photometricInterpretation` will be "RGB",
/// `context.pixelRepresentation` will be 0, and
/// `context.planarConfiguration` will be 0.
internal final class PixelInterpretationTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a pixel interpretation tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Samples per Pixel, Photometric Interpretation, etc.)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with interpretation values
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
        // Process based on specific tag type
        switch tag {
        case Tag.samplesPerPixel.rawValue:
            // Read 16-bit value for number of color channels
            let spp = Int(reader.readShort(location: &location))
            context.samplesPerPixel = spp
            addInfoInt(tag, spp)

        case Tag.photometricInterpretation.rawValue:
            // Read string value for color space identifier
            let elementLength = parser.currentElementLength
            let s = reader.readString(length: elementLength, location: &location)
            context.photometricInterpretation = s
            addInfo(tag, s)

        case Tag.pixelRepresentation.rawValue:
            // Read 16-bit value for signed/unsigned data type
            let pixelRep = Int(reader.readShort(location: &location))
            context.pixelRepresentation = pixelRep
            addInfoInt(tag, pixelRep)

        case Tag.planarConfiguration.rawValue:
            // Read 16-bit value for RGB channel organization
            let planarConfig = Int(reader.readShort(location: &location))
            context.planarConfiguration = planarConfig
            addInfoInt(tag, planarConfig)

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }
}
