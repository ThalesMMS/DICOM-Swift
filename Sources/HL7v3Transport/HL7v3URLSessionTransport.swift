import DicomCore
import Foundation
#if canImport(Security)
import Security
#endif

/// URLSession transport for HL7 v3 exchanges: ephemeral session per request, no cookies or caches,
/// redirects are never followed (3xx is returned unchanged), responses are bounded, and server trust
/// follows the injected `HL7v3TransportTrust`. Send progress is tracked so failures classify as
/// before-send, after-body-sent or unknown.
public struct HL7v3URLSessionTransport: DicomWebHTTPTransport {
    public let maximumResponseBytes: Int
    public let trust: HL7v3TransportTrust
    public let serverName: String?

    public init(maximumResponseBytes: Int = 16 * 1024 * 1024, trust: HL7v3TransportTrust = .system, serverName: String? = nil) {
        self.maximumResponseBytes = maximumResponseBytes
        self.trust = trust
        self.serverName = serverName
    }

    public func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        guard maximumResponseBytes > 0, request.timeout.isFinite, request.timeout > 0, request.bodyFileURL == nil else {
            throw HL7v3TransportError.invalidConfiguration("request")
        }
        let delegate = HL7v3RedirectBlockingDelegate(maximumResponseBytes: maximumResponseBytes, trust: trust,
                                                     serverName: serverName ?? request.url.host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeout
        configuration.timeoutIntervalForResource = request.timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.allHTTPHeaderFields = request.headers
        urlRequest.httpBody = request.body
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: urlRequest)
                delegate.start(task: task, continuation: continuation)
            }
        } onCancel: { delegate.cancel() }
    }

    public func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        let response = try await send(request)
        return .init(statusCode: response.statusCode, headers: response.headers, body: AsyncThrowingStream { continuation in
            continuation.yield(response.body)
            continuation.finish()
        })
    }
}

final class HL7v3RedirectBlockingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private let trust: HL7v3TransportTrust
    private let serverName: String?
    private var continuation: CheckedContinuation<DicomWebHTTPResponse, Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var bodySent = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private var failure: HL7v3TransportError?

    init(maximumResponseBytes: Int, trust: HL7v3TransportTrust, serverName: String?) {
        self.maximumResponseBytes = maximumResponseBytes
        self.trust = trust
        self.serverName = serverName
    }

    func start(task: URLSessionTask, continuation: CheckedContinuation<DicomWebHTTPResponse, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
            if cancelled { task.cancel() }
            task.resume()
        }
    }

    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock { bodySent = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Client certificates and HTTP auth are not supplied by this transport; hosts inject headers instead.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard case .pinnedRoots(let roots) = trust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #if canImport(Security)
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            lock.withLock { failure = .tlsTrustRejected }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let anchors = roots.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var accepted = false
        if !anchors.isEmpty,
           SecTrustSetAnchorCertificates(serverTrust, anchors as CFArray) == errSecSuccess,
           SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess,
           SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, serverName as CFString?)) == errSecSuccess {
            var error: CFError?
            accepted = SecTrustEvaluateWithError(serverTrust, &error)
        }
        if accepted {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            lock.withLock { failure = .tlsTrustRejected }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
        #else
        lock.withLock { failure = .tlsTrustRejected }
        completionHandler(.cancelAuthenticationChallenge, nil)
        #endif
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accept = lock.withLock {
            self.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                failure = .responseTooLarge
                return false
            }
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard data.count <= maximumResponseBytes - body.count else {
                failure = .responseTooLarge
                dataTask.cancel()
                return
            }
            body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            self.task = nil
            if let failure {
                continuation.resume(throwing: failure)
            } else if let error {
                let code = (error as? URLError)?.code
                if cancelled && code == .cancelled {
                    continuation.resume(throwing: CancellationError())
                } else if bodySent {
                    continuation.resume(throwing: HL7v3TransportError.afterBodySent(code.map { "URLError \($0.rawValue)" } ?? "error"))
                } else if code == .cannotConnectToHost || code == .cannotFindHost || code == .dnsLookupFailed ||
                            code == .notConnectedToInternet || code == .secureConnectionFailed ||
                            code == .serverCertificateUntrusted {
                    continuation.resume(throwing: HL7v3TransportError.beforeSend)
                } else {
                    continuation.resume(throwing: HL7v3TransportError.unknownProgress(code.map { "URLError \($0.rawValue)" } ?? "error"))
                }
            } else if let response {
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                continuation.resume(returning: .init(statusCode: response.statusCode, headers: headers, body: body))
            } else {
                continuation.resume(throwing: HL7v3TransportError.unknownProgress("no response"))
            }
        }
    }
}
