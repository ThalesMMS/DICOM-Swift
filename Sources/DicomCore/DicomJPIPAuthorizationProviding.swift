import Foundation

/// Supplies an HTTP Authorization value for an already allowlisted JPIP origin.
public protocol DicomJPIPAuthorizationProviding: Sendable {
    /// Returns a complete Authorization header value, or `nil` for anonymous access.
    func authorizationHeader(for origin: DicomJPIPOrigin) async throws -> String?
}
