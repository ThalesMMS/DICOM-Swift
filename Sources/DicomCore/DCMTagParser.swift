//
//  DCMTagParser.swift
//
//  DICOM tag parsing and metadata extraction.
//  This module handles parsing DICOM tags, determining value
//  representations (VR), extracting element lengths, and building
//  human-readable metadata entries for the DICOM info dictionary.
//
//  Usage:
//
//    let dict = DCMDictionary()
//    let parser = DCMTagParser(
//        data: dicomData,
//        dict: dict,
//        binaryReader: reader
//    )
//    var location = 132
//    let tag = parser.getNextTag(&location, littleEndian: true)
//    let info = parser.headerInfo(for: tag, value: nil, &location)
//

import Foundation

/// Backward compatibility alias to centralized DICOM tag constants.
fileprivate typealias Tag = DicomTag

/// Parser for DICOM tags and metadata.
/// Handles tag reading, VR determination, element length extraction,
/// and metadata dictionary construction.  Designed to work in conjunction
/// with DCMBinaryReader for low-level binary I/O operations.
///
/// This class maintains state about the current tag being parsed (VR,
/// element length, sequence nesting) and provides methods to read tags
/// sequentially from a DICOM file stream.
internal final class DCMTagParser {

    // MARK: - Properties

    /// Dictionary used to translate tags to human readable names.
    private let dict: DCMDictionary

    /// Binary reader for low-level I/O operations
    private let binaryReader: DCMBinaryReader

    /// The current Value Representation.  Represented as the raw
    /// 16‑bit ASCII code stored in the DICOM header.  A value of
    /// ``VR.implicitRaw`` indicates implicit VR.
    private(set) var vr: DicomVR = .unknown

    /// The length of the current element value.  Computed by
    /// ``getLength()`` during tag parsing.
    private(set) var elementLength: Int = 0

    /// True when the current element used the DICOM undefined-length marker.
    private(set) var elementLengthIsUndefined: Bool = false

    /// Flag indicating whether we are currently inside a sequence
    private var inSequence: Bool = false

    private static func isSequenceControlTag(_ tag: Int) -> Bool {
        tag == 0xFFFEE000 || tag == 0xFFFEE00D || tag == 0xFFFEE0DD
    }

    // MARK: - Initialization

    /// Creates a tag parser for DICOM data.
    /// - Parameters:
    ///   - data: The DICOM file data
    ///   - dict: The DICOM dictionary for tag name lookups
    ///   - binaryReader: Binary reader for I/O operations
    internal init(data: Data, dict: DCMDictionary, binaryReader: DCMBinaryReader) {
        self.dict = dict
        self.binaryReader = binaryReader
    }

    // MARK: - Tag Parsing Methods

