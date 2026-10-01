import Foundation
import XCTest
import CryptoKit
@testable import DicomCore

final class DicomJPIPOpenJPIPInteropTests: XCTestCase {
    func test_openJPIP_cumulativeGoldenPixels() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaries = environment["DICOM_JPIP_OPENJPIP_BIN"] else {
            if environment["DICOM_REQUIRE_OPENJPIP"] == "1" {
                XCTFail("DICOM_REQUIRE_OPENJPIP=1 requires DICOM_JPIP_OPENJPIP_BIN")
                return
            }
            throw XCTSkip("DICOM_JPIP_OPENJPIP_BIN is unset")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-a1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("synthetic.pgm")
        var pixels = Data("P5\n512 512\n65535\n".utf8)
        for y in 0..<512 {
            for x in 0..<512 {
                let value = (x * 67 + y * 53 + ((x * y) % 257) * 29) & 65_535
                pixels.append(UInt8(value >> 8))
                pixels.append(UInt8(value & 255))
            }
        }
        try pixels.write(to: input)
        let ready = directory.appendingPathComponent("ready.json")
        let work = directory.appendingPathComponent("server")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["DICOM_SWIFT_PYNETDICOM_PYTHON"] ?? "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("Scripts/interop/openjpip_server.py").path,
            "--input", input.path, "--rates", "32,16,8,4,1", "--resolutions", "4",
            "--precincts", "[64,64]", "--ready-path", ready.path, "--work-dir", work.path]
        let log = directory.appendingPathComponent("harness.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? handle.close()
        }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let readiness = try? Data(contentsOf: ready),
              let json = try JSONSerialization.jsonObject(with: readiness) as? [String: Any],
              let port = json["port"] as? Int else {
            XCTFail("OpenJPIP failed to start: \(log.path)")
            return
        }
        let originalURL = work.appendingPathComponent("target.jp2")
        let originalBytes = try Data(contentsOf: originalURL)
        let isOpenJPIP152 = originalBytes.range(of: Data("OpenJPEG version 1.5.2".utf8)) != nil
        let full = try DicomJPEG2000Codec.decode(originalBytes)
        let decoder = URL(fileURLWithPath: binaries).appendingPathComponent("j2k_to_image")
        let modernDecoder = URL(fileURLWithPath: binaries).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("openjpip/build/bin/opj_decompress")
        let hasModernDecoder = FileManager.default.isExecutableFile(atPath: modernDecoder.path)
        func nativeDecode(_ source: URL, _ name: String, options: [String] = [], tool: URL? = nil) throws -> Data? {
            let output = directory.appendingPathComponent("\(name).pgm")
            let process = Process()
            process.executableURL = tool ?? decoder
            process.arguments = ["-i", source.path, "-o", output.path] + options
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try Self.pgmPixels(Data(contentsOf: output))
        }
        XCTAssertEqual(try nativeDecode(originalURL, "original-full"), full.bytes)

