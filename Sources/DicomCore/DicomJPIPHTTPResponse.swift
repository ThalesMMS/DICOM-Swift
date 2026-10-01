import Foundation

/// Privacy-safe HTTP response data consumed by the JPIP protocol layer.
public struct DicomJPIPHTTPResponse: Sendable, Equatable {
    /// HTTP status code.
    public let statusCode: Int
    /// Response headers with their original field names.
    public let headers: [String: String]
    /// Response body already bounded by the HTTP client.
    public let body: Data

    /// Creates a bounded JPIP HTTP response.
    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Finds a response header using case-insensitive HTTP field-name comparison.
    public func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Optional incremental delivery surface; injected complete-response clients remain compatible.
public protocol DicomJPIPStreamingHTTPClient: DicomJPIPHTTPClient {
    func response(
        for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy,
        receive: @escaping @Sendable (DicomJPIPHTTPResponse, Data) throws -> Void
    ) async throws -> DicomJPIPHTTPResponse
}