    /// Determines the length of the next element.  Updates the
    /// current ``vr`` based on the data read.  This logic mirrors
    /// ``getLength()`` from the original code.  The return value is
    /// the element length in bytes.  The active transfer syntax
    /// determines whether the four bytes after the tag are an
    /// implicit-VR length or an explicit-VR header.
    ///
    /// - Parameters:
    ///   - location: Current read position (updated after reading)
    ///   - littleEndian: Byte order flag
    /// - Returns: Element length in bytes
    internal func getLength(location: inout Int, littleEndian: Bool, explicitVR: Bool) -> Int {
        // Read four bytes for VR and initial length field
        let b0 = binaryReader.readByte(location: &location)
        let b1 = binaryReader.readByte(location: &location)
        let b2 = binaryReader.readByte(location: &location)
        let b3 = binaryReader.readByte(location: &location)

        // Combine the first two bytes into a VR code; this will be
        // overwritten later if we detect an implicit VR
        let rawVR = Int(UInt16(b0) << 8 | UInt16(b1))
        vr = DicomVR(rawValue: rawVR) ?? .unknown

        if !explicitVR {
            vr = .implicitRaw
            let retValue: Int
            if littleEndian {
                retValue = Int(b3) << 24 | Int(b2) << 16 | Int(b1) << 8 | Int(b0)
            } else {
                retValue = Int(b0) << 24 | Int(b1) << 16 | Int(b2) << 8 | Int(b3)
            }
            elementLengthIsUndefined = retValue == -1 || retValue == 0xFFFFFFFF
            elementLength = retValue
            return retValue
        }

        var retValue: Int = 0

        switch vr {
        case .OB, .OD, .OF, .OW, .OV, .SQ, .UN, .UR, .UT:
            // Explicit VRs with 32‑bit lengths have two reserved
            // bytes (b2 and b3).  If those bytes are zero we
            // interpret the following 4 bytes as the length.
            if b2 == 0 || b3 == 0 {
                let l0 = binaryReader.readByte(location: &location)
                let l1 = binaryReader.readByte(location: &location)
                let l2 = binaryReader.readByte(location: &location)
                let l3 = binaryReader.readByte(location: &location)
                if littleEndian {
                    retValue = Int(l3) << 24 | Int(l2) << 16 | Int(l1) << 8 | Int(l0)
                } else {
                    retValue = Int(l0) << 24 | Int(l1) << 16 | Int(l2) << 8 | Int(l3)
                }
            } else {
                // This is actually an implicit VR; the four bytes
                // read constitute the length.
                vr = .implicitRaw
                if littleEndian {
                    retValue = Int(b3) << 24 | Int(b2) << 16 | Int(b1) << 8 | Int(b0)
                } else {
                    retValue = Int(b0) << 24 | Int(b1) << 16 | Int(b2) << 8 | Int(b3)
                }
            }

        case .AE, .AS, .AT, .CS, .DA, .DS, .DT, .FD, .FL, .IS, .LO,
             .LT, .PN, .SH, .SL, .SS, .ST, .TM, .UI, .UL, .US, .QQ, .RT:
            // Explicit VRs with 16‑bit lengths
            if littleEndian {
                retValue = Int(b3) << 8 | Int(b2)
            } else {
                retValue = Int(b2) << 8 | Int(b3)
            }

        default:
            if Self.isPlausibleExplicitVRCode(b0, b1) {
                // Unrecognized but plausible explicit VR code (retired or
                // vendor-specific, e.g. "XZ"): treat as a short-form
                // explicit element and skip its value by the declared
                // 16-bit length instead of derailing the scan (#1235).
                vr = .unknown
                if littleEndian {
                    retValue = Int(b3) << 8 | Int(b2)
                } else {
                    retValue = Int(b2) << 8 | Int(b3)
                }
            } else {
                // Implicit VR with 32‑bit length
                vr = .implicitRaw
                if littleEndian {
                    retValue = Int(b3) << 24 | Int(b2) << 16 | Int(b1) << 8 | Int(b0)
                } else {
                    retValue = Int(b0) << 24 | Int(b1) << 16 | Int(b2) << 8 | Int(b3)
                }
            }
        }

        elementLengthIsUndefined = retValue == -1 || retValue == 0xFFFFFFFF
        elementLength = retValue
        return retValue
    }

    /// Two uppercase ASCII letters where a VR code belongs mark an
    /// unrecognized explicit VR; implicit-VR length bytes rarely form
    /// that pattern.
    private static func isPlausibleExplicitVRCode(_ first: UInt8, _ second: UInt8) -> Bool {
        (0x41...0x5A).contains(first) && (0x41...0x5A).contains(second)
    }

