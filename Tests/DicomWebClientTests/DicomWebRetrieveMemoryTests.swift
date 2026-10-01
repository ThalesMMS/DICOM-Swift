import DicomTestUtilities
import DicomData
import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// A WADO-RS retrieve keeps its memory bounded however large the response is (#2890).
final class DicomWebRetrieveMemoryTests: XCTestCase {
    func test_streamedRetrieveOf256MiB_staysBelow128MiBOfFootprint() async throws {
        let server = StreamingMultipartServer(partCount: 16, partBytes: 16 * 1024 * 1024)
        let url = try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = DicomWebClient(configuration: .init(baseURL: url, timeout: 120),
                                    transport: URLSessionDicomWebHTTPTransport(session: session))
        let sink = VerifyingRetrieveSink(blocks: server.blocks)

        let meter = FootprintMeter()
        let status = try await Task.detached {
            try await client.retrieveStudy(studyInstanceUID: "2.25.2890", sink: sink)
        }.value
        let peak = meter.stop()

        XCTAssertEqual(status, 200)
        let counts = await sink.counts
        XCTAssertEqual(counts.parts, 16)
        XCTAssertEqual(counts.bytes, 16 * 16 * 1024 * 1024)
        XCTAssertEqual(counts.mismatches, 0)
        XCTAssertLessThan(peak, 128 * 1024 * 1024, "peak footprint growth \(peak / 1_048_576) MiB")
    }
}

/// Compares every payload byte with the block the server sent, holding none of the payload.
private actor VerifyingRetrieveSink: DicomWebRetrieveSink {
    private let blocks: [Data]
    private var parts = 0
    private var bytes = 0
    private var offset = 0
    private var mismatches = 0

    init(blocks: [Data]) { self.blocks = blocks }

    var counts: (parts: Int, bytes: Int, mismatches: Int) { (parts, bytes, mismatches) }

    func receive(_ event: DicomWebMultipartEvent) async throws {
        switch event {
        case .partHeaders:
            parts += 1
            offset = 0
        case .payload(var data):
            bytes += data.count
            let block = blocks[(parts - 1) % blocks.count]
            while !data.isEmpty {
                let start = offset % block.count
                let count = min(data.count, block.count - start)
                if data.prefix(count) != block[start..<(start + count)] { mismatches += 1 }
                data = data.dropFirst(count)
                offset += count
            }
        default: break
        }
    }
}

/// Answers one GET with a close-delimited multipart/related body made up as it is sent, one MiB at a time, so the
/// server never holds the response. Even parts declare Content-Length, odd parts end at the delimiter.
private final class StreamingMultipartServer: @unchecked Sendable {
    static let boundary = "ISIS2890"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebRetrieveMemoryTests.server")
    private let partCount: Int
    private let partBytes: Int
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(partCount: Int, partBytes: Int) {
        self.partCount = partCount
        self.partBytes = partBytes
        blocks = (0..<partCount).map { part in
            Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: 48 + ($0 &* 7 &+ part &* 13 &+ $0 / 4096) % 64) })
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
    }

    /// One MiB of payload per part, repeated through it: bytes 48–111, never "-" or a line break, so no payload
    /// byte starts a delimiter, and distinct per part so a part out of place is caught.
    let blocks: [Data]

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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nConnection: close\r\n"
                    + "Content-Type: multipart/related; type=\"application/dicom\"; boundary=\(Self.boundary)\r\n\r\n"
                send(Data(head.utf8), on: connection, part: 0, offset: 0)
            }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        let port = try XCTUnwrap(next)
        return URL(string: "http://127.0.0.1:\(port)/dicom-web")!
    }

    /// Sends `prefix`, then the next MiB of the body once the previous send was processed.
    private func send(_ prefix: Data, on connection: NWConnection, part: Int, offset: Int) {
        var piece = prefix
        var part = part, offset = offset
        if part < partCount {
            if offset == 0 {
                let length = part % 2 == 0 ? "Content-Length: \(partBytes)\r\n" : ""
                piece.append(Data("--\(Self.boundary)\r\nContent-Type: application/dicom\r\n\(length)\r\n".utf8))
            }
            let count = min(1024 * 1024, partBytes - offset)
            piece.append(blocks[part].prefix(count))
            offset += count
            if offset == partBytes {
                piece.append(Data("\r\n".utf8))
                part += 1
                offset = 0
            }
        } else {
            piece.append(Data("--\(Self.boundary)--\r\n".utf8))
            connection.send(content: piece, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let nextPart = part, nextOffset = offset
        connection.send(content: piece, completion: .contentProcessed { [self] error in
            guard error == nil else { return connection.cancel() }
            send(Data(), on: connection, part: nextPart, offset: nextOffset)
        })
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}
