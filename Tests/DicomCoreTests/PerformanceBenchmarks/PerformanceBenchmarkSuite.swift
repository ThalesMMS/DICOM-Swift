//
//  PerformanceBenchmarkSuite.swift
//  DicomCoreTests
//
//  Comprehensive benchmark suite test harness. Runs complete benchmark suite, generates reports,
//  and performs baseline comparison with regression detection. Designed to run both locally and in
//  CI.
//
//  Follows patterns from DCMDecoderPerformanceTests.swift for XCTest integration and formatted
//  output.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

/// Comprehensive benchmark suite test harness
///
/// This test class integrates the full benchmark infrastructure:
/// - BenchmarkRunner: Executes all performance benchmarks
/// - BenchmarkReporter: Generates JSON and Markdown reports
/// - BaselineComparator: Detects performance regressions
///
/// Can be run locally for development or in CI for automated tracking:
/// ```
/// swift test --filter PerformanceBenchmarkSuite
/// ```
///
/// Environment variables for configuration:
/// - `BENCHMARK_BASELINE_PATH`: Path to baseline JSON file for comparison
/// - `BENCHMARK_OUTPUT_DIR`: Directory for output reports (default: current directory)
/// - `BENCHMARK_FAIL_ON_REGRESSION`: "true" to fail test on regressions (default: false)
/// - `BENCHMARK_ITERATIONS`: Number of benchmark iterations (default: 100)
/// - `BENCHMARK_IMAGE_SIZE`: Image size for windowing tests (default: 1024)
final class PerformanceBenchmarkSuite: XCTestCase {

    // MARK: - Configuration

    /// Output directory for benchmark reports
    private var outputDirectory: String {
        return ProcessInfo.processInfo.environment["BENCHMARK_OUTPUT_DIR"] ?? "."
    }

    /// Path to baseline file for comparison (optional)
    private var baselinePath: String? {
        return ProcessInfo.processInfo.environment["BENCHMARK_BASELINE_PATH"]
    }

    /// Whether to fail test on regression detection
    private var failOnRegression: Bool {
        return ProcessInfo.processInfo.environment["BENCHMARK_FAIL_ON_REGRESSION"] == "true"
    }

    /// Number of benchmark iterations
    private var benchmarkIterations: Int {
        if let value = ProcessInfo.processInfo.environment["BENCHMARK_ITERATIONS"],
           let iterations = Int(value) {
            return iterations
        }
        return 100 // Default
    }

    /// Image size for windowing benchmarks
    private var imageSize: Int {
        if let value = ProcessInfo.processInfo.environment["BENCHMARK_IMAGE_SIZE"],
           let size = Int(value) {
            return size
        }
        return 1024 // Default
    }

    // MARK: - Main Test

    /// Run complete benchmark suite with reporting and baseline comparison
    ///
    /// This test executes the following steps:
    /// 1. Configure benchmark runner
    /// 2. Run all benchmarks (decoder + windowing)
    /// 3. Generate JSON and Markdown reports
    /// 4. Save reports to disk
    /// 5. Compare against baseline (if provided)
    /// 6. Print comprehensive results
    /// 7. Optionally fail on regressions (if configured)
    func testCompleteBenchmarkSuite() throws {
        print("\n" + String(repeating: "=", count: 80))
        print("PERFORMANCE BENCHMARK SUITE")
        print(String(repeating: "=", count: 80))
        print("\nConfiguration:")
        print("  Output directory: \(outputDirectory)")
        print("  Baseline path: \(baselinePath ?? "none")")
        print("  Fail on regression: \(failOnRegression)")
        print("  Benchmark iterations: \(benchmarkIterations)")
        print("  Image size: \(imageSize)×\(imageSize)")
        print("")

        // Step 1: Configure benchmark runner
        let config = BenchmarkConfig(
            warmupIterations: 10,
            benchmarkIterations: benchmarkIterations,
            imageWidth: imageSize,
            imageHeight: imageSize,
            windowCenter: 50.0,
            windowWidth: 400.0,
            verbose: false
        )

        let runner = BenchmarkRunner(config: config)

        // Step 2: Run all benchmarks
        print("▶ Running complete benchmark suite...\n")
        let suiteResult = try runner.runFullSuite()

        // Step 3: Generate reports
        print("\n▶ Generating reports...\n")
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Step 4: Save reports to disk
        try saveReports(reporter: reporter, timestamp: suiteResult.timestamp)

        // Step 5: Compare against baseline (if provided)
        var comparisonResult: ComparisonResult?
        if let baselinePath = baselinePath {
            comparisonResult = try compareWithBaseline(
                suiteResult: suiteResult,
                baselinePath: baselinePath
            )
        } else {
            print("ℹ️  No baseline provided for comparison")
            print("   Set BENCHMARK_BASELINE_PATH environment variable to enable regression detection\n")
        }

        // Step 6: Print comprehensive summary
        printFinalSummary(
            suiteResult: suiteResult,
            comparisonResult: comparisonResult
        )

        // Step 7: Optionally fail on regressions
        if let comparison = comparisonResult, failOnRegression {
            try evaluateRegressions(comparison: comparison)
        }

        print("\n" + String(repeating: "=", count: 80))
        print("✅ Benchmark suite completed successfully")
        print(String(repeating: "=", count: 80) + "\n")
    }

