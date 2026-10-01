import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPHTTPTransportTests: XCTestCase {
    func test_requestSerializationPreservesProviderQueryAndAppendsManagedFields() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [
            response(mediaType: "image/jp2", body: Data([0x01]))
        ])
        let configuration = DicomJPIPTransportConfiguration(
            defaultLayerCount: 1,
            maximumLayerCount: 4,
            maximumResponseBytes: 1_024,
            maximumTotalBytes: 2_048,
            requestTimeout: 7,
            resourceTimeout: 19,
            redirectPolicy: .sameOrigin(maximumHops: 2),
            allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: providerURL))]
        )
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)
        let request = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(
                string: "https://pacs.example.test/jpip?target=study%20one.jp2&vendor=a%2Bb"
            )),
            resource: .frame(index: 6),
            transferSyntax: .jpipReferenced
        )

        var iterator = transport.payloads(for: request).makeAsyncIterator()
        _ = try await iterator.next()

        let recordedRequests = await httpClient.recordedRequests()
        let recorded = try XCTUnwrap(recordedRequests.first)
        XCTAssertTrue(recorded.url.contains("target=study%20one.jp2&vendor=a%2Bb&"), recorded.url)
        let url = try XCTUnwrap(URL(string: recorded.url))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "target" }.map(\.value), ["study one.jp2"])
        XCTAssertEqual(items.filter { $0.name == "vendor" }.map(\.value), ["a+b"])
        XCTAssertEqual(items.filter { $0.name.caseInsensitiveCompare("layers") == .orderedSame }.map(\.value), ["1"])
        XCTAssertEqual(items.filter { $0.name.caseInsensitiveCompare("len") == .orderedSame }.map(\.value), ["1024"])
        XCTAssertEqual(items.filter { $0.name.caseInsensitiveCompare("stream") == .orderedSame }.map(\.value), ["7"])
        XCTAssertEqual(
            items.filter { $0.name.caseInsensitiveCompare("type") == .orderedSame }.map(\.value),
            ["image/jp2"]
        )
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.cacheControl, "no-store")
        XCTAssertEqual(recorded.timeout, 7)
        XCTAssertEqual(recorded.resourceTimeout, 19)
        XCTAssertEqual(recorded.maximumBytes, 1_024)
        XCTAssertEqual(recorded.redirectPolicy, .sameOrigin(maximumHops: 2))
    }

    func test_providerManagedQueryCollisionIsRejectedBeforeHTTPWork() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [])
        let transport = try DicomJPIPHTTPTransport(
            configuration: singleLayerConfiguration(),
            httpClient: httpClient
        )
        let conflictingRequest = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(
                string: "https://pacs.example.test/jpip?target=fixture.jp2&layers=99"
            )),
            resource: .volume,
            transferSyntax: .jpipReferenced
        )

        await assertNextThrows(
            transport,
            request: conflictingRequest,
            expected: .conflictingQueryParameter("layers")
        )
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test_volumeRequest_existingStreamParameter_isRejectedBeforeHTTPWork() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [])
        let transport = try DicomJPIPHTTPTransport(
            configuration: singleLayerConfiguration(),
            httpClient: httpClient
        )
        let conflictingRequest = DicomJPIPRequest(
            pixelDataProviderURL: try XCTUnwrap(URL(
                string: "https://pacs.example.test/jpip?target=fixture.jp2&stream=1"
            )),
            resource: .volume,
            transferSyntax: .jpipReferenced
        )

        await assertNextThrows(
            transport,
            request: conflictingRequest,
            expected: .conflictingQueryParameter("stream")
        )
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test_transferSyntaxSelectsCompleteEntityMediaTypes() async throws {
        let cases: [(DicomTransferSyntax, String, String)] = [
            (.jpipReferenced, "image/jp2", "image/jp2"),
            (.jpipReferencedDeflate, "image/jp2", "image/jp2"),
            (.jpipHTJ2KReferenced, "image/jph", "image/jph, image/jphc"),
            (.jpipHTJ2KReferencedDeflate, "image/jphc", "image/jph, image/jphc")
        ]

        for (syntax, responseMediaType, expectedAccept) in cases {
            let httpClient = DicomJPIPHTTPClientMock(responses: [
                response(mediaType: responseMediaType, body: Data([0x01]))
            ])
            let transport = try DicomJPIPHTTPTransport(
                configuration: singleLayerConfiguration(),
                httpClient: httpClient
            )
            var iterator = transport.payloads(for: request(transferSyntax: syntax)).makeAsyncIterator()

            let payload = try await iterator.next()

            XCTAssertEqual(payload?.mediaType, responseMediaType, syntax.rawValue)
            let recordedRequests = await httpClient.recordedRequests()
            XCTAssertEqual(recordedRequests.first?.accept, expectedAccept, syntax.rawValue)
        }
    }

    func test_partialJPIPStreamMediaTypesAreRejectedUntilDatabinParserExists() async throws {
        for mediaType in ["image/jpp-stream", "image/jpt-stream"] {
            let httpClient = DicomJPIPHTTPClientMock(responses: [
                response(mediaType: mediaType, body: Data([0x01]))
            ])
            let transport = try DicomJPIPHTTPTransport(
                configuration: singleLayerConfiguration(),
                httpClient: httpClient
            )

            await assertNextThrows(
                transport,
                request: request(transferSyntax: .jpipReferenced),
                expected: .unsupportedMediaType(mediaType)
            )
        }
    }

    func test_responseByteLimitReturnsTypedError() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [
            response(mediaType: "image/jp2", body: Data(repeating: 0x01, count: 5))
        ])
        var configuration = singleLayerConfiguration()
        configuration.maximumResponseBytes = 4
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)

        await assertNextThrows(
            transport,
            request: request(transferSyntax: .jpipReferenced),
            expected: .responseTooLarge(limit: 4)
        )
    }

    func test_totalByteLimitAcrossPullsReturnsTypedError() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [
            response(mediaType: "image/jp2", body: Data(repeating: 0x01, count: 3)),
            response(mediaType: "image/jp2", body: Data(repeating: 0x02, count: 3))
        ])
        var configuration = singleLayerConfiguration()
        configuration.defaultLayerCount = 2
        configuration.maximumResponseBytes = 4
        configuration.maximumTotalBytes = 5
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)
        var iterator = transport.payloads(for: request(transferSyntax: .jpipReferenced)).makeAsyncIterator()

        let first = try await iterator.next()
        XCTAssertNotNil(first)
        do {
            _ = try await iterator.next()
            XCTFail("Expected the cumulative response limit to fail")
        } catch let error as DicomJPIPTransportError {
            XCTAssertEqual(error, .totalResponseTooLarge(limit: 5))
        } catch {
            XCTFail("Expected DicomJPIPTransportError, got \(error)")
        }
    }

    func test_layerLimitIsRejectedBeforeStartingHTTPWork() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [])
        var configuration = singleLayerConfiguration()
        configuration.maximumLayerCount = 2
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)
        let overLimit = DicomJPIPRequest(
            pixelDataProviderURL: providerURL,
            resource: .volume,
            requestedLayerRange: 0..<3,
            transferSyntax: .jpipReferenced
        )

        await assertNextThrows(
            transport,
            request: overLimit,
            expected: .layerLimitExceeded(limit: 2, requested: 3)
        )
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test_responseLayerHeaderLimitsAndMalformedValuesReturnTypedErrors() async throws {
        let cases: [(String, DicomJPIPTransportError)] = [
            ("3", .layerLimitExceeded(limit: 2, requested: 3)),
            ("not-a-number", .invalidResponseHeader("JPIP-layers"))
        ]

        for (header, expected) in cases {
            let httpClient = DicomJPIPHTTPClientMock(responses: [
                DicomJPIPHTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "image/jp2", "JPIP-layers": header],
                    body: Data([0x01])
                )
            ])
            var configuration = singleLayerConfiguration()
            configuration.maximumLayerCount = 2
            let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)

            await assertNextThrows(
                transport,
                request: request(transferSyntax: .jpipReferenced),
                expected: expected
            )
        }
    }

    func test_httpStatusAndMediaFailuresReturnTypedErrors() async throws {
        let cases: [(DicomJPIPHTTPResponse, DicomJPIPTransportError)] = [
            (response(statusCode: 401), .authenticationRequired(statusCode: 401)),
            (response(statusCode: 403), .authenticationRequired(statusCode: 403)),
            (response(statusCode: 302), .redirectRejected),
            (response(statusCode: 503), .unexpectedHTTPStatus(503)),
            (response(mediaType: "text/html"), .unsupportedMediaType("text/html")),
            (DicomJPIPHTTPResponse(statusCode: 200, headers: [:], body: Data()), .unsupportedMediaType(nil))
        ]

        for (httpResponse, expected) in cases {
            let httpClient = DicomJPIPHTTPClientMock(responses: [httpResponse])
            let transport = try DicomJPIPHTTPTransport(
                configuration: singleLayerConfiguration(),
                httpClient: httpClient
            )
            await assertNextThrows(
                transport,
                request: request(transferSyntax: .jpipReferenced),
                expected: expected
            )
        }
    }

    func test_transportIsPullBasedAndDoesNotRunAhead() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [
            response(mediaType: "image/jp2", body: Data([0x00])),
            response(mediaType: "image/jp2", body: Data([0x00, 0x01])),
            response(mediaType: "image/jp2", body: Data([0x00, 0x01, 0x02]))
        ])
        var configuration = singleLayerConfiguration()
        configuration.defaultLayerCount = 3
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)
        let stream = transport.payloads(for: request(transferSyntax: .jpipReferenced))

        await Task.yield()
        var requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.layer.quality, .preview)
        requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 1)

        try await Task.sleep(for: .milliseconds(20))
        requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 1, "The producer must wait for the next iterator pull")

        let second = try await iterator.next()
        XCTAssertEqual(second?.layer.quality, .refinement)
        requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 2)

        let final = try await iterator.next()
        XCTAssertEqual(final?.layer.quality, .final)
        XCTAssertEqual(final?.layer.isFinal, true)
        requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 3)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func test_cancellingConsumerCancelsInFlightHTTPClient() async throws {
        let httpClient = DicomJPIPHTTPClientMock(stalls: true)
        let transport = try DicomJPIPHTTPTransport(
            configuration: singleLayerConfiguration(),
            httpClient: httpClient
        )
        let jpipRequest = request(transferSyntax: .jpipReferenced)
        let task = Task {
            var iterator = transport.payloads(for: jpipRequest).makeAsyncIterator()
            return try await iterator.next()
        }
        try await waitUntil { await httpClient.requestCount() == 1 }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        try await waitUntil { await httpClient.cancellationCount() == 1 }
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func test_originOutsideAllowlistIsRejectedBeforeHTTPWork() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [])
        let configuration = DicomJPIPTransportConfiguration(
            defaultLayerCount: 1,
            maximumLayerCount: 4,
            maximumResponseBytes: 1_024,
            maximumTotalBytes: 4_096,
            allowedOrigins: []
        )
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: httpClient)

        await assertNextThrows(
            transport,
            request: request(transferSyntax: .jpipReferenced),
            expected: .originNotAllowed
        )
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test_authorizationProviderAddsHeaderWithoutPuttingSecretInQuery() async throws {
        let httpClient = DicomJPIPHTTPClientMock(responses: [
            response(mediaType: "image/jp2", body: Data([0x01]))
        ])
        let transport = try DicomJPIPHTTPTransport(
            configuration: singleLayerConfiguration(),
            httpClient: httpClient,
            authorizationProvider: StaticDicomJPIPAuthorizationProvider(header: "Bearer top-secret")
        )
        var iterator = transport.payloads(for: request(transferSyntax: .jpipReferenced)).makeAsyncIterator()

        _ = try await iterator.next()

        let recordedRequests = await httpClient.recordedRequests()
        let recorded = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(recorded.authorization, "Bearer top-secret")
        XCTAssertFalse(recorded.url.contains("top-secret"))
        XCTAssertNil(URLComponents(string: recorded.url)?.queryItems?.first {
            $0.name.caseInsensitiveCompare("authorization") == .orderedSame
        })
    }

    func test_authenticatedHTTP_isRejectedBeforeHTTPWork() async throws {
        let providerURL = try XCTUnwrap(URL(string: "http://pacs.example.test/jpip?target=fixture.jp2"))
        let httpClient = DicomJPIPHTTPClientMock(responses: [])
        let configuration = DicomJPIPTransportConfiguration(
            defaultLayerCount: 1,
            maximumLayerCount: 4,
            maximumResponseBytes: 1_024,
            maximumTotalBytes: 2_048,
            allowsInsecureHTTP: true,
            allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: providerURL))]
        )
        let transport = try DicomJPIPHTTPTransport(
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: StaticDicomJPIPAuthorizationProvider(header: "Bearer top-secret")
        )
        let request = DicomJPIPRequest(
            pixelDataProviderURL: providerURL,
            resource: .volume,
            transferSyntax: .jpipReferenced
        )

        await assertNextThrows(transport, request: request, expected: .insecureTransportRejected)
        let requestCount = await httpClient.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test_invalidLimitsAreRejectedWithTypedConfigurationErrors() {
        var invalidLayers = singleLayerConfiguration()
        invalidLayers.defaultLayerCount = 0
        XCTAssertThrowsError(try DicomJPIPHTTPTransport(configuration: invalidLayers)) { error in
            XCTAssertEqual(error as? DicomJPIPTransportError, .invalidConfiguration("layer limits"))
        }

        var invalidBytes = singleLayerConfiguration()
        invalidBytes.maximumResponseBytes = 0
        XCTAssertThrowsError(try DicomJPIPHTTPTransport(configuration: invalidBytes)) { error in
            XCTAssertEqual(error as? DicomJPIPTransportError, .invalidConfiguration("byte limits"))
        }

        var invalidTimeout = singleLayerConfiguration()
        invalidTimeout.resourceTimeout = .infinity
        XCTAssertThrowsError(try DicomJPIPHTTPTransport(configuration: invalidTimeout)) { error in
            XCTAssertEqual(error as? DicomJPIPTransportError, .invalidConfiguration("timeouts"))
        }
    }

    func test_urlSessionDelegateRejectsChunkThatExceedsResponseLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DicomJPIPChunkURLProtocol.self]
        let delegate = DicomJPIPURLSessionDelegate(maximumBytes: 4, redirectPolicy: .forbidden)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://pacs.example.test/8")))

        do {
            _ = try await delegate.response(for: request, using: session)
            XCTFail("Expected the oversized response chunk to be rejected")
        } catch let error as DicomJPIPTransportError {
            XCTAssertEqual(error, .responseTooLarge(limit: 4))
        }
    }

    private var providerURL: URL {
        URL(string: "https://pacs.example.test/jpip?target=fixture.jp2")!
    }

    private func request(transferSyntax: DicomTransferSyntax) -> DicomJPIPRequest {
        DicomJPIPRequest(
            pixelDataProviderURL: providerURL,
            resource: .volume,
            transferSyntax: transferSyntax
        )
    }

    private func singleLayerConfiguration() -> DicomJPIPTransportConfiguration {
        DicomJPIPTransportConfiguration(
            defaultLayerCount: 1,
            maximumLayerCount: 4,
            maximumResponseBytes: 1_024,
            maximumTotalBytes: 4_096,
            allowedOrigins: [DicomJPIPOrigin(url: providerURL)!]
        )
    }

    private func response(
        statusCode: Int = 200,
        mediaType: String = "image/jp2",
        body: Data = Data()
    ) -> DicomJPIPHTTPResponse {
        DicomJPIPHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": mediaType],
            body: body
        )
    }

    private func assertNextThrows(
        _ transport: DicomJPIPHTTPTransport,
        request: DicomJPIPRequest,
        expected: DicomJPIPTransportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var iterator = transport.payloads(for: request).makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as DicomJPIPTransportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected DicomJPIPTransportError, got \(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for asynchronous state")
    }
}

