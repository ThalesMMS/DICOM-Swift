//
//  WindowingTagHandler.swift
//  DicomCore
//
//  Handler for DICOM windowing tags: Window Center (0028,1050) and Window Width (0028,1051).  These
//  tags specify the default window/level settings for displaying grayscale medical images. Window
//  center defines the midpoint of the intensity range, while window width controls the contrast by
//  defining the range of pixel values mapped to the full display range.
//
//  Supported Tags:
//
//  - Window Center (0028,1050): Midpoint of the window (level) - Window Width (0028,1051): Width of
//  the window (contrast)
//
//  Multiple Values:
//
//  DICOM allows multiple window settings separated by backslashes (e.g., "40\80" for two window
//  centers).  This handler takes the second value if multiple values are present, or the only value
//  if a single value is provided.  This matches the legacy behavior from the original switch
//  statement.
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the windowing tags are
//  encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM windowing tags (Window Center, Window Width).
/// Extracts default window/level settings from the DICOM stream
/// and updates the decoder context.
///
/// **Processing Steps:**
///
/// 1. Determines which windowing tag is being processed
/// 2. Reads the string value from the DICOM stream
/// 3. Handles multiple values separated by backslashes:
///    - If backslash exists: takes the value after the first backslash
///    - If no backslash: uses the entire value
/// 4. Converts the string to a Double (defaults to 0.0 if invalid)
/// 5. Updates the corresponding context property with the legacy selected value:
///    - Window Center → `context.windowCenter`
///    - Window Width → `context.windowWidth`
/// 6. Adds the complete raw string value to the metadata dictionary for client access
///
/// **Multiple Window Settings:**
///
/// Some DICOM files specify multiple window presets separated by
/// backslashes, for example:
///
///     (0028,1050) DS [40\80\350]       # Window Centers
///     (0028,1051) DS [400\200\2000]    # Window Widths
///
/// This represents three presets:
/// - Preset 1: center=40, width=400
/// - Preset 2: center=80, width=200
/// - Preset 3: center=350, width=2000
///
/// The legacy behavior (preserved here) is to use the second value
/// if multiple values exist, otherwise the first value.  This provides
/// a reasonable default when multiple presets are present.
///
/// **Example DICOM Data:**
///
///     (0028,1050) DS [40]              # Window Center (single value)
///     (0028,1051) DS [400]             # Window Width (single value)
///
/// After processing, `context.windowCenter` will be 40.0 and
/// `context.windowWidth` will be 400.0.
///
///     (0028,1050) DS [40\80]           # Window Center (multiple values)
///     (0028,1051) DS [400\200]         # Window Width (multiple values)
///
/// After processing, `context.windowCenter` will be 80.0 and
/// `context.windowWidth` will be 200.0 (second values selected).
internal final class WindowingTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a windowing tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Window Center or Window Width)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with windowing values
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

        // Read raw string value from DICOM stream. Keep the complete multi-value
        // string in metadata so higher-level VOI selection can pair alternatives.
        let rawValueString = reader.readString(length: elementLength, location: &location)
        var selectedValueString = rawValueString

        // Handle multiple values separated by backslash
        // If backslash present, take the value after the first backslash
        if let index = selectedValueString.firstIndex(of: "\\") {
            selectedValueString = String(selectedValueString[selectedValueString.index(after: index)...])
        }

        // Convert string to Double, defaulting to 0.0 on failure
        let doubleValue = Double(selectedValueString) ?? 0.0

        // Process based on specific tag type
        switch tag {
        case Tag.windowCenter.rawValue:
            // Update context with window center value
            context.windowCenter = doubleValue
            addInfo(tag, rawValueString)

        case Tag.windowWidth.rawValue:
            // Update context with window width value
            context.windowWidth = doubleValue
            addInfo(tag, rawValueString)

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }
}
