import Foundation

public struct DicomWebHTTPStreamedResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    /// Called before every WebSocket event. Throwing closes the connection before sending the event.
    public var authorizeNotification: (@Sendable (String) async throws -> Void)?
    public var cancel: @Sendable () -> Void

    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>,
                cancel: @escaping @Sendable () -> Void = {},
                authorizeNotification: (@Sendable (String) async throws -> Void)? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.authorizeNotification = authorizeNotification
        self.cancel = cancel
    }
}

extension DicomWebHTTPTransport {
    /// Compatibility adapter with the default STOW request limit for buffered file bodies.
    public func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        try await stream(request, bufferingLimit: DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes)
    }

    func stream(_ request: DicomWebHTTPRequest, bufferingLimit: Int) async throws -> DicomWebHTTPStreamedResponse {
        var buffered = request
        if let file = request.bodyFileURL {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let body = try handle.read(upToCount: bufferingLimit + 1) ?? Data()
            guard body.count <= bufferingLimit else { throw DicomWebError(kind: .tooLarge) }
            buffered.body = body
            buffered.bodyFileURL = nil
        } else if let streamed = request.streamedBody {
            guard streamed.length <= bufferingLimit else { throw DicomWebError(kind: .tooLarge) }
            let stream = streamed.makeInputStream()
            stream.open()
            defer { stream.close() }
            var body = Data(count: streamed.length)
            let count = body.withUnsafeMutableBytes { raw -> Int in
                var total = 0
                while total < raw.count {
                    let read = stream.read(raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + total,
                                           maxLength: raw.count - total)
                    guard read > 0 else { break }
                    total += read
                }
                return total
            }
            if let error = stream.streamError { throw error }
            guard count == streamed.length else { throw DicomWebError(kind: .invalidResponse) }
            buffered.body = body
            buffered.streamedBody = nil
        }
        let response = try await send(buffered)
        return .init(statusCode: response.statusCode, headers: response.headers,
                     body: AsyncThrowingStream { continuation in
            continuation.yield(response.body)
            continuation.finish()
        })
    }
}

extension URLSessionDicomWebHTTPTransport: DicomWebStreamedBodyTransport {
    public func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        try Task.checkCancellation()
        guard request.connectAddress == nil else { throw DicomWebClientError.unsupportedConnectAddress }
        let policy = request.originPolicy ?? .init(configuredURL: request.url)
        try policy.validate(request.url)
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = policy.forwardsCredentials(to: request.url)
        urlRequest.httpBody = request.body
        if let file = request.bodyFileURL { urlRequest.httpBodyStream = InputStream(url: file) }
        if let body = request.streamedBody { urlRequest.httpBodyStream = body.makeInputStream() }
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        let delegate = DicomWebRedirectDelegate(policy: policy, credentialHeaderNames: request.credentialHeaderNames,
                                                followsRedirects: request.followsRedirects, bodyFileURL: request.bodyFileURL,
                                                streamedBody: request.streamedBody)
        let watchdog = delegate.enforce(deadline: request.deadline)
        let responseBody: DicomWebResponseBody, response: URLResponse
        do {
            (responseBody, response) = try await session.dicomWebResponse(for: urlRequest, delegate: delegate)
        } catch {
            watchdog?.cancel()
            throw delegate.mapping(error)
        }
        guard let http = response as? HTTPURLResponse else {
            watchdog?.cancel()
            responseBody.task.cancel()
            throw DicomWebError(kind: .invalidResponse)
        }
        let task = responseBody.task
        let body = AsyncThrowingStream<Data, Error>(unfolding: {
            do {
                let chunk = try await responseBody.next()
                if chunk == nil { watchdog?.cancel() }
                return chunk
            } catch {
                watchdog?.cancel()
                throw delegate.mapping(error)
            }
        })
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = String(describing: pair.value) }
        }
        return .init(statusCode: http.statusCode, headers: headers, body: body, cancel: {
            watchdog?.cancel()
            task.cancel()
        })
    }
}
