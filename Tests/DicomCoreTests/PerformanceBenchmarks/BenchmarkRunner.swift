//
//  BenchmarkRunner.swift
//  DicomCoreTests
//
//  Unified benchmark runner integrating all performance tests. Provides comprehensive benchmarking
//  for decoder operations, windowing operations (vDSP/Metal), and performance comparisons.
//
//  All timings come from BenchmarkClock, a monotonic nanosecond clock. Operations that finish
//  inside a single clock tick are timed in batches and reported as a per-operation average, so no
//  sample can collapse to zero.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
@testable import DicomCore

// MARK: - Benchmark Types

/// Types of benchmarks that can be executed
public enum BenchmarkType: String, CaseIterable {
    case lockOverhead = "Lock Overhead"
    case decoderInit = "Decoder Initialization"
    case decoderValidation = "Decoder Validation"
    case metadataAccess = "Metadata Access"
    case windowingVDSP = "Windowing (vDSP)"
    case windowingMetal = "Windowing (Metal)"
    case windowingComparison = "Windowing Comparison"
}

/// Benchmark suite results containing multiple benchmark results
public struct BenchmarkSuiteResult {
    public let results: [BenchmarkType: BenchmarkResult]
    public let config: BenchmarkConfig
    public let timestamp: Date

    /// Initialize suite result
    public init(results: [BenchmarkType: BenchmarkResult], config: BenchmarkConfig) {
        self.results = results
        self.config = config
        self.timestamp = Date()
    }

    /// Get result for specific benchmark type
    public func result(for type: BenchmarkType) -> BenchmarkResult? {
        return results[type]
    }
}

// MARK: - Benchmark Runner

/// Unified benchmark runner for all performance tests
public final class BenchmarkRunner {

    private let config: BenchmarkConfig

    // MARK: - Initialization

    /// Initialize benchmark runner with configuration
    ///
    /// - Parameter config: Benchmark configuration parameters
    public init(config: BenchmarkConfig = BenchmarkConfig()) {
        self.config = config
    }

    // MARK: - Decoder Benchmarks

    /// Benchmark lock overhead in sequential access patterns
    ///
    /// Measures the overhead of the decoder lock by comparing locked vs unlocked operations.
    /// This simulates the worst-case overhead where every operation acquires/releases locks.
    ///
    /// - Returns: Benchmark result for lock overhead
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkLockOverhead() throws -> BenchmarkResult {
        let iterations = max(1000, config.benchmarkIterations * 10) // More iterations for lock overhead
        let operationsPerIteration = 10_000
        var timings = [Double]()
        timings.reserveCapacity(iterations)
        var baselineTimings = [Double]()
        baselineTimings.reserveCapacity(iterations)

        let lock = DicomLock()
        var baselineCounter = 0
        var counter = 0

        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            for _ in 0..<operationsPerIteration {
                baselineCounter &+= 1
                benchmarkBlackHole(baselineCounter)
            }
            let elapsed = BenchmarkClock.secondsElapsed(since: start) / Double(operationsPerIteration)
            baselineTimings.append(elapsed)
        }

        let baselineElapsed = baselineTimings.reduce(0, +) / Double(baselineTimings.count)