    /// Reads the next tag from the stream.  Returns the tag value
    /// (group << 16 | element).  Updates ``elementLength`` and
    /// ``vr`` internally.  Implicit sequences update the
    /// ``inSequence`` flag.
    ///
    /// - Parameters:
    ///   - location: Current read position (updated after reading)
    ///   - data: DICOM file data
    ///   - littleEndian: Byte order flag (may be modified for big endian detection)
    ///   - bigEndianTransferSyntax: Flag indicating big endian transfer syntax
    ///   - explicitVR: Whether the active transfer syntax encodes explicit VR fields
    /// - Returns: Tag value as 32-bit integer (group << 16 | element)
    internal func getNextTag(
        location: inout Int,
        data: Data,
        littleEndian: inout Bool,
        bigEndianTransferSyntax: Bool,
        explicitVR: Bool
    ) -> Int {
        // Check if we have enough data to read a tag
        guard location + 4 <= data.count else {
            return 0  // Return 0 to signal end of data
        }

        let group = Int(binaryReader.readShort(location: &location))

        // Endianness detection: if the group appears as 0x0800 in a
        // big endian transfer syntax we flip endianness.  This
        // mirrors the hack in the original implementation.
        var actualGroup = group
        let element: Int
        if group == 0x0800 && bigEndianTransferSyntax {
            littleEndian = false
            actualGroup = 0x0008
            guard location + 2 <= data.count else {
                return 0
            }
            element = Int(UInt16(data[location]) << 8 | UInt16(data[location + 1]))
            location += 2
        } else {
            element = Int(binaryReader.readShort(location: &location))
        }

        let tag = actualGroup << 16 | element

        let elementUsesExplicitVR = actualGroup == 0x0002 || explicitVR
        elementLength = getLength(location: &location, littleEndian: littleEndian, explicitVR: elementUsesExplicitVR)

        // Handle undefined lengths indicating the start of a sequence
        if elementLength == -1 || elementLength == 0xFFFFFFFF {
            elementLength = 0
            inSequence = true
        }

        // Sanity check: element length should not exceed remaining data
        let remainingBytes = data.count - location
        if elementLength > remainingBytes {
            elementLength = min(elementLength, remainingBytes)
        }

        return tag
    }

    /// Constructs a human readable header string for the given tag
    /// and optional value.  This replicates the behaviour of
    /// ``getHeaderInfo(withValue:)`` in the original code.  If
    /// ``inSequence`` is true the description is prefixed with
    /// ``">"``.  Private tags (those with odd group numbers)
    /// receive the description ``"Private Tag"``.  Unknown tags
    /// produce nil.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag
    ///   - value: Optional pre-parsed value string
    ///   - location: Current read position (updated if value is read)
    /// - Returns: Formatted header info string or nil
    internal func headerInfo(
        for tag: Int,
        value inValue: String?,
        location: inout Int
    ) -> String? {
        if tag == 0xFFFEE000 {
            return dict.value(forTag: tag) ?? ":null"
        }

        if tag == 0xFFFEE00D {
            return nil
        }

        if tag == 0xFFFEE0DD {
            inSequence = false
            return nil
        }

        var description: String? = dict.value(forTag: tag)

        // Determine VR if implicit
        if let desc = description, vr == .implicitRaw {
            let rawVRCode = desc.prefix(2)
            if let ascii = rawVRCode.data(using: .utf8), ascii.count == 2 {
                let code = Int(UInt16(ascii[0]) << 8 | UInt16(ascii[1]))
                vr = DicomVR(rawValue: code) ?? .unknown
            }
            description = String(desc.dropFirst(2))
        }

        if let provided = inValue {
            let prefix = description ?? "---"
            return "\(prefix): \(provided)"
        }

        // Determine how to read the value based on VR
        var value: String? = nil
        var privateTag = false

        switch vr {
        case .FD, .OD:
            // Skip elementLength bytes (8 bytes per double)
            location += elementLength

        case .FL, .OF:
            // Skip elementLength bytes (4 bytes per float)
            location += elementLength

        case .AE, .AS, .AT, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UI:
            value = binaryReader.readString(length: elementLength, location: &location)

        case .US:
            if elementLength == 2 {
                let s = binaryReader.readShort(location: &location)
                value = String(s)
            } else {
                // Multiple unsigned shorts separated by spaces
                var vals = [String]()
                let count = elementLength / 2
                for _ in 0..<count {
                    vals.append(String(binaryReader.readShort(location: &location)))
                }
                value = vals.joined(separator: " ")
            }

        case .implicitRaw:
            // Interpret as a string unless extremely long
            let s = binaryReader.readString(length: elementLength, location: &location)
            if elementLength <= 44 {
                value = s
            } else {
                value = nil
            }

        case .SQ:
            // Sequences are read elsewhere; here we just skip
            value = ""
            privateTag = ((tag >> 16) & 1) != 0
            if tag != Tag.iconImageSequence.rawValue && !privateTag {
                break
            }
            location += elementLength

        default:
            // Unknown VR: skip the bytes
            location += elementLength
            value = ""
        }

        // Build the return string
        if value?.isEmpty == false {
            // If we have no description look up the tag again
            let desc = description ?? "---"
            return "\(desc): \(value ?? "")"
        } else if description == nil {
            return nil
        } else {
            let desc = description ?? "---"
            return "\(desc): \(value ?? "")"
        }
    }

