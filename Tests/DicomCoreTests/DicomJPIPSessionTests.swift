import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPSessionTests: XCTestCase {
    actor Client: DicomJPIPHTTPClient {
        var requests: [URLRequest] = []
        var budgets: [Int] = []
        var replies: [DicomJPIPHTTPResponse]
        init(_ replies: [DicomJPIPHTTPResponse]) { self.replies = replies }
        func response(for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
                      redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy) async throws -> DicomJPIPHTTPResponse {
            requests.append(request)
            budgets.append(maximumBytes)
            return replies.removeFirst()
        }
    }

    func test_sessionCreateRefineClose_keepsCacheAndFinalRequiresEOR() async throws {
        let fixture = try await DicomJPIPCodestreamReconstructorTests.fixture()
        let header = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 6, codestream: 0, binID: 0,
            offset: 0, isComplete: true, body: fixture.main))
        let tile = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 4, codestream: 0, binID: 0,
            offset: 0, isComplete: true, body: fixture.tile))
        let client = Client([
            .init(statusCode: 200, headers: ["Content-Type": "image/jpt-stream", "JPIP-cnew": "cid=test,transport=http"], body: header + tile),
            .init(statusCode: 200, headers: ["Content-Type": "image/jpt-stream"], body: Data([0, 2, 0])),
            .init(statusCode: 200, headers: [:], body: Data())
        ])
        let url = try XCTUnwrap(URL(string: "https://example.test/?target=synthetic.jp2"))
        var configuration = DicomJPIPTransportConfiguration(defaultLayerCount: 2,
            allowedResponseMediaTypes: ["image/jpt-stream"], allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: url))])
        configuration.maximumTotalBytes = header.count + tile.count + 100
        let transport = try DicomJPIPHTTPTransport(configuration: configuration, httpClient: client)
        let session = DicomJPIPSession()
        let request = DicomJPIPRequest(pixelDataProviderURL: url, resource: .volume, streamMode: .jptStream, session: session)
        var iterator = transport.payloads(for: request).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.layer.isFinal, false)
        let second = try await iterator.next()
        XCTAssertEqual(second?.layer.isFinal, true)
        XCTAssertEqual(try DicomJPEG2000Codec.decode(XCTUnwrap(second?.data)).bytes, fixture.pixels)
        try await session.end()
        let requests = await client.requests
        let queries = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertTrue(queries[0].contains(.init(name: "cnew", value: "http")))
        XCTAssertTrue(queries[1].contains(.init(name: "cid", value: "test")))
        XCTAssertEqual(queries[2], [.init(name: "cclose", value: "test")])
        let budgets = await client.budgets
        XCTAssertEqual(budgets[1], 100)
        let report = await session.performanceReport
        XCTAssertNotNil(report.firstPreviewTimestamp)
        XCTAssertNotNil(report.finalTimestamp)
        XCTAssertEqual(report.usefulBytes, fixture.main.count + fixture.tile.count)
    }

    func test_multiframeSession_boundedCacheRetainsRequestedFrameForEOROnlyRefinement() async throws {
        let fixture = try await DicomJPIPCodestreamReconstructorTests.fixture()
        func response(stream: Int) -> DicomJPIPHTTPResponse {
            let header = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 6, codestream: stream, binID: 0,
                offset: 0, isComplete: true, body: fixture.main))
            let tile = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 4, codestream: stream, binID: 0,
                offset: 0, isComplete: true, body: fixture.tile))
            return .init(statusCode: 200, headers: ["Content-Type": "image/jpt-stream"],
                         body: header + tile + Data([0, 2, 0]))
        }
        let url = try XCTUnwrap(URL(string: "https://example.test/?target=multiframe.jp2"))
        for explicitWindow in [false, true] {
            let client = Client([response(stream: 0), response(stream: 1),
                .init(statusCode: 200, headers: ["Content-Type": "image/jpt-stream"], body: Data([0, 2, 0]))])
            let transport = try DicomJPIPHTTPTransport(configuration: .init(defaultLayerCount: 1,
                allowedResponseMediaTypes: ["image/jpt-stream"],
                allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: url))]), httpClient: client)
            let session = DicomJPIPSession(maximumCacheBytes: fixture.main.count + fixture.tile.count, maximumBins: 2)
            for frame in [0, 1, 1] {
                let window = try explicitWindow ? DicomJPIPWindow(stream: frame + 1, type: .jptStream) : nil
                let request = DicomJPIPRequest(pixelDataProviderURL: url, resource: .frame(index: frame),
                    streamMode: .jptStream, window: window, session: session)
                let payload = try await transport.payloads(for: request).next()
                XCTAssertTrue(try XCTUnwrap(payload).layer.isFinal)
                XCTAssertEqual(try DicomJPEG2000Codec.decode(XCTUnwrap(payload?.data)).bytes, fixture.pixels)
                let cache = await session.cache
                XCTAssertEqual(cache.activeCodestream, frame)
                XCTAssertNotNil(cache.bin(codestream: frame, classID: 6, binID: 0))
                XCTAssertLessThanOrEqual(cache.byteCount, fixture.main.count + fixture.tile.count)
            }
        }
    }

    actor InterruptedClient: DicomJPIPStreamingHTTPClient {
        let header: Data
        let tile: Data
        var started = false
        var calls = 0
        init(header: Data, tile: Data) { self.header = header; self.tile = tile }
        func response(for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
                      redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy) async throws -> DicomJPIPHTTPResponse {
            try await response(for: request, maximumBytes: maximumBytes, resourceTimeout: resourceTimeout,
                               redirectPolicy: redirectPolicy, receive: { _, _ in })
        }
        func response(for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
                      redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy,
                      receive: @escaping @Sendable (DicomJPIPHTTPResponse, Data) throws -> Void) async throws -> DicomJPIPHTTPResponse {
            calls += 1
            let metadata = DicomJPIPHTTPResponse(statusCode: 200,
                headers: ["Content-Type": "image/jpt-stream", "JPIP-cnew": "cid=resume,transport=http"], body: Data())
            if calls == 1 {
                try receive(metadata, header)
                started = true
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            let body = tile + Data([0, 1, 0])
            try receive(metadata, body)
            return .init(statusCode: 200, headers: metadata.headers, body: body)
        }
    }

    func test_supersedence_preservesParsedMessagesBeforeNextWindow() async throws {
        let fixture = try await DicomJPIPCodestreamReconstructorTests.fixture()
        let header = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 6, codestream: 0, binID: 0,
            offset: 0, isComplete: true, body: fixture.main))
        let tile = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 4, codestream: 0, binID: 0,
            offset: 0, isComplete: true, body: fixture.tile))
        let client = InterruptedClient(header: header, tile: tile)
        let url = try XCTUnwrap(URL(string: "https://example.test/?target=synthetic.jp2"))
        let transport = try DicomJPIPHTTPTransport(configuration: .init(defaultLayerCount: 1,
            allowedResponseMediaTypes: ["image/jpt-stream"], allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: url))]),
            httpClient: client)
        let session = DicomJPIPSession()
        let scheduler = DicomJPIPRequestScheduler(transport: transport)
        let request = DicomJPIPRequest(pixelDataProviderURL: url, resource: .volume, streamMode: .jptStream, session: session)
        await scheduler.supersede(with: request)
        let first = Task { try await scheduler.next() }
        for _ in 0..<100 {
            if await client.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await client.started
        XCTAssertTrue(started)
        await scheduler.supersede(with: request)
        let second = try await scheduler.next()
        do { _ = try await first.value; XCTFail("Superseded request must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(second?.layer.isFinal, true)
        XCTAssertEqual(try DicomJPEG2000Codec.decode(XCTUnwrap(second?.data)).bytes, fixture.pixels)
        let cache = await session.cache
        XCTAssertEqual(cache.usefulBytes, fixture.main.count + fixture.tile.count)
        XCTAssertEqual(cache.redundantBytes, 0)
    }

    func test_windowValidationAndGrammar() throws {
        XCTAssertThrowsError(try DicomJPIPWindow(fsiz: .init(100, 100), rsiz: .init(80, 80), roff: .init(30, 0)))
        XCTAssertThrowsError(try DicomJPIPWindow(stream: 0))
        XCTAssertThrowsError(try DicomJPIPWindow(layers: 0))
        let window = try DicomJPIPWindow(fsiz: .init(512, 512), rounding: .roundDown,
            rsiz: .init(64, 64), roff: .init(32, 32), stream: 17, layers: 2, comps: [0...2], quality: 80)
        XCTAssertTrue(window.queryItems.contains(.init(name: "stream", value: "17")))
        XCTAssertTrue(window.queryItems.contains(.init(name: "fsiz", value: "512,512,round-down")))
        XCTAssertTrue(window.queryItems.contains(.init(name: "comps", value: "0-2")))
    }
    func test_statelessCacheModel_emitsOneActualModelAndImportsNeed() async throws {
        let fixture = try await DicomJPIPCodestreamReconstructorTests.fixture()
        let body = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 6, codestream: 0, binID: 0,
            offset: 0, isComplete: true, body: fixture.main)) +
            DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 4, codestream: 0, binID: 0,
                offset: 0, isComplete: true, body: fixture.tile))
        let reply = DicomJPIPHTTPResponse(statusCode: 200, headers: ["Content-Type": "image/jpt-stream"], body: body)
        let client = Client([reply, reply, reply])
        let url = try XCTUnwrap(URL(string: "https://example.test/?target=synthetic.jp2"))
        let transport = try DicomJPIPHTTPTransport(configuration: .init(defaultLayerCount: 1,
            allowedResponseMediaTypes: ["image/jpt-stream"], allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: url))]),
            httpClient: client)
        let session = DicomJPIPSession(usesHTTPChannel: false)
        for need in [nil, nil, "T0:12"] as [String?] {
            let model = try need.map { try DicomJPIPCacheModel(need: $0) }
            _ = try await transport.payloads(for: .init(pixelDataProviderURL: url, resource: .volume,
                streamMode: .jptStream, session: session, cacheModel: model)).next()
        }
        let requests = await client.requests
        let queries = requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertFalse(queries[0].contains { ["cid", "cnew", "model"].contains($0.name) })
        XCTAssertEqual(queries[1].filter { $0.name == "model" }, [.init(name: "model", value: "[0],T0,Hm")])
        XCTAssertTrue(queries[2].contains(.init(name: "need", value: "T0:12")))
        XCTAssertFalse(queries[2].contains { ["model", "tpmodel", "cid"].contains($0.name) })
        let cache = await session.cache
        XCTAssertEqual(cache.importedNeed.first?.extent, .bytes(12))
    }

}
