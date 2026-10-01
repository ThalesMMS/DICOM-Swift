import Foundation
import XCTest
@testable import DicomCore

#if os(macOS)
import Darwin
#endif

final class DicomVideoParsingBenchmarkTests: XCTestCase {
    /// Reports startup and retained-memory measurements without imposing hardware-dependent budgets.
    /// Run each mode in a separate Release process through `Scripts/benchmark_video_parsing.sh`.
    func test_videoPayloadMode_reportsIsolatedParsingMetrics() throws {
        guard ProcessInfo.processInfo.environment["DICOM_VIDEO_PARSING_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOM_VIDEO_PARSING_BENCHMARK=1 to run the video parsing benchmark.")
        }

        #if os(macOS)
        let mode = try requestedMode()
        let fragmentCount = 64
        let fragmentByteCount = 256 * 1_024
        let fragments = (0..<fragmentCount).map { index in
            Data(repeating: UInt8(index), count: fragmentByteCount)
        }
        let expectedStream = fragments.reduce(into: Data()) { $0.append($1) }
        let pixelData = try DicomVideoPixelData(
            fragments: fragments,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41Fragmentable,
            columns: 1_920,
            rows: 1_080,
            numberOfFrames: fragmentCount,
            recommendedDisplayFrameRate: 30
        )
        let decoder = try DCMDecoder(data: DicomVideoBuilder.part10Data(video: pixelData))
        let memory = try measureRetainedMemory(decoder: decoder, mode: mode, expectedStream: expectedStream)

        let iterations = 10
        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            let video = try XCTUnwrap(decoder.video(payloadMode: mode))
            timings.append(BenchmarkClock.secondsElapsed(since: start))
            XCTAssertEqual(video.streamData, expectedStream)
            benchmarkBlackHole(video)
        }
        let result = try BenchmarkResult(timings: timings)
        let payloadBytes = expectedStream.count
        let duplicatedPayloadBytes = mode == .indexedFrames ? payloadBytes : 0
        let materializedPayloadCount = mode == .indexedFrames ? fragmentCount : 0

        print(
            String(
                format: "DICOM_VIDEO_PARSING mode=%@ iterations=%d p50_ms=%.3f p95_ms=%.3f "
                    + "payload_bytes=%d retained_payload_bytes=%d duplicated_payload_bytes=%d "
                    + "materialized_payload_count=%d live_heap_delta_bytes=%llu resident_delta_bytes=%llu "
                    + "process_peak_rss_bytes=%llu",
                modeName(mode),
                iterations,
                result.percentile(50) * 1_000,
                result.p95Time * 1_000,
                payloadBytes,
                payloadBytes + duplicatedPayloadBytes,
                duplicatedPayloadBytes,
                materializedPayloadCount,
                memory.heapDelta ?? 0,
                memory.residentDelta ?? 0,
                BenchmarkMemorySampler.currentPeakResidentMemoryBytes() ?? 0
            )
        )
        #else
        throw XCTSkip("The video parsing memory benchmark currently requires macOS process metrics.")
        #endif
    }

    private func requestedMode() throws -> DicomVideoPayloadMode {
        switch ProcessInfo.processInfo.environment["DICOM_VIDEO_PARSING_MODE"] {
        case "indexed-frames":
            return .indexedFrames
        case "stream-only":
            return .streamOnly
        default:
            throw XCTSkip("Set DICOM_VIDEO_PARSING_MODE to indexed-frames or stream-only.")
        }
    }

    private func modeName(_ mode: DicomVideoPayloadMode) -> String {
        switch mode {
        case .indexedFrames:
            return "indexed-frames"
        case .streamOnly:
            return "stream-only"
        }
    }

    #if os(macOS)
    private func measureRetainedMemory(
        decoder: DCMDecoder,
        mode: DicomVideoPayloadMode,
        expectedStream: Data
    ) throws -> (heapDelta: UInt64?, residentDelta: UInt64?) {
        let baselineHeap = currentLiveHeapBytes()
        let baselineResident = currentResidentMemoryBytes()
        let video = try XCTUnwrap(decoder.video(payloadMode: mode))
        let retainedHeap = currentLiveHeapBytes()
        let retainedResident = currentResidentMemoryBytes()
        XCTAssertEqual(video.streamData, expectedStream)
        benchmarkBlackHole(video)
        return (
            difference(retainedHeap, baselineHeap),
            difference(retainedResident, baselineResident)
        )
    }

    private func currentLiveHeapBytes() -> UInt64? {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.size_in_use)
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    private func difference(_ value: UInt64?, _ baseline: UInt64?) -> UInt64? {
        guard let value, let baseline, value >= baseline else { return nil }
        return value - baseline
    }
    #endif
}
