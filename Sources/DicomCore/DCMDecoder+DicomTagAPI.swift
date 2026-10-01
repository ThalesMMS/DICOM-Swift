//
//  DCMDecoder+DicomTagAPI.swift
//
//  Type-safe DicomTag overloads for DCMDecoder.
//

import Foundation

extension DCMDecoder {

    /// Retrieves the value of a parsed DICOM header entry identified by the given tag.
    /// - Parameter tag: The DICOM tag to look up.
    /// - Returns: The header value as a `String`; an empty string if the tag is not found.
    public func info(for tag: DicomTag) -> String {
        info(for: tag.rawValue)
    }

    /// Retrieve the integer value for the given DICOM tag.
    /// - Parameter tag: The `DicomTag` to look up in the decoded header.
    /// - Returns: The `Int` value associated with `tag`, or `nil` if the tag is missing or cannot be parsed as an integer.
    public func intValue(for tag: DicomTag) -> Int? {
        intValue(for: tag.rawValue)
    }

    /// Retrieves the `Double` value associated with the specified `DicomTag`.
    /// - Parameter tag: The DICOM tag to look up.
    /// - Returns: The `Double` value for `tag`, or `nil` if the tag is missing or the value cannot be parsed.
    public func doubleValue(for tag: DicomTag) -> Double? {
        doubleValue(for: tag.rawValue)
    }
}
