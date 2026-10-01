import Foundation

/// Normalized network origin used for JPIP SSRF and credential boundaries.
public struct DicomJPIPOrigin: Sendable, Hashable {
    /// Lowercase URL scheme.
    public let scheme: String
    /// Lowercase host name.
    public let host: String
    /// Explicit or scheme-default port.
    public let port: Int

    /// Creates an origin from an absolute HTTP or HTTPS URL.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
