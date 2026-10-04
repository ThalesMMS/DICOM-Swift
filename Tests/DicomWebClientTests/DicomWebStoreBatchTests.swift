import DicomTestUtilities
import CryptoKit
import DicomData
import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// STOW-RS in batches with one result per file (#2892).
final class DicomWebStoreBatchTests: XCTestCase {
    func test_partialResponseMapsPerInstanceAndA401StopsTheRemainingBatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-2892-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uids = (0..<6).map { "2.25.28920\($0)" }
        var files: [URL] = []
        for (index, uid) in uids.enumerated() {
            let url = directory.appendingPathComponent("\(index).dcm")
            try (index == 2 ? Data("not a Part 10 file".utf8) : Self.part10(uid)).write(to: url)
            files.append(url)
        }
        let server = ScriptedSTOWServer(responses: [
            (202, Self.partialResponse(stored: uids[0], refused: uids[1], reason: 0xC000)),
            (401, Data())
        ])
        let base = try await server.start()
        defer { server.stop() }
        let client = DicomWebClient(configuration: .init(baseURL: base))
        let reports = ProgressLog()

        let results = await client.storeFiles(files, options: .init(maximumFilesPerBatch: 2)) { await reports.append($0) }

        XCTAssertEqual(results.map(\.url), files)
        XCTAssertEqual(results.map(\.state), [.stored, .failed, .failed, .failed, .failed, .notSent])
        XCTAssertEqual(results[1].dicomStatus, 0xC000)
        XCTAssertEqual(results[1].reason, "Cannot understand (0xC000)")
        XCTAssertEqual(results[1].httpStatus, 202)
        XCTAssertEqual(results[2].reason, "The file has no valid File Meta Information.")
        XCTAssertNil(results[2].sopInstanceUID)
        XCTAssertEqual(results[3].httpStatus, 401)
        XCTAssertEqual(results[5].sopInstanceUID, uids[5])
        XCTAssertEqual(results[5].httpStatus, 401, "the not-sent file names what stopped the store")
        XCTAssertEqual(server.requestCount, 2, "no request after the 401")
        let progress = await reports.entries
        XCTAssertEqual(progress.map(\.completedBatches), [1, 2])
        XCTAssertEqual(progress.map(\.totalBatches), [3, 3])
        XCTAssertEqual(progress.last?.completedFiles, 5)
    }

    func test_aBatchRefusedWith503IsRepeatedAndExhaustedAttemptsLeaveTheRestNotSent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uids = (0..<3).map { "2.25.29400\($0)" }
        let files = try uids.enumerated().map { index, uid in
            let url = directory.appendingPathComponent("\(index).dcm")
            try Self.part10(uid).write(to: url)
            return url
        }
        let server = ScriptedSTOWServer(responses: [(503, Data()), (200, Self.storedResponse(uids[0])),
                                                    (503, Data()), (503, Data()), (503, Data())])
        var configuration = DicomWebClientConfiguration(baseURL: try await server.start())
        defer { server.stop() }
        configuration.retryPolicy = .init(maximumAttempts: 3, initialBackoff: 0.05, maximumBackoff: 0.2)
        let client = DicomWebClient(configuration: configuration)

        let results = await client.storeFiles(files, options: .init(maximumFilesPerBatch: 1))

        XCTAssertEqual(results.map(\.state), [.stored, .failed, .notSent])
        XCTAssertEqual(results[1].httpStatus, 503)
        XCTAssertEqual(results[2].httpStatus, 503, "the not-sent file names what stopped the store")
        XCTAssertEqual(server.requestCount, 5, "two attempts for the first batch, three for the second, none for the third")
        let lastBody = try XCTUnwrap(server.receivedBody)
        XCTAssertNil(lastBody.error)
        XCTAssertEqual(lastBody.uids, [uids[1]], "the repeated request sent the whole staged body again")
    }

    func test_withoutARetryPolicy_a503FailsOnlyItsBatchOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uids = (0..<2).map { "2.25.29401\($0)" }
        let files = try uids.enumerated().map { index, uid in
            let url = directory.appendingPathComponent("\(index).dcm")
            try Self.part10(uid).write(to: url)
            return url
        }
        let server = ScriptedSTOWServer(responses: [(503, Data()), (200, Self.storedResponse(uids[1]))])
        let client = DicomWebClient(configuration: .init(baseURL: try await server.start()))
        defer { server.stop() }

        let results = await client.storeFiles(files, options: .init(maximumFilesPerBatch: 1))

        XCTAssertEqual(results.map(\.state), [.failed, .stored])
        XCTAssertEqual(server.requestCount, 2)
    }

    func test_aBatchThatNeverReachedTheServerKeepsItsURLErrorCode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-unreachable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("0.dcm")
        try Self.part10("2.25.2892901").write(to: file)
        // Nothing listens on port 1 of the loopback address.
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "http://127.0.0.1:1/dicom-web")!, timeout: 5))

        let results = await client.storeFiles([file])

        XCTAssertEqual(results.map(\.state), [.failed])
        XCTAssertNil(results[0].httpStatus)
        XCTAssertEqual(results[0].transportErrorCode, .cannotConnectToHost)
    }

    func test_batchesSplitByCountAndBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-2892-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [URL] = []
        for index in 0..<5 {
            let url = directory.appendingPathComponent("\(index).dcm")
            try Self.part10("2.25.289210\(index)").write(to: url)
            files.append(url)
        }
        let size = try XCTUnwrap(try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let server = ScriptedSTOWServer(responses: Array(repeating: (200, Data()), count: 5))
        let client = DicomWebClient(configuration: .init(baseURL: try await server.start()))
        defer { server.stop() }

        let results = await client.storeFiles(files, options: .init(maximumFilesPerBatch: 3, maximumBytesPerBatch: 2 * size))

        XCTAssertEqual(results.map(\.state), Array(repeating: .unknown, count: 5), "an empty answer confirms nothing")
        XCTAssertEqual(server.requestCount, 3, "two files per request by bytes, although three fit by count")
    }

    func test_fileBacked48MiBInstances_preserveWireAndBoundMemory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uids = (0..<3).map { "2.25.2910.\($0)" }
        let fileBytes = 48 * 1024 * 1024
        let syntax = "1.2.840.10008.1.2.1"
        var files: [URL] = []
        var hashes: [SHA256.Digest] = []
        var normalizedBody = SHA256()
        for (index, uid) in uids.enumerated() {
            let file = directory.appendingPathComponent("\(index).dcm")
            let hash = try autoreleasepool { () throws -> SHA256.Digest in
                var prefix = try Self.part10(uid)
                let pixelBytes = fileBytes - prefix.count - 12
                prefix.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0])
                withUnsafeBytes(of: UInt32(pixelBytes).littleEndian) { prefix.append(contentsOf: $0) }
                _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var digest = SHA256()
                normalizedBody.update(data: Data(("--normalized\r\nContent-Type: application/dicom; " +
                    "transfer-syntax=\(syntax)\r\nContent-Length: \(fileBytes)\r\n\r\n").utf8))
                try handle.write(contentsOf: prefix)
                digest.update(data: prefix)
                normalizedBody.update(data: prefix)
                let block = Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) })
                for offset in stride(from: 0, to: pixelBytes, by: block.count) {
                    let chunk = block.prefix(min(block.count, pixelBytes - offset))
                    try handle.write(contentsOf: chunk)
                    digest.update(data: chunk)
                    normalizedBody.update(data: chunk)
                }
                normalizedBody.update(data: Data("\r\n".utf8))
                return digest.finalize()
            }
            files.append(file)
            hashes.append(hash)
        }
        normalizedBody.update(data: Data("--normalized--\r\n".utf8))
        let response = try JSONSerialization.data(withJSONObject: [["00081199": ["vr": "SQ", "Value": uids.map {
            ["00081150": ["vr": "UI", "Value": ["1.2.840.10008.5.1.4.1.1.7"]],
             "00081155": ["vr": "UI", "Value": [$0]]]
        }]]])
        let server = ScriptedSTOWServer(responses: [(200, response)])
        let client = DicomWebClient(configuration: .init(baseURL: try await server.start(), timeout: 120,
            maximumSTOWRequestBodyBytes: 160 * 1024 * 1024))
        defer { server.stop() }
        let meter = FootprintMeter()
        let start = DispatchTime.now().uptimeNanoseconds
        let inputFiles = files
        let results = await Task.detached {
            await client.storeFiles(inputFiles, options: .init(maximumFilesPerBatch: 3,
                maximumBytesPerBatch: 160 * 1024 * 1024))
        }.value
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let peak = meter.stop()
        XCTAssertEqual(results.map(\.state), [.stored, .stored, .stored])
        XCTAssertEqual(results.map(\.sopInstanceUID), uids)
        XCTAssertEqual(server.requestCount, 1)
        let received = try XCTUnwrap(server.receivedBody)
        XCTAssertNil(received.error)
        XCTAssertEqual(received.byteCounts, Array(repeating: fileBytes, count: 3))
        XCTAssertEqual(received.hashes, hashes)
        XCTAssertEqual(received.uids, uids)
        XCTAssertEqual(received.syntaxes, Array(repeating: syntax, count: 3))
        XCTAssertEqual(received.normalizedHash, normalizedBody.finalize())
        XCTAssertLessThan(peak, 64 * 1024 * 1024, "footprint growth must stay below the 144 MiB payload")
        for (index, file) in files.enumerated() {
            let originalHash = try autoreleasepool { () throws -> SHA256.Digest in
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
                return hash.finalize()
            }
            XCTAssertEqual(originalHash, hashes[index])
        }
        print("DICOMWEB_STOW_FILE_BENCHMARK instances=3 file_bytes=\(fileBytes) " +
            "elapsed_ms=\(milliseconds) footprint_growth_bytes=\(peak) " +
            "normalized_body_sha256=\(received.normalizedHash)")
    }

    private static func part10(_ uid: String) throws -> Data {
        try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])),
            .init(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2892"])),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2892.1"])),
            .init(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["ISIS2892"]))
        ]), options: .init(transferSyntax: .explicitVRLittleEndian))
    }

    private static func storedResponse(_ uid: String) -> Data {
        Data(("[{\"00081199\":{\"vr\":\"SQ\",\"Value\":[{\"00081150\":{\"vr\":\"UI\",\"Value\":[\"1.2.840.10008.5.1.4.1.1.7\"]},"
            + "\"00081155\":{\"vr\":\"UI\",\"Value\":[\"\(uid)\"]}}]}}]").utf8)
    }

    private static func partialResponse(stored: String, refused: String, reason: Int) -> Data {
        let item = { (uid: String) in #"{"00081150":{"vr":"UI","Value":["1.2.840.10008.5.1.4.1.1.7"]},"00081155":{"vr":"UI","Value":["\#(uid)"]}"# }
        return Data(("[{\"00081199\":{\"vr\":\"SQ\",\"Value\":[\(item(stored))}]},"
            + "\"00081198\":{\"vr\":\"SQ\",\"Value\":[\(item(refused)),\"00081197\":{\"vr\":\"US\",\"Value\":[\(reason)]}}]}}]").utf8)
    }
}

