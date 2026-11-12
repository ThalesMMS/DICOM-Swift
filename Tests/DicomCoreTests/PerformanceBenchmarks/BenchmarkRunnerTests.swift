//
//  BenchmarkRunnerTests.swift
//  DicomCoreTests
//
//  Tests for the unified BenchmarkRunner. Verifies that the benchmark runner can execute all
//  benchmark types and produce valid results.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
import DicomTestSupport
@testable import DicomCore

/// Tests for BenchmarkRunner
final class BenchmarkRunnerTests: XCTestCase {

    // MARK: - Basic Functionality Tests

    /// Test that BenchmarkRunner can be initialized with default config
    func testInitialization() {
        let runner = BenchmarkRunner()
        XCTAssertNotNil(runner, "BenchmarkRunner should initialize")
    }

    /// Test that BenchmarkRunner can be initialized with custom config
    func testInitializationWithCustomConfig() {
        var config = BenchmarkConfig()
        config.benchmarkIterations = 10
        config.warmupIterations = 5
        config.imageWidth = 512
        config.imageHeight = 512

        let runner = BenchmarkRunner(config: config)
        XCTAssertNotNil(runner, "BenchmarkRunner should initialize with custom config")
    }

    /// Test speedup calculation rejects non-positive inputs
    func testBenchmarkResultSpeedupRejectsNonPositiveInputs() {
        let valid = BenchmarkResult(meanTime: 1.0, stdDevTime: 0, timings: [1.0], iterationCount: 1)
        let zero = BenchmarkResult(meanTime: 0, stdDevTime: 0, timings: [0], iterationCount: 1)
        let negative = BenchmarkResult(meanTime: -1.0, stdDevTime: 0, timings: [-1.0], iterationCount: 1)

        XCTAssertEqual(valid.speedup(comparedTo: zero), 0)
        XCTAssertEqual(valid.speedup(comparedTo: negative), 0)
        XCTAssertEqual(zero.speedup(comparedTo: valid), 0)
        XCTAssertEqual(negative.speedup(comparedTo: valid), 0)
        XCTAssertTrue(valid.percentageDifference(comparedTo: zero).isNaN)
        XCTAssertTrue(valid.percentageDifference(comparedTo: negative).isNaN)
    }

    // MARK: - Decoder Benchmark Tests

    /// Test lock overhead benchmark
    func testLockOverheadBenchmark() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 100,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkLockOverhead()

        XCTAssertGreaterThan(result.iterationCount, 0, "Should have iterations")
        XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")
        XCTAssertGreaterThanOrEqual(result.stdDevTime, 0, "Std dev should be non-negative")
        XCTAssertGreaterThanOrEqual(result.medianTime, 0, "Median time should be non-negative after baseline subtraction")
        XCTAssertGreaterThanOrEqual(result.p95Time, 0, "P95 time should be non-negative after baseline subtraction")

