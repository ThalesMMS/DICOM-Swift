import Foundation
import XCTest
import DicomWebHTTP
@testable import DicomCore

final class DicomJPIPLoopbackTests: XCTestCase {
    func test_A1EveryLayerROIStreamAndCacheNegotiation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaries = environment["DICOM_JPIP_OPENJPIP_BIN"] else {
            if environment["DICOM_REQUIRE_OPENJPIP"] == "1" {
                XCTFail("DICOM_REQUIRE_OPENJPIP=1 requires DICOM_JPIP_OPENJPIP_BIN")
                return
            }
            throw XCTSkip("DICOM_JPIP_OPENJPIP_BIN is unset")
        }
        let server = try DicomJPIPServerTests.server()
        let listener = DicomWebHTTPListener { request, _ in await server.handle(request) }
        let root = try await listener.start()
        do {
            let endpoint = URL(string: root.absoluteString + "/jpip?target=test")!
            let transport = try DicomJPIPHTTPTransport(configuration: .init(allowsInsecureHTTP: true,
                allowedResponseMediaTypes: ["image/jpp-stream", "image/jpt-stream"],
                allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: endpoint))]))
            let source = try DicomJPIPCodestreamIndexerTests.source()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-a2-loopback-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("source.j2k"); try source.write(to: sourceURL)
            let old = URL(fileURLWithPath: binaries)
            let modern = old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("openjpip/build/bin/opj_decompress")
            for channel in [false, true] {
                let session = DicomJPIPSession(usesHTTPChannel: channel)
                for layer in 1...3 {
                    let request = DicomJPIPRequest(pixelDataProviderURL: endpoint, resource: .volume,
                        window: try .init(layers: layer), session: session)
                    var output: Data?
                    for try await payload in transport.payloads(for: request) { output = payload.data }
                    let data = try XCTUnwrap(output)
                    let file = directory.appendingPathComponent("layer\(layer).j2k"); try data.write(to: file)
                    let decoded = directory.appendingPathComponent("layer\(layer).ppm")
                    let golden = directory.appendingPathComponent("golden\(layer).ppm")
                    _ = try await DicomJPIPServerIndependentTests.run(modern, ["-i", file.path, "-o", decoded.path])
                    _ = try await DicomJPIPServerIndependentTests.run(modern, ["-i", sourceURL.path, "-o", golden.path, "-l", String(layer)])
                    let expected = Data(try Data(contentsOf: golden).suffix(64 * 64 * 3))
                    XCTAssertEqual(Data(try Data(contentsOf: decoded).suffix(64 * 64 * 3)), expected)
                    XCTAssertEqual(try DicomJPEG2000Codec.decode(data).bytes, expected)
                }
                let cache = await session.cache
                XCTAssertEqual(cache.redundantBytes, 0)
                XCTAssertGreaterThan(cache.usefulBytes, 0)
                try await session.end()
            }
            for stream in [1, 2, 3] {
                let window = try DicomJPIPWindow(fsiz: .init(64, 64), rsiz: .init(32, 32), roff: .init(16, 16), stream: stream, layers: 3)
                let request = DicomJPIPRequest(pixelDataProviderURL: endpoint, resource: .frame(index: stream - 1), window: window)
                for try await payload in transport.payloads(for: request) {
                    let actual = try DicomJPEG2000Codec.decode(payload.data).bytes
                    let expected = try DicomJPEG2000Codec.decode(source).bytes
                    for y in 16..<48 {
                        XCTAssertEqual(actual[y * 64 * 3 + 48..<y * 64 * 3 + 144], expected[y * 64 * 3 + 48..<y * 64 * 3 + 144])
                    }
                }
            }
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func test_interruptedSession_reconnectWithExplicitModel() async throws {
        let server = try DicomJPIPServerTests.server()
        let response = await server.handle(DicomJPIPServerTests.request("target=test&cnew=http"))
        let cid = try XCTUnwrap(response.headers["JPIP-cnew"]?.split(separator: ",").first?.dropFirst(4))
        var iterator = response.body.makeAsyncIterator(), parser = DicomJPIPMessageParser(), cache = DicomJPIPDatabinCache()
        for _ in 0..<8 {
            if let data = try await iterator.next() { for message in try parser.feed(data) { try cache.insert(message) } }
        }
        response.cancel()
        let reconnect = await server.handle(DicomJPIPServerTests.request("cid=\(cid)"))
        let (_, messages, reason) = try await DicomJPIPServerTests.collect(reconnect)
        for message in messages { try cache.insert(message) }
        XCTAssertEqual(reason, 1); XCTAssertEqual(cache.redundantBytes, 0)
        let reconstructed = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
        XCTAssertEqual(try DicomJPEG2000Codec.decode(reconstructed.data).bytes,
                       try DicomJPEG2000Codec.decode(DicomJPIPCodestreamIndexerTests.source()).bytes)
    }
}

