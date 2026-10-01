import Foundation

/// Executes one bounded JPIP HTTP request for the higher-level transport.
public protocol DicomJPIPHTTPClient: Sendable {
    /// Returns a bounded response while enforcing the supplied redirect policy.
    func response(
        for request: URLRequest,
        maximumBytes: Int,
        resourceTimeout: TimeInterval,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy
    ) async throws -> DicomJPIPHTTPResponse
}
