//
//  GeometryTagHandler.swift
//  DicomCore
//
//  Handler for DICOM geometry tags: Image Orientation (Patient) (0020,0037) and Image Position
//  (Patient) (0020,0032).  These tags define the spatial relationship between DICOM images and
//  patient anatomy, enabling 3D reconstruction and series ordering.
//
//  Supported Tags:
//
//  - Image Orientation (Patient) (0020,0037): Direction cosines for image rows and columns relative
//  to patient axes - Image Position (Patient) (0020,0032): Patient-space origin of the top-left
//  voxel (x, y, z coordinates)
//
//  Coordinate System:
//
//  DICOM uses the patient-based coordinate system (LPS+): - x increases from patient right to left
//  - y increases from patient anterior to posterior - z increases from patient inferior to superior
//
//  Image Orientation specifies 6 values: [Xx, Xy, Xz, Yx, Yy, Yz] where (Xx, Xy, Xz) is the
//  direction cosine of the image row axis and (Yx, Yy, Yz) is the direction cosine of the image
//  column axis.  These vectors are normalized to avoid drift from rounding errors.
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder instance processes one file
//  on a single thread.  No internal state is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when any of the geometry tags are
//  encountered during file parsing. Client code does not interact with this class directly.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import simd

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM geometry tags (Image Orientation, Image Position).
/// Extracts spatial position and orientation information from the DICOM
/// stream and updates the decoder context with SIMD3 vectors.
///
/// **Processing Steps:**
///
/// **Image Orientation (Patient):**
///
/// 1. Reads the string value containing 6 backslash-separated doubles
/// 2. Parses the 6 values into a Double array
/// 3. Splits into row direction cosines (first 3 values) and column
///    direction cosines (last 3 values)
/// 4. Constructs SIMD3<Double> vectors for both directions
/// 5. Normalizes both vectors using simd_normalize() to prevent drift
/// 6. Stores the normalized tuple in `context.imageOrientation`
/// 7. Adds the original string to the metadata dictionary
///
/// **Image Position (Patient):**
///
/// 1. Reads the string value containing 3 backslash-separated doubles
/// 2. Parses the 3 values into a Double array
/// 3. Constructs a SIMD3<Double> vector (x, y, z)
/// 4. Stores the vector in `context.imagePosition`
/// 5. Adds the original string to the metadata dictionary
///
/// **Example DICOM Data:**
///
///     (0020,0037) DS [1\0\0\0\1\0]         # Image Orientation (Patient)
///
/// This represents an axial slice with:
/// - Row direction: (1, 0, 0) → patient right to left
/// - Column direction: (0, 1, 0) → patient anterior to posterior
///
///     (0020,0032) DS [-125.0\-125.0\100.0]  # Image Position (Patient)
///
/// This represents the top-left voxel at position:
/// - x = -125.0 mm (right of center)
/// - y = -125.0 mm (anterior to center)
/// - z = 100.0 mm (superior to center)
///
/// **Normalization:**
///
/// Direction cosines should theoretically have length 1.0, but
/// floating-point rounding during DICOM file creation can introduce
/// small errors.  The handler normalizes both vectors using
/// `simd_normalize()` to ensure unit length, preventing drift in
/// downstream geometric calculations.
internal final class GeometryTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a geometry tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Image Orientation or Image Position)
    ///   - reader: Binary reader for extracting the tag value
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with geometry vectors
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
        case Tag.imageOrientationPatient.rawValue:
            // Image Orientation (Patient) - 6 values
            addInfo(tag, valueString)

            // Parse 6 double values for orientation
            if let values = parseDoubleValues(valueString, expectedCount: 6) {
                // First 3 values: row direction cosines
                let row = SIMD3<Double>(values[0], values[1], values[2])
                // Last 3 values: column direction cosines
                let column = SIMD3<Double>(values[3], values[4], values[5])

                // Normalize to avoid drift from rounding
                let normalizedRow = simd_normalize(row)
                let normalizedCol = simd_normalize(column)

                // Store normalized orientation tuple in context
                context.imageOrientation = (row: normalizedRow, column: normalizedCol)
            }

        case Tag.imagePositionPatient.rawValue:
            // Image Position (Patient) - 3 values
            addInfo(tag, valueString)

            // Parse 3 double values for position
            if let values = parseDoubleValues(valueString, expectedCount: 3) {
                // Store position as SIMD3<Double>
                context.imagePosition = SIMD3<Double>(values[0], values[1], values[2])
            }

        default:
            // Should not reach here if registry is configured correctly
            break
        }

        // Continue processing subsequent tags
        return true
    }

    // MARK: - Helper Methods

    /// Parses a string containing backslash- or whitespace-separated
    /// double values and returns them as an array.  Returns `nil` if
    /// the string contains fewer than the expected count of valid doubles.
    ///
    /// This method is duplicated from DCMDecoder to maintain handler
    /// independence.  Each handler is self-contained and does not rely
    /// on decoder internals.
    ///
    /// - Parameters:
    ///   - string: The string to parse (e.g., "1.0\0.0\0.0")
    ///   - expectedCount: Minimum number of values required
    ///
    /// - Returns: Array of `expectedCount` Double values, or `nil` if
    ///            parsing fails or insufficient values are present.
    ///
    /// **Example:**
    ///
    ///     parseDoubleValues("1.0\\0.0\\0.0\\0.0\\1.0\\0.0", expectedCount: 6)
    ///     // Returns: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    ///
    ///     parseDoubleValues("-125.0\\-125.0\\100.0", expectedCount: 3)
    ///     // Returns: [-125.0, -125.0, 100.0]
    ///
    ///     parseDoubleValues("1.0\\0.0", expectedCount: 3)
    ///     // Returns: nil (insufficient values)
    private func parseDoubleValues(_ string: String, expectedCount: Int) -> [Double]? {
        // Split by backslash or whitespace
        let parts = string.split(whereSeparator: { $0 == "\\" || $0.isWhitespace })

        // Verify we have enough values
        guard parts.count >= expectedCount else { return nil }

        // Convert string parts to Double values
        var values: [Double] = []
        values.reserveCapacity(expectedCount)

        for idx in 0..<expectedCount {
            guard let value = Double(parts[idx]) else { return nil }
            values.append(value)
        }

        return values
    }
}
