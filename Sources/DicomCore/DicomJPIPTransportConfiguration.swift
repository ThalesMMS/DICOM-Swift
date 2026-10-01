import Foundation

/// Security, resource, and interoperability limits for a JPIP transport session.
public struct DicomJPIPTransportConfiguration: Sendable {
    /// Controls whether redirects are rejected or limited to the original origin.
    public enum RedirectPolicy: Sendable, Equatable {
        case forbidden
        case sameOrigin(maximumHops: Int)
    }

    /// Number of cumulative layer requests when the request does not override the range.
    public var defaultLayerCount: Int
    /// Maximum cumulative quality-layer count accepted from requests and responses.
    public var maximumLayerCount: Int
    /// Maximum decoded HTTP response bytes for one layer request.
    public var maximumResponseBytes: Int
    /// Maximum sum of all cumulative response bodies in one sequence.
    public var maximumTotalBytes: Int
    public var maximumMessageLength: Int = 32 * 1_024 * 1_024
    public var maximumCacheBytes: Int = 64 * 1_024 * 1_024
    public var maximumDatabins: Int = 65_536
    /// Inactivity timeout for each HTTP request.
    public var requestTimeout: TimeInterval
    /// Total deadline for one HTTP resource transfer, including redirects.
    public var resourceTimeout: TimeInterval
    /// Whether explicit test or intranet configurations may use cleartext HTTP.
    public var allowsInsecureHTTP: Bool
    /// Redirect behavior for the URLSession client.
    public var redirectPolicy: RedirectPolicy
    /// Complete-image media types that this transport may negotiate.
    public var allowedResponseMediaTypes: Set<String>
    /// Exact origins authorized to receive requests and credentials.
    public var allowedOrigins: Set<DicomJPIPOrigin>

    /// Creates a finite JPIP transport configuration.
    public init(
        defaultLayerCount: Int = 3,
        maximumLayerCount: Int = 16,
        maximumResponseBytes: Int = 32 * 1_024 * 1_024,
        maximumTotalBytes: Int = 64 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        allowsInsecureHTTP: Bool = false,
        redirectPolicy: RedirectPolicy = .forbidden,
        allowedResponseMediaTypes: Set<String> = [
            "image/jp2",
            "image/jph",
            "image/jphc"
        ],
        allowedOrigins: Set<DicomJPIPOrigin> = []
    ) {
        self.defaultLayerCount = defaultLayerCount
        self.maximumLayerCount = maximumLayerCount
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.redirectPolicy = redirectPolicy
        self.allowedResponseMediaTypes = allowedResponseMediaTypes
        self.allowedOrigins = allowedOrigins
    }
}