        for mode in ["jpp-stream", "jpt-stream"] {
            var channel: String?
            var cache = DicomJPIPDatabinCache()
            var accumulated = Data()
            var rawBodies = Data()
            var firstPreview: Date?
            var finalTimestamp: Date?
            let started = Date()
            for layer in [1, 2, 3, 5] {
                var query = "target=target.jp2&type=\(mode)&fsiz=512,512&layers=\(layer)"
                query += channel.map { "&cid=\($0)" } ?? "&cnew=http"
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?\(query)"))
                let (body, response) = try await URLSession.shared.data(from: url)
                let http = try XCTUnwrap(response as? HTTPURLResponse)
                XCTAssertEqual(http.statusCode, 200)
                if let field = http.value(forHTTPHeaderField: "JPIP-cnew") {
                    channel = field.split(separator: ",").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("cid=") }
                        .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(4)) }
                }
                var parser = DicomJPIPMessageParser()
                let messages = try parser.feed(body)
                try parser.finish()
                for message in messages {
                    try cache.insert(message)
                }
                rawBodies.append(body)
                try rawBodies.write(to: directory.appendingPathComponent("\(mode)-\(layer)-cumulative-http.bin"))
                // The 1.5.2 utility parses only databin messages, not HTTP EOR envelopes.
                // Preserve every original databin byte, stripping only the parsed terminal EOR.
                let eorBytes = parser.endOfResponse == nil ? 0 : 3
                XCTAssertTrue(parser.endOfResponse?.body.isEmpty ?? true)
                accumulated.append(body.dropLast(eorBytes))
                let result = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
                let wire = directory.appendingPathComponent("\(mode)-\(layer).wire")
                let oracle = directory.appendingPathComponent("\(mode)-\(layer).j2k")
                try accumulated.write(to: wire)
                try result.data.write(to: directory.appendingPathComponent("\(mode)-\(layer)-swift.j2k"))
                let transcode = Process()
                transcode.executableURL = URL(fileURLWithPath: binaries).appendingPathComponent("jpip_to_j2k")
                transcode.arguments = [wire.path, oracle.path]
                transcode.standardOutput = handle
                transcode.standardError = handle
                try transcode.run()
                transcode.waitUntilExit()
                XCTAssertEqual(transcode.terminationStatus, 0)
                print("JPIP decoding layer=\(layer) mode=\(mode) evidence=\(directory.path)")
                let oraclePixels = try nativeDecode(oracle, "\(mode)-\(layer)-oracle")
                let originalLayer = try nativeDecode(originalURL, "original-layer\(layer)", options: ["-l", String(layer)])
                XCTAssertNotNil(originalLayer, "The supplied j2k_to_image 1.5.2 supports -l")
                let oracleData = try Data(contentsOf: oracle)
                if let oraclePixels {
                    let golden = try DicomJPEG2000Codec.decode(oracleData)
                    let actual = try DicomJPEG2000Codec.decode(result.data)
                    XCTAssertEqual(actual.width, golden.width)
                    XCTAssertEqual(actual.height, golden.height)
                    XCTAssertEqual(actual.bytes, golden.bytes, "\(mode) layers=\(layer)")
                    if hasModernDecoder {
                        let modernPixels = try nativeDecode(oracle, "\(mode)-\(layer)-oracle25", tool: modernDecoder)
                        XCTAssertEqual(actual.bytes, modernPixels, "Client versus native OpenJPEG 2.5.4 oracle")
                        if oraclePixels != modernPixels && isOpenJPIP152 {
                            XCTExpectFailure("OpenJPEG 1.5.2 j2k_to_image and OpenJPEG 2.5.4 opj_decompress disagree on the same cumulative oracle codestream") {
                                XCTAssertEqual(oraclePixels, modernPixels)
                            }
                        } else { XCTAssertEqual(oraclePixels, modernPixels) }
                    } else { XCTAssertEqual(actual.bytes, oraclePixels) }
                    if layer == 5 { XCTAssertEqual(actual.bytes, full.bytes) }
                } else {
                    // Compare all bytes independently of decoding, except the reference's stale TNsot=4.
                    var canonicalOracle = oracleData
                    if let sot = canonicalOracle.range(of: Data([255, 144, 0, 10])) {
                        canonicalOracle[sot.lowerBound + 11] = 1
                    }
                    XCTAssertEqual(result.data, canonicalOracle, "No client/oracle discrepancy may be waived")
                    XCTAssertThrowsError(try DicomJPEG2000Codec.decode(result.data))
                }
                if oraclePixels != originalLayer && isOpenJPIP152 {
                    XCTExpectFailure("OpenJPIP 1.5.2: cumulative jpip_to_j2k output disagrees with j2k_to_image -l on the original; server sends all lower-resolution layers and class-0 truncated precincts have no padding") {
                        XCTAssertEqual(oraclePixels, originalLayer)
                    }
                } else { XCTAssertEqual(oraclePixels, originalLayer) }
                if result.info.completeness == .full && parser.endOfResponse?.windowDone == true { finalTimestamp = Date() }
                else if firstPreview == nil { firstPreview = Date() }
                let report = DicomJPIPPerformanceReport(cache: cache, firstPreviewTimestamp: firstPreview, finalTimestamp: finalTimestamp)
                print("JPIP \(mode) layers=\(layer) headers=\(http.allHeaderFields) EOR=\(String(describing: parser.endOfResponse?.reason)) useful=\(report.usefulBytes) redundant=\(report.redundantBytes) peak=\(report.peakCacheBytes) firstPreview=\(String(describing: report.firstPreviewTimestamp)) final=\(String(describing: report.finalTimestamp)) elapsed=\(Date().timeIntervalSince(started)) complete=\(result.info.completeness)")
            }
            if let channel {
                let (_, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?cclose=\(channel)")))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            }
        }
        for (name, query) in [("roi", "fsiz=512,512&roff=64,64&rsiz=128,128"),
                              ("resolution", "fsiz=256,256")] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?target=target.jp2&type=jpp-stream&\(query)"))
            let (body, response) = try await URLSession.shared.data(from: url)
            var parser = DicomJPIPMessageParser()
            var cache = DicomJPIPDatabinCache()
            var wire = Data()
            for message in try parser.feed(body) { try cache.insert(message); wire.append(Self.encode(message)) }
            try parser.finish()
            let reconstructed = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
            let actual = try DicomJPEG2000Codec.decode(reconstructed.data)
            let source = directory.appendingPathComponent("\(name).wire")
            let output = directory.appendingPathComponent("\(name).j2k")
            try wire.write(to: source)
            let transcode = Process()
            transcode.executableURL = URL(fileURLWithPath: binaries).appendingPathComponent("jpip_to_j2k")
            transcode.arguments = [source.path, output.path]
            transcode.standardOutput = handle
            transcode.standardError = handle
            try transcode.run()
            transcode.waitUntilExit()
            XCTAssertEqual(transcode.terminationStatus, 0)
            let golden = try DicomJPEG2000Codec.decode(Data(contentsOf: output))
            XCTAssertEqual(actual.width, golden.width)
            XCTAssertEqual(actual.height, golden.height)
            if name == "resolution" { XCTAssertEqual(actual.bytes, golden.bytes) }
            if name == "roi" {
                var actualCrop = Data()
                var expectedCrop = Data()
                var oracleCrop = Data()
                for y in 64..<192 {
                    let range = (y * 512 + 64) * 2..<(y * 512 + 192) * 2
                    actualCrop.append(actual.bytes.subdata(in: range))
                    expectedCrop.append(full.bytes.subdata(in: range))
                    oracleCrop.append(golden.bytes.subdata(in: range))
                }
                print("JPIP ROI headers=\((response as? HTTPURLResponse)?.allHeaderFields ?? [:]) actualSHA256=\(SHA256.hash(data: actualCrop)) originalSHA256=\(SHA256.hash(data: expectedCrop))")
                XCTAssertEqual(actualCrop, oracleCrop, "Client ROI must match the OpenJPIP oracle")
                let region = try DicomJPIPWindow(fsiz: .init(512, 512), rsiz: .init(128, 128), roff: .init(64, 64))
                let main = try XCTUnwrap(cache.bin(codestream: 0, classID: 6, binID: 0))
                let required = try DicomJPIPCodestreamReconstructor.windowBins(header: main.contiguousData, codestream: 0, window: region)
                let absent = required.filter { $0.classID == 0 && cache.bins[$0] == nil }.map(\.binID).sorted()
                print("JPIP ROI required overlapping precincts absent from SERVER response=\(absent)")
                if oracleCrop != expectedCrop && isOpenJPIP152 {
                    XCTExpectFailure("OpenJPIP 1.5.2: jpip_to_j2k ROI crop disagrees with original j2k_to_image; enqueue_precincts uses unscaled window coordinates at lower resolutions, omitting required low-resolution and edge precincts") {
                        XCTAssertEqual(oracleCrop, expectedCrop)
                    }
                } else { XCTAssertEqual(oracleCrop, expectedCrop) }
            } else {
                XCTAssertEqual(actual.width, 256)
                XCTAssertEqual(actual.height, 256)
                XCTAssertEqual(actual.bytes, try nativeDecode(originalURL, "original-reduced", options: ["-r", "1"]))
            }
            print("JPIP \(name) oracle comparison completed useful=\(cache.usefulBytes) redundant=\(cache.redundantBytes) peak=\(cache.peakBytes)")
        }
        // Cancel inside the real URLSession data callback, not after collecting a response.
        let interruptedSession = DicomJPIPSession(supportsCacheModel: false)
        let interruptedURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?target=target.jp2"))
        let interruptedClient = InterruptingHTTPClient(afterBytes: 4_096)
        let transport = try DicomJPIPHTTPTransport(configuration: .init(defaultLayerCount: 1, allowsInsecureHTTP: true,
            allowedResponseMediaTypes: ["image/jpp-stream"],
            allowedOrigins: [try XCTUnwrap(DicomJPIPOrigin(url: interruptedURL))]),
            httpClient: interruptedClient)
        func pull(_ layers: Int) async throws -> DicomJPIPLayerPayload? {
            let request = DicomJPIPRequest(pixelDataProviderURL: interruptedURL, resource: .volume,
                streamMode: .jppStream, window: try .init(fsiz: .init(512, 512), layers: layers),
                session: interruptedSession)
            return try await transport.payloads(for: request).next()
        }
        _ = try await pull(1)
        let originalChannel = await interruptedSession.channelID
        do { _ = try await pull(2); XCTFail("Second URLSession response must be interrupted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let partialCache = await interruptedSession.cache
        print("JPIP interruption N=4096 channel=\(originalChannel ?? "nil") cached=\(partialCache.byteCount)")
        // Reissue exactly the interrupted window on the same channel before asking for final quality.
        do { _ = try await pull(2) }
        catch { print("JPIP interrupted-window reconstruction error=\(error)") }
        do {
            let final = try await pull(5)
            XCTAssertEqual(try DicomJPEG2000Codec.decode(XCTUnwrap(final?.data)).bytes, full.bytes)
            XCTAssertEqual(final?.layer.isFinal, true)
        } catch { XCTFail("OpenJPIP same-channel reconnect lost bytes: \(error)") }
        let resumedChannel = await interruptedSession.channelID
        XCTAssertEqual(resumedChannel, originalChannel)
        let interruptedReport = await interruptedSession.performanceReport
        XCTAssertLessThanOrEqual(interruptedReport.redundantBytes, partialCache.byteCount,
            "A stateless repair may replay the existing prefix once when OpenJPIP ignores model=")
        print("JPIP reconnect useful=\(interruptedReport.usefulBytes) redundant=\(interruptedReport.redundantBytes) firstPreview=\(String(describing: interruptedReport.firstPreviewTimestamp)) final=\(String(describing: interruptedReport.finalTimestamp)) peak=\(interruptedReport.peakCacheBytes)")
        try await interruptedSession.end()
        var reuseChannel: String?
        var reuseCache = DicomJPIPDatabinCache()
        var reuseSizes: [Int] = []
        for window in ["roff=0,0&rsiz=256,256", "roff=128,128&rsiz=128,128"] {
            let channelField = reuseChannel.map { "cid=\($0)" } ?? "cnew=http"
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?target=target.jp2&type=jpp-stream&fsiz=512,512&layers=5&\(window)&\(channelField)"))
            let (body, response) = try await URLSession.shared.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            if let field = http.value(forHTTPHeaderField: "JPIP-cnew") {
                reuseChannel = field.split(separator: ",").first { $0.hasPrefix("cid=") }.map { String($0.dropFirst(4)) }
            }
            var parser = DicomJPIPMessageParser()
            for message in try parser.feed(body) { try reuseCache.insert(message) }
            try parser.finish()
            reuseSizes.append(body.count)
        }
        XCTAssertLessThan(reuseSizes[1], reuseSizes[0])
        XCTAssertEqual(reuseCache.redundantBytes, 0)
        if let reuseChannel {
            let (_, response) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/?cclose=\(reuseChannel)")))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        print("JPIP overlapping-window reuse responseBytes=\(reuseSizes) useful=\(reuseCache.usefulBytes) redundant=\(reuseCache.redundantBytes) peak=\(reuseCache.peakBytes)")
        print("JPIP independent evidence retained: \(directory.path); stream/model/HTJ2K: pending independent evidence")
    }

    static func pgmPixels(_ data: Data) throws -> Data {
        var cursor = 0
        var tokens: [String] = []
        while tokens.count < 4 && cursor < data.count {
            if data[cursor] == 35 {
                while cursor < data.count && data[cursor] != 10 { cursor += 1 }
            } else if [9, 10, 13, 32].contains(data[cursor]) { cursor += 1 }
            else {
                let start = cursor
                while cursor < data.count && ![9, 10, 13, 32].contains(data[cursor]) { cursor += 1 }
                tokens.append(String(decoding: data[start..<cursor], as: UTF8.self))
            }
        }
        guard tokens.count == 4, tokens[0] == "P5", let width = Int(tokens[1]), let height = Int(tokens[2]),
              tokens[3] == "65535", data.count - cursor - 1 == width * height * 2 else {
            throw DicomJPIPReconstructionError.malformedCodestream
        }
        var pixels = Data(data.dropFirst(cursor + 1))
        for index in stride(from: 0, to: pixels.count, by: 2) { pixels.swapAt(index, index + 1) }
        return pixels
    }

    actor InterruptingHTTPClient: DicomJPIPStreamingHTTPClient {
        let afterBytes: Int
        var calls = 0
        init(afterBytes: Int) { self.afterBytes = afterBytes }
        func response(for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
                      redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy) async throws -> DicomJPIPHTTPResponse {
            try await response(for: request, maximumBytes: maximumBytes, resourceTimeout: resourceTimeout,
                               redirectPolicy: redirectPolicy, receive: { _, _ in })
        }
        func response(for request: URLRequest, maximumBytes: Int, resourceTimeout: TimeInterval,
                      redirectPolicy: DicomJPIPTransportConfiguration.RedirectPolicy,
                      receive: @escaping @Sendable (DicomJPIPHTTPResponse, Data) throws -> Void) async throws -> DicomJPIPHTTPResponse {
            calls += 1
            let limit = calls == 2 ? afterBytes : Int.max
            let counter = ByteCounter()
            return try await URLSessionDicomJPIPHTTPClient().response(for: request, maximumBytes: maximumBytes,
                resourceTimeout: resourceTimeout, redirectPolicy: redirectPolicy) { response, chunk in
                    let accepted = counter.take(chunk, limit: limit)
                    try receive(response, accepted.data)
                    if accepted.cancel { throw CancellationError() }
                }
        }
    }

    final class ByteCounter: @unchecked Sendable {
        let lock = NSLock()
        var received = 0
        func take(_ data: Data, limit: Int) -> (data: Data, cancel: Bool) {
            lock.withLock {
                let count = min(data.count, limit - received)
                received += count
                return (Data(data.prefix(count)), received == limit)
            }
        }
    }

    static func encode(_ message: DicomJPIPMessage) -> Data {
        func vbas(_ value: Int) -> [UInt8] {
            var value = value
            var result = [UInt8(value & 127)]
            value >>= 7
            while value > 0 { result.insert(UInt8(value & 127) | 128, at: 0); value >>= 7 }
            return result
        }
        var id = message.binID
        var tail: [UInt8] = []
        while id > 15 { tail.insert(UInt8(id & 127), at: 0); id >>= 7 }
        for index in tail.indices.dropLast() { tail[index] |= 128 }
        var bytes = [UInt8(id) | 96 | (message.isComplete ? 16 : 0) | (tail.isEmpty ? 0 : 128)] + tail
        bytes += vbas(message.classID) + vbas(message.codestream) + vbas(message.offset) + vbas(message.body.count)
        if message.classID % 2 == 1 { bytes += vbas(message.auxiliary ?? 0) }
        return Data(bytes) + message.body
    }
}
