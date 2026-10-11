import Foundation

/// Strict MIME remains the default. Legacy decoding requires a missing opening delimiter,
/// application/dicom part headers, and structurally bounded Part 10 objects.
public enum DicomWebMultipartCompatibility: Equatable, Sendable {
    case strict
    /// Explicitly configured for a known legacy node.
    case pixeonLegacyFraming
    /// Only responses identifying the observed DicomWebServices server family are eligible.
    case identifiedPixeonLegacyFraming

    func forResponse(headers: [String: String]) -> Self {
        guard self == .identifiedPixeonLegacyFraming else { return self }
        let server = headers.dicomWebHeaderValue("Server") ?? ""
        return server.hasPrefix("DicomWebServices ") ? .pixeonLegacyFraming : .strict
    }
}
