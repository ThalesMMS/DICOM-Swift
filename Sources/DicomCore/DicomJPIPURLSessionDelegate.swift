import Foundation

/// URLSession delegate callbacks may arrive concurrently. Every mutable field in this
/// NSObject bridge is protected by `lock`; remove `@unchecked Sendable` when Foundation's
/// delegate protocols can express that invariant with checked isolation.
final class DicomJPIPURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy
    private let receive: (@Sendable (DicomJPIPHTTPResponse, Data) throws -> Void)?
    private let lock = NSLock()
    private var body = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<DicomJPIPHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var redirectCount = 0
    private var isFinished = false

    init(
        maximumBytes: Int,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy,
        receive: (@Sendable (DicomJPIPHTTPResponse, Data) throws -> Void)? = nil
    ) {
        self.receive = receive
        self.maximumBytes = maximumBytes
        self.redirectPolicy = redirectPolicy
    }

    func response(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> DicomJPIPHTTPResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let shouldStart = lock.withLock { () -> Bool in
                    guard !isFinished else { return false }
                    self.continuation = continuation
                    self.task = task
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            finish(throwing: CancellationError())
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: DicomJPIPTransportError.networkFailure(code: nil))
            return
        }
        guard httpResponse.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(throwing: DicomJPIPTransportError.responseTooLarge(limit: maximumBytes))
            return
        }
        lock.withLock {
            self.response = httpResponse
            body.reserveCapacity(min(maximumBytes, max(0, Int(httpResponse.expectedContentLength))))
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock { () -> Bool in
            guard !isFinished, data.count <= maximumBytes - body.count else { return false }
            body.append(data)
            return true
        }
        guard accepted else {
            dataTask.cancel()
            finish(throwing: DicomJPIPTransportError.responseTooLarge(limit: maximumBytes))
            return
        }
        let metadata = lock.withLock { () -> DicomJPIPHTTPResponse? in
            guard !isFinished, let response else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                if let key = $1.key as? String { $0[key] = String(describing: $1.value) }
            }
            return DicomJPIPHTTPResponse(statusCode: response.statusCode, headers: headers, body: Data())
        }
        if let metadata {
            do { try receive?(metadata, data) }
            catch { finish(throwing: error) }
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            redirectCount += 1
            return redirectPolicy.allows(
                hop: redirectCount,
                from: task.currentRequest?.url,
                to: request.url
            )
        }
        completionHandler(allowed ? request : nil)
        if !allowed {
            finish(throwing: DicomJPIPTransportError.redirectRejected)
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(throwing: error)
            return
        }
        let result = lock.withLock { () -> DicomJPIPHTTPResponse? in
            guard let response else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, element in
                guard let key = element.key as? String else { return }
                result[key] = String(describing: element.value)
            }
            return DicomJPIPHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
        }
        guard let result else {
            finish(throwing: DicomJPIPTransportError.networkFailure(code: nil))
            return
        }
        finish(returning: result)
    }

    private func finish(returning response: DicomJPIPHTTPResponse) {
        let continuation = takeContinuationAndFinish()
        continuation?.resume(returning: response)
    }

    private func finish(throwing error: Error) {
        let state = lock.withLock { () -> (URLSessionDataTask?, CheckedContinuation<DicomJPIPHTTPResponse, Error>?) in
            guard !isFinished else { return (nil, nil) }
            isFinished = true
            let state = (task, continuation)
            task = nil
            continuation = nil
            return state
        }
        state.0?.cancel()
        state.1?.resume(throwing: error)
    }

    private func takeContinuationAndFinish() -> CheckedContinuation<DicomJPIPHTTPResponse, Error>? {
        lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            task = nil
            defer { continuation = nil }
            return continuation
        }
    }
}

private extension DicomJPIPTransportConfiguration.RedirectPolicy {
    func allows(hop: Int, from source: URL?, to destination: URL?) -> Bool {
        guard case .sameOrigin(let maximumHops) = self,
              hop <= maximumHops,
              let source,
              let destination else {
            return false
        }
        return source.scheme?.lowercased() == destination.scheme?.lowercased()
            && source.host?.lowercased() == destination.host?.lowercased()
            && effectivePort(source) == effectivePort(destination)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
