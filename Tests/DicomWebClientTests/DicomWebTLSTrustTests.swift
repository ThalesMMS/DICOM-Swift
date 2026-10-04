import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import DicomWebClient

/// Server trust beyond the system's, and a client certificate for servers that require one, against local TLS
/// servers whose certificates are made for each run and never stored.
final class DicomWebTLSTrustTests: XCTestCase {
    private var directory: URL!
    private var serverIdentity: SecIdentity!
    private var serverCertificate: SecCertificate!
    private var clientIdentity: SecIdentity!
    private var clientCertificate: SecCertificate!
    private var servers: [TLSTestServer] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DicomWebTLSTrustTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (serverIdentity, serverCertificate) = try makeIdentity(name: "server", subject: "/CN=127.0.0.1",
                                                               extensions: ["subjectAltName=IP:127.0.0.1",
                                                                            "extendedKeyUsage=serverAuth"])
        (clientIdentity, clientCertificate) = try makeIdentity(name: "client", subject: "/CN=DICOMweb test client",
                                                               extensions: ["extendedKeyUsage=clientAuth"])
    }

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func test_selfSignedServer_failsByDefault_connectsWithItsFingerprint_andFailsWithAnother() async throws {
        let base = try await start(TLSTestServer(identity: serverIdentity, requiresClientCertificate: false))
        // One transport for every choice: a connection opened under one trust never carries a request of another.
        let transport = URLSessionDicomWebHTTPTransport(session: URLSession(configuration: .ephemeral))
        func search(_ trust: DicomWebServerTrust) async throws {
            var configuration = DicomWebClientConfiguration(baseURL: base, timeout: 10)
            configuration.serverTrust = trust
            _ = try await DicomWebClient(configuration: configuration, transport: transport)
                .search(parameters: .init(level: .study))
        }

        await assertFails(with: .serverCertificateUntrusted) { try await search(.system) }
        try await search(.leafCertificateSHA256(digest(of: serverCertificate)))
        await assertFails(with: .serverCertificateUntrusted) {
            try await search(.leafCertificateSHA256(self.digest(of: self.clientCertificate)))
        }
        try await search(.anchors([serverCertificate]))
        await assertFails(with: .serverCertificateUntrusted) { try await search(.anchors([self.clientCertificate])) }
    }

    func test_pinnedCertificate_keepsTheHostNameCheck() async throws {
        let base = try await start(TLSTestServer(identity: serverIdentity, requiresClientCertificate: false))
        var components = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
        components.host = "localhost" // not in the certificate, which names 127.0.0.1 only
        var configuration = DicomWebClientConfiguration(baseURL: try XCTUnwrap(components.url), timeout: 10)
        configuration.serverTrust = .leafCertificateSHA256(digest(of: serverCertificate))
        let client = DicomWebClient(configuration: configuration,
                                    transport: URLSessionDicomWebHTTPTransport(session: URLSession(configuration: .ephemeral)))
        await assertFails(with: .serverCertificateUntrusted) { _ = try await client.search(parameters: .init(level: .study)) }
    }

    func test_serverRequiringClientCertificate_connectsWithTheIdentity_andWithoutItFailsClearly() async throws {
        let server = TLSTestServer(identity: serverIdentity, requiresClientCertificate: true)
        let base = try await start(server)
        let transport = URLSessionDicomWebHTTPTransport(session: URLSession(configuration: .ephemeral))
        var configuration = DicomWebClientConfiguration(baseURL: base, timeout: 10)
        configuration.serverTrust = .leafCertificateSHA256(digest(of: serverCertificate))

        await assertFails(with: .clientCertificateRequired) {
            _ = try await DicomWebClient(configuration: configuration, transport: transport)
                .search(parameters: .init(level: .study))
        }
        XCTAssertEqual(server.searchCount, 0)

        configuration.clientIdentity = .init(identity: clientIdentity)
        _ = try await DicomWebClient(configuration: configuration, transport: transport)
            .search(parameters: .init(level: .study))
        XCTAssertEqual(server.searchCount, 1)
        XCTAssertEqual(server.clientCertificates, [SecCertificateCopyData(clientCertificate) as Data])
    }

    func test_identityAndCredentialsNeverReachAnotherOrigin() async throws {
        let configured = TLSTestServer(identity: serverIdentity, requiresClientCertificate: true)
        let mutualForeign = TLSTestServer(identity: serverIdentity, requiresClientCertificate: true)
        let plainForeign = TLSTestServer(identity: serverIdentity, requiresClientCertificate: false)
        let base = try await start(configured)
        let mutualForeignURL = try await start(mutualForeign)
        let plainForeignURL = try await start(plainForeign)
        var configuration = DicomWebClientConfiguration(baseURL: base, headers: ["Authorization": "Bearer node-secret"],
                                                        timeout: 10,
                                                        allowedBulkDataOrigins: [mutualForeignURL, plainForeignURL])
        configuration.serverTrust = .leafCertificateSHA256(digest(of: serverCertificate))
        configuration.clientIdentity = .init(identity: clientIdentity)
        let client = DicomWebClient(configuration: configuration,
                                    transport: URLSessionDicomWebHTTPTransport(session: URLSession(configuration: .ephemeral)))

        _ = try await client.search(parameters: .init(level: .study))
        XCTAssertEqual(configured.clientCertificates.count, 1)
        XCTAssertTrue(configured.requestHeads.allSatisfy { $0.contains("Bearer node-secret") })

        // Another origin the policy allows: trusted the same way, but never sent the certificate or the header.
        await assertFails(with: .clientCertificateRequired) {
            _ = try await client.retrieveBulkData(uri: mutualForeignURL.appendingPathComponent("bulk/1").absoluteString)
        }
        XCTAssertEqual(mutualForeign.clientCertificates, [])
        XCTAssertEqual(mutualForeign.requestHeads, [])

        _ = try await client.retrieveBulkData(uri: plainForeignURL.appendingPathComponent("bulk/1").absoluteString)
        XCTAssertEqual(plainForeign.requestHeads.count, 1)
        XCTAssertFalse(plainForeign.requestHeads.contains { $0.lowercased().contains("authorization") })
    }

    // MARK: - Helpers

    private func start(_ server: TLSTestServer) async throws -> URL {
        servers.append(server)
        return try await server.start()
    }

    private func digest(of certificate: SecCertificate) -> Data {
        Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    private func assertFails(with code: URLError.Code, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("The request succeeded", file: file, line: line)
        } catch let error as URLError {
            XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    /// A self-signed certificate and its key, made with openssl in the test's own folder and imported in memory.
    private func makeIdentity(name: String, subject: String,
                              extensions: [String]) throws -> (SecIdentity, SecCertificate) {
        let key = directory.appendingPathComponent("\(name)-key.pem")
        let certificate = directory.appendingPathComponent("\(name).pem")
        let bundle = directory.appendingPathComponent("\(name).p12")
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", subject,
                 "-addext", "basicConstraints=critical,CA:FALSE"]
                + extensions.flatMap { ["-addext", $0] } + ["-keyout", key.path, "-out", certificate.path])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out", bundle.path,
                 "-passout", "pass:dicomweb-test"])
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: "dicomweb-test",
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: bundle) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let identity = value as! SecIdentity
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
        }
        return (identity, leaf)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: String(decoding: output, as: UTF8.self), code: Int(process.terminationStatus))
        }
    }
}

