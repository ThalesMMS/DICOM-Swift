//
//  DicomMetadataAccessor.swift
//
//  Presentation-layer metadata access helpers for DicomSwiftUI views.
//
//  Purpose:
//  - Keep SwiftUI views focused on layout/composition.
//  - Centralize common tag extraction patterns and fallback handling.
//  - Avoid repeating `decoder.info(for:)` + empty-string checks across views.
//

import Foundation
import DicomCore

/// Lightweight accessor for extracting display-ready metadata values from a DICOM decoder.
///
/// This type intentionally stays small and UI-agnostic: it does not build SwiftUI views.
/// It only encapsulates common access patterns used by `DicomSwiftUI` view code.
public struct DicomMetadataAccessor {
    private let decoder: any DicomDecoderProtocol

    public init(decoder: any DicomDecoderProtocol) {
        self.decoder = decoder
    }

    /// Returns the raw string for a tag, or `nil` when the decoder has no value.
    ///
    /// Note: This does not treat an empty string as missing.
    public func string(_ tag: DicomTag) -> String {
        decoder.info(for: tag)
    }

    /// Returns the raw string for a tag, treating empty strings as missing (`nil`).
    public func nonEmptyString(_ tag: DicomTag) -> String? {
        let value = decoder.info(for: tag)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Returns the raw string for a tag, with a caller-provided fallback.
    public func string(_ tag: DicomTag, fallback: String) -> String {
        nonEmptyString(tag) ?? fallback
    }

    /// Returns an optional string for a tag (empty string is treated as missing).
    public func optionalString(_ tag: DicomTag) -> String? {
        nonEmptyString(tag)
    }
}