        // Lock overhead should be very fast (nanoseconds to microseconds)
        XCTAssertLessThan(result.meanTime, 0.001, "Lock overhead should be <1ms")
    }

    /// Test decoder initialization benchmark
    func testDecoderInitBenchmark() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 100,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkDecoderInit()

        XCTAssertGreaterThan(result.iterationCount, 0, "Should have iterations")
        XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")

        // Decoder init should be fast
        XCTAssertLessThan(result.meanTime, 0.01, "Decoder init should be <10ms")
    }

    /// Test decoder validation benchmark
    func testDecoderValidationBenchmark() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 100,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkDecoderValidation()

        XCTAssertGreaterThan(result.iterationCount, 0, "Should have iterations")
        XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")

        // Validation check should be very fast
        XCTAssertLessThan(result.meanTime, 0.001, "Validation should be <1ms")
    }

    /// Test metadata access benchmark
    func testMetadataAccessBenchmark() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 100,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkMetadataAccess()

        XCTAssertGreaterThan(result.iterationCount, 0, "Should have iterations")
        XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")

        // Metadata access should be very fast
        XCTAssertLessThan(result.meanTime, 0.001, "Metadata access should be <1ms")
    }

    // MARK: - Windowing Benchmark Tests

    /// Test vDSP windowing benchmark
    func testWindowingVDSPBenchmark() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 50,
            imageWidth: 512,
            imageHeight: 512
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkWindowingVDSP()

        XCTAssertEqual(result.iterationCount, 50, "Should have 50 iterations")
        XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")
        XCTAssertGreaterThanOrEqual(result.stdDevTime, 0, "Std dev should be non-negative")

        // vDSP should process reasonable-sized images efficiently
        XCTAssertLessThan(result.meanTime, 1.0, "vDSP should process 512×512 in <1s")
    }

    /// Test Metal windowing benchmark (if available)
    func testWindowingMetalBenchmark() throws {
        try DicomTestRuntimePreflight.require(.metalDevice)

        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 50,
            imageWidth: 512,
            imageHeight: 512
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkWindowingMetal()

        XCTAssertNotNil(result, "Metal benchmark should return result")
        if let result = result {
            XCTAssertEqual(result.iterationCount, 50, "Should have 50 iterations")
            XCTAssertGreaterThan(result.meanTime, 0, "Mean time should be positive")
            XCTAssertGreaterThanOrEqual(result.stdDevTime, 0, "Std dev should be non-negative")

            // Metal should process efficiently
            XCTAssertLessThan(result.meanTime, 1.0, "Metal should process 512×512 in <1s")
        }
    }

    // MARK: - Suite Execution Tests

    /// Test running all decoder benchmarks
    func testRunDecoderBenchmarks() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 50,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let results = try runner.runDecoderBenchmarks()

        XCTAssertTrue(results.count >= 4, "Should have at least 4 decoder benchmarks")
        XCTAssertNotNil(results[.lockOverhead], "Should have lock overhead result")
        XCTAssertNotNil(results[.decoderInit], "Should have decoder init result")
        XCTAssertNotNil(results[.decoderValidation], "Should have decoder validation result")
        XCTAssertNotNil(results[.metadataAccess], "Should have metadata access result")

        // Verify all results are valid
        for (type, result) in results {
            XCTAssertGreaterThan(result.iterationCount, 0, "\(type.rawValue): Should have iterations")
            XCTAssertGreaterThan(result.meanTime, 0, "\(type.rawValue): Mean time should be positive")
        }
    }

    /// Test running all windowing benchmarks
    func testRunWindowingBenchmarks() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 50,
            imageWidth: 512,
            imageHeight: 512
        )
        let runner = BenchmarkRunner(config: config)

        let results = try runner.runWindowingBenchmarks()

        XCTAssertTrue(results.count >= 1, "Should have at least vDSP benchmark")
        XCTAssertNotNil(results[.windowingVDSP], "Should have vDSP result")

        // If Metal is available, should have Metal result
        if MetalWindowingProcessor.isMetalAvailable {
            XCTAssertNotNil(results[.windowingMetal], "Should have Metal result if available")
        }

        // Verify all results are valid
        for (type, result) in results {
            XCTAssertGreaterThan(result.iterationCount, 0, "\(type.rawValue): Should have iterations")
            XCTAssertGreaterThan(result.meanTime, 0, "\(type.rawValue): Mean time should be positive")
        }
    }

    /// Test running full benchmark suite
    func testRunFullSuite() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 50,
            imageWidth: 512,
            imageHeight: 512,
            verbose: false
        )
        let runner = BenchmarkRunner(config: config)

        let suiteResult = try runner.runFullSuite()

        // Verify suite result structure
        XCTAssertGreaterThan(suiteResult.results.count, 0, "Should have benchmark results")
        XCTAssertEqual(suiteResult.config.benchmarkIterations, 50, "Config should match")

        // Verify timestamp is recent
        let now = Date()
        XCTAssertLessThan(now.timeIntervalSince(suiteResult.timestamp), 60, "Timestamp should be recent")

        // Verify decoder benchmarks are present
        XCTAssertNotNil(suiteResult.result(for: .lockOverhead), "Should have lock overhead result")
        XCTAssertNotNil(suiteResult.result(for: .decoderInit), "Should have decoder init result")
        XCTAssertNotNil(suiteResult.result(for: .decoderValidation), "Should have decoder validation result")
        XCTAssertNotNil(suiteResult.result(for: .metadataAccess), "Should have metadata access result")

        // Verify windowing benchmarks are present
        XCTAssertNotNil(suiteResult.result(for: .windowingVDSP), "Should have vDSP result")
    }

    // MARK: - Configuration Validation Tests

    /// Test that invalid configuration throws error
    func testInvalidConfigurationThrows() {
        var config = BenchmarkConfig()
        config.benchmarkIterations = 0 // Invalid

        XCTAssertThrowsError(try config.validate()) { error in
            guard let benchmarkError = error as? BenchmarkError else {
                XCTFail("Should throw BenchmarkError")
                return
            }
            if case .invalidConfiguration = benchmarkError {
                // Expected
            } else {
                XCTFail("Should throw invalidConfiguration error")
            }
        }
    }

    /// Test that full suite validates configuration
    func testFullSuiteValidatesConfiguration() {
        var config = BenchmarkConfig()
        config.imageWidth = -1 // Invalid

        let runner = BenchmarkRunner(config: config)

        XCTAssertThrowsError(try runner.runFullSuite()) { error in
            guard let benchmarkError = error as? BenchmarkError else {
                XCTFail("Should throw BenchmarkError")
                return
            }
            if case .invalidConfiguration = benchmarkError {
                // Expected
            } else {
                XCTFail("Should throw invalidConfiguration error")
            }
        }
    }

    // MARK: - Result Quality Tests

    /// Test that benchmark results have reasonable coefficient of variation
    func testResultsHaveReasonableVariation() throws {
        let config = BenchmarkConfig(
            warmupIterations: 10,
            benchmarkIterations: 100,
            imageWidth: 512,
            imageHeight: 512
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkWindowingVDSP()

        // Use a trimmed sample to avoid failing on a single scheduler outlier
        // while still verifying that the central benchmark data is stable.
        let sortedTimings = result.timings.sorted()
        let trimCount = max(1, Int(Double(sortedTimings.count) * 0.1))
        let trimmedTimings = Array(sortedTimings.dropFirst(trimCount).dropLast(trimCount))
        let stableResult = try BenchmarkResult(timings: trimmedTimings)

        XCTAssertLessThan(stableResult.coefficientOfVariation, 50.0,
                         "Trimmed CV should be <50% for stable benchmarks (raw CV: \(result.coefficientOfVariation)%)")
    }

    /// Test that benchmark results have proper statistical properties
    func testResultsHaveProperStatistics() throws {
        let config = BenchmarkConfig(
            warmupIterations: 5,
            benchmarkIterations: 100,
            imageWidth: 256,
            imageHeight: 256
        )
        let runner = BenchmarkRunner(config: config)

        let result = try runner.benchmarkDecoderInit()

        // Verify statistical properties
        XCTAssertGreaterThan(result.minTime, 0, "Min time should be positive")
        XCTAssertLessThanOrEqual(result.minTime, result.meanTime, "Min should be ≤ mean")
        XCTAssertLessThanOrEqual(result.meanTime, result.maxTime, "Mean should be ≤ max")
        XCTAssertLessThanOrEqual(result.minTime, result.medianTime, "Min should be ≤ median")
        XCTAssertLessThanOrEqual(result.medianTime, result.maxTime, "Median should be ≤ max")

        // Percentiles are ordered by construction, so assert that ordering rather than
        // P95 ≥ mean: timing samples are right-skewed, and a single slow iteration can
        // legitimately pull the mean above the 95th percentile.
        XCTAssertGreaterThanOrEqual(result.p95Time, result.medianTime, "P95 should be ≥ median")
        XCTAssertLessThanOrEqual(result.p95Time, result.p99Time, "P95 should be ≤ P99")
        XCTAssertLessThanOrEqual(result.p95Time, result.maxTime, "P95 should be ≤ max")
    }
}
