//
//  DicomWebMultipartCompatibility.swift
//  DicomWebClient
//
//  Strict MIME remains the default. Legacy decoding requires a missing opening delimiter,
//  application/dicom part headers, and structurally bounded Part 10 objects.
//
//  Thales Matheus Mendonça Santos — October 2026
//

import Foundation

/// Strict MIME remains the default. Legacy decoding requires a missing opening delimiter,
/// application/dicom part headers, and structurally bounded Part 10 objects.
public enum DicomWebMultipartCompatibility: Equatable, Sendable {
    case strict
    /// Explicitly configured for a known node whose responses omit the opening boundary.
    case missingOpeningBoundaryFraming
    /// Only responses identifying the observed DicomWebServices server family are eligible.
    case identifiedMissingOpeningBoundaryFraming

    func forResponse(headers: [String: String]) -> Self {
        guard self == .identifiedMissingOpeningBoundaryFraming else { return self }
        let server = headers.dicomWebHeaderValue("Server") ?? ""
        return server.hasPrefix("DicomWebServices ") ? .missingOpeningBoundaryFraming : .strict
    }
}