        // Batch tiny lock/unlock cycles so each timing sample is above timer resolution,
        // then subtract the unlocked loop baseline to isolate lock overhead.
        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            for _ in 0..<operationsPerIteration {
                lock.lock()
                counter &+= 1
                lock.unlock()
                benchmarkBlackHole(counter)
            }
            let elapsed = BenchmarkClock.secondsElapsed(since: start) / Double(operationsPerIteration)
            timings.append(max(0, elapsed - baselineElapsed))
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    /// Benchmark decoder initialization performance
    ///
    /// Measures the time to create a new decoder instance. A single allocation can
    /// finish inside one clock tick, so each sample times a batch of allocations and
    /// records the per-allocation average.
    ///
    /// - Returns: Benchmark result for decoder initialization
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkDecoderInit() throws -> BenchmarkResult {
        let iterations = config.benchmarkIterations
        let allocationsPerSample = 200
        var timings = [Double]()
        timings.reserveCapacity(iterations)

        // Warmup with the same batch shape as a measured sample, so one-off costs
        // (lazy globals, malloc arena growth) are paid before timing starts instead
        // of landing in the first sample and skewing the mean.
        for _ in 0..<config.warmupIterations {
            for _ in 0..<allocationsPerSample {
                benchmarkBlackHole(DCMDecoder())
            }
        }

        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            for _ in 0..<allocationsPerSample {
                benchmarkBlackHole(DCMDecoder())
            }
            let elapsed = BenchmarkClock.secondsElapsed(since: start) / Double(allocationsPerSample)
            timings.append(elapsed)
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    /// Benchmark decoder validation status check performance
    ///
    /// Measures the time to check validation status (synchronized method).
    ///
    /// - Returns: Benchmark result for validation check
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkDecoderValidation() throws -> BenchmarkResult {
        let decoder = DCMDecoder()
        let iterations = config.benchmarkIterations
        let checksPerSample = 100
        var timings = [Double]()
        timings.reserveCapacity(iterations)

        // Warmup so first-call costs stay out of the measured samples
        for _ in 0..<config.warmupIterations {
            benchmarkBlackHole(decoder.getValidationStatus())
        }

        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            for _ in 0..<checksPerSample {
                benchmarkBlackHole(decoder.getValidationStatus())
            }
            let elapsed = BenchmarkClock.secondsElapsed(since: start) / Double(checksPerSample)
            timings.append(elapsed)
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    /// Benchmark metadata access performance
    ///
    /// Measures the time to access various metadata fields (synchronized methods).
    ///
    /// - Returns: Benchmark result for metadata access
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkMetadataAccess() throws -> BenchmarkResult {
        let decoder = DCMDecoder()
        let iterations = config.benchmarkIterations
        let checksPerSample = 100
        var timings = [Double]()
        timings.reserveCapacity(iterations)

        // Warmup so first-call costs (tag dictionary loading, cache population) stay
        // out of the measured samples
        for _ in 0..<config.warmupIterations {
            accessMetadata(on: decoder)
        }

        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            for _ in 0..<checksPerSample {
                accessMetadata(on: decoder)
            }
            let elapsed = BenchmarkClock.secondsElapsed(since: start) / Double(checksPerSample)
            timings.append(elapsed)
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    /// Read the metadata fields sampled by `benchmarkMetadataAccess()`
    ///
    /// - Parameter decoder: Decoder to read from
    private func accessMetadata(on decoder: DCMDecoder) {
        // Access multiple metadata fields (synchronized methods)
        benchmarkBlackHole(decoder.info(for: .patientName))
        benchmarkBlackHole(decoder.intValue(for: .rows))
        benchmarkBlackHole(decoder.doubleValue(for: .pixelSpacing))
    }

    // MARK: - Windowing Benchmarks

    /// Benchmark vDSP windowing performance
    ///
    /// Measures CPU-based window/level processing using vDSP.
    ///
    /// - Returns: Benchmark result for vDSP windowing
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkWindowingVDSP() throws -> BenchmarkResult {
        let pixels = generateTestPixels()
        let iterations = config.benchmarkIterations
        var timings = [Double]()
        timings.reserveCapacity(iterations)

        // Warmup
        for _ in 0..<config.warmupIterations {
            _ = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: config.windowCenter,
                width: config.windowWidth,
                processingMode: .vdsp
            )
        }

        // Benchmark
        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            benchmarkBlackHole(DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: config.windowCenter,
                width: config.windowWidth,
                processingMode: .vdsp
            ))
            let elapsed = BenchmarkClock.secondsElapsed(since: start)
            timings.append(elapsed)

            if config.verbose {
                print("  vDSP iteration: \(String(format: "%.6f", elapsed))s")
            }
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    /// Benchmark Metal GPU windowing performance
    ///
    /// Measures GPU-based window/level processing using Metal.
    ///
    /// - Returns: Benchmark result for Metal windowing, or nil if Metal unavailable
    /// - Throws: BenchmarkError if benchmark fails
    public func benchmarkWindowingMetal() throws -> BenchmarkResult? {
        guard MetalWindowingProcessor.isMetalAvailable else {
            return nil
        }

        let pixels = generateTestPixels()
        let iterations = config.benchmarkIterations
        var timings = [Double]()
        timings.reserveCapacity(iterations)

        // Warmup
        for _ in 0..<config.warmupIterations {
            _ = DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: config.windowCenter,
                width: config.windowWidth,
                processingMode: .metal
            )
        }

        // Benchmark
        for _ in 0..<iterations {
            let start = BenchmarkClock.now()
            benchmarkBlackHole(DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels,
                center: config.windowCenter,
                width: config.windowWidth,
                processingMode: .metal
            ))
            let elapsed = BenchmarkClock.secondsElapsed(since: start)
            timings.append(elapsed)

            if config.verbose {
                print("  Metal iteration: \(String(format: "%.6f", elapsed))s")
            }
        }

        return try BenchmarkResult(timings: timings, peakMemoryBytes: BenchmarkMemorySampler.currentPeakResidentMemoryBytes())
    }

