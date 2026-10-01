import DicomCore
import DicomWebHTTP
import Foundation
import HL7v3Transport
import XCTest
@testable import FHIR

/// In-process HTTP behaviours the Python server does not simulate: redirects, slow peers,
/// oversized responses, insecure endpoints and XML negotiation.
final class FHIRClientBehaviorTests: XCTestCase {
    func test_serverFailures_areUncertainOnlyForWrites() async throws {
        for status in [400, 401, 403, 409, 412, 500, 503, 599] {
            let outcome = Data(#"{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"processing"}]}"#.utf8)
            let server = StubServer { _, _ in (status, ["Content-Type": "application/fhir+json"], outcome) }
            addTeardownBlock { await server.stop() }
            let url = try await server.start()
            let write = try await client(url).update(FHIRPatient(id: "x").resource)
            let read = try await client(url).read("Patient", id: "x")
            XCTAssertEqual(write.failure?.uncertain, status >= 500, "\(status)")
            XCTAssertEqual(read.failure?.uncertain, false, "\(status)")
            XCTAssertEqual(write.failure?.status, status)
            XCTAssertEqual(write.failure?.message, "HTTP \(status)")
            XCTAssertNotNil(write.failure?.outcome)
        }
    }

    func test_collectionPageLimit_doesNotSendAnExtraRequest() async throws {
        let server = StubServer { _, _ in
            (200, ["Content-Type": "application/fhir+json"], Data(#"{"resourceType":"Bundle","type":"searchset","link":[{"relation":"next","url":"Patient?page=2"}]}"#.utf8))
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let configuration = FHIRClientConfiguration(baseURL: url, policy: .init(allowInsecureForHosts: ["127.0.0.1"]), maxPages: 1)
        let result = try await FHIRClient(configuration: configuration).collect(FHIRSearchQuery(resourceType: "Patient"))
        XCTAssertEqual(result.failure?.reason, .pageLimit)
        XCTAssertEqual(server.received.count, 1)
    }

    final class StubServer: @unchecked Sendable {
        typealias Behavior = @Sendable (DicomWebHTTPRequest, Data) async -> (Int, [String: String], Data)
        private let lock = NSLock()
        private var requests: [(method: String, path: String, headers: [String: String], body: Data)] = []
        private var listener: DicomWebHTTPListener!
        var received: [(method: String, path: String, headers: [String: String], body: Data)] { lock.withLock { requests } }

        init(behavior: @escaping Behavior) {
            listener = DicomWebHTTPListener(configuration: .init()) { [weak self] request, stream in
                var body = Data()
                do { for try await chunk in stream { body.append(chunk) } } catch { body = Data() }
                if body.isEmpty, let direct = request.body { body = direct }
                self?.lock.withLock { self?.requests.append((request.method.rawValue, request.url.path, request.headers, body)) }
                let (status, headers, data) = await behavior(request, body)
                return .init(statusCode: status, headers: headers, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
            }
        }
        func start() async throws -> URL { try await listener.start() }
        func stop() async { await listener.stop() }
    }

    private func client(_ url: URL, timeout: TimeInterval = 3, maxResponse: Int = 16 * 1024 * 1024, format: FHIRWireFormat = .json) -> FHIRClient {
        var configuration = FHIRClientConfiguration(baseURL: url, policy: .init(timeout: timeout, maximumResponseBytes: maxResponse, allowInsecureForHosts: ["127.0.0.1"]))
        configuration.format = format
        return FHIRClient(configuration: configuration)
    }

    func test_redirect_isRejectedAndNotFollowed() async throws {
        let destination = StubServer { _, _ in (200, [:], try! FHIRFixtures.resource("patient-example").jsonData()) }
        let destinationURL = try await destination.start()
        let source = StubServer { _, _ in (302, ["Location": destinationURL.absoluteString + "/Patient/example"], Data()) }
        let sourceURL = try await source.start()
        defer { Task { await source.stop(); await destination.stop() } }
        let result = try await client(sourceURL).read("Patient", id: "example")
        XCTAssertEqual(result.failure?.reason, .redirectNotAllowed)
        XCTAssertEqual(result.failure?.status, 302)
        XCTAssertTrue(destination.received.isEmpty)
    }

    func test_slowWrite_isUncertainButSlowReadIsNot() async throws {
        let server = StubServer { _, _ in
            try? await Task.sleep(for: .seconds(2))
            return (200, [:], Data())
        }
        let url = try await server.start()
        defer { Task { await server.stop() } }
        let slow = client(url, timeout: 0.4)
        let write = try await slow.update(FHIRPatient(id: "x").resource)
        XCTAssertEqual(write.failure?.reason, .network)
        XCTAssertEqual(write.failure?.uncertain, true)
        let read = try await slow.read("Patient", id: "x")
        XCTAssertEqual(read.failure?.reason, .network)
        XCTAssertEqual(read.failure?.uncertain, false, "reads are safe to repeat")
    }

    func test_oversizedResponse_isBoundedAndMalformedBodiesAreReported() async throws {
        let huge = Data(repeating: UInt8(ascii: "a"), count: 200_000)
        let server = StubServer { request, _ in
            request.url.path.hasSuffix("/big") ? (200, ["Content-Type": "application/fhir+json"], huge) : (200, ["Content-Type": "application/fhir+json"], Data("{\"resourceType\":\"Patient\",\"id\":\"x\"".utf8))
        }
        let url = try await server.start()
        defer { Task { await server.stop() } }
        let bounded = client(url, maxResponse: 64 * 1024)
        let big = try await bounded.read("Patient", id: "big")
        XCTAssertEqual(big.failure?.reason, .responseTooLarge)
        let truncated = try await bounded.read("Patient", id: "x")
        XCTAssertEqual(truncated.failure?.reason, .malformedResponse)
        let fetched = try await bounded.fetch(url: url.appendingPathComponent("Binary/x"))
        XCTAssertNotNil(fetched.value)
        let foreign = try await bounded.fetch(url: URL(string: "http://127.0.0.1:1/x")!)
        XCTAssertEqual(foreign.failure?.reason, .originNotAllowed)
    }

    func test_policy_refusesPlainHTTPUnlessAllowed_andXMLNegotiation() async throws {
        let server = StubServer { request, body in
            let accept = request.headers.first { $0.key.lowercased() == "accept" }?.value ?? ""
            let resource = (try? FHIRResource(xmlData: body)) ?? FHIRFixtures.own(name: "primitive-extensions")
            let xml = try! resource.xmlData()
            return accept.contains("xml") ? (200, ["Content-Type": "application/fhir+xml"], xml) : (415, [:], Data())
        }
        let url = try await server.start()
        defer { Task { await server.stop() } }
        let insecure = FHIRClient(baseURL: url)
        let refusedPlainHTTP = try await insecure.read("Patient", id: "x")
        XCTAssertEqual(refusedPlainHTTP.failure?.reason, .invalidRequest)
        let xmlClient = client(url, format: .xml)
        let patient = try FHIRFixtures.own("primitive-extensions")
        let updated = try await xmlClient.update(patient).get()
        XCTAssertEqual(updated?.as(FHIRPatient.self)?.names.first?.given, ["Alpha", "Beta"])
        let sent = try XCTUnwrap(server.received.first)
        XCTAssertTrue(sent.headers.first { $0.key.lowercased() == "content-type" }?.value.hasPrefix("application/fhir+xml") ?? false)
        XCTAssertTrue(String(decoding: sent.body, as: UTF8.self).hasPrefix("<Patient xmlns=\"http://hl7.org/fhir\""))
        XCTAssertEqual(sent.headers.first { $0.key.lowercased() == "prefer" }?.value, "return=representation")
    }
}

private extension FHIRFixtures {
    static func own(name: String) -> FHIRResource { (try? own(name)) ?? FHIRResource(resourceType: "Patient") }
}
