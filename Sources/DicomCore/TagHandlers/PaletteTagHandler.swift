//
//  PaletteTagHandler.swift
//
//  Handler for DICOM palette color lookup table descriptor and data tags.
//  These tags define color lookup tables (LUTs) for converting grayscale
//  pixel values to RGB color values in PALETTE COLOR images.
//
//  Supported Tags:
//
//  - Red/Green/Blue Palette Color Lookup Table Descriptor (0028,1101-1103)
//  - Red/Green/Blue Palette Color Lookup Table Data (0028,1201-1203)
//
//  PALETTE COLOR Images:
//
//  Some DICOM images (particularly ultrasound and nuclear medicine)
//  use palette color mode where pixel values are indices into color
//  lookup tables rather than direct RGB values.  The palette tags
//  store the red, green, and blue intensity mappings.
//
//  LUT data is stored as 8-bit or 16-bit entries according to the descriptor.
//  Display output uses 8-bit values, preserving 8-bit LUT entries directly and
//  using the high byte of 16-bit entries.
//
//  Color Mapping:
//
//  For a pixel with grayscale value `i`:
//    red[i]   = reds[i]    // Red intensity (0-255)
//    green[i] = greens[i]  // Green intensity (0-255)
//    blue[i]  = blues[i]   // Blue intensity (0-255)
//
//  Typical LUT sizes are 256 entries (8-bit indices) or 4096 entries
//  (12-bit indices).
//
//  Thread Safety:
//
//  This handler is thread-safe when used as intended: each DCMDecoder
//  instance processes one file on a single thread.  No internal state
//  is maintained between handle() calls.
//
//  Usage:
//
//  The handler is invoked automatically by TagHandlerRegistry when
//  any of the palette tags are encountered during file parsing.
//  Client code does not interact with this class directly.
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
private typealias Tag = DicomTag

/// Handler for DICOM palette color lookup table tags (Red, Green, Blue Palette).
/// Extracts color lookup tables from the DICOM stream and updates the decoder
/// context for PALETTE COLOR image rendering.
///
/// **Processing Steps:**
///
/// 1. Determines which palette tag is being processed
/// 2. Gets the element length from the tag parser
/// 3. Reads the LUT descriptor or data payload
/// 4. If successful, updates the corresponding context property:
///    - Red Palette → `context.reds`
///    - Green Palette → `context.greens`
///    - Blue Palette → `context.blues`
/// 5. Adds the LUT size (entry count) to the metadata dictionary
///
/// **Example DICOM Data:**
///
///     (0028,1201) OW [16-bit red values]     # Red Palette
///     (0028,1202) OW [16-bit green values]   # Green Palette
///     (0028,1203) OW [16-bit blue values]    # Blue Palette
///
/// After processing, `context.reds`, `context.greens`, and `context.blues`
/// will each contain 256 or 4096 UInt8 values representing color intensities.
///
/// **Error Handling:**
///
/// If `readLUT()` returns nil (malformed data or odd length), the handler
/// silently skips that palette.  The image can still be displayed as
/// grayscale if all three palettes fail to load.
internal final class PaletteTagHandler: TagHandler {

    // MARK: - TagHandler Protocol

    /// Processes a palette color lookup table tag and updates decoder context.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag ID (Red, Green, or Blue Palette)
    ///   - reader: Binary reader for extracting the LUT data
    ///   - location: Current read position (advanced by read operations)
    ///   - parser: Tag parser providing element length information
    ///   - context: Decoder context to update with palette data
    ///   - addInfo: Unused by this handler (uses addInfoInt instead)
    ///   - addInfoInt: Callback to add LUT size to the metadata dictionary
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
        let elementLength = parser.currentElementLength

