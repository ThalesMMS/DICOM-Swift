import Foundation

public enum DicomWebhookDeliveryOutcome: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case status(Int), redirectNotAllowed, network
    }
    case delivered(status: Int)
    case rejected(Reason)
    case transient(Reason, retryAfter: TimeInterval?)
    case uncertain(String)
}

/// Transport implementations must report send progress conservatively and must not follow redirects.
public enum DicomWebhookTransportError: Error, Sendable {
    case beforeSend
    case afterBodySent(String)
    case unknownProgress(String)
    case responseTooLarge
}

public enum DicomWebhookDeliveryError: Error { case invalidConfiguration, invalidHeaderValue }

public struct DicomWebhookDeliveryClient: Sendable {
    private let transport: any DicomWebHTTPTransport
    private let policy: DicomWebhookTargetPolicy
    private let signer: DicomWebhookSigner

    /// Injected transports must honor connectAddress and refuse redirects; use DicomWebhookURLSessionTransport for HTTP.
    public init(transport: any DicomWebHTTPTransport, policy: DicomWebhookTargetPolicy, signer: DicomWebhookSigner) {
        self.transport = transport
        self.policy = policy
        self.signer = signer
    }

    public func deliver(event: DicomWebhookEvent, to url: URL, idempotencyKey: String,
                        now: Date = Date()) async throws -> DicomWebhookDeliveryOutcome {
        guard policy.timeout.isFinite, policy.timeout > 0, policy.maxResponseBytes >= 0,
              policy.maxRedirects >= 0 else { throw DicomWebhookDeliveryError.invalidConfiguration }
        for value in [event.eventID, idempotencyKey] {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                throw DicomWebhookDeliveryError.invalidHeaderValue
            }
        }
        var addresses = try policy.validatedAddresses(url)
        var addressIndex = 0
        let body = try DicomWebhookCanonicalJSON.encode(event)
        let signature = try signer.sign(body: body, now: now)
        let headers = ["Content-Type": "application/json", DicomWebhookSignatureHeader.headerName: signature.serialized,
                       "X-Isis-Event-ID": event.eventID, "X-Isis-Idempotency-Key": idempotencyKey,
                       "User-Agent": "Isis-DICOM-Webhook/1"]
        var target = url
        var redirects = 0
        while true {
            let response: DicomWebHTTPStreamedResponse
            do {
                var request = DicomWebHTTPRequest(method: .post, url: target, headers: headers,
                                                   body: body, timeout: policy.timeout)
                request.connectAddress = addresses[addressIndex]
                response = try await transport.stream(request)
                defer { response.cancel() }
                var count = 0
                for try await chunk in response.body {
                    guard chunk.count <= policy.maxResponseBytes - count else {
                        return .uncertain("Response exceeded byte limit; delivery may have been accepted")
                    }
                    count += chunk.count
                }
            } catch let error as DicomWebhookDeliveryError {
                throw error
            } catch DicomWebhookTransportError.beforeSend {
                if addressIndex + 1 < addresses.count { addressIndex += 1; continue }
                return .transient(.network, retryAfter: nil)
            } catch DicomWebhookTransportError.afterBodySent(let reason) {
                return .uncertain(reason)
            } catch DicomWebhookTransportError.unknownProgress(let reason) {
                return .uncertain(reason)
            } catch DicomWebhookTransportError.responseTooLarge {
                return .uncertain("Response exceeded byte limit; delivery may have been accepted")
            } catch {
                // Generic transports have no send-progress contract. A timeout alone cannot prove non-delivery.
                let code = (error as? URLError)?.code
                if code == .cannotFindHost || code == .cannotConnectToHost || code == .dnsLookupFailed {
                    return .transient(.network, retryAfter: nil)
                }
                return .uncertain("Transport failed without confirmed delivery: \(String(describing: error))")
            }
            let status = response.statusCode
            if (200...299).contains(status) { return .delivered(status: status) }
            if (300...399).contains(status) {
                guard policy.allowRedirects, redirects < policy.maxRedirects,
                      [307, 308].contains(status),
                      let location = response.headers.first(where: { $0.key.lowercased() == "location" })?.value,
                      let next = URL(string: location, relativeTo: target)?.absoluteURL,
                      sameOrigin(url, next) else { return .rejected(.redirectNotAllowed) }
                addresses = try policy.validatedAddresses(next)
                addressIndex = 0
                target = next
                redirects += 1
                // Explicit same-origin redirects retain the original signature and nonce; never re-sign.
                continue
            }
            if [408, 425, 429].contains(status) || (500...599).contains(status) {
                let raw = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                let seconds = raw.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let retry = seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                return .transient(.status(status), retryAfter: retry)
            }
            return .rejected(.status(status))
        }
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() &&
            (lhs.port ?? (lhs.scheme == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
    }
}

/// Policy-pinned deliveries use a direct numeric connection with the URL's TLS identity.
/// Unpinned diagnostic requests use a separate ephemeral session without cookies, credentials or caching.
/// Redirect decisions belong to the delivery client; this transport always exposes 3xx unchanged.
public struct DicomWebhookURLSessionTransport: DicomWebHTTPTransport {
    public let maxResponseBytes: Int
    public init(maxResponseBytes: Int = 64 * 1024) { self.maxResponseBytes = maxResponseBytes }

