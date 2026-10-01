import Foundation

/// Produces demand-driven cumulative image entities for a JPIP request.
public protocol DicomJPIPTransport: Sendable {
    /// Returns a single-pass sequence that performs work only when its iterator advances.
    func payloads(for request: DicomJPIPRequest) -> DicomJPIPPayloadSequence
}