private actor DicomJPIPHTTPClientMock: DicomJPIPHTTPClient {
    struct RecordedRequest: Sendable {
        let url: String
        let method: String?
        let accept: String?
        let authorization: String?
        let cacheControl: String?
        let timeout: TimeInterval
        let maximumBytes: Int
        let resourceTimeout: TimeInterval
        let redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy
    }

    private var responses: [DicomJPIPHTTPResponse]
    private let stalls: Bool
    private var requests: [RecordedRequest] = []
    private var cancellations = 0

    init(responses: [DicomJPIPHTTPResponse] = [], stalls: Bool = false) {
        self.responses = responses
        self.stalls = stalls
    }

    func response(
        for request: URLRequest,
        maximumBytes: Int,
        resourceTimeout: TimeInterval,
        redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy
    ) async throws -> DicomJPIPHTTPResponse {
        requests.append(RecordedRequest(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod,
            accept: request.value(forHTTPHeaderField: "Accept"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
            timeout: request.timeoutInterval,
            maximumBytes: maximumBytes,
            resourceTimeout: resourceTimeout,
            redirectPolicy: redirectPolicy
        ))
        if stalls {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancellations += 1
                throw CancellationError()
            }
        }
        guard !responses.isEmpty else {
            throw DicomJPIPHTTPClientMockError.missingResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }

    func cancellationCount() -> Int {
        cancellations
    }
}

private enum DicomJPIPHTTPClientMockError: Error, Sendable {
    case missingResponse
}

private struct StaticDicomJPIPAuthorizationProvider: DicomJPIPAuthorizationProviding {
    let header: String?

    func authorizationHeader(for origin: DicomJPIPOrigin) async throws -> String? {
        header
    }
}

private final class DicomJPIPChunkURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "image/jp2"]
              ) else {
            return
        }
        let byteCount = Int(url.lastPathComponent) ?? 0
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x5A, count: byteCount))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
