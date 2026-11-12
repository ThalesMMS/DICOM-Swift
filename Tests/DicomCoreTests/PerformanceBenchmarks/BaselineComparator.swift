//
//  BaselineComparator.swift
//  DicomCoreTests
//
//  Baseline comparator with regression detection. Compares current benchmark results against stored
//  baselines to detect performance regressions. Supports >10% warning threshold and >20% failure.
//
//  Follows patterns from DCMDecoderPerformanceTests.swift for statistical analysis and formatted
//  reporting.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - Regression Level

/// Severity level of performance regression
enum RegressionLevel: String, Codable {
    case none = "No Regression"
    case warning = "Warning"  // >10% slower
    case failure = "Failure"  // >20% slower
    case improvement = "Improvement"
}

// MARK: - Operation Comparison

/// Comparison result for a single operation
struct OperationComparison: Codable {
    let operation: String
    let baselineMeanTime: Double
    let currentMeanTime: Double
    let deltaSeconds: Double
    let deltaPercentage: Double
    let regressionLevel: RegressionLevel

    /// Human-readable summary of comparison
    var summary: String {
        let direction = deltaPercentage > 0 ? "slower" : "faster"
        let absPercentage = abs(deltaPercentage)

        return """
        \(operation):
          Baseline: \(BenchmarkResult.formatMilliseconds(baselineMeanTime))
          Current:  \(BenchmarkResult.formatMilliseconds(currentMeanTime))
          Delta:    \(String(format: "%.1f%%", absPercentage)) \(direction)
          Status:   \(regressionLevel.rawValue)
        """
    }
}

// MARK: - Comparison Result

/// Complete comparison result between baseline and current benchmarks
struct ComparisonResult: Codable {
    let timestamp: Date
    let baselineTimestamp: String
    let comparisons: [OperationComparison]
    let overallRegressionLevel: RegressionLevel
    let regressionCount: Int
    let warningCount: Int
    let improvementCount: Int

    /// Initialize comparison result
    init(
        baselineTimestamp: String,
        comparisons: [OperationComparison]
    ) {
        self.timestamp = Date()
        self.baselineTimestamp = baselineTimestamp
        self.comparisons = comparisons

        // Calculate regression statistics
        var regressions = 0
        var warnings = 0
        var improvements = 0

        for comparison in comparisons {
            switch comparison.regressionLevel {
            case .failure:
                regressions += 1
            case .warning:
                warnings += 1
            case .improvement:
                improvements += 1
            case .none:
                break
            }
        }

        self.regressionCount = regressions
        self.warningCount = warnings
        self.improvementCount = improvements

        // Determine overall regression level
        if regressions > 0 {
            self.overallRegressionLevel = .failure
        } else if warnings > 0 {
            self.overallRegressionLevel = .warning
        } else if improvements > 0 {
            self.overallRegressionLevel = .improvement
        } else {
            self.overallRegressionLevel = .none
        }
    }

