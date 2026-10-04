import XCTest
import Darwin
import Foundation
import DicomCore
@testable import DicomWebHTTP

final class DicomWebHTTPListenerTests: XCTestCase {
    func test_loopbackOnly_rejectsConflictingBindAddress() async throws {
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.bindAddress = "0.0.0.0"
        let listener = DicomWebHTTPListener(configuration: configuration) { _, _ in
            .init(statusCode: 200, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
        do { _ = try await listener.start(); XCTFail("Conflicting non-loopback bind was accepted") }
        catch { XCTAssertEqual((error as? HTTPFailure)?.status, 400) }
        await listener.stop()
    }

    func test_fixedPort_startsOnLoopback() async throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return XCTFail("socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        close(socket)
        guard bound else { return XCTFail("could not reserve a port") }
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.port = UInt16(bigEndian: address.sin_port)
        let listener = DicomWebHTTPListener(server: DicomWebServer(), configuration: configuration)
        let root = try await listener.start()
        XCTAssertEqual(root.port, Int(configuration.port))
        let (_, response) = try await URLSession.shared.data(from: root.appendingPathComponent("dicom-web/studies"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await listener.stop()
    }

    func test_ephemeralPort_remainsBoundToLoopback() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nc") else { throw XCTSkip("nc absent") }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return XCTFail("getifaddrs failed") }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        var address: String?
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let value = current.pointee.ifa_addr, value.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(value, socklen_t(value.pointee.sa_len), &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST) == 0 { address = String(cString: buffer); break }
        }
        guard let address else { throw XCTSkip("No local non-loopback IPv4 interface for the negative probe") }
        let listener = DicomWebHTTPListener(server: DicomWebServer())
        let root = try await listener.start()
        do {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            probe.arguments = ["-z", "-w", "1", address, String(try XCTUnwrap(root.port))]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try probe.run(); probe.waitUntilExit()
            XCTAssertNotEqual(probe.terminationStatus, 0, "Loopback listener accepted a non-loopback connection")
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_loopback_searchAndCapabilities() async throws {
        let listener = DicomWebHTTPListener(server: DicomWebServer())
        let root = try await listener.start()
        do {
            let (body, response) = try await URLSession.shared.data(from: root.appendingPathComponent("dicom-web/studies"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: body, encoding: .utf8), "[]")
            let (_, capabilities) = try await URLSession.shared.data(from: root.appendingPathComponent("dicom-web"))
            XCTAssertEqual((capabilities as? HTTPURLResponse)?.statusCode, 200)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}

extension DicomWebHTTPListenerTests {
    func test_URLSession_chunkedSTOWAndLimits() async throws {
        let fixture = try Self.fixture()
        let bytes = Self.multipart(fixture.part10Data)
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.maximumHeaderBytes = 1024
        configuration.maximumBodyBytes = bytes.count + 10
        let store = DicomWebInMemoryStorage()
        let listener = DicomWebHTTPListener(server: .init(store: store), configuration: configuration)
        let root = try await listener.start()
        do {
            var request = URLRequest(url: root.appendingPathComponent("dicom-web/studies"))
            request.httpMethod = "POST"
            request.setValue(Self.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBodyStream = InputStream(data: bytes)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(store.allInstances().first?.part10Data, fixture.part10Data)
            request.httpBodyStream = nil
            request.httpBody = Data(repeating: 0, count: configuration.maximumBodyBytes + 1)
            let (_, excessive) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((excessive as? HTTPURLResponse)?.statusCode, 413)
            request.httpBody = nil
            request.httpBodyStream = InputStream(data: Data(repeating: 0, count: configuration.maximumBodyBytes + 1))
            let (_, excessiveChunked) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((excessiveChunked as? HTTPURLResponse)?.statusCode, 413)
            var headers = URLRequest(url: root.appendingPathComponent("dicom-web/studies"))
            headers.setValue(String(repeating: "a", count: 2048), forHTTPHeaderField: "X-Large")
            let (_, largeHeader) = try await URLSession.shared.data(for: headers)
            XCTAssertEqual((largeHeader as? HTTPURLResponse)?.statusCode, 431)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_curl_chunkedSTOWAndUnsupportedMIME() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else { throw XCTSkip("curl absent") }
        let store = DicomWebInMemoryStorage()
        let listener = DicomWebHTTPListener(server: .init(store: store))
        let fixture = try Self.fixture()
        let root = try await listener.start()
        do {
            let output = try await Self.curl(url: root.appendingPathComponent("dicom-web/studies"), type: Self.contentType, body: Self.multipart(fixture.part10Data))
            XCTAssertTrue(output.hasSuffix("200"), output)
            XCTAssertEqual(store.allInstances().first?.part10Data, fixture.part10Data)
            let malformed = Data("--test-boundary\r\nContent-Type: image/not-dicom\r\n\r\nwrong\r\n--test-boundary--\r\n".utf8)
            let failure = try await Self.curl(url: root.appendingPathComponent("dicom-web/studies"), type: Self.contentType, body: malformed)
            XCTAssertTrue(failure.hasSuffix("415"), failure)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_TLS_generatedSelfSignedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem"), cert = directory.appendingPathComponent("cert.pem"), p12 = directory.appendingPathComponent("identity.p12")
        try Self.command("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
            "-keyout", key.path, "-out", cert.path])
        try Self.command("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:dicomweb-test"])
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.tls = .init(mode: .enabled, material: .init(pkcs12Data: try Data(contentsOf: p12), pkcs12Password: "dicomweb-test"))
        let listener = DicomWebHTTPListener(server: DicomWebServer(), configuration: configuration)
        let root = try await listener.start()
        let delegate = DicomWebTestTrustDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        do {
            let (_, response) = try await session.data(from: root.appendingPathComponent("dicom-web/studies"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            var pinned = DicomWebHTTPRequest(method: .post, url: root, body: Data("test".utf8), timeout: 3)
            pinned.connectAddress = "127.0.0.1"
            do {
                _ = try await DicomWebhookURLSessionTransport().send(pinned)
                XCTFail("A pinned connection must still reject an untrusted TLS identity")
            } catch DicomWebhookTransportError.beforeSend {}
        } catch { session.invalidateAndCancel(); await listener.stop(); throw error }
        session.invalidateAndCancel()
        await listener.stop()
    }

    func test_disconnect_cancelsResponseProducer() async throws {
        let cancelled = DicomWebTestSignal()
        let started = DicomWebTestSignal()
        let listener = DicomWebHTTPListener { _, _ in
            .init(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: AsyncThrowingStream(unfolding: {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                    return Data(repeating: 0, count: 1024 * 1024)
                } catch { throw error }
            }), cancel: { cancelled.resolve(true) })
        }
        let root = try await listener.start()
        let delegate = DicomWebDisconnectDelegate(started: started)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: root)
        task.resume()
        let didStart = await started.wait(timeout: .seconds(2))
        XCTAssertTrue(didStart, "Response did not start within 2 seconds")
        let didCancel = await cancelled.wait(timeout: .seconds(3))
        XCTAssertTrue(didCancel, "Disconnect did not cancel the response producer within 3 seconds")
        session.invalidateAndCancel()
        await listener.stop()
    }

    private static let contentType = "multipart/related; type=\"application/dicom\"; boundary=test-boundary"
    private static func multipart(_ data: Data) -> Data {
        Data("--test-boundary\r\nContent-Type: application/dicom\r\n\r\n".utf8) + data + Data("\r\n--test-boundary--\r\n".utf8)
    }
    private static func fixture() throws -> DicomWebStoredInstance {
        let set = DicomDataSet(elements: [
            .init(tag: 0x00100010, vr: .PN, value: .strings(["NETWORK^SYNTHETIC"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.51"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.52"])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.53"]))
        ])
        return try DicomWebInMemoryStorage().add(dataSet: set)
    }
    private static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: String(decoding: data, as: UTF8.self), code: Int(process.terminationStatus)) }
    }
    private static func curl(url: URL, type: String, body: Data) async throws -> String {
        try await Task.detached {
            let traceURL = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-curl-\(UUID().uuidString).trace")
            defer { try? FileManager.default.removeItem(at: traceURL) }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["--silent", "--show-error", "--http1.1", "--max-time", "10", "--request", "POST", "--upload-file", "-",
                "--trace-ascii", traceURL.path, "--header", "Transfer-Encoding: chunked", "--header", "Expect:", "--header", "Content-Type: \(type)", "--write-out", "%{http_code}", url.absoluteString]
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            // Boundary and header bytes are delivered through independent writes.
            for offset in stride(from: 0, to: body.count, by: 7) {
                do { try input.fileHandleForWriting.write(contentsOf: Data(body.dropFirst(offset).prefix(7))) }
                catch { break } // curl may stop reading as soon as the server rejects a MIME part.
                try await Task.sleep(for: .milliseconds(5))
            }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let trace = try String(contentsOf: traceURL, encoding: .utf8)
            XCTAssertTrue(trace.contains("0000: 7"), "curl must emit a seven-byte HTTP chunk, splitting the MIME boundary: \(trace)")
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

private final class DicomWebTestTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }
}

extension DicomWebHTTPListenerTests {
    func test_URLSession_reusesHTTP11Connection() async throws {
        let listener = DicomWebHTTPListener(server: .init())
        let root = try await listener.start()
        let delegate = DicomWebConnectionMetrics()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        do {
            for _ in 0..<2 {
                let (_, response) = try await session.data(from: root.appendingPathComponent("dicom-web/studies"))
                XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Connection"), "keep-alive")
            }
            XCTAssertTrue(delegate.reused)
        } catch { session.invalidateAndCancel(); await listener.stop(); throw error }
        session.invalidateAndCancel()
        await listener.stop()
    }
}

private final class DicomWebConnectionMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didReuse = false
    var reused: Bool { lock.withLock { didReuse } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { didReuse = didReuse || metrics.transactionMetrics.contains { $0.isReusedConnection } }
    }
}

private final class DicomWebDisconnectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let started: DicomWebTestSignal
    private var cancelled = false
    init(started: DicomWebTestSignal) { self.started = started }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        cancelled = true
        started.resolve(true)
        dataTask.cancel()
    }
}

/// Stores an early result and ignores duplicate or late callbacks, including after timeout.
private final class DicomWebTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func resolve(_ result: Bool) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
            let saved = continuation
            continuation = nil
            saved?.resume(returning: result)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            resolve(false)
        }
        let result: Bool = await withCheckedContinuation { continuation in
            lock.withLock {
                if let result = self.result { continuation.resume(returning: result) }
                else { self.continuation = continuation }
            }
        }
        timer.cancel()
        await timer.value
        return result
    }
}

extension DicomWebHTTPListenerTests {
    func test_webSocket_upgradePingAndStopCloses1001() async throws {
        let server = DicomWebServer(unifiedProcedureSteps: .init(store: DicomInMemoryUnifiedProcedureStepStore()), notifications: .init())
        let listener = DicomWebHTTPListener(server: server)
        let root = try await listener.start()
        var components = URLComponents(url: root.appendingPathComponent("dicom-web/subscribers/TEST"), resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("dicom", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("application/dicom+json", forHTTPHeaderField: "Content-Type")
        request.setValue(root.absoluteString, forHTTPHeaderField: "Origin")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let receive = Task { try? await socket.receive() }
            await listener.stop()
            _ = await receive.value
            XCTAssertEqual(socket.closeCode, .goingAway)
        } catch { socket.cancel(with: .goingAway, reason: nil); await listener.stop(); throw error }
    }
}
