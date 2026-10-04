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
        }
        let response = try await send(buffered)
        return .init(statusCode: response.statusCode, headers: response.headers,
                     body: AsyncThrowingStream { continuation in
            continuation.yield(response.body)
            continuation.finish()
        })
    }
}

/// Only the stream consumer advances the byte iterator; no unbounded producer queue is created.
private actor DicomWebByteIterator {
    private var iterator: URLSession.AsyncBytes.AsyncIterator?
    init(_ bytes: URLSession.AsyncBytes) { iterator = bytes.makeAsyncIterator() }
    func next() async throws -> Data? {
        guard var active = iterator else { return nil }
        iterator = nil
        var chunk = Data()
        chunk.reserveCapacity(16 * 1024)
        while chunk.count < 16 * 1024 {
            try Task.checkCancellation()
            guard let byte = try await active.next() else { break }
            chunk.append(byte)
        }
        iterator = active
        return chunk.isEmpty ? nil : chunk
    }
}

extension URLSessionDicomWebHTTPTransport {
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
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        let delegate = DicomWebRedirectDelegate(policy: policy, credentialHeaderNames: request.credentialHeaderNames,
                                                followsRedirects: request.followsRedirects, bodyFileURL: request.bodyFileURL)
        let watchdog = delegate.enforce(deadline: request.deadline)
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate) } catch {
            watchdog?.cancel()
            throw delegate.mapping(error)
        }
        guard let http = response as? HTTPURLResponse else {
            watchdog?.cancel()
            bytes.task.cancel()
            throw DicomWebError(kind: .invalidResponse)
        }
        let iterator = DicomWebByteIterator(bytes)
        let task = bytes.task
        let body = AsyncThrowingStream<Data, Error>(unfolding: {
            do {
                let chunk = try await withTaskCancellationHandler {
                    try await iterator.next()
                } onCancel: { task.cancel() }
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