    /// Extracts raw tag metadata without formatting to a string.
    /// Returns TagMetadata containing the tag's location, VR, and element length.
    /// This is used for lazy parsing where the tag value is not immediately needed.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag
    ///   - location: Current read position (pointing to tag value start)
    /// - Returns: TagMetadata if the tag should be stored, nil if it should be skipped
    internal func getTagMetadata(tag: Int, location: Int) -> TagMetadata? {
        // Handle sequence delimiters - these are not stored
        if Self.isSequenceControlTag(tag) {
            return nil
        }

        // Return metadata capturing current parser state
        return TagMetadata(
            tag: tag,
            offset: location,
            vr: vr,
            elementLength: elementLength
        )
    }

    /// Adds the provided value to the DICOM info dictionary keyed by the raw
    /// tag.  If ``inSequence`` is true the stored string is
    /// prefixed with ``">"`` to indicate nesting.  Private tag
    /// markers ``"---"`` are replaced with the literal string
    /// ``"Private Tag"`` for clarity.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag
    ///   - stringValue: Optional value string
    ///   - location: Current read position (updated if value is read)
    ///   - infoDict: Dictionary to store the parsed info
    internal func addInfo(
        tag: Int,
        stringValue: String?,
        location: inout Int,
        infoDict: inout [Int: String]
    ) {
        guard let info = headerInfo(for: tag, value: stringValue, location: &location) else {
            return
        }

        var stored = info
        if inSequence {
            stored = ">" + stored
        }

        // Replace unknown description marker with "Private Tag"
        if let range = stored.range(of: "---") {
            stored.replaceSubrange(range, with: "Private Tag")
        }

        infoDict[tag] = stored
    }

    /// Convenience overload for adding integer values as strings.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag
    ///   - intValue: Integer value to store
    ///   - location: Current read position (updated if value is read)
    ///   - infoDict: Dictionary to store the parsed info
    internal func addInfo(
        tag: Int,
        intValue: Int,
        location: inout Int,
        infoDict: inout [Int: String]
    ) {
        addInfo(tag: tag, stringValue: String(intValue), location: &location, infoDict: &infoDict)
    }

    // MARK: - State Management

    /// Resets the parser state for a new file
    internal func reset() {
        vr = .unknown
        elementLength = 0
        elementLengthIsUndefined = false
        inSequence = false
    }

    /// Clears sequence-tracking state after callers skip a complete sequence value.
    internal func finishSequenceValue() {
        inSequence = false
        elementLengthIsUndefined = false
    }

    /// Returns true if currently inside a DICOM sequence
    internal var isInSequence: Bool {
        return inSequence
    }

    /// Returns the current element length
    internal var currentElementLength: Int {
        return elementLength
    }

    /// Returns true when the current element length was undefined.
    internal var currentElementLengthIsUndefined: Bool {
        return elementLengthIsUndefined
    }

    /// Returns the current Value Representation
    internal var currentVR: DicomVR {
        return vr
    }
}