        switch tag {
        case Tag.redPaletteDescriptor.rawValue,
             Tag.greenPaletteDescriptor.rawValue,
             Tag.bluePaletteDescriptor.rawValue:
            let signed = parser.currentVR == .SS || (parser.currentVR == .implicitRaw && context.pixelRepresentation == 1)
            let descriptor = readDescriptor(reader: reader, length: elementLength, signed: signed, location: &location)
            switch tag {
            case Tag.redPaletteDescriptor.rawValue:
                context.redPaletteDescriptor = descriptor
            case Tag.greenPaletteDescriptor.rawValue:
                context.greenPaletteDescriptor = descriptor
            case Tag.bluePaletteDescriptor.rawValue:
                context.bluePaletteDescriptor = descriptor
            default:
                break
            }
            addInfo(tag, descriptor.map {
                "\($0.storedEntryCount)\\\($0.firstMappedValue)\\\($0.bitsPerEntry)"
            } ?? "")

        case Tag.redPalette.rawValue,
             Tag.greenPalette.rawValue,
             Tag.bluePalette.rawValue:
            let descriptor = descriptor(for: tag, context: context)
            if let table = readPaletteData(
                reader: reader,
                length: elementLength,
                descriptor: descriptor,
                location: &location
            ) {
                switch tag {
                case Tag.redPalette.rawValue:
                    context.reds = table
                    addInfoInt(tag, table.count)
                case Tag.greenPalette.rawValue:
                    context.greens = table
                    addInfoInt(tag, table.count)
                case Tag.bluePalette.rawValue:
                    context.blues = table
                    addInfoInt(tag, table.count)
                default:
                    break
                }
            }

        case Tag.segmentedRedPalette.rawValue,
             Tag.segmentedGreenPalette.rawValue,
             Tag.segmentedBluePalette.rawValue:
            let plainTag = tag - 0x20
            let descriptor = descriptor(for: plainTag, context: context)
            let start = location
            defer { location = start + elementLength }
            guard let descriptor, elementLength.isMultiple(of: 2) else { return true }
            // Each supported segment emits entries using at most four words per output entry.
            guard elementLength / 2 <= descriptor.entryCount * 4 else { return true }
            let words = (0..<(elementLength / 2)).map { _ in reader.readShort(location: &location) }
            guard let expanded = try? DicomSegmentedPaletteExpander.expand(
                words: words, entryCount: descriptor.entryCount
            ) else { return true }
            let table = expanded.map { descriptor.bitsPerEntry <= 8 ? UInt8(truncatingIfNeeded: $0) : UInt8($0 >> 8) }
            switch tag {
            case Tag.segmentedRedPalette.rawValue: context.reds = table
            case Tag.segmentedGreenPalette.rawValue: context.greens = table
            case Tag.segmentedBluePalette.rawValue: context.blues = table
            default: break
            }
            addInfoInt(tag, table.count)

        default:
            location += elementLength
        }

        return true
    }

    private func readDescriptor(
        reader: DCMBinaryReader,
        length: Int,
        signed: Bool,
        location: inout Int
    ) -> DicomLUTDescriptor? {
        guard length >= 6 else {
            location += length
            return nil
        }

        let start = location
        let storedEntryCount = Int(reader.readShort(location: &location))
        let firstMappedWord = reader.readShort(location: &location)
        let firstMappedValue = signed ? Int(Int16(bitPattern: firstMappedWord)) : Int(firstMappedWord)
        let bitsPerEntry = Int(reader.readShort(location: &location))
        if length > location - start {
            location += length - (location - start)
        }

        return DicomLUTDescriptor(
            storedEntryCount: storedEntryCount,
            firstMappedValue: firstMappedValue,
            bitsPerEntry: bitsPerEntry
        )
    }

    private func descriptor(for tag: Int, context: DecoderContext) -> DicomLUTDescriptor? {
        switch tag {
        case Tag.redPalette.rawValue:
            return context.redPaletteDescriptor
        case Tag.greenPalette.rawValue:
            return context.greenPaletteDescriptor
        case Tag.bluePalette.rawValue:
            return context.bluePaletteDescriptor
        default:
            return nil
        }
    }

    private func readPaletteData(
        reader: DCMBinaryReader,
        length: Int,
        descriptor: DicomLUTDescriptor?,
        location: inout Int
    ) -> [UInt8]? {
        guard let descriptor else {
            return reader.readLUT(length: length, location: &location)
        }

        if descriptor.bitsPerEntry <= 8 {
            var table: [UInt8] = []
            table.reserveCapacity(min(length, descriptor.entryCount))
            for _ in 0..<length {
                table.append(reader.readByte(location: &location))
            }
            return Array(table.prefix(descriptor.entryCount))
        }

        return reader.readLUT(length: length, location: &location).map {
            Array($0.prefix(descriptor.entryCount))
        }
    }
}