    // MARK: - Test Data Generation

    /// Generate synthetic 16-bit pixel data for benchmarking
    ///
    /// Creates realistic DICOM-like data with gradients and variation.
    ///
    /// - Returns: Array of UInt16 pixel values
    private func generateTestPixels() -> [UInt16] {
        let pixelCount = config.totalPixels
        var pixels = [UInt16](repeating: 0, count: pixelCount)

        // Generate gradient pattern with some noise for realistic data
        for i in 0..<pixelCount {
            // Create gradient from 0 to 4095 (12-bit range typical for CT)
            let baseValue = UInt16((Double(i) / Double(pixelCount)) * 4095.0)

            // Add some variation to simulate real DICOM data
            let noise = UInt16.random(in: 0..<100)
            pixels[i] = min(4095, baseValue &+ noise)
        }

        return pixels
    }

    // MARK: - Suite Execution

    /// Run all decoder benchmarks
    ///
    /// - Returns: Dictionary of benchmark results by type
    /// - Throws: BenchmarkError if any benchmark fails
    public func runDecoderBenchmarks() throws -> [BenchmarkType: BenchmarkResult] {
        var results: [BenchmarkType: BenchmarkResult] = [:]

        print("\n" + String(repeating: "=", count: 70))
        print("DECODER BENCHMARKS")
        print(String(repeating: "=", count: 70))

        // Lock overhead
        print("\n➤ Running Lock Overhead benchmark...")
        results[.lockOverhead] = try benchmarkLockOverhead()

        // Decoder initialization
        print("➤ Running Decoder Initialization benchmark...")
        results[.decoderInit] = try benchmarkDecoderInit()

        // Decoder validation
        print("➤ Running Decoder Validation benchmark...")
        results[.decoderValidation] = try benchmarkDecoderValidation()

        // Metadata access
        print("➤ Running Metadata Access benchmark...")
        results[.metadataAccess] = try benchmarkMetadataAccess()

        return results
    }

    /// Run all windowing benchmarks
    ///
    /// - Returns: Dictionary of benchmark results by type
    /// - Throws: BenchmarkError if any benchmark fails
    public func runWindowingBenchmarks() throws -> [BenchmarkType: BenchmarkResult] {
        var results: [BenchmarkType: BenchmarkResult] = [:]

        print("\n" + String(repeating: "=", count: 70))
        print("WINDOWING BENCHMARKS")
        print(String(repeating: "=", count: 70))
        print("Image size: \(config.imageWidth)×\(config.imageHeight) (\(config.totalPixels) pixels)")

        // vDSP windowing
        print("\n➤ Running vDSP Windowing benchmark...")
        results[.windowingVDSP] = try benchmarkWindowingVDSP()

        // Metal windowing
        if MetalWindowingProcessor.isMetalAvailable {
            print("➤ Running Metal Windowing benchmark...")
            if let metalResult = try benchmarkWindowingMetal() {
                results[.windowingMetal] = metalResult
            }
        } else {
            print("⚠ Metal not available, skipping Metal benchmark")
        }

        return results
    }

