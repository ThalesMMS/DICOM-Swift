//
//  BenchmarkRunner.swift
//  MetalBenchmark
//
//  Benchmark runner comparing Metal GPU and vDSP CPU performance for DICOM windowing operations.
//  Uses high-resolution timing to measure execution time across multiple iterations, reporting
//  statistical metrics including mean, standard deviation, and speedup ratio.
//
//  Follows timing patterns from DCMDecoderPerformanceTests.swift with CFAbsoluteTimeGetCurrent()
//  for precise measurements.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Configuration for benchmark execution
public struct BenchmarkConfig {
    /// Number of warmup iterations (not included in timing)
    public var warmupIterations: Int = 20

    /// Number of benchmark iterations for statistical analysis
    public var benchmarkIterations: Int = 100

    /// Image width in pixels (default 1024 for modern DICOM images)
    public var imageWidth: Int = 1024

    /// Image height in pixels (default 1024 for modern DICOM images)
    public var imageHeight: Int = 1024

    /// Window center for windowing operation
    public var windowCenter: Double = 2048.0

    /// Window width for windowing operation
    public var windowWidth: Double = 4096.0

    /// Enable verbose per-iteration output
    public var verbose: Bool = false

    public init() {}
}

/// Results from a single benchmark run
public struct BenchmarkResult {
    /// Mean execution time in seconds
    public let meanTime: Double

    /// Standard deviation of execution time in seconds
    public let stdDevTime: Double

    /// All individual timing measurements (seconds)
    public let timings: [Double]

    /// Number of iterations performed
    public let iterationCount: Int

    /// Coefficient of variation (stddev/mean as percentage)
    public var coefficientOfVariation: Double {
        guard meanTime > 0 else { return 0 }
        return (stdDevTime / meanTime) * 100.0
    }
}

/// Benchmark runner for comparing Metal GPU vs vDSP CPU performance
public final class BenchmarkRunner {

    private let config: BenchmarkConfig
    private var metalProcessor: MetalWindowingProcessor?

    // MARK: - Initialization

    /// Initialize benchmark runner with configuration
    ///
    /// - Parameter config: Benchmark configuration parameters
    public init(config: BenchmarkConfig = BenchmarkConfig()) {
        self.config = config
    }

    // MARK: - Setup

    /// Initialize Metal processor if available
    ///
    /// - Returns: true if Metal is available, false otherwise
    public func setupMetal() -> Bool {
        do {
            metalProcessor = try MetalWindowingProcessor()
            print("✓ Metal device: \(metalProcessor!.deviceName)")
            return true
        } catch {
            print("⚠ Metal not available: \(error)")
            return false
        }
    }

    // MARK: - Test Data Generation

    /// Generate synthetic 16-bit pixel data for benchmarking.
    /// Creates realistic DICOM-like data with gradients and variation.
    ///
    /// - Returns: Array of UInt16 pixel values
    private func generateTestPixels() -> [UInt16] {
        let pixelCount = config.imageWidth * config.imageHeight
        var pixels = [UInt16](repeating: 0, count: pixelCount)

        // Generate gradient pattern with some noise for realistic data
        for y in 0..<config.imageHeight {
            for x in 0..<config.imageWidth {
                let idx = y * config.imageWidth + x

                // Create gradient from 0 to 4095 (12-bit range)
                let baseValue = UInt16((Double(x + y) / Double(config.imageWidth + config.imageHeight)) * 4095.0)

                // Add some variation to simulate real DICOM data
                let noise = UInt16.random(in: 0..<100)
                pixels[idx] = min(4095, baseValue + noise)
            }
        }

        return pixels
    }

    // MARK: - Benchmark Execution

    /// Run Metal GPU benchmark
    ///
    /// - Returns: Benchmark results or nil if Metal unavailable
    public func benchmarkMetal() -> BenchmarkResult? {
        guard let processor = metalProcessor else {
            print("⚠ Metal processor not initialized")
            return nil
        }

        let pixels = generateTestPixels()
        let center = Float(config.windowCenter)
        let width = Float(config.windowWidth)

        // Warmup iterations
        print("\nRunning Metal warmup (\(config.warmupIterations) iterations)...")
        for _ in 0..<config.warmupIterations {
            _ = try? processor.applyWindowLevel(pixels16: pixels, center: center, width: width)
        }

        // Benchmark iterations
        print("Running Metal benchmark (\(config.benchmarkIterations) iterations)...")
        var timings = [Double]()
        timings.reserveCapacity(config.benchmarkIterations)

        for iteration in 0..<config.benchmarkIterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? processor.applyWindowLevel(pixels16: pixels, center: center, width: width)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            timings.append(elapsed)

            if config.verbose {
                print("  Iteration \(iteration + 1): \(String(format: "%.6f", elapsed))s")
            }
        }