/// An HTTPS server on 127.0.0.1 that answers every search with an empty result and every other request with two
/// bytes, recording the request heads and the client certificates it was given.
private final class TLSTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var heads: [String] = []
    private let received: ReceivedCertificates

    var requestHeads: [String] { lock.withLock { heads } }
    var searchCount: Int { lock.withLock { heads.filter { $0.contains("/studies") }.count } }
    var clientCertificates: [Data] { received.all }

    init(identity: SecIdentity, requiresClientCertificate: Bool) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        let received = ReceivedCertificates()
        let queue = DispatchQueue(label: "DicomWebTLSTrustTests.server")
        if requiresClientCertificate {
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            // Any certificate is accepted: the tests check which one arrived, not its chain.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
                    as? [SecCertificate] ?? []
                if let leaf = chain.first { received.append(SecCertificateCopyData(leaf) as Data) }
                complete(!chain.isEmpty)
            }, queue)
        }
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
        self.received = received
        self.queue = queue
    }

    func start() async throws -> URL {
        let ready = AsyncThrowingStream<UInt16, any Error>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port { ready.continuation.yield(port.rawValue); ready.continuation.finish() }
            case .failed(let error): ready.continuation.finish(throwing: error)
            case .cancelled: ready.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            readRequest(on: connection, received: Data())
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        return URL(string: "https://127.0.0.1:\(try XCTUnwrap(next))/dicom-web")!
    }

    func stop() {
        listener.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }

    /// Reads one request head (these requests have no body) and answers it.
    private func readRequest(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            var received = received
            if let data { received.append(data) }
            guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete, error == nil { readRequest(on: connection, received: received) }
                return
            }
            let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
            lock.withLock { heads.append(head) }
            let answer = head.contains("/studies")
                ? "HTTP/1.1 200 OK\r\nContent-Type: application/dicom+json\r\nContent-Length: 2\r\n\r\n[]"
                : "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 2\r\n\r\nok"
            connection.send(content: Data(answer.utf8), completion: .contentProcessed { [self] error in
                if error == nil { readRequest(on: connection, received: Data()) }
            })
        }
    }
}

/// The client certificates a server's TLS handshakes received.
private final class ReceivedCertificates: @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [Data] = []

    var all: [Data] { lock.withLock { certificates } }

    func append(_ certificate: Data) {
        lock.withLock { certificates.append(certificate) }
    }
}