    /// Run complete benchmark suite
    ///
    /// Executes all decoder and windowing benchmarks and returns comprehensive results.
    ///
    /// - Returns: BenchmarkSuiteResult containing all benchmark results
    /// - Throws: BenchmarkError if any benchmark fails
    public func runFullSuite() throws -> BenchmarkSuiteResult {
        // Validate configuration
        try config.validate()

        print("\n🚀 Starting comprehensive benchmark suite...")
        print("Configuration:")
        print("  Warmup iterations: \(config.warmupIterations)")
        print("  Benchmark iterations: \(config.benchmarkIterations)")
        print("  Verbose: \(config.verbose)")

        var allResults: [BenchmarkType: BenchmarkResult] = [:]

        // Run decoder benchmarks
        let decoderResults = try runDecoderBenchmarks()
        allResults.merge(decoderResults) { _, new in new }

        // Run windowing benchmarks
        let windowingResults = try runWindowingBenchmarks()
        allResults.merge(windowingResults) { _, new in new }

        let suiteResult = BenchmarkSuiteResult(results: allResults, config: config)

        // Print comprehensive results
        printSuiteResults(suiteResult)

        return suiteResult
    }

    // MARK: - Results Reporting

    /// Print comprehensive suite results
    ///
    /// - Parameter suiteResult: Complete suite results to print
    public func printSuiteResults(_ suiteResult: BenchmarkSuiteResult) {
        print("\n" + String(repeating: "=", count: 70))
        print("BENCHMARK SUITE RESULTS")
        print(String(repeating: "=", count: 70))
        print("Timestamp: \(suiteResult.timestamp)")
        print("Configuration: \(suiteResult.config.totalPixels) pixels, \(suiteResult.config.benchmarkIterations) iterations")

        // Decoder results
        printDecoderResults(suiteResult)

        // Windowing results
        printWindowingResults(suiteResult)

        print("\n" + String(repeating: "=", count: 70))
    }

    /// Print decoder benchmark results
    ///
    /// - Parameter suiteResult: Suite results containing decoder benchmarks
    private func printDecoderResults(_ suiteResult: BenchmarkSuiteResult) {
        print("\n" + String(repeating: "-", count: 70))
        print("DECODER PERFORMANCE")
        print(String(repeating: "-", count: 70))

        let decoderTypes: [BenchmarkType] = [.lockOverhead, .decoderInit, .decoderValidation, .metadataAccess]

        for type in decoderTypes {
            guard let result = suiteResult.result(for: type) else { continue }

            print("\n\(type.rawValue):")
            print("  Mean: \(BenchmarkResult.formatMicroseconds(result.meanTime))")
            print("  Std Dev: \(BenchmarkResult.formatMicroseconds(result.stdDevTime))")
            print("  Min: \(BenchmarkResult.formatMicroseconds(result.minTime))")
            print("  Median: \(BenchmarkResult.formatMicroseconds(result.medianTime))")
            print("  Max: \(BenchmarkResult.formatMicroseconds(result.maxTime))")
            print("  CV: \(String(format: "%.2f%%", result.coefficientOfVariation))")

            // Performance check indicators
            if result.coefficientOfVariation < 10.0 {
                print("  ✓ Low variance: Results are reliable")
            } else {
                print("  ⚠ High variance: Results may be affected by system load")
            }

            // Performance assertions
            switch type {
            case .lockOverhead:
                #if targetEnvironment(simulator)
                let threshold = 0.0001 // 100us on simulator
                #else
                let threshold = 0.000001 // 1us on device/mac
                #endif
                if result.meanTime < threshold {
                    print("  ✓ Lock overhead within acceptable threshold")
                } else {
                    print("  ⚠ Lock overhead exceeds threshold")
                }

            case .decoderInit:
                if result.meanTime < 0.001 {
                    print("  ✓ Initialization time <1ms")
                }

            case .decoderValidation:
                if result.meanTime < 0.0001 {
                    print("  ✓ Validation time <0.1ms")
                }

            case .metadataAccess:
                if result.meanTime < 0.0001 {
                    print("  ✓ Metadata access time <0.1ms")
                }

            default:
                break
            }
        }
    }