        return calculateStatistics(timings: timings)
    }

    /// Run vDSP CPU benchmark
    ///
    /// - Returns: Benchmark results
    public func benchmarkVDSP() -> BenchmarkResult {
        let pixels = generateTestPixels()
        let center = config.windowCenter
        let width = config.windowWidth

        // Warmup iterations
        print("\nRunning vDSP warmup (\(config.warmupIterations) iterations)...")
        for _ in 0..<config.warmupIterations {
            _ = VDSPProcessor.applyWindowLevel(pixels16: pixels, center: center, width: width)
        }

        // Benchmark iterations
        print("Running vDSP benchmark (\(config.benchmarkIterations) iterations)...")
        var timings = [Double]()
        timings.reserveCapacity(config.benchmarkIterations)

        for iteration in 0..<config.benchmarkIterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = VDSPProcessor.applyWindowLevel(pixels16: pixels, center: center, width: width)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            timings.append(elapsed)

            if config.verbose {
                print("  Iteration \(iteration + 1): \(String(format: "%.6f", elapsed))s")
            }
        }

        return calculateStatistics(timings: timings)
    }

    // MARK: - Statistical Analysis

    /// Calculate mean and standard deviation from timing measurements
    ///
    /// - Parameter timings: Array of timing measurements in seconds
    /// - Returns: Benchmark result with statistical metrics
    private func calculateStatistics(timings: [Double]) -> BenchmarkResult {
        guard !timings.isEmpty else {
            return BenchmarkResult(meanTime: 0, stdDevTime: 0, timings: [], iterationCount: 0)
        }

        // Calculate mean
        let sum = timings.reduce(0.0, +)
        let mean = sum / Double(timings.count)

        // Calculate standard deviation
        let variance = timings.reduce(0.0) { acc, time in
            let diff = time - mean
            return acc + (diff * diff)
        } / Double(timings.count)
        let stdDev = sqrt(variance)

        return BenchmarkResult(
            meanTime: mean,
            stdDevTime: stdDev,
            timings: timings,
            iterationCount: timings.count
        )
    }

    // MARK: - Results Reporting

    /// Print formatted benchmark results
    ///
    /// - Parameters:
    ///   - metalResult: Metal benchmark results (nil if unavailable)
    ///   - vdspResult: vDSP benchmark results
    public func printResults(metalResult: BenchmarkResult?, vdspResult: BenchmarkResult) {
        print("\n" + String(repeating: "=", count: 70))
        print("BENCHMARK RESULTS")
        print(String(repeating: "=", count: 70))

        print("\nConfiguration:")
        print("  Image size: \(config.imageWidth)x\(config.imageHeight)")
        print("  Pixel count: \(config.imageWidth * config.imageHeight)")
        print("  Window center: \(config.windowCenter)")
        print("  Window width: \(config.windowWidth)")
        print("  Warmup iterations: \(config.warmupIterations)")
        print("  Benchmark iterations: \(config.benchmarkIterations)")

        print("\n" + String(repeating: "-", count: 70))
        print("vDSP CPU Baseline:")
        print(String(repeating: "-", count: 70))
        printResult(vdspResult, name: "vDSP")

        if let metalResult = metalResult {
            print("\n" + String(repeating: "-", count: 70))
            print("Metal GPU:")
            print(String(repeating: "-", count: 70))
            printResult(metalResult, name: "Metal")

            print("\n" + String(repeating: "-", count: 70))
            print("Performance Comparison:")
            print(String(repeating: "-", count: 70))

            let speedup = vdspResult.meanTime / metalResult.meanTime
            let speedupFormatted = String(format: "%.2f", speedup)

            print("  Metal speedup: \(speedupFormatted)x")

            if speedup >= 3.0 {
                print("  ✓ PASSED: Metal achieves ≥3.00x speedup target")
            } else {
                print("  ✗ FAILED: Metal speedup below 3.00x target")
            }

            // Additional metrics
            let vdspMs = vdspResult.meanTime * 1000.0
            let metalMs = metalResult.meanTime * 1000.0
            let improvement = ((vdspResult.meanTime - metalResult.meanTime) / vdspResult.meanTime) * 100.0

            print("  Time saved per operation: \(String(format: "%.3f", vdspMs - metalMs))ms")
            print("  Performance improvement: \(String(format: "%.1f", improvement))%")

        } else {
            print("\n⚠ Metal benchmark not available")
        }

        print("\n" + String(repeating: "=", count: 70))
    }

    /// Print individual benchmark result
    ///
    /// - Parameters:
    ///   - result: Benchmark result to print
    ///   - name: Name of the implementation
    private func printResult(_ result: BenchmarkResult, name: String) {
        let meanMs = result.meanTime * 1000.0
        let stdDevMs = result.stdDevTime * 1000.0

        print("  Mean time: \(String(format: "%.6f", result.meanTime))s (\(String(format: "%.3f", meanMs))ms)")
        print("  Std deviation: \(String(format: "%.6f", result.stdDevTime))s (\(String(format: "%.3f", stdDevMs))ms)")
        print("  Coefficient of variation: \(String(format: "%.2f", result.coefficientOfVariation))%")
        print("  Iterations: \(result.iterationCount)")

        if result.coefficientOfVariation < 10.0 {
            print("  ✓ Low variance: Results are reliable")
        } else {
            print("  ⚠ High variance: Results may be affected by system load")
        }
    }

    // MARK: - Convenience Methods

    /// Run complete benchmark suite (both Metal and vDSP)
    ///
    /// - Returns: Tuple of (Metal result, vDSP result)
    public func runFullBenchmark() -> (metal: BenchmarkResult?, vdsp: BenchmarkResult) {
        print("\n🚀 Starting benchmark suite...")
        print("Image size: \(config.imageWidth)x\(config.imageHeight)")

        // Setup Metal
        let metalAvailable = setupMetal()

        // Run vDSP benchmark (always available)
        let vdspResult = benchmarkVDSP()

        // Run Metal benchmark if available
        let metalResult = metalAvailable ? benchmarkMetal() : nil

        // Print results
        printResults(metalResult: metalResult, vdspResult: vdspResult)

        return (metalResult, vdspResult)
    }
}