    // MARK: - Report Generation

    /// Save JSON and Markdown reports to disk
    ///
    /// Reports are saved with timestamp-based filenames:
    /// - benchmark-results-<timestamp>.json
    /// - benchmark-results-<timestamp>.md
    ///
    /// - Parameters:
    ///   - reporter: Configured benchmark reporter
    ///   - timestamp: Timestamp for filename generation
    private func saveReports(reporter: BenchmarkReporter, timestamp: Date) throws {
        // Generate timestamp string for filenames
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestampString = dateFormatter.string(from: timestamp)

        // Save JSON report
        let jsonPath = (outputDirectory as NSString)
            .appendingPathComponent("benchmark-results-\(timestampString).json")
        try reporter.writeJSON(to: jsonPath, prettyPrinted: true)
        print("✅ JSON report saved: \(jsonPath)")

        // Save Markdown report
        let markdownPath = (outputDirectory as NSString)
            .appendingPathComponent("benchmark-results-\(timestampString).md")
        try reporter.writeMarkdown(to: markdownPath)
        print("✅ Markdown report saved: \(markdownPath)")

        print("")
    }

    // MARK: - Baseline Comparison

    /// Compare current results against baseline
    ///
    /// - Parameters:
    ///   - suiteResult: Current benchmark suite results
    ///   - baselinePath: Path to baseline JSON file
    /// - Returns: Comparison result with regression detection
    /// - Throws: Error if baseline loading or comparison fails
    private func compareWithBaseline(
        suiteResult: BenchmarkSuiteResult,
        baselinePath: String
    ) throws -> ComparisonResult {
        print("\n▶ Comparing against baseline...\n")
        print("  Baseline: \(baselinePath)\n")

        let comparator = BaselineComparator()

        // Load baseline
        let baseline = try comparator.loadBaseline(from: baselinePath)

        // Compare
        let comparison = comparator.compare(current: suiteResult, against: baseline)

        // Print comparison summary
        print(comparison.summary)

        // Save comparison report
        let comparisonPath = (outputDirectory as NSString)
            .appendingPathComponent("comparison-results-\(formatTimestamp(Date())).json")
        try saveComparisonReport(comparison: comparison, to: comparisonPath)
        print("\n✅ Comparison report saved: \(comparisonPath)\n")

        return comparison
    }

