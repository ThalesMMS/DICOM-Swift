//
//  TagMetadata.swift
//  DicomCore
//
//  Lightweight structure for lazy DICOM tag parsing. Stores tag location and format information
//  without parsing the tag value to a string. This enables deferred parsing where tag values are
//  only extracted when first accessed, reducing memory allocations for files with many tags.
//
//  Usage:
//
//  let metadata = TagMetadata( tag: 0x00100010, offset: 512, vr: .PN, elementLength: 64 )
//  // Later: use offset and length to read and parse the value.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - TagMetadata Structure

/// Metadata for a DICOM tag stored in a file.
/// Contains information needed to parse the tag value on demand
/// without performing the actual string parsing upfront.
///
/// This structure is used to implement lazy tag parsing where
/// tag values are only converted to strings when first accessed
/// via `info(for:)`. This optimization reduces memory usage for
/// DICOM files containing hundreds of private or unused tags.
///
/// **Storage Requirements:**
/// - 32 bytes per tag (tag + offset + VR + length)
/// - vs ~100+ bytes for parsed strings
///
/// **Thread Safety:**
/// This structure is immutable and thread-safe after creation.
internal struct TagMetadata {

    // MARK: - Properties

    /// The DICOM tag identifier (group << 16 | element)
    /// Example: 0x00100010 for Patient Name
    let tag: Int

    /// Byte offset from the start of the file to the tag's value
    /// This offset points to the first byte of the tag's value data,
    /// after the tag header, VR, and length fields.
    let offset: Int

    /// Value Representation indicating the data type and encoding
    /// Examples: PN (Person Name), DA (Date), UI (UID)
    let vr: DicomVR

    /// Length of the element value in bytes
    /// This is the raw byte count from the DICOM tag header,
    /// not the character count after string parsing.
    let elementLength: Int

    // MARK: - Initialization

    /// Creates a new tag metadata record.
    ///
    /// - Parameters:
    ///   - tag: The DICOM tag identifier
    ///   - offset: Byte offset to the tag's value in the file
    ///   - vr: Value representation of the tag
    ///   - elementLength: Length of the tag's value in bytes
    init(tag: Int, offset: Int, vr: DicomVR, elementLength: Int) {
        self.tag = tag
        self.offset = offset
        self.vr = vr
        self.elementLength = elementLength
    }
}

// MARK: - Equatable Conformance

extension TagMetadata: Equatable {
    static func == (lhs: TagMetadata, rhs: TagMetadata) -> Bool {
        return lhs.tag == rhs.tag &&
               lhs.offset == rhs.offset &&
               lhs.vr == rhs.vr &&
               lhs.elementLength == rhs.elementLength
    }
}

// MARK: - CustomStringConvertible Conformance

extension TagMetadata: CustomStringConvertible {
    var description: String {
        let tagHex = String(format: "0x%08X", tag)
        return "TagMetadata(tag: \(tagHex), offset: \(offset), vr: \(vr), length: \(elementLength))"
    }
}