private actor ProgressLog {
    private(set) var entries: [DicomWebStoreBatchProgress] = []
    func append(_ entry: DicomWebStoreBatchProgress) { entries.append(entry) }
}

/// Answers each STOW-RS request, once its whole body has arrived, with the next scripted status and DICOM JSON body.
private final class ScriptedSTOWServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebStoreBatchTests.server")
    private let lock = NSLock()
    private var responses: [(Int, Data)]
    private var connections: [NWConnection] = []
    private var served = 0
    private var lastBody: RequestBody?

    var receivedBody: RequestBody? { lock.withLock { lastBody } }

    var requestCount: Int { lock.withLock { served } }

    init(responses: [(Int, Data)]) {
        self.responses = responses
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
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
            read(on: connection, body: RequestBody())
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        return URL(string: "http://127.0.0.1:\(try XCTUnwrap(next))/dicom-web")!
    }

    /// Consume bodies incrementally so the loopback peer does not retain the uploaded payload.
    private func read(on connection: NWConnection, body: RequestBody) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            do {
                if let data { try body.consume(data) }
                if body.remaining == 0 {
                    try body.finish()
                    let (status, response) = lock.withLock { () -> (Int, Data) in
                        served += 1
                        lastBody = body
                        return responses.isEmpty ? (500, Data()) : responses.removeFirst()
                    }
                    let header = "HTTP/1.1 \(status) Scripted\r\nContent-Type: application/dicom+json\r\n"
                        + "Content-Length: \(response.count)\r\n\r\n"
                    connection.send(content: Data(header.utf8) + response, completion: .contentProcessed { _ in })
                    if !complete && error == nil { read(on: connection, body: RequestBody()) }
                } else if !complete && error == nil {
                    read(on: connection, body: body)
                }
                if complete || error != nil { connection.cancel() }
            } catch {
                body.error = error
                lock.withLock { lastBody = body }
                connection.cancel()
            }
        }
    }

    final class RequestBody: @unchecked Sendable {
        private var header = Data()
        private var parser: DicomWebMultipartStreamParser?
        private var digest = SHA256()
        private var normalized = SHA256()
        private var prefix = Data()
        private var type = ""
        var remaining: Int?
        var error: (any Error)?
        var byteCounts: [Int] = []
        var hashes: [SHA256.Digest] = []
        var uids: [String] = []
        var syntaxes: [String] = []
        var normalizedHash: SHA256.Digest { normalized.finalize() }

        func consume(_ data: Data) throws {
            var payload = data
            if remaining == nil {
                header.append(data)
                guard let end = header.range(of: Data("\r\n\r\n".utf8)) else { return }
                let lines = String(decoding: header[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let length = try XCTUnwrap(lines.first { $0.lowercased().hasPrefix("content-length:") })
                remaining = try XCTUnwrap(Int(length.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)))
                let contentType = try XCTUnwrap(lines.first { $0.lowercased().hasPrefix("content-type:") })
                    .dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                parser = try DicomWebMultipartStreamParser(contentType: contentType)
                payload = Data(header[end.upperBound...])
                header.removeAll()
            }
            remaining = try XCTUnwrap(remaining) - payload.count
            try inspect(try parser!.feed(payload))
        }

        func finish() throws {
            try inspect(try parser!.finish())
            normalized.update(data: Data("--normalized--\r\n".utf8))
        }

        private func inspect(_ events: [DicomWebMultipartEvent]) throws {
            for event in events {
                switch event {
                case .partHeaders(let headers, _):
                    type = try XCTUnwrap(headers["Content-Type"])
                    let length = try XCTUnwrap(headers["Content-Length"])
                    normalized.update(data: Data("--normalized\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n\r\n".utf8))
                    byteCounts.append(0)
                    digest = SHA256()
                    prefix.removeAll()
                case .payload(let chunk):
                    digest.update(data: chunk)
                    normalized.update(data: chunk)
                    byteCounts[byteCounts.count - 1] += chunk.count
                    if prefix.count < 1024 { prefix.append(chunk.prefix(1024 - prefix.count)) }
                case .partEnd:
                    let meta = try DicomPart10FileMetaParser.parse(prefix)
                    uids.append(try XCTUnwrap(meta.mediaStorageSOPInstanceUID))
                    syntaxes.append(try XCTUnwrap(meta.transferSyntaxUID))
                    XCTAssertEqual(try DicomWebMediaType(type).parameters["transfer-syntax"], meta.transferSyntaxUID)
                    hashes.append(digest.finalize())
                    normalized.update(data: Data("\r\n".utf8))
                default: break
                }
            }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}