    /// Save comparison report to JSON
    ///
    /// - Parameters:
    ///   - comparison: Comparison result to save
    ///   - path: File path for JSON output
    private func saveComparisonReport(comparison: ComparisonResult, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(comparison)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Results Reporting

    /// Print final summary with key metrics and recommendations
    ///
    /// - Parameters:
    ///   - suiteResult: Benchmark suite results
    ///   - comparisonResult: Optional baseline comparison result
    private func printFinalSummary(
        suiteResult: BenchmarkSuiteResult,
        comparisonResult: ComparisonResult?
    ) {
        print("\n" + String(repeating: "=", count: 80))
        print("FINAL SUMMARY")
        print(String(repeating: "=", count: 80))

        // Performance highlights
        printPerformanceHighlights(suiteResult: suiteResult)

        // Regression summary (if available)
        if let comparison = comparisonResult {
            printRegressionSummary(comparison: comparison)
        }

        // Recommendations
        printRecommendations(
            suiteResult: suiteResult,
            comparisonResult: comparisonResult
        )
    }

    /// Print key performance highlights
    ///
    /// - Parameter suiteResult: Benchmark suite results
    private func printPerformanceHighlights(suiteResult: BenchmarkSuiteResult) {
        print("\n📊 Performance Highlights:\n")

        // Decoder performance
        if let lockOverhead = suiteResult.results[.lockOverhead] {
            let overheadUs = lockOverhead.meanTime * 1_000_000
            print("  • Lock overhead: \(String(format: "%.2f", overheadUs))µs per operation")
        }

        if let metadataAccess = suiteResult.results[.metadataAccess] {
            let accessUs = metadataAccess.meanTime * 1_000_000
            print("  • Metadata access: \(String(format: "%.2f", accessUs))µs per operation")
        }

        // Windowing performance
        if let vdspResult = suiteResult.results[.windowingVDSP] {
            let vdspMs = vdspResult.meanTime * 1000
            let throughput = Double(suiteResult.config.totalPixels) / vdspResult.meanTime / 1_000_000
            print("  • vDSP windowing: \(String(format: "%.2f", vdspMs))ms (\(String(format: "%.1f", throughput))M pixels/sec)")
        }

        if let metalResult = suiteResult.results[.windowingMetal] {
            let metalMs = metalResult.meanTime * 1000
            let throughput = Double(suiteResult.config.totalPixels) / metalResult.meanTime / 1_000_000
            print("  • Metal windowing: \(String(format: "%.2f", metalMs))ms (\(String(format: "%.1f", throughput))M pixels/sec)")

            // Calculate Metal speedup
            if let vdspResult = suiteResult.results[.windowingVDSP] {
                let speedup = metalResult.speedup(comparedTo: vdspResult)
                print("  • Metal speedup: \(String(format: "%.2fx", speedup))")

                if speedup >= 2.0 {
                    print("    ✅ Metal acceleration target achieved (≥2x)")
                } else {
                    print("    ⚠️  Metal speedup below 2x target")
                }
            }
        }
    }

    /// Print regression summary
    ///
    /// - Parameter comparison: Baseline comparison result
    private func printRegressionSummary(comparison: ComparisonResult) {
        print("\n📈 Regression Analysis:\n")

        print("  Overall status: \(statusEmoji(comparison.overallRegressionLevel)) \(comparison.overallRegressionLevel.rawValue)")

        if comparison.regressionCount > 0 {
            print("  ❌ Failures (>20% slower): \(comparison.regressionCount)")
        }

        if comparison.warningCount > 0 {
            print("  ⚠️  Warnings (>10% slower): \(comparison.warningCount)")
        }

        if comparison.improvementCount > 0 {
            print("  ✅ Improvements (>10% faster): \(comparison.improvementCount)")
        }

        if comparison.regressionCount == 0 && comparison.warningCount == 0 {
            print("  ✅ No performance regressions detected")
        }
    }

    /// Print recommendations based on results
    ///
    /// - Parameters:
    ///   - suiteResult: Benchmark suite results
    ///   - comparisonResult: Optional baseline comparison result
    private func printRecommendations(
        suiteResult: BenchmarkSuiteResult,
        comparisonResult: ComparisonResult?
    ) {
        print("\n💡 Recommendations:\n")

        var recommendations = [String]()

        // Check Metal performance
        if let vdspResult = suiteResult.results[.windowingVDSP],
           let metalResult = suiteResult.results[.windowingMetal] {
            let speedup = metalResult.speedup(comparedTo: vdspResult)

            if speedup < 1.5 {
                recommendations.append("Metal acceleration is below 1.5x - consider investigating GPU performance")
            } else if speedup < 2.0 {
                recommendations.append("Metal speedup is \(String(format: "%.2fx", speedup)) - close to 2x target")
            }
        }

        // Check for regressions
        if let comparison = comparisonResult {
            if comparison.regressionCount > 0 {
                recommendations.append("⚠️  \(comparison.regressionCount) operation(s) have significant regressions (>20%) - investigate immediately")
            }

            if comparison.warningCount > 0 {
                recommendations.append("⚠️  \(comparison.warningCount) operation(s) have minor regressions (>10%) - monitor closely")
            }
        }

        // Check coefficient of variation
        for (type, result) in suiteResult.results {
            if result.coefficientOfVariation > 20.0 {
                recommendations.append("High variability in \(type.rawValue) (CV: \(String(format: "%.1f%%", result.coefficientOfVariation))) - consider increasing iterations")
            }
        }

        // Print recommendations
        if recommendations.isEmpty {
            print("  ✅ All performance metrics look good!")
        } else {
            for (index, recommendation) in recommendations.enumerated() {
                print("  \(index + 1). \(recommendation)")
            }
        }
    }

    // MARK: - Regression Evaluation

    /// Evaluate regressions and fail test if configured
    ///
    /// - Parameter comparison: Baseline comparison result
    /// - Throws: XCTestError if regressions detected and failOnRegression is true
    private func evaluateRegressions(comparison: ComparisonResult) throws {
        if comparison.regressionCount > 0 {
            let message = """

            ❌ REGRESSION DETECTED: \(comparison.regressionCount) operation(s) are >20% slower than baseline

            See comparison results above for details.

            To update baseline with current results, run:
            cp benchmark-results-*.json Tests/DicomCoreTests/PerformanceBenchmarks/Baselines/baseline_<platform>_<arch>_<date>.json

            """
            XCTFail(message)
        } else if comparison.warningCount > 0 {
            print("\n⚠️  WARNING: \(comparison.warningCount) operation(s) are >10% slower than baseline")
            print("   Monitoring recommended - not failing test\n")
        }
    }

    // MARK: - Helpers

    /// Get emoji for regression level
    ///
    /// - Parameter level: Regression level
    /// - Returns: Emoji representing the level
    private func statusEmoji(_ level: RegressionLevel) -> String {
        switch level {
        case .none:
            return "✅"
        case .warning:
            return "⚠️"
        case .failure:
            return "❌"
        case .improvement:
            return "🚀"
        }
    }

    /// Format timestamp for filenames
    ///
    /// - Parameter date: Date to format
    /// - Returns: Formatted timestamp string
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Quick Execution Tests

extension PerformanceBenchmarkSuite {

    /// Quick test to verify benchmark infrastructure works
    ///
    /// Runs a minimal benchmark suite with fewer iterations for fast verification.
    /// Use this for development to ensure the infrastructure is working correctly.
    func testQuickBenchmarkVerification() throws {
        print("\n🚀 Running quick benchmark verification (reduced iterations)...\n")

        let config = BenchmarkConfig(
            warmupIterations: 2,
            benchmarkIterations: 10,
            imageWidth: 256,
            imageHeight: 256,
            windowCenter: 50.0,
            windowWidth: 400.0,
            verbose: false
        )

        let runner = BenchmarkRunner(config: config)
        let suiteResult = try runner.runFullSuite()

        // Verify all expected benchmarks ran
        XCTAssertNotNil(suiteResult.results[.lockOverhead], "Lock overhead benchmark should run")
        XCTAssertNotNil(suiteResult.results[.decoderInit], "Decoder init benchmark should run")
        XCTAssertNotNil(suiteResult.results[.decoderValidation], "Validation benchmark should run")
        XCTAssertNotNil(suiteResult.results[.metadataAccess], "Metadata access benchmark should run")
        XCTAssertNotNil(suiteResult.results[.windowingVDSP], "vDSP windowing benchmark should run")

        // Verify result validity
        for (type, result) in suiteResult.results {
            XCTAssertGreaterThan(result.meanTime, 0, "\(type.rawValue) should have positive mean time")
            XCTAssertGreaterThanOrEqual(result.stdDevTime, 0, "\(type.rawValue) should have non-negative stddev")

            // Lock overhead benchmark uses max(1000, config.benchmarkIterations * 10)
            // Other benchmarks use config.benchmarkIterations
            if type == .lockOverhead {
                XCTAssertGreaterThanOrEqual(result.iterationCount, 100, "\(type.rawValue) should have at least 100 iterations")
            } else {
                XCTAssertEqual(result.iterationCount, 10, "\(type.rawValue) should have correct iteration count")
            }
        }

        print("\n✅ Quick verification passed - infrastructure is working correctly\n")
    }
}
