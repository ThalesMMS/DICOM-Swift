import CryptoKit
import DicomCore
import Foundation
import XCTest

@MainActor
final class DicomWebhookDeliveryClientTests: XCTestCase {
    private let url = URL(string: "https://example.test/hook")!
    private var keys: DicomWebhookInMemoryKeyProvider {
        .init(activeKeyID: "test", keys: ["test": SymmetricKey(data: Data("secret".utf8))])
    }
    private func event() throws -> DicomWebhookEvent {
        try .init(eventID: "stable-id", kind: "complete", occurredAt: Date(), subject: .init(), source: "test")
    }
    private func client(_ fake: Fake, policy: DicomWebhookTargetPolicy? = nil) -> DicomWebhookDeliveryClient {
        .init(transport: fake, policy: policy ?? .init(resolve: { _ in ["8.8.8.8"] }), signer: .init(keys: keys))
    }
    func test_statusClasses_andRetryAfter() async throws {
        for status in [200, 201, 204, 299, 301, 307, 400, 401, 403, 404, 405, 410, 413, 415, 422, 408, 425, 429, 500, 503] {
            let fake = Fake([.success(.init(statusCode: status, headers: ["Retry-After": "12"]))])
            let actual = try await client(fake).deliver(event: event(), to: url, idempotencyKey: "same")
            let expected: DicomWebhookDeliveryOutcome
            if (200...299).contains(status) { expected = .delivered(status: status) }
            else if (300...399).contains(status) { expected = .rejected(.redirectNotAllowed) }
            else if [408, 425, 429, 500, 503].contains(status) { expected = .transient(.status(status), retryAfter: 12) }
            else { expected = .rejected(.status(status)) }
            XCTAssertEqual(actual, expected, "\(status)")
        }
    }
    func test_invalidRetryAfter_ignored() async throws {
        for value in ["-1", "NaN", "inf", "tomorrow"] {
            let result = try await client(Fake([.success(.init(statusCode: 429, headers: ["retry-after": value]))]))
                .deliver(event: event(), to: url, idempotencyKey: "same")
            XCTAssertEqual(result, .transient(.status(429), retryAfter: nil))
        }
    }
    func test_transportProgress_classifiesConservatively() async throws {
        let cases: [(DicomWebhookTransportError, DicomWebhookDeliveryOutcome)] = [
            (.beforeSend, .transient(.network, retryAfter: nil)),
            (.afterBodySent("timeout"), .uncertain("timeout")),
            (.unknownProgress("lost"), .uncertain("lost"))
        ]
        for (error, expected) in cases {
            let result = try await client(Fake([.failure(error)])).deliver(event: event(), to: url, idempotencyKey: "same")
            XCTAssertEqual(result, expected)
        }
    }
    func test_headersAndCanonicalBody_validSignature() async throws {
        let fake = Fake([.success(.init(statusCode: 200))])
        let event = try event()
        _ = try await client(fake).deliver(event: event, to: url, idempotencyKey: "stable-key")
        let requests = await fake.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.connectAddress, "8.8.8.8")
        XCTAssertEqual(request.timeout, 15)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["X-Isis-Event-ID"], event.eventID)
        XCTAssertEqual(request.headers["X-Isis-Idempotency-Key"], "stable-key")
        XCTAssertNotNil(request.headers["User-Agent"])
        XCTAssertEqual(request.body, try DicomWebhookCanonicalJSON.encode(event))
        try await DicomWebhookVerifier(keys: keys, nonceCache: .init()).verify(
            header: XCTUnwrap(request.headers["X-Isis-Signature"]), body: XCTUnwrap(request.body))
    }
    func test_responseLimit_uncertainAndNoRetry() async throws {
        let fake = Fake([.success(.init(statusCode: 200, body: Data(repeating: 1, count: 5)))])
        let policy = DicomWebhookTargetPolicy(maxResponseBytes: 4, resolve: { _ in ["8.8.8.8"] })
        let result = try await client(fake, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
        guard case .uncertain = result else { return XCTFail("Expected uncertain") }
        let count = await fake.requests.count
        XCTAssertEqual(count, 1)
    }
    func test_crossOriginRedirect_neverFollowed() async throws {
        let fake = Fake([.success(.init(statusCode: 307, headers: ["Location": "https://other.test"]))])
        let policy = DicomWebhookTargetPolicy(allowRedirects: true, maxRedirects: 3, resolve: { _ in ["8.8.8.8"] })
        let result = try await client(fake, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
        XCTAssertEqual(result, .rejected(.redirectNotAllowed))
        let count = await fake.requests.count
        XCTAssertEqual(count, 1)
    }
    func test_sameOriginOptIn_boundedAndNeverResigned() async throws {
        let fake = Fake([.success(.init(statusCode: 307, headers: ["Location": "/next"])),
                         .success(.init(statusCode: 200))])
        let policy = DicomWebhookTargetPolicy(allowRedirects: true, maxRedirects: 1, resolve: { _ in ["8.8.8.8"] })
        let result = try await client(fake, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
        XCTAssertEqual(result, .delivered(status: 200))
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].headers, requests[1].headers)
        XCTAssertEqual(requests[0].body, requests[1].body)
        XCTAssertEqual(requests[1].url.path, "/next")
    }
    func test_targetRefused_beforeTransport() async throws {
        let fake = Fake([])
        do {
            _ = try await client(fake).deliver(event: event(), to: URL(string: "http://example.test")!, idempotencyKey: "key")
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? DicomWebhookTargetError, .schemeNotAllowed) }
        let count = await fake.requests.count
        XCTAssertEqual(count, 0)
    }
    func test_onlyBeforeSendFailureCanTryAnotherValidatedAddress() async throws {
        let fake = Fake([.failure(.beforeSend), .success(.init(statusCode: 200))])
        let policy = DicomWebhookTargetPolicy(resolve: { _ in ["8.8.8.8", "1.1.1.1"] })
        let result = try await client(fake, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
        XCTAssertEqual(result, .delivered(status: 200))
        let requests = await fake.requests
        XCTAssertEqual(requests.map(\.connectAddress), ["8.8.8.8", "1.1.1.1"])
        XCTAssertEqual(requests.first?.headers[DicomWebhookSignatureHeader.headerName],
                       requests.last?.headers[DicomWebhookSignatureHeader.headerName])
        let uncertain = Fake([.failure(.unknownProgress("partial write")), .success(.init(statusCode: 200))])
        let ambiguous = try await client(uncertain, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
        XCTAssertEqual(ambiguous, .uncertain("partial write"))
        let attempts = await uncertain.requests.count
        XCTAssertEqual(attempts, 1)
    }

    func test_redirectRevalidatesDNSBeforeSecondSend() async throws {
        let resolver = WebhookRebindingResolver()
        let fake = Fake([.success(.init(statusCode: 307, headers: ["Location": "/next"]))])
        let policy = DicomWebhookTargetPolicy(allowRedirects: true, maxRedirects: 1, resolve: { _ in resolver.next() })
        do {
            _ = try await client(fake, policy: policy).deliver(event: event(), to: url, idempotencyKey: "same")
            XCTFail("Expected newly private address to be rejected")
        } catch { XCTAssertEqual(error as? DicomWebhookTargetError, .addressNotAllowed("10.0.0.1")) }
        let requests = await fake.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.connectAddress, "8.8.8.8")
    }

    private actor Fake: DicomWebHTTPTransport {
        let results: [Result<DicomWebHTTPResponse, DicomWebhookTransportError>]
        var requests = [DicomWebHTTPRequest]()
        init(_ results: [Result<DicomWebHTTPResponse, DicomWebhookTransportError>]) { self.results = results }
        func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
            let index = requests.count
            requests.append(request)
            guard index < results.count else { throw DicomWebhookTransportError.beforeSend }
            return try results[index].get()
        }
    }
}

private final class WebhookRebindingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> [String] {
        lock.withLock { calls += 1; return calls == 1 ? ["8.8.8.8"] : ["10.0.0.1"] }
    }
}
