import Foundation
import XCTest
@testable import DicomCore

#if os(macOS)
import Darwin
#endif

final class DicomEncapsulatedPixelDataBenchmarkTests: XCTestCase {
    func test_frameAssemblyStrategies_preserveSimpleAndFragmentedPayloads() {
        let source = Data((0..<64).map(UInt8.init))
        let scenarios = [
            Scenario(name: "simple", ranges: [8..<56]),
            Scenario(name: "fragmented", ranges: [4..<12, 24..<33, 50..<64])
        ]

        for scenario in scenarios {
            let expected = scenario.ranges.reduce(into: Data()) { payload, range in
                payload.append(contentsOf: source[range])
            }
            for strategy in Strategy.allCases {
                XCTAssertEqual(assemble(source: source, ranges: scenario.ranges, strategy: strategy), expected)
            }
        }
    }

    /// Records measurements without asserting a hardware-dependent winner. Enable with
    /// `DICOM_ENCAPSULATED_EXTRACTION_BENCHMARK=1` and use a release build.
    func test_benchmarkFrameAssemblyCopies() throws {
        guard ProcessInfo.processInfo.environment["DICOM_ENCAPSULATED_EXTRACTION_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOM_ENCAPSULATED_EXTRACTION_BENCHMARK=1 to run the frame assembly benchmark.")
        }

        #if os(macOS)
        let payloadByteCount = 16 * 1_024 * 1_024
        let sourcePrefixBytes = 1_024 * 1_024
        var source = Data(repeating: 0xEE, count: sourcePrefixBytes)
        source.append(Data(repeating: 0xA5, count: payloadByteCount))
        source.append(Data(repeating: 0xDD, count: sourcePrefixBytes))
        let expected = Data(repeating: 0xA5, count: payloadByteCount)
        let fragmentCount = 64
        let fragmentByteCount = payloadByteCount / fragmentCount
        let scenarios = [
            Scenario(
                name: "simple",
                ranges: [sourcePrefixBytes..<(sourcePrefixBytes + payloadByteCount)]
            ),
            Scenario(
                name: "fragmented",
                ranges: (0..<fragmentCount).map { index in
                    let lowerBound = sourcePrefixBytes + index * fragmentByteCount
                    return lowerBound..<(lowerBound + fragmentByteCount)
                }
            )
        ]
        let requestedScenario = ProcessInfo.processInfo.environment["DICOM_ENCAPSULATED_EXTRACTION_SCENARIO"]
        let requestedStrategy = ProcessInfo.processInfo.environment["DICOM_ENCAPSULATED_EXTRACTION_STRATEGY"]
        let selectedScenarios = scenarios.filter { requestedScenario == nil || $0.name == requestedScenario }
        let selectedStrategies = Strategy.allCases.filter { requestedStrategy == nil || $0.rawValue == requestedStrategy }
        XCTAssertFalse(selectedScenarios.isEmpty, "Unknown benchmark scenario: \(requestedScenario ?? "")")
        XCTAssertFalse(selectedStrategies.isEmpty, "Unknown benchmark strategy: \(requestedStrategy ?? "")")

