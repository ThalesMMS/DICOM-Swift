import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class DicomSourceFrameBenchmarkTests: XCTestCase {
    func test_legacyFrameReads_measureSelectedSyntheticInput() throws {
        let input = try inputURL()
        let decoder = try DCMDecoder(contentsOf: input)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)
        var hashes: [String] = []
        var bytes = 0
        for index in 0..<descriptor.numberOfFrames {
            try autoreleasepool {
                let frame = try XCTUnwrap(decoder.getFrame(index))
                bytes += frame.data.count
                hashes.append(hash(frame.data))
            }
        }
        try report(hashes: hashes, bytes: bytes, rows: descriptor.rows, columns: descriptor.columns, metrics: nil)
    }

    func test_boundedFrameReads_measureSelectedSyntheticInput() async throws {
        let source = try await DicomByteSource.openFile(inputURL(), limits: .init(maximumTotalReadBytes: Int.max))
        do {
            let session = try await DicomSourceFrameSession.open(source: source)
            var hashes: [String] = []
            var bytes = 0
            for try await frame in try session.frames() {
                XCTAssertEqual(frame.index, hashes.count)
                hashes.append(hash(frame.data))
                bytes += frame.data.count
                let metrics = await session.metrics
                XCTAssertEqual(metrics.retainedCompletedBytes, 0)
                XCTAssertEqual(metrics.inFlightReservedBytes, 0)
            }
            let layout = try XCTUnwrap(session.index.nativeLayout)
            try await report(hashes: hashes, bytes: bytes, rows: layout.rows, columns: layout.columns, metrics: session.metrics)
            await session.close()
        } catch {
            await source.close()
            throw error
        }
    }

    private func inputURL() throws -> URL {
        guard let input = ProcessInfo.processInfo.environment["DICOM_FRAME_BENCHMARK_INPUT"] else {
            throw XCTSkip("Explicit synthetic benchmark input was not selected")
        }
        return URL(fileURLWithPath: input)
    }

    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func report(hashes: [String], bytes: Int, rows: Int, columns: Int,
                        metrics: DicomSourceFrameSession.Metrics?) throws {
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["DICOM_FRAME_BENCHMARK_OUTPUT"])
        var report: [String: Any] = ["frameHashes": hashes, "frameCount": hashes.count, "payloadBytes": bytes,
                                    "rows": rows, "columns": columns]
        if let metrics {
            report["sourceBytesRead"] = metrics.source.receivedBytes
            report["materializedBytes"] = metrics.materializedBytes
            report["retainedCompletedBytes"] = metrics.retainedCompletedBytes
            report["storageCopiedBytes"] = metrics.source.storageCopiedBytes
        }
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