    /// Human-readable summary
    var summary: String {
        var lines = [String]()

        lines.append("========== Baseline Comparison Summary ==========")
        lines.append("Baseline: \(baselineTimestamp)")
        lines.append("Current:  \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("Overall Status: \(overallRegressionLevel.rawValue)")
        lines.append("")

        if regressionCount > 0 {
            lines.append("⚠️  Regressions (>20%): \(regressionCount)")
        }
        if warningCount > 0 {
            lines.append("⚠️  Warnings (>10%): \(warningCount)")
        }
        if improvementCount > 0 {
            lines.append("✅ Improvements: \(improvementCount)")
        }

        lines.append("")
        lines.append("Detailed Comparisons:")
        lines.append("")

        for comparison in comparisons {
            lines.append(comparison.summary)
            lines.append("")
        }

        lines.append("=================================================")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Baseline Comparator

/// Compares benchmark results against stored baselines to detect regressions
final class BaselineComparator {

    /// Regression detection thresholds
    struct Thresholds {
        /// Warning threshold: operations slower than this percentage trigger warning
        let warningThreshold: Double

        /// Failure threshold: operations slower than this percentage trigger failure
        let failureThreshold: Double

        /// Default thresholds (warning: 10%, failure: 20%)
        static let standard = Thresholds(warningThreshold: 10.0, failureThreshold: 20.0)

        /// Initialize thresholds
        init(warningThreshold: Double, failureThreshold: Double) {
            self.warningThreshold = warningThreshold
            self.failureThreshold = failureThreshold
        }
    }

    private let thresholds: Thresholds

    // MARK: - Initialization

    /// Initialize baseline comparator
    ///
    /// - Parameter thresholds: Regression detection thresholds (default: standard)
    init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    // MARK: - Baseline Loading

    /// Load baseline from JSON file
    ///
    /// - Parameter path: Path to baseline JSON file
    /// - Returns: Loaded baseline report
    /// - Throws: Error if loading or parsing fails
    func loadBaseline(from path: String) throws -> BenchmarkReport {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(BenchmarkReport.self, from: data)
    }

    /// Find baseline file matching platform and architecture
    ///
    /// Searches for baseline files in the Baselines directory matching the pattern:
    /// baseline_<platform>_<architecture>_<date>.json
    ///
    /// - Parameters:
    ///   - directory: Directory to search for baselines
    ///   - platform: Platform name (e.g., "macOS", "iOS")
    ///   - architecture: Architecture (e.g., "arm64", "x86_64")
    /// - Returns: Path to most recent matching baseline, or nil if not found
    func findBaseline(
        inDirectory directory: String,
        platform: String,
        architecture: String
    ) -> String? {
        let fileManager = FileManager.default

        // Get all JSON files in directory
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        // Filter to matching baselines
        let prefix = "baseline_\(platform)_\(architecture)_"
        let matchingFiles = files
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted(by: >) // Sort descending to get most recent first

        guard let mostRecent = matchingFiles.first else {
            return nil
        }

        return (directory as NSString).appendingPathComponent(mostRecent)
    }

    // MARK: - Comparison

    /// Compare current results against baseline
    ///
    /// - Parameters:
    ///   - current: Current benchmark suite results
    ///   - baseline: Baseline benchmark report
    /// - Returns: Comparison result with regression detection
    func compare(
        current: BenchmarkSuiteResult,
        against baseline: BenchmarkReport
    ) -> ComparisonResult {
        var comparisons = [OperationComparison]()

        // Build lookup dictionary from baseline results
        var baselineResults = [String: SerializableBenchmarkResult]()
        for result in baseline.results {
            baselineResults[result.operation] = result
        }

        // Compare each operation
        for (type, currentResult) in current.results {
            let operationName = mapTypeToOperationName(type)

            guard let baselineResult = baselineResults[operationName] else {
                // No baseline for this operation, skip
                continue
            }

            let comparison = compareOperation(
                operation: operationName,
                current: currentResult,
                baseline: baselineResult
            )

            comparisons.append(comparison)
        }

        // Sort comparisons by operation name for consistent output
        comparisons.sort { $0.operation < $1.operation }

        return ComparisonResult(
            baselineTimestamp: baseline.timestamp,
            comparisons: comparisons
        )
    }

    /// Compare a single operation
    private func compareOperation(
        operation: String,
        current: BenchmarkResult,
        baseline: SerializableBenchmarkResult
    ) -> OperationComparison {
        let baselineMean = baseline.meanTimeSeconds
        let currentMean = current.meanTime

        // Calculate delta
        let deltaSeconds = currentMean - baselineMean
        let deltaPercentage = (deltaSeconds / baselineMean) * 100.0

        // Determine regression level
        let regressionLevel: RegressionLevel
        if deltaPercentage >= thresholds.failureThreshold {
            regressionLevel = .failure
        } else if deltaPercentage >= thresholds.warningThreshold {
            regressionLevel = .warning
        } else if deltaPercentage <= -thresholds.warningThreshold {
            // Significantly faster than baseline
            regressionLevel = .improvement
        } else {
            regressionLevel = .none
        }

        return OperationComparison(
            operation: operation,
            baselineMeanTime: baselineMean,
            currentMeanTime: currentMean,
            deltaSeconds: deltaSeconds,
            deltaPercentage: deltaPercentage,
            regressionLevel: regressionLevel
        )
    }

    // MARK: - Helper Methods

    /// Map BenchmarkType to operation name used in baseline
    private func mapTypeToOperationName(_ type: BenchmarkType) -> String {
        // SerializableBenchmarkResult uses type.rawValue for operation names
        return type.rawValue
    }

    // MARK: - Report Generation

    /// Generate markdown comparison report
    ///
    /// - Parameter comparison: Comparison result
    /// - Returns: Markdown formatted comparison report
    func generateMarkdownReport(for comparison: ComparisonResult) -> String {
        var markdown = [String]()

        markdown.append("# Performance Regression Report\n")

        // Summary
        markdown.append("## Summary\n")
        markdown.append("- **Baseline**: \(comparison.baselineTimestamp)")
        markdown.append("- **Current**: \(ISO8601DateFormatter().string(from: comparison.timestamp))")
        markdown.append("- **Overall Status**: \(comparison.overallRegressionLevel.rawValue)")
        markdown.append("")

        if comparison.regressionCount > 0 {
            markdown.append("⚠️ **\(comparison.regressionCount) regressions detected** (>20% slower)")
            markdown.append("")
        }
        if comparison.warningCount > 0 {
            markdown.append("⚠️ **\(comparison.warningCount) warnings** (>10% slower)")
            markdown.append("")
        }
        if comparison.improvementCount > 0 {
            markdown.append("✅ **\(comparison.improvementCount) improvements** (>10% faster)")
            markdown.append("")
        }

        // Detailed results table
        markdown.append("## Detailed Results\n")
        markdown.append("| Operation | Baseline | Current | Delta | Change | Status |")
        markdown.append("|-----------|----------|---------|-------|--------|--------|")

        for comparison in comparison.comparisons {
            let baseline = BenchmarkResult.formatMilliseconds(comparison.baselineMeanTime)
            let current = BenchmarkResult.formatMilliseconds(comparison.currentMeanTime)
            let delta = BenchmarkResult.formatMilliseconds(abs(comparison.deltaSeconds))
            let change = String(format: "%.1f%%", comparison.deltaPercentage)
            let status = statusEmoji(for: comparison.regressionLevel)

            markdown.append("| \(comparison.operation) | \(baseline) | \(current) | \(delta) | \(change) | \(status) |")
        }

        markdown.append("")

        // Legend
        markdown.append("## Legend\n")
        markdown.append("- ✅ Improvement (>10% faster)")
        markdown.append("- 🟢 No regression (within ±10%)")
        markdown.append("- ⚠️ Warning (>10% slower)")
        markdown.append("- ❌ Failure (>20% slower)")

        return markdown.joined(separator: "\n")
    }

    /// Write markdown comparison report to file
    ///
    /// - Parameters:
    ///   - comparison: Comparison result
    ///   - path: File path to write report
    /// - Throws: Error if writing fails
    func writeMarkdownReport(
        for comparison: ComparisonResult,
        to path: String
    ) throws {
        let markdown = generateMarkdownReport(for: comparison)
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Generate JSON comparison report
    ///
    /// - Parameters:
    ///   - comparison: Comparison result
    ///   - prettyPrinted: Enable pretty printing (default: true)
    /// - Returns: JSON string representation
    /// - Throws: Error if encoding fails
    func generateJSONReport(
        for comparison: ComparisonResult,
        prettyPrinted: Bool = true
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        let data = try encoder.encode(comparison)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw BenchmarkError.benchmarkFailed("Failed to convert JSON data to string")
        }

        return jsonString
    }

    /// Write JSON comparison report to file
    ///
    /// - Parameters:
    ///   - comparison: Comparison result
    ///   - path: File path to write report
    ///   - prettyPrinted: Enable pretty printing (default: true)
    /// - Throws: Error if writing fails
    func writeJSONReport(
        for comparison: ComparisonResult,
        to path: String,
        prettyPrinted: Bool = true
    ) throws {
        let jsonString = try generateJSONReport(for: comparison, prettyPrinted: prettyPrinted)
        try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Helpers

    private func statusEmoji(for level: RegressionLevel) -> String {
        switch level {
        case .none:
            return "🟢"
        case .warning:
            return "⚠️"
        case .failure:
            return "❌"
        case .improvement:
            return "✅"
        }
    }
}