        for scenario in selectedScenarios {
            for strategy in selectedStrategies {
                let measurement = try measure(
                    source: source,
                    expected: expected,
                    scenario: scenario,
                    strategy: strategy
                )
                print(measurement.reportLine)
            }
        }
        #else
        throw XCTSkip("The frame assembly memory benchmark currently requires macOS malloc and task metrics.")
        #endif
    }

    private enum Strategy: String, CaseIterable {
        case intermediateData = "intermediate-data"
        case directRange = "direct-range"
    }

    private struct Scenario {
        let name: String
        let ranges: [Range<Int>]

        var payloadBytes: Int {
            ranges.reduce(0) { $0 + $1.count }
        }

        var largestFragmentBytes: Int {
            ranges.map(\.count).max() ?? 0
        }
    }

    #if os(macOS)
    private struct Measurement {
        let scenario: String
        let strategy: Strategy
        let iterations: Int
        let p50Seconds: Double
        let p95Seconds: Double
        let payloadBytes: Int
        let intermediateCopyBytes: Int
        let intermediateBufferCount: Int
        let modeledPeakPayloadBytes: Int
        let peakLiveHeapDeltaBytes: UInt64?
        let peakResidentDeltaBytes: UInt64?
        let processPeakRSSBytes: UInt64?

        var reportLine: String {
            String(
                format: "ENCAPSULATED_FRAME_ASSEMBLY scenario=%@ strategy=%@ iterations=%d "
                    + "p50_ms=%.3f p95_ms=%.3f payload_bytes=%d intermediate_copy_bytes=%d "
                    + "intermediate_buffer_count=%d modeled_peak_payload_bytes=%d "
                    + "peak_live_heap_delta_bytes=%llu peak_resident_delta_bytes=%llu process_peak_rss_bytes=%llu",
                scenario,
                strategy.rawValue,
                iterations,
                p50Seconds * 1_000,
                p95Seconds * 1_000,
                payloadBytes,
                intermediateCopyBytes,
                intermediateBufferCount,
                modeledPeakPayloadBytes,
                peakLiveHeapDeltaBytes ?? 0,
                peakResidentDeltaBytes ?? 0,
                processPeakRSSBytes ?? 0
            )
        }
    }

    private func measure(source: Data,
                         expected: Data,
                         scenario: Scenario,
                         strategy: Strategy) throws -> Measurement {
        let warmupIterations = 3
        let benchmarkIterations = 20
        let memory = measurePeakMemory(
            source: source,
            expected: expected,
            ranges: scenario.ranges,
            strategy: strategy
        )
        for _ in 0..<warmupIterations {
            benchmarkBlackHole(assemble(source: source, ranges: scenario.ranges, strategy: strategy))
        }

        var timings: [Double] = []
        timings.reserveCapacity(benchmarkIterations)
        for _ in 0..<benchmarkIterations {
            let start = BenchmarkClock.now()
            let payload = assemble(source: source, ranges: scenario.ranges, strategy: strategy)
            timings.append(BenchmarkClock.secondsElapsed(since: start))
            benchmarkBlackHole(payload)
        }
        let timing = try BenchmarkResult(timings: timings)
        let intermediateCopyBytes = strategy == .intermediateData ? scenario.payloadBytes : 0
        let intermediateBufferCount = strategy == .intermediateData ? scenario.ranges.count : 0
        let modeledPeakPayloadBytes = scenario.payloadBytes
            + (strategy == .intermediateData ? scenario.largestFragmentBytes : 0)

        return Measurement(
            scenario: scenario.name,
            strategy: strategy,
            iterations: benchmarkIterations,
            p50Seconds: timing.percentile(50),
            p95Seconds: timing.p95Time,
            payloadBytes: scenario.payloadBytes,
            intermediateCopyBytes: intermediateCopyBytes,
            intermediateBufferCount: intermediateBufferCount,
            modeledPeakPayloadBytes: modeledPeakPayloadBytes,
            peakLiveHeapDeltaBytes: memory.heapDelta,
            peakResidentDeltaBytes: memory.residentDelta,
            processPeakRSSBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes()
        )
    }

    private func measurePeakMemory(
        source: Data,
        expected: Data,
        ranges: [Range<Int>],
        strategy: Strategy
    ) -> (heapDelta: UInt64?, residentDelta: UInt64?) {
        let baselineHeap = currentLiveHeapBytes()
        let baselineResident = currentResidentMemoryBytes()
        var peakHeap = baselineHeap
        var peakResident = baselineResident
        let observe = {
            if let currentHeap = self.currentLiveHeapBytes() {
                peakHeap = max(peakHeap ?? currentHeap, currentHeap)
            }
            if let currentResident = self.currentResidentMemoryBytes() {
                peakResident = max(peakResident ?? currentResident, currentResident)
            }
        }
        let payload = assemble(source: source, ranges: ranges, strategy: strategy, observe: observe)
        observe()
        XCTAssertEqual(payload, expected)
        benchmarkBlackHole(payload)
        return (difference(peakHeap, baselineHeap), difference(peakResident, baselineResident))
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

    @inline(never)
    private func assemble(source: Data,
                          ranges: [Range<Int>],
                          strategy: Strategy,
                          observe: (() -> Void)? = nil) -> Data {
        var payload = Data()
        switch strategy {
        case .intermediateData:
            for range in ranges {
                let fragment = Data(source[range])
                observe?()
                payload.append(fragment)
                observe?()
            }
        case .directRange:
            for range in ranges {
                payload.append(contentsOf: source[range])
                observe?()
            }
        }
        return payload
    }
}