    public func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        guard maxResponseBytes >= 0, request.timeout.isFinite, request.timeout > 0,
              request.bodyFileURL == nil else { throw DicomWebhookDeliveryError.invalidConfiguration }
        if let address = request.connectAddress {
            return try await DicomWebhookPinnedConnection.send(request, address: address, maxResponseBytes: maxResponseBytes)
        }
        let delegate = DicomWebhookRedirectBlockingDelegate(maxResponseBytes: maxResponseBytes)
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
}

public final class DicomWebhookRedirectBlockingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maxResponseBytes: Int
    private var continuation: CheckedContinuation<DicomWebHTTPResponse, Error>?
    private var task: URLSessionTask?
    private var cancelled = false
    private var bodySent = false
    private var response: HTTPURLResponse?
    private var body = Data()
    private var failure: (any Error)?

    public init(maxResponseBytes: Int = 64 * 1024) { self.maxResponseBytes = maxResponseBytes }

    fileprivate func start(task: URLSessionTask, continuation: CheckedContinuation<DicomWebHTTPResponse, Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
            if cancelled { task.cancel() }
            task.resume()
        }
    }
    fileprivate func cancel() { lock.withLock { cancelled = true; task?.cancel() } }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock { bodySent = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend }
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let accept = lock.withLock {
            self.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(maxResponseBytes) {
                failure = DicomWebhookTransportError.responseTooLarge
                return false
            }
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard data.count <= maxResponseBytes - body.count else {
                failure = DicomWebhookTransportError.responseTooLarge
                dataTask.cancel()
                return
            }
            body.append(data)
        }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            self.task = nil
            if let failure { continuation.resume(throwing: failure) }
            else if let error {
                let code = (error as? URLError)?.code
                if bodySent {
                    continuation.resume(throwing: DicomWebhookTransportError.afterBodySent("\(error)"))
                } else if code == .cannotConnectToHost || code == .cannotFindHost || code == .dnsLookupFailed ||
                            code == .notConnectedToInternet {
                    continuation.resume(throwing: DicomWebhookTransportError.beforeSend)
                } else {
                    continuation.resume(throwing: DicomWebhookTransportError.unknownProgress("\(error)"))
                }
            } else if let response {
                var headers = [String: String]()
                for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
                continuation.resume(returning: .init(statusCode: response.statusCode, headers: headers, body: body))
            } else { continuation.resume(throwing: DicomWebhookTransportError.unknownProgress("Missing HTTP response")) }
        }
    }
}
