import Foundation

/// Ephemeral URLSession client with bounded incremental response collection.
public struct URLSessionDicomJPIPHTTPClient: DicomJPIPStreamingHTTPClient {
    /// Creates an ephemeral JPIP HTTP client.
    public init() {}

    /// Executes one cancellable request without cookies, caches, or persistent storage.
    public func response(
        for request: URLRequest,
        maximumBytes: Int,
        resourceTimeout: TimeInterval,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy
    ) async throws -> DicomJPIPHTTPResponse {
        try await response(for: request, maximumBytes: maximumBytes, resourceTimeout: resourceTimeout,
                           redirectPolicy: redirectPolicy, receive: { _, _ in })
    }

    public func response(
        for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy,
        receive: @escaping @Sendable (DicomJPIPHTTPResponse, Data) throws -> Void
    ) async throws -> DicomJPIPHTTPResponse {
        let delegate = DicomJPIPURLSessionDelegate(
            maximumBytes: maximumBytes,
            redirectPolicy: redirectPolicy,
            receive: receive
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            return try await delegate.response(for: request, using: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DicomJPIPTransportError {
            throw error
        } catch let error as DicomJPIPMessageError {
            throw error
        } catch let error as DicomJPIPCacheError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw DicomJPIPTransportError.networkFailure(code: error.errorCode)
        } catch {
            throw DicomJPIPTransportError.networkFailure(code: nil)
        }
    }
}
