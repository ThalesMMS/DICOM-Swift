//
//  DicomDictionaryProtocol.swift
//
//  Protocol abstraction for DICOM tag dictionary lookups.
//  Defines the public API for mapping between DICOM tag identifiers
//  (hexadecimal strings or numeric values) and their human-readable
//  descriptions and Value Representation (VR) codes.
//
//  Thread Safety:
//
//  All protocol methods must be thread-safe and support concurrent
//  access from multiple threads without requiring external
//  synchronization.
//

import Foundation

/// Protocol defining the public API for DICOM tag dictionary operations.
/// Implementations must provide lookup services for tag descriptions,
/// VR codes, and formatted tag strings.  The underlying data source
/// may be a property list, database, or any other backing store.
///
/// **Thread Safety:** All methods must be thread-safe and support
/// concurrent access without data races. Implementations should use
/// internal synchronization mechanisms as needed.
public protocol DicomDictionaryProtocol: Sendable {

    // MARK: - Core Lookup Methods

    /// Returns the raw value associated with a DICOM tag key.
    /// The value format is typically "VR:Description" where VR is
    /// the two-character Value Representation code followed by a
    /// colon and human-readable description.
    ///
    /// - Parameter key: Hexadecimal string identifying a DICOM tag (e.g., "00100010")
    /// - Returns: Raw value string if found, otherwise nil
    func value(forKey key: String) -> String?

    // MARK: - Convenience Methods

    /// Returns the Value Representation code for a given tag.
    /// The VR code indicates the data type and format of the tag value
    /// (e.g., "PN" for Person Name, "DA" for Date, "UI" for UID).
    ///
    /// - Parameter key: Hexadecimal string identifying a DICOM tag (e.g., "00100010")
    /// - Returns: Two-character VR code or nil if tag not found
    func vrCode(forKey key: String) -> String?

    /// Returns the human-readable description for a given tag.
    /// This is the tag name without the VR code prefix.
    ///
    /// - Parameter key: Hexadecimal string identifying a DICOM tag (e.g., "00100010")
    /// - Returns: Tag description (e.g., "Patient Name") or nil if tag not found
    func description(forKey key: String) -> String?

    /// Formats a numeric tag value as a standard DICOM tag string.
    /// The result follows the DICOM standard format "(GGGG,EEEE)"
    /// where GGGG is the group number and EEEE is the element number.
    ///
    /// - Parameter tag: 32-bit tag value (group in upper 16 bits, element in lower 16 bits)
    /// - Returns: Formatted tag string in format "(XXXX,XXXX)"
    func formatTag(_ tag: UInt32) -> String
}
