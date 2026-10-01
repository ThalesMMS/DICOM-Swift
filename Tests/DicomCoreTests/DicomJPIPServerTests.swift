import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPServerTests: XCTestCase {
    struct Provider: DicomJPIPTargetProviding {
        let frames: [Data]
        func target(named name: String, maximumBytes: Int) async throws -> DicomJPIPTarget {
            guard name == "test" else { throw DicomJPIPServerError.targetNotFound }
            guard frames.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw DicomJPIPServerError.limitExceeded }
            return .init(codestreams: frames)
        }
    }
    static func server(configuration: DicomJPIPServerConfiguration = .init()) throws -> DicomJPIPServer {
        let source = try DicomJPIPCodestreamIndexerTests.source()
        return .init(provider: Provider(frames: [source, source, try DicomJPIPCodestreamIndexerTests.withoutPLT(source)]), configuration: configuration)
    }
    static func collect(_ response: DicomWebHTTPStreamedResponse) async throws -> (Data, [DicomJPIPMessage], UInt8?) {
        var data = Data()
        for try await chunk in response.body { data.append(chunk) }
        var parser = DicomJPIPMessageParser()
        let messages = try parser.feed(data); try parser.finish()
        return (data, messages, parser.endOfResponse?.reason)
    }
    static func request(_ query: String) -> DicomWebHTTPRequest {
        .init(method: .get, url: URL(string: "http://localhost/jpip?" + query)!)
    }
    func test_fullLayerROIAndResolution_areDecodableAndOrdered() async throws {
        let server = try Self.server()
        for query in ["", "&layers=1", "&fsiz=32,32", "&fsiz=64,64&roff=16,16&rsiz=32,32", "&type=jpt-stream"] {
            let response = await server.handle(Self.request("target=test" + query))
            XCTAssertEqual(response.statusCode, 200)
            let (_, messages, reason) = try await Self.collect(response)
            XCTAssertEqual(messages.first?.classID, 6)
            XCTAssertTrue([1, 2].contains(reason))
            var cache = DicomJPIPDatabinCache()
            for message in messages { try cache.insert(message) }
            let result = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
            XCTAssertFalse(try DicomJPEG2000Codec.decode(result.data).bytes.isEmpty)
        }
    }
    func test_modelNeedAndSession_reduceBytes() async throws {
        let server = try Self.server()
        let first = await server.handle(Self.request("target=test&cnew=http"))
        let (body, messages, _) = try await Self.collect(first)
        let cid = try XCTUnwrap(first.headers["JPIP-cnew"]?.split(separator: ",").first?.dropFirst(4))
        let second = try await Self.collect(await server.handle(Self.request("cid=\(cid)")))
        XCTAssertEqual(second.0.count, 3)
        var cache = DicomJPIPDatabinCache()
        for message in messages { try cache.insert(message) }
        var url = URLComponents(string: "http://localhost/jpip")!
        url.queryItems = [.init(name: "target", value: "test"), .init(name: "model", value: DicomJPIPCacheModel(cache: cache).model)]
        let modeled = try await Self.collect(await server.handle(.init(method: .get, url: url.url!)))
        XCTAssertEqual(modeled.0.count, 3); XCTAssertGreaterThan(body.count, modeled.0.count)
        let needed = try await Self.collect(await server.handle(Self.request("target=test&need=Hm")))
        XCTAssertEqual(needed.1.count, 1); XCTAssertEqual(needed.1.first?.classID, 6)
        let close = await server.handle(Self.request("cclose=\(cid)"))
        XCTAssertEqual(close.headers["JPIP-cclose"], String(cid))
        let invalid = await server.handle(Self.request("cid=\(cid)"))
        XCTAssertEqual(invalid.statusCode, 400)
    }
    func test_supersedenceAndLimits_emitCorrectEOR() async throws {
        var config = DicomJPIPServerConfiguration(); config.maximumResponseBytes = 200
        let server = try Self.server(configuration: config)
        let limited = try await Self.collect(await server.handle(Self.request("target=test")))
        XCTAssertLessThanOrEqual(limited.0.count, 200); XCTAssertEqual(limited.2, 7)
        let len = try await Self.collect(await server.handle(Self.request("target=test&len=100")))
        XCTAssertLessThanOrEqual(len.0.count, 100); XCTAssertEqual(len.2, 4)
        let first = await server.handle(Self.request("target=test&cnew=http"))
        let cid = try XCTUnwrap(first.headers["JPIP-cnew"]?.split(separator: ",").first?.dropFirst(4))
        _ = await server.handle(Self.request("cid=\(cid)&layers=1"))
        let superseded = try await Self.collect(first)
        XCTAssertEqual(superseded.2, 3)
        config.maximumChannelBytes = 100
        let bounded = try Self.server(configuration: config)
        let session = try await Self.collect(await bounded.handle(Self.request("target=test&cnew=http")))
        XCTAssertEqual(session.2, 6)
    }
    func test_errorsAndHosting_keepJPIPHeadersOffErrors() async throws {
        let server = try Self.server()
        for query in ["target=test&layers=-1", "target=test&type=raw", "target=test&stream=100", "target=test&!required=x"] {
            let response = await server.handle(Self.request(query))
            XCTAssertTrue([400, 415].contains(response.statusCode))
            XCTAssertFalse(response.headers.keys.contains { $0.hasPrefix("JPIP-") })
        }
        let hosted = DicomWebServer(configuration: .init(servicePath: "/api/dicom", requiredBearerToken: "secret"), jpip: server)
        let denied = try await hosted.send(Self.request("target=test"))
        XCTAssertEqual(denied.statusCode, 401)
        var request = Self.request("target=test"); request.headers["Authorization"] = "Bearer secret"
        let outsideService = try await hosted.send(request)
        XCTAssertEqual(outsideService.statusCode, 404)
        request.url = try XCTUnwrap(URL(string: "http://localhost/api/dicom/jpip?target=test"))
        let allowed = try await hosted.send(request)
        XCTAssertEqual(allowed.statusCode, 200)
    }
    func test_HTJ2KWithoutPLT_isJPTOnly() async throws {
        let fixture = try await DicomJPIPCodestreamReconstructorTests.fixture(htj2k: true)
        let data = fixture.main + fixture.tile + Data([255, 217])
        let index = try DicomJPIPCodestreamIndexer().index(data)
        XCTAssertTrue(index.isHTJ2K); XCTAssertFalse(index.supportsJPP)
        let server = DicomJPIPServer(provider: Provider(frames: [data]))
        let jpp = await server.handle(Self.request("target=test"))
        XCTAssertEqual(jpp.statusCode, 415)
        let jpt = try await Self.collect(await server.handle(Self.request("target=test&type=jpt-stream")))
        XCTAssertEqual(jpt.2, 1)
    }
}

extension DicomJPIPServerTests {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { lock.withLock { value } }
        func advance() { lock.withLock { value += 121 } }
    }
    func test_expiryAndChannelCount_enforceBounds() async throws {
        let clock = Clock()
        var config = DicomJPIPServerConfiguration(); config.maximumChannels = 1
        let server = DicomJPIPServer(provider: Provider(frames: [try DicomJPIPCodestreamIndexerTests.source()]),
                                    configuration: config, now: { clock.now() })
        let first = await server.handle(Self.request("target=test&cnew=http"))
        XCTAssertEqual(first.statusCode, 200)
        let denied = await server.handle(Self.request("target=test&cnew=http"))
        XCTAssertEqual(denied.statusCode, 413)
        clock.advance()
        let expired = try await Self.collect(first)
        XCTAssertEqual(expired.2, 3)
        let new = await server.handle(Self.request("target=test&cnew=http"))
        XCTAssertEqual(new.statusCode, 200)
    }
}