extension DicomJPIPLoopbackTests {
    func test_socketInterruption_A1ReconnectPreservesPixels() async throws {
        let server = try DicomJPIPServerTests.server()
        let listener = DicomWebHTTPListener { request, _ in
            let response = await server.handle(request)
            guard response.headers["JPIP-cnew"] != nil else { return response }
            return DicomWebHTTPStreamedResponse(statusCode: response.statusCode, headers: response.headers,
                body: AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            var count = 0
                            for try await chunk in response.body {
                                continuation.yield(chunk); count += 1
                                if count == 8 { throw URLError(.networkConnectionLost) }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            continuation.finish()
                        } catch { response.cancel(); continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                })
        }
        let root = try await listener.start()
        do {
            let endpoint = URL(string: root.absoluteString + "/jpip?target=test")!
            let session = DicomJPIPSession()
            let transport = try DicomJPIPHTTPTransport(configuration: .init(allowsInsecureHTTP: true,
                allowedResponseMediaTypes: ["image/jpp-stream"], allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: endpoint))]))
            let request = DicomJPIPRequest(pixelDataProviderURL: endpoint, resource: .volume, window: try .init(layers: 3), session: session)
            do {
                for try await payload in transport.payloads(for: request) {
                    XCTAssertEqual(payload.reconstructionInfo?.completeness, .partial, "Truncated socket body cannot be final")
                }
            } catch {}
            let cache = await session.cache
            XCTAssertGreaterThan(cache.byteCount, 0)
            var received = false
            for try await payload in transport.payloads(for: request) {
                received = true
                XCTAssertEqual(try DicomJPEG2000Codec.decode(payload.data).bytes,
                               try DicomJPEG2000Codec.decode(DicomJPIPCodestreamIndexerTests.source()).bytes)
            }
            XCTAssertTrue(received)
            try await session.end()
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}

extension DicomJPIPLoopbackTests {
    actor SupersedenceProbe {
        var started = false
        func mark() { started = true }
    }
    func test_A1Scheduler_supersedesOnExistingHTTPChannel() async throws {
        let server = try DicomJPIPServerTests.server(), probe = SupersedenceProbe()
        let listener = DicomWebHTTPListener { request, _ in
            let response = await server.handle(request)
            if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "layers", value: "2")) == true {
                await probe.mark()
                try? await Task.sleep(for: .seconds(1))
            }
            return response
        }
        let root = try await listener.start()
        do {
            let endpoint = URL(string: root.absoluteString + "/jpip?target=test")!
            let session = DicomJPIPSession()
            let transport = try DicomJPIPHTTPTransport(configuration: .init(allowsInsecureHTTP: true,
                allowedResponseMediaTypes: ["image/jpp-stream"], allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: endpoint))]))
            func request(_ layer: Int) throws -> DicomJPIPRequest {
                .init(pixelDataProviderURL: endpoint, resource: .volume, window: try .init(layers: layer), session: session)
            }
            for try await _ in transport.payloads(for: try request(1)) {}
            let cid = await session.channelID
            XCTAssertNotNil(cid)
            let scheduler = DicomJPIPRequestScheduler(transport: transport)
            await scheduler.supersede(with: try request(2))
            let stale = Task { try await scheduler.next() }
            for _ in 0..<100 {
                if await probe.started { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let started = await probe.started; XCTAssertTrue(started)
            await scheduler.supersede(with: try request(3))
            let newest = try await scheduler.next()
            do { _ = try await stale.value; XCTFail("Superseded pull must cancel") } catch {}
            let current = await session.channelID; XCTAssertEqual(current, cid)
            XCTAssertEqual(try DicomJPEG2000Codec.decode(XCTUnwrap(newest?.data)).bytes,
                           try DicomJPEG2000Codec.decode(DicomJPIPCodestreamIndexerTests.source()).bytes)
            try await session.end()
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}