    /// Print windowing benchmark results
    ///
    /// - Parameter suiteResult: Suite results containing windowing benchmarks
    private func printWindowingResults(_ suiteResult: BenchmarkSuiteResult) {
        print("\n" + String(repeating: "-", count: 70))
        print("WINDOWING PERFORMANCE")
        print(String(repeating: "-", count: 70))

        guard let vdspResult = suiteResult.result(for: .windowingVDSP) else {
            print("\n⚠ No vDSP results available")
            return
        }

        // vDSP results
        print("\nvDSP CPU Baseline:")
        print("  Mean: \(BenchmarkResult.formatMilliseconds(vdspResult.meanTime))")
        print("  Std Dev: \(BenchmarkResult.formatMilliseconds(vdspResult.stdDevTime))")
        print("  Min: \(BenchmarkResult.formatMilliseconds(vdspResult.minTime))")
        print("  Median: \(BenchmarkResult.formatMilliseconds(vdspResult.medianTime))")
        print("  Max: \(BenchmarkResult.formatMilliseconds(vdspResult.maxTime))")
        print("  P95: \(BenchmarkResult.formatMilliseconds(vdspResult.p95Time))")
        print("  P99: \(BenchmarkResult.formatMilliseconds(vdspResult.p99Time))")
        print("  CV: \(String(format: "%.2f%%", vdspResult.coefficientOfVariation))")

        let pixelCount = suiteResult.config.totalPixels
        let throughputMBps = Double(pixelCount * 2) / vdspResult.meanTime / (1024 * 1024)
        print("  Throughput: \(String(format: "%.2f", throughputMBps)) MB/s")

        // Metal results and comparison
        if let metalResult = suiteResult.result(for: .windowingMetal) {
            print("\nMetal GPU:")
            print("  Mean: \(BenchmarkResult.formatMilliseconds(metalResult.meanTime))")
            print("  Std Dev: \(BenchmarkResult.formatMilliseconds(metalResult.stdDevTime))")
            print("  Min: \(BenchmarkResult.formatMilliseconds(metalResult.minTime))")
            print("  Median: \(BenchmarkResult.formatMilliseconds(metalResult.medianTime))")
            print("  Max: \(BenchmarkResult.formatMilliseconds(metalResult.maxTime))")
            print("  P95: \(BenchmarkResult.formatMilliseconds(metalResult.p95Time))")
            print("  P99: \(BenchmarkResult.formatMilliseconds(metalResult.p99Time))")
            print("  CV: \(String(format: "%.2f%%", metalResult.coefficientOfVariation))")

            let metalThroughputMBps = Double(pixelCount * 2) / metalResult.meanTime / (1024 * 1024)
            print("  Throughput: \(String(format: "%.2f", metalThroughputMBps)) MB/s")

            // Performance comparison
            print("\nPerformance Comparison:")
            let speedup = metalResult.speedup(comparedTo: vdspResult)
            let improvement = metalResult.percentageDifference(comparedTo: vdspResult)

            print("  Metal speedup: \(String(format: "%.2f", speedup))x")
            print("  Performance improvement: \(String(format: "%.1f", improvement))%")
            print("  Time saved: \(BenchmarkResult.formatMilliseconds(vdspResult.meanTime - metalResult.meanTime))")

            // Acceptance criteria check (for images ≥800×800, expect ≥2x speedup)
            let imageSize = suiteResult.config.imageWidth * suiteResult.config.imageHeight
            if imageSize >= 800 * 800 {
                if speedup >= 2.0 {
                    print("  ✓ PASSED: Metal achieves ≥2.00x speedup for large images")
                } else {
                    print("  ⚠ Metal speedup below 2.00x target for large images")
                }
            }
        } else {
            print("\n⚠ Metal not available on this system")
        }
    }
}
