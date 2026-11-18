//
//  BaselineComparatorTests.swift
//  DicomCoreTests
//
//  Tests for BaselineComparator with regression detection. Verifies baseline loading, comparison
//  logic, regression detection thresholds, and report generation.
//
//  Follows patterns from DCMDecoderPerformanceTests.swift for test structure and validation.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class BaselineComparatorTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Create sample baseline report for testing
    private func createSampleBaseline() -> BenchmarkReport {
        let platform = PlatformInfo()
        let config = BenchmarkReport.ReportConfiguration(
            config: BenchmarkConfig(
                warmupIterations: 20,
                benchmarkIterations: 100,
                imageWidth: 512,
                imageHeight: 512
            )
        )

        let results = [
            SerializableBenchmarkResult(
                type: .lockOverhead,
                result: try! BenchmarkResult(timings: [0.000050]),
                config: BenchmarkConfig()
            ),
            SerializableBenchmarkResult(
                type: .decoderInit,
                result: try! BenchmarkResult(timings: [0.000100]),
                config: BenchmarkConfig()
            ),
            SerializableBenchmarkResult(
                type: .windowingVDSP,
                result: try! BenchmarkResult(timings: [0.002000]),
                config: BenchmarkConfig()
            ),
            SerializableBenchmarkResult(
                type: .windowingMetal,
                result: try! BenchmarkResult(timings: [0.001160]),
                config: BenchmarkConfig()
            )
        ]

        return BenchmarkReport(
            timestamp: "2026-02-15T10:00:00Z",
            platform: platform,
            configuration: config,
            results: results
        )
    }

    /// Create sample current benchmark results
    private func createSampleCurrent(
        lockOverheadMultiplier: Double = 1.0,
        decoderInitMultiplier: Double = 1.0,
        windowingVDSPMultiplier: Double = 1.0,
        windowingMetalMultiplier: Double = 1.0
    ) -> BenchmarkSuiteResult {
        var results = [BenchmarkType: BenchmarkResult]()

        results[.lockOverhead] = try! BenchmarkResult(
            timings: [0.000050 * lockOverheadMultiplier]
        )
        results[.decoderInit] = try! BenchmarkResult(
            timings: [0.000100 * decoderInitMultiplier]
        )
        results[.windowingVDSP] = try! BenchmarkResult(
            timings: [0.002000 * windowingVDSPMultiplier]
        )
        results[.windowingMetal] = try! BenchmarkResult(
            timings: [0.001160 * windowingMetalMultiplier]
        )

        return BenchmarkSuiteResult(
            results: results,
            config: BenchmarkConfig()
        )
    }

    // MARK: - Initialization Tests

    func testInitializationWithDefaultThresholds() {
        let comparator = BaselineComparator()
        XCTAssertNotNil(comparator)
    }

    func testInitializationWithCustomThresholds() {
        let thresholds = BaselineComparator.Thresholds(
            warningThreshold: 15.0,
            failureThreshold: 25.0
        )
        let comparator = BaselineComparator(thresholds: thresholds)
        XCTAssertNotNil(comparator)
    }

    func testStandardThresholds() {
        let thresholds = BaselineComparator.Thresholds.standard
        XCTAssertEqual(thresholds.warningThreshold, 10.0)
        XCTAssertEqual(thresholds.failureThreshold, 20.0)
    }

    // MARK: - Comparison Tests

    func testCompareNoRegression() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent() // Same values

        let comparison = comparator.compare(current: current, against: baseline)

        XCTAssertEqual(comparison.overallRegressionLevel, .none)
        XCTAssertEqual(comparison.regressionCount, 0)
        XCTAssertEqual(comparison.warningCount, 0)
        XCTAssertEqual(comparison.improvementCount, 0)
    }

    func testCompareWithWarning() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Make lockOverhead 15% slower (warning threshold)
        let current = createSampleCurrent(lockOverheadMultiplier: 1.15)

        let comparison = comparator.compare(current: current, against: baseline)

        XCTAssertEqual(comparison.overallRegressionLevel, .warning)
        XCTAssertEqual(comparison.warningCount, 1)
        XCTAssertEqual(comparison.regressionCount, 0)
    }

    func testCompareWithFailure() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Make lockOverhead 25% slower (failure threshold)
        let current = createSampleCurrent(lockOverheadMultiplier: 1.25)

        let comparison = comparator.compare(current: current, against: baseline)

        XCTAssertEqual(comparison.overallRegressionLevel, .failure)
        XCTAssertEqual(comparison.regressionCount, 1)
        XCTAssertEqual(comparison.warningCount, 0)
    }

    func testCompareWithImprovement() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Make lockOverhead 15% faster (improvement)
        let current = createSampleCurrent(lockOverheadMultiplier: 0.85)

        let comparison = comparator.compare(current: current, against: baseline)

        XCTAssertEqual(comparison.overallRegressionLevel, .improvement)
        XCTAssertEqual(comparison.improvementCount, 1)
    }

    func testCompareWithMixedResults() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Mix of regression, warning, and improvement
        let current = createSampleCurrent(
            lockOverheadMultiplier: 1.25,  // Failure: 25% slower
            decoderInitMultiplier: 1.15,    // Warning: 15% slower
            windowingVDSPMultiplier: 0.85,  // Improvement: 15% faster
            windowingMetalMultiplier: 1.05  // None: 5% slower (within threshold)
        )

        let comparison = comparator.compare(current: current, against: baseline)

        // Overall should be failure since there's at least one failure
        XCTAssertEqual(comparison.overallRegressionLevel, .failure)
        XCTAssertEqual(comparison.regressionCount, 1)
        XCTAssertEqual(comparison.warningCount, 1)
        XCTAssertEqual(comparison.improvementCount, 1)
    }

    func testCompareDeltaCalculation() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.20) // 20% slower

        let comparison = comparator.compare(current: current, against: baseline)

        guard let lockOverheadComparison = comparison.comparisons.first(where: {
            $0.operation == "Lock Overhead"
        }) else {
            XCTFail("Lock overhead comparison not found")
            return
        }

        XCTAssertEqual(lockOverheadComparison.baselineMeanTime, 0.000050, accuracy: 0.000001)
        XCTAssertEqual(lockOverheadComparison.currentMeanTime, 0.000060, accuracy: 0.000001)
        XCTAssertEqual(lockOverheadComparison.deltaPercentage, 20.0, accuracy: 0.1)
    }

    func testCompareOnlyMatchingOperations() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()

        // Current has different operations
        var results = [BenchmarkType: BenchmarkResult]()
        results[.lockOverhead] = try! BenchmarkResult(timings: [0.000050])
        results[.metadataAccess] = try! BenchmarkResult(timings: [0.000200]) // Not in baseline

        let current = BenchmarkSuiteResult(
            results: results,
            config: BenchmarkConfig()
        )

        let comparison = comparator.compare(current: current, against: baseline)

        // Should only compare lockOverhead (the matching operation)
        XCTAssertEqual(comparison.comparisons.count, 1)
        XCTAssertEqual(comparison.comparisons[0].operation, "Lock Overhead")
    }

    // MARK: - Threshold Detection Tests

    func testExactWarningThreshold() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Exactly 10% slower
        let current = createSampleCurrent(lockOverheadMultiplier: 1.10)

        let comparison = comparator.compare(current: current, against: baseline)

        guard let lockOverheadComparison = comparison.comparisons.first(where: {
            $0.operation == "Lock Overhead"
        }) else {
            XCTFail("Lock overhead comparison not found")
            return
        }

        // Just over 10% should trigger warning
        XCTAssertEqual(lockOverheadComparison.regressionLevel, .warning)
    }

    func testExactFailureThreshold() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Exactly 20% slower
        let current = createSampleCurrent(lockOverheadMultiplier: 1.20)

        let comparison = comparator.compare(current: current, against: baseline)

        guard let lockOverheadComparison = comparison.comparisons.first(where: {
            $0.operation == "Lock Overhead"
        }) else {
            XCTFail("Lock overhead comparison not found")
            return
        }

        // Just over 20% should trigger failure
        XCTAssertEqual(lockOverheadComparison.regressionLevel, .failure)
    }

    func testCustomThresholds() {
        let thresholds = BaselineComparator.Thresholds(
            warningThreshold: 5.0,
            failureThreshold: 15.0
        )
        let comparator = BaselineComparator(thresholds: thresholds)
        let baseline = createSampleBaseline()
        // 10% slower - would be warning with standard thresholds, failure with custom
        let current = createSampleCurrent(lockOverheadMultiplier: 1.10)

        let comparison = comparator.compare(current: current, against: baseline)

        // Should be warning (between 5% and 15%)
        XCTAssertEqual(comparison.overallRegressionLevel, .warning)
    }

    // MARK: - Report Generation Tests

    func testComparisonResultSummary() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.25)

        let comparison = comparator.compare(current: current, against: baseline)
        let summary = comparison.summary

        XCTAssertTrue(summary.contains("Baseline Comparison Summary"))
        XCTAssertTrue(summary.contains("Lock Overhead"))
        XCTAssertTrue(summary.contains("Failure"))
    }

    func testOperationComparisonSummary() {
        let comparison = OperationComparison(
            operation: "Lock Overhead",
            baselineMeanTime: 0.000050,
            currentMeanTime: 0.000060,
            deltaSeconds: 0.000010,
            deltaPercentage: 20.0,
            regressionLevel: .failure
        )

        let summary = comparison.summary

        XCTAssertTrue(summary.contains("Lock Overhead"))
        XCTAssertTrue(summary.contains("Baseline:"))
        XCTAssertTrue(summary.contains("Current:"))
        XCTAssertTrue(summary.contains("Delta:"))
        XCTAssertTrue(summary.contains("Status:"))
        XCTAssertTrue(summary.contains("Failure"))
    }

    func testMarkdownReportGeneration() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.15)

        let comparison = comparator.compare(current: current, against: baseline)
        let markdown = comparator.generateMarkdownReport(for: comparison)

        XCTAssertTrue(markdown.contains("# Performance Regression Report"))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Detailed Results"))
        XCTAssertTrue(markdown.contains("## Legend"))
        XCTAssertTrue(markdown.contains("| Operation | Baseline | Current | Delta | Change | Status |"))
    }

    func testJSONReportGeneration() throws {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.15)

        let comparison = comparator.compare(current: current, against: baseline)
        let jsonString = try comparator.generateJSONReport(for: comparison)

        XCTAssertFalse(jsonString.isEmpty)
        XCTAssertTrue(jsonString.contains("\"operation\""))
        XCTAssertTrue(jsonString.contains("\"deltaPercentage\""))
        XCTAssertTrue(jsonString.contains("\"regressionLevel\""))

        // Verify it's valid JSON by decoding
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ComparisonResult.self, from: data)
        XCTAssertEqual(decoded.comparisons.count, comparison.comparisons.count)
    }

    func testJSONReportPrettyPrinted() throws {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent()

        let comparison = comparator.compare(current: current, against: baseline)

        let prettyJSON = try comparator.generateJSONReport(for: comparison, prettyPrinted: true)
        let compactJSON = try comparator.generateJSONReport(for: comparison, prettyPrinted: false)

        // Pretty printed should have more characters (whitespace)
        XCTAssertGreaterThan(prettyJSON.count, compactJSON.count)
        XCTAssertTrue(prettyJSON.contains("\n"))
    }

    // MARK: - File I/O Tests

    func testSaveAndLoadBaseline() throws {
        let tempDir = NSTemporaryDirectory()
        let baselinePath = (tempDir as NSString).appendingPathComponent("test_baseline.json")

        // Create and save baseline
        let baseline = createSampleBaseline()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(baseline)
        try data.write(to: URL(fileURLWithPath: baselinePath))

        // Load baseline
        let comparator = BaselineComparator()
        let loaded = try comparator.loadBaseline(from: baselinePath)

        XCTAssertEqual(loaded.timestamp, baseline.timestamp)
        XCTAssertEqual(loaded.results.count, baseline.results.count)

        // Cleanup
        try? FileManager.default.removeItem(atPath: baselinePath)
    }

    func testWriteMarkdownReport() throws {
        let tempDir = NSTemporaryDirectory()
        let reportPath = (tempDir as NSString).appendingPathComponent("test_report.md")

        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.15)
        let comparison = comparator.compare(current: current, against: baseline)

        try comparator.writeMarkdownReport(for: comparison, to: reportPath)

        // Verify file exists and has content
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath))
        let content = try String(contentsOfFile: reportPath, encoding: .utf8)
        XCTAssertTrue(content.contains("# Performance Regression Report"))

        // Cleanup
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    func testWriteJSONReport() throws {
        let tempDir = NSTemporaryDirectory()
        let reportPath = (tempDir as NSString).appendingPathComponent("test_report.json")

        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent(lockOverheadMultiplier: 1.15)
        let comparison = comparator.compare(current: current, against: baseline)

        try comparator.writeJSONReport(for: comparison, to: reportPath)

        // Verify file exists and has valid JSON
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ComparisonResult.self, from: data)
        XCTAssertEqual(decoded.comparisons.count, comparison.comparisons.count)

        // Cleanup
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    // MARK: - Edge Cases

    func testCompareEmptyResults() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = BenchmarkSuiteResult(
            results: [:],
            config: BenchmarkConfig()
        )

        let comparison = comparator.compare(current: current, against: baseline)

        XCTAssertEqual(comparison.comparisons.count, 0)
        XCTAssertEqual(comparison.overallRegressionLevel, .none)
    }

    func testCompareNegativeDelta() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // Make significantly faster (20% improvement)
        let current = createSampleCurrent(lockOverheadMultiplier: 0.80)

        let comparison = comparator.compare(current: current, against: baseline)

        guard let lockOverheadComparison = comparison.comparisons.first(where: {
            $0.operation == "Lock Overhead"
        }) else {
            XCTFail("Lock overhead comparison not found")
            return
        }

        XCTAssertLessThan(lockOverheadComparison.deltaPercentage, 0)
        XCTAssertEqual(lockOverheadComparison.regressionLevel, .improvement)
    }

    func testCompareVerySmallDifference() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        // 1% slower (well within threshold)
        let current = createSampleCurrent(lockOverheadMultiplier: 1.01)

        let comparison = comparator.compare(current: current, against: baseline)

        guard let lockOverheadComparison = comparison.comparisons.first(where: {
            $0.operation == "Lock Overhead"
        }) else {
            XCTFail("Lock overhead comparison not found")
            return
        }

        XCTAssertEqual(lockOverheadComparison.regressionLevel, .none)
    }

    // MARK: - Real-World Scenario Tests

    func testRealWorldRegressionScenario() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()

        // Simulate a realistic regression scenario:
        // - Lock overhead increased by 30% (possible regression in locking code)
        // - Decoder init slightly slower (8%, within threshold)
        // - vDSP windowing unchanged
        // - Metal windowing improved by 12% (optimization)
        let current = createSampleCurrent(
            lockOverheadMultiplier: 1.30,   // Failure
            decoderInitMultiplier: 1.08,    // None (within threshold)
            windowingVDSPMultiplier: 1.00,  // None (unchanged)
            windowingMetalMultiplier: 0.88  // Improvement
        )

        let comparison = comparator.compare(current: current, against: baseline)

        print("""

        ========== Real-World Regression Scenario ==========
        \(comparison.summary)
        ===================================================

        """)

        XCTAssertEqual(comparison.overallRegressionLevel, .failure)
        XCTAssertEqual(comparison.regressionCount, 1) // lock overhead
        XCTAssertEqual(comparison.improvementCount, 1) // metal windowing
    }

    func testMetalAccelerationValidation() {
        let comparator = BaselineComparator()
        let baseline = createSampleBaseline()
        let current = createSampleCurrent()

        let comparison = comparator.compare(current: current, against: baseline)

        // Find Metal and vDSP comparisons
        guard let metalComparison = comparison.comparisons.first(where: {
            $0.operation == "Windowing (Metal)"
        }) else {
            XCTFail("Metal comparison not found")
            return
        }

        guard let vdspComparison = comparison.comparisons.first(where: {
            $0.operation == "Windowing (vDSP)"
        }) else {
            XCTFail("vDSP comparison not found")
            return
        }

        // Metal should be faster than vDSP
        XCTAssertLessThan(
            metalComparison.currentMeanTime,
            vdspComparison.currentMeanTime,
            "Metal should be faster than vDSP"
        )

        print("""

        ========== Metal Acceleration Validation ==========
        vDSP time: \(BenchmarkResult.formatMilliseconds(vdspComparison.currentMeanTime))
        Metal time: \(BenchmarkResult.formatMilliseconds(metalComparison.currentMeanTime))
        Speedup: \(String(format: "%.2fx", vdspComparison.currentMeanTime / metalComparison.currentMeanTime))
        ==================================================

        """)
    }
}
