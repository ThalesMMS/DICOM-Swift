import DicomCore
import DicomWebHTTP
import Foundation
import HL7v3CDA
import XCTest
@testable import HL7v3Transport

/// Loopback HTTP server built on the existing DicomWebHTTP listener; records every request it received.
final class SOAPTestServer: @unchecked Sendable {
    typealias Behavior = @Sendable (DicomWebHTTPRequest, Data) async -> (Int, [String: String], Data)
    private let lock = NSLock()
    private var requests: [(headers: [String: String], body: Data)] = []
    private var listener: DicomWebHTTPListener!
    var received: [(headers: [String: String], body: Data)] { lock.withLock { requests } }

    init(tls: DicomTLSConfiguration? = nil, behavior: @escaping Behavior) {
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.tls = tls
        configuration.maximumBodyBytes = 4 * 1024 * 1024
        listener = DicomWebHTTPListener(configuration: configuration) { [weak self] request, stream in
            var body = Data()
            do { for try await chunk in stream { body.append(chunk) } } catch { body = Data() }
            if body.isEmpty, let direct = request.body { body = direct }
            self?.lock.withLock { self?.requests.append((request.headers, body)) }
            let (status, headers, data) = await behavior(request, body)
            return .init(statusCode: status, headers: headers, body: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            })
        }
    }

    func start() async throws -> URL { try await listener.start() }
    func stop() async { await listener.stop() }

    static func envelope(_ version: SOAPVersion, _ payload: HL7v3CDA.XMLNode) -> Data {
        (try? SOAPEnvelope(version: version, body: payload).serialize()) ?? Data()
    }
}

final class HL7v3TransportLoopbackTests: XCTestCase {
    private struct FailingTransport: DicomWebHTTPTransport {
        let error: DicomWebhookTransportError
        func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse { throw error }
    }

    func test_restTransportErrors_preserveWhetherRequestWasSent() async throws {
        let url = try XCTUnwrap(URL(string: "https://synthetic.example.test"))
        let beforeSend = try await HL7v3RESTClient(baseURL: url, transport: FailingTransport(error: .beforeSend)).send(.post)
        guard case .rejected(.network, nil) = beforeSend else { return XCTFail("an unsent request must be rejected, not uncertain") }
        for error in [DicomWebhookTransportError.afterBodySent("synthetic"), .unknownProgress("synthetic"), .responseTooLarge] {
            let outcome = try await HL7v3RESTClient(baseURL: url, transport: FailingTransport(error: error)).send(.post)
            guard case .uncertain = outcome else { return XCTFail("a possibly sent request needs reconciliation") }
        }
    }

    private let lab = HL7v3TransportPolicy(timeout: 3, allowInsecureForHosts: ["127.0.0.1"])
    private static func payload() -> HL7v3CDA.XMLNode {
        HL7v3CDA.XMLNode("PRPA_IN201301UV02", children: [HL7v3CDA.XMLNode("id", attributes: ["root": "2.25.2362.2"])])
    }
    private static func ack() -> HL7v3CDA.XMLNode { HL7v3CDA.XMLNode("MCCI_IN000002UV01", children: [HL7v3CDA.XMLNode("acknowledgement")]) }

