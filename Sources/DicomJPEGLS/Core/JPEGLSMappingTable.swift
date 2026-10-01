/// JPEG-LS mapping table (palette) support per ITU-T.87 §5.1.1.3.
///
/// Mapping tables allow pixel sample values to be used as indices into a
/// lookup table, enabling efficient encoding of palettised or indexed-colour
/// images.  Each component in a scan may optionally reference a mapping table;
/// when it does, every decoded raw sample value is replaced by the
/// corresponding table entry before the pixel is returned to the caller.
///
/// ## Standard References
///
/// - ITU-T.87 §5.1.1.3 — LSE marker, mapping-table specification (type 2)
/// - ITU-T.87 §5.1.1.3 — LSE marker, mapping-table continuation (type 3)
/// - ISO/IEC 14495-1:1999 Annex E — mapping-table data formats

import Foundation

/// A single mapping table used for palettised JPEG-LS images.
///
/// A mapping table maps a decoded raw sample value (the *index*) to the
/// actual sample value stored in the output.  The table is referenced by
/// ID; scan-header component selectors carry the table ID for each component.
///
/// ### Entry width
///
/// Each table entry occupies either 1 byte (`entryWidth == 1`) or 2 bytes
/// (`entryWidth == 2`).  2-byte entries are stored big-endian in the
/// bitstream but are presented here as plain `Int` values.
///
/// ### Usage
/// ```swift
/// // Look up the output value for a raw decoded pixel
/// let outputValue = mappingTable.map(rawPixelValue)
/// ```
public struct JPEGLSMappingTable: Sendable {

    // MARK: - Properties

    /// Table identifier (1–255).  Matches the `TID` field in the LSE marker.
    public let id: UInt8

    /// Number of bytes per table entry (1 or 2) as encoded in the `Wt` field.
    public let entryWidth: Int

    /// Table entries in index order.  `entries[i]` gives the output sample
    /// value for a raw pixel whose value equals `i`.
    public let entries: [Int]

    // MARK: - Initialisation

    /// Initialise a mapping table with the given identifier, entry width, and entries.
    ///
    /// ```swift
    /// // 4-entry 1-byte palette: maps indices 0–3 to luminance values 0, 85, 170, 255
    /// let palette = try JPEGLSMappingTable(id: 1, entryWidth: 1, entries: [0, 85, 170, 255])
    ///
    /// // 4-entry 2-byte palette for 12-bit output values
    /// let palette12 = try JPEGLSMappingTable(id: 2, entryWidth: 2, entries: [0, 1365, 2730, 4095])
    /// ```
    ///
    /// - Parameters:
    ///   - id: Table identifier (1–255).
    ///   - entryWidth: Number of bytes per entry (1 or 2).
    ///   - entries: Table entries in ascending index order.
    /// - Throws: `JPEGLSError.invalidBitstreamStructure` if the parameters are invalid.
    public init(id: UInt8, entryWidth: Int, entries: [Int]) throws {
        guard id >= 1 else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Mapping table ID must be in range [1, 255], got \(id)"
            )
        }
        guard entryWidth == 1 || entryWidth == 2 else {
            throw JPEGLSError.invalidBitstreamStructure(
                reason: "Mapping table entry width must be 1 or 2 bytes, got \(entryWidth)"
            )
        }
        let maxEntryValue = (1 << (entryWidth * 8)) - 1
        for (index, entry) in entries.enumerated() {
            guard entry >= 0 && entry <= maxEntryValue else {
                throw JPEGLSError.invalidBitstreamStructure(
                    reason: "Mapping table entry \(index) value \(entry) out of range [0, \(maxEntryValue)] for entry width \(entryWidth)"
                )
            }
        }
        self.id = id
        self.entryWidth = entryWidth
        self.entries = entries
    }

    // MARK: - Lookup

    /// Map a raw decoded pixel value to the corresponding table entry.
    ///
    /// If `pixelValue` is out of range for this table, the raw value is returned
    /// unchanged to provide graceful degradation for malformed data.
    ///
    /// ```swift
    /// let palette = try JPEGLSMappingTable(id: 1, entryWidth: 1, entries: [0, 85, 170, 255])
    /// let output = palette.map(2)   // returns 170
    /// let safe   = palette.map(99)  // out of range — returns 99 unchanged
    /// ```
    ///
    /// - Parameter pixelValue: Raw decoded sample value used as a table index.
    /// - Returns: The mapped output sample value, or `pixelValue` if out of range.
    public func map(_ pixelValue: Int) -> Int {
        guard pixelValue >= 0 && pixelValue < entries.count else {
            return pixelValue
        }
        return entries[pixelValue]
    }

    /// Number of entries in the table.
    public var count: Int {
        return entries.count
    }

    /// Maximum output sample value across all entries.
    public var maxOutputValue: Int {
        return entries.max() ?? 0
    }
}

extension JPEGLSMappingTable: CustomStringConvertible {
    /// Human-readable description of the mapping table.
    public var description: String {
        return "JPEGLSMappingTable(id=\(id), entryWidth=\(entryWidth), entries=\(entries.count))"
    }
}

extension JPEGLSMappingTable: Equatable {}