    func test_soap12_roundTrip_sendsSecurityAndCredentialHeadersAndAcceptsResponse() async throws {
        let server = SOAPTestServer { _, _ in (200, ["Content-Type": "application/soap+xml"], SOAPTestServer.envelope(.v1_2, Self.ack())) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let client = HL7v3SOAPClient(endpoint: url.appendingPathComponent("pix"), version: .v1_2, policy: lab,
                                     security: .init(usernameToken: .init(username: "svc", password: "pw"), timestamp: .init()),
                                     additionalHeaders: { ["Authorization": "Bearer synthetic"] })
        let outcome = try await client.send(Self.payload(), action: "urn:hl7-org:v3:PRPA_IN201301UV02")
        guard case .accepted(let response) = outcome else { return XCTFail("expected accepted, got \(outcome)") }
        XCTAssertEqual(response.envelope.body.name.localName, "MCCI_IN000002UV01")
        XCTAssertEqual(HL7v3RetryAdvice.classify(outcome), .doNotRetry)
        let request = try XCTUnwrap(server.received.first)
        let contentType = request.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
        XCTAssertTrue(contentType.hasPrefix("application/soap+xml"), contentType)
        XCTAssertTrue(contentType.contains("action=\"urn:hl7-org:v3:PRPA_IN201301UV02\""))
        XCTAssertEqual(request.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer synthetic")
        let sent = try SOAPEnvelope.parse(request.body)
        XCTAssertEqual(sent.headerElements.first?.name.localName, "Security")
        XCTAssertEqual(sent.body.first("id")?[attribute: "root"], "2.25.2362.2")
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("pw"), "digest mode never sends the password")
    }

    func test_soap11_faultResponse_isReportedAsFault() async throws {
        let fault = SOAPFault(code: "soap:Server", reason: "synthetic failure").node(version: .v1_1)
        let server = SOAPTestServer { _, _ in (500, ["Content-Type": "text/xml"], SOAPTestServer.envelope(.v1_1, fault)) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let client = HL7v3SOAPClient(endpoint: url, version: .v1_1, policy: lab)
        let outcome = try await client.send(Self.payload(), action: "urn:x")
        guard case .fault(let parsed, let status) = outcome else { return XCTFail("expected fault, got \(outcome)") }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(parsed.code, "soap:Server")
        XCTAssertEqual(server.received.first?.headers.first { $0.key.lowercased() == "soapaction" }?.value, "\"urn:x\"")
        XCTAssertEqual(HL7v3RetryAdvice.classify(outcome), .doNotRetry)
    }

    func test_redirect_isRejectedAndNeverFollowed() async throws {
        let destination = SOAPTestServer { _, _ in (200, [:], SOAPTestServer.envelope(.v1_2, Self.ack())) }
        addTeardownBlock { await destination.stop() }
        let destinationURL = try await destination.start()
        let source = SOAPTestServer { _, _ in (307, ["Location": destinationURL.absoluteString], Data()) }
        addTeardownBlock { await source.stop() }
        let sourceURL = try await source.start()
        let outcome = try await HL7v3SOAPClient(endpoint: sourceURL, policy: lab).send(Self.payload())
        guard case .rejected(.redirectNotAllowed, let status) = outcome else { return XCTFail("expected redirect rejection, got \(outcome)") }
        XCTAssertEqual(status, 307)
        XCTAssertEqual(source.received.count, 1)
        XCTAssertTrue(destination.received.isEmpty)
        XCTAssertEqual(HL7v3RetryAdvice.classify(outcome), .doNotRetry)
    }

    func test_slowPeer_isUncertainAfterBodyWasSent() async throws {
        let server = SOAPTestServer { _, _ in
            try? await Task.sleep(for: .seconds(2))
            return (200, [:], SOAPTestServer.envelope(.v1_2, Self.ack()))
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        var policy = lab
        policy.timeout = 0.4
        let outcome = try await HL7v3SOAPClient(endpoint: url, policy: policy).send(Self.payload())
        guard case .uncertain = outcome else { return XCTFail("expected uncertain, got \(outcome)") }
        XCTAssertEqual(HL7v3RetryAdvice.classify(outcome), .requiresReconciliation)
        XCTAssertEqual(server.received.count, 1)
    }

    func test_oversizedResponse_isUncertainNotAccepted() async throws {
        let big = HL7v3CDA.XMLNode("MCCI_IN000002UV01", children: (0..<200).map { _ in HL7v3CDA.XMLNode("acknowledgement", attributes: ["typeCode": String(repeating: "A", count: 64)]) })
        let server = SOAPTestServer { _, _ in (200, [:], SOAPTestServer.envelope(.v1_2, big)) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        var policy = lab
        policy.maximumResponseBytes = 2048
        let outcome = try await HL7v3SOAPClient(endpoint: url, policy: policy).send(Self.payload())
        guard case .uncertain = outcome else { return XCTFail("expected uncertain, got \(outcome)") }
    }

    func test_malformedOrDTDResponse_isRejectedAsMalformed() async throws {
        let bodies = [Data("<!DOCTYPE x><a/>".utf8), Data("<a/>".utf8), Data("not xml".utf8), Data()]
        let index = LockedCounter()
        let server = SOAPTestServer { _, _ in (200, ["Content-Type": "text/xml"], bodies[index.next() % bodies.count]) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let client = HL7v3SOAPClient(endpoint: url, policy: lab)
        for _ in bodies {
            let outcome = try await client.send(Self.payload())
            guard case .rejected(.malformedResponse, 200) = outcome else { return XCTFail("expected malformed rejection, got \(outcome)") }
        }
    }

    func test_httpErrorWithoutFault_isRejectedWithStatus() async throws {
        let server = SOAPTestServer { _, _ in (503, [:], Data("busy".utf8)) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let outcome = try await HL7v3SOAPClient(endpoint: url, policy: lab).send(Self.payload())
        guard case .rejected(.status, 503) = outcome else { return XCTFail("expected status rejection, got \(outcome)") }
    }

    func test_connectionRefused_isNetworkRejectionSafeToRetry() async throws {
        let server = SOAPTestServer { _, _ in (200, [:], Data()) }
        let url = try await server.start()
        await server.stop()
        let outcome = try await HL7v3SOAPClient(endpoint: url, policy: lab).send(Self.payload())
        guard case .rejected(.network, nil) = outcome else { return XCTFail("expected network rejection, got \(outcome)") }
        XCTAssertEqual(HL7v3RetryAdvice.classify(outcome), .safeToRetry)
    }

    func test_policy_refusesInsecureEndpointAndOversizedRequestBeforeSending() async throws {
        let server = SOAPTestServer { _, _ in (200, [:], SOAPTestServer.envelope(.v1_2, Self.ack())) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        do {
            _ = try await HL7v3SOAPClient(endpoint: url, policy: .init()).send(Self.payload())
            XCTFail("plain http must be refused by the default policy")
        } catch { XCTAssertEqual(error as? HL7v3TransportError, .insecureEndpoint) }
        var small = lab
        small.maximumRequestBytes = 64
        do {
            _ = try await HL7v3SOAPClient(endpoint: url, policy: small).send(Self.payload())
            XCTFail("oversized request must be refused")
        } catch { XCTAssertEqual(error as? HL7v3TransportError, .requestTooLarge) }
        XCTAssertTrue(server.received.isEmpty)
    }

    func test_tls_pinnedRootAcceptsServerAndWrongRootIsRefusedBeforeSend() async throws {
        let material = try HL7v3TLSTestMaterial.write()
        addTeardownBlock { material.remove() }
        let serverTLS = DicomTLSConfiguration(mode: .enabled, material: .init(
            certificatePath: material.serverCertificatePath, privateKeyPath: material.serverPrivateKeyPath),
            securityProfile: .bcp195RFC8996)
        let server = SOAPTestServer(tls: serverTLS) { _, _ in (200, [:], SOAPTestServer.envelope(.v1_2, Self.ack())) }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        XCTAssertEqual(url.scheme, "https")
        for (ca, expectAccepted) in [(material.caCertificatePath, true), (material.wrongCACertificatePath, false)] {
            let policy = HL7v3TransportPolicy(timeout: 3, trust: try .pinnedRoots(pemFileAtPath: ca), serverName: "localhost")
            let outcome = try await HL7v3SOAPClient(endpoint: url, policy: policy).send(Self.payload())
            if expectAccepted {
                guard case .accepted = outcome else { return XCTFail("expected accepted over pinned TLS, got \(outcome)") }
            } else {
                guard case .rejected(.network, nil) = outcome else { return XCTFail("expected trust refusal, got \(outcome)") }
            }
        }
        XCTAssertEqual(server.received.count, 1, "the untrusted handshake never delivered a request")
    }

    func test_rest_postEchoesXMLAndGetWithoutBody() async throws {
        let server = SOAPTestServer { request, body in
            request.method == .get ? (204, [:], Data()) : (200, ["Content-Type": "application/xml"], body)
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let client = HL7v3RESTClient(baseURL: url, policy: lab)
        let posted = try await client.send(.post, path: "Patient", body: Self.payload())
        guard case .accepted(200, _, let node) = posted else { return XCTFail("expected accepted, got \(posted)") }
        XCTAssertEqual(node?.first("id")?[attribute: "root"], "2.25.2362.2")
        let fetched = try await client.send(.get, path: "Patient/1")
        guard case .accepted(204, _, nil) = fetched else { return XCTFail("expected empty accepted, got \(fetched)") }
        XCTAssertEqual(server.received.count, 2)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
