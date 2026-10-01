//
//  BenchmarkReporterTests.swift
//  DicomCore
//
//  Tests for BenchmarkReporter JSON and markdown generation.
//  Verifies report formatting, serialization, and file output.
//
//  Created by automated performance benchmarking suite.
//

import XCTest
@testable import DicomCore

final class BenchmarkReporterTests: XCTestCase {

    // MARK: - Test Helpers

    func test_modelIdentifier_nullTerminatedBufferExcludesTerminatorAndTrailingBytes() {
        let machine = Array("Mac16,12".utf8).map { CChar(bitPattern: $0) } + [0, 88]

        XCTAssertEqual(PlatformInfo.decodeModelIdentifier(machine), "Mac16,12")
    }

    func test_modelIdentifier_bufferWithoutTerminatorDecodesItsBoundedContents() {
        let machine = Array("Mac16,12".utf8).map { CChar(bitPattern: $0) }

        XCTAssertEqual(PlatformInfo.decodeModelIdentifier(machine), "Mac16,12")
    }

    /// Create sample benchmark results for testing
    private func createSampleResults() -> BenchmarkSuiteResult {
        let config = BenchmarkConfig(
            warmupIterations: 10,
            benchmarkIterations: 50,
            imageWidth: 512,
            imageHeight: 512
        )

        // Create sample timings for different operations
        let lockTimings = (0..<50).map { _ in 0.000001 + Double.random(in: -0.0000002...0.0000002) }
        let initTimings = (0..<50).map { _ in 0.0001 + Double.random(in: -0.00002...0.00002) }
        let vdspTimings = (0..<50).map { _ in 0.005 + Double.random(in: -0.0005...0.0005) }
        let metalTimings = (0..<50).map { _ in 0.002 + Double.random(in: -0.0002...0.0002) }

        var results: [BenchmarkType: BenchmarkResult] = [:]

        do {
            results[.lockOverhead] = try BenchmarkResult(timings: lockTimings, peakMemoryBytes: 16_777_216)
            results[.decoderInit] = try BenchmarkResult(timings: initTimings, peakMemoryBytes: 16_777_216)
            results[.windowingVDSP] = try BenchmarkResult(timings: vdspTimings, peakMemoryBytes: 33_554_432)
            results[.windowingMetal] = try BenchmarkResult(timings: metalTimings, peakMemoryBytes: 41_943_040)
        } catch {
            XCTFail("Failed to create sample results: \(error)")
        }

        return BenchmarkSuiteResult(results: results, config: config)
    }

    // MARK: - JSON Generation Tests

    func testJSONGeneration() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Generate JSON
        let jsonString = try reporter.generateJSON()

        // Verify it's valid JSON by parsing it back
        guard let jsonData = jsonString.data(using: .utf8) else {
            XCTFail("Failed to convert JSON string to data")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let _ = try decoder.decode(BenchmarkReport.self, from: jsonData)

        // Verify JSON contains expected fields
        XCTAssertTrue(jsonString.contains("timestamp"))
        XCTAssertTrue(jsonString.contains("platform"))
        XCTAssertTrue(jsonString.contains("configuration"))
        XCTAssertTrue(jsonString.contains("results"))
        XCTAssertTrue(jsonString.contains("meanTimeSeconds"))
        XCTAssertTrue(jsonString.contains("iterations"))
        XCTAssertTrue(jsonString.contains("peakMemoryBytes"))
    }

    func testJSONContainsAllResults() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let jsonString = try reporter.generateJSON()

        // Verify all benchmark types are present
        XCTAssertTrue(jsonString.contains("Lock Overhead"))
        XCTAssertTrue(jsonString.contains("Decoder Initialization"))
        XCTAssertTrue(jsonString.contains("Windowing (vDSP)"))
        XCTAssertTrue(jsonString.contains("Windowing (Metal)"))
    }

    func testJSONContainsPlatformInfo() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let jsonString = try reporter.generateJSON()

        // Verify platform information is included
        XCTAssertTrue(jsonString.contains("operatingSystem"))
        XCTAssertTrue(jsonString.contains("osVersion"))
        XCTAssertTrue(jsonString.contains("architecture"))
        XCTAssertTrue(jsonString.contains("processorCount"))
        XCTAssertTrue(jsonString.contains("physicalMemoryBytes"))
    }

    func testJSONContainsConfiguration() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let jsonString = try reporter.generateJSON()

        // Verify configuration is included
        XCTAssertTrue(jsonString.contains("warmupIterations"))
        XCTAssertTrue(jsonString.contains("benchmarkIterations"))
        XCTAssertTrue(jsonString.contains("imageWidth"))
        XCTAssertTrue(jsonString.contains("imageHeight"))
        XCTAssertTrue(jsonString.contains("totalPixels"))
        XCTAssertTrue(jsonString.contains("buildConfiguration"))
    }

    func testJSONContainsStatistics() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let jsonString = try reporter.generateJSON()

        // Verify statistical metrics are included
        XCTAssertTrue(jsonString.contains("meanTimeSeconds"))
        XCTAssertTrue(jsonString.contains("stdDevSeconds"))
        XCTAssertTrue(jsonString.contains("minTimeSeconds"))
        XCTAssertTrue(jsonString.contains("maxTimeSeconds"))
        XCTAssertTrue(jsonString.contains("medianTimeSeconds"))
        XCTAssertTrue(jsonString.contains("p95TimeSeconds"))
        XCTAssertTrue(jsonString.contains("p99TimeSeconds"))
        XCTAssertTrue(jsonString.contains("coefficientOfVariation"))
    }

    func testJSONContainsThroughputForWindowingOperations() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let jsonString = try reporter.generateJSON()

        // Verify throughput metrics are included for windowing operations
        XCTAssertTrue(jsonString.contains("throughputPixelsPerSecond"))
    }

    // MARK: - Markdown Generation Tests

    func testMarkdownGeneration() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify markdown structure
        XCTAssertTrue(markdown.contains("# Benchmark Results"))
        XCTAssertTrue(markdown.contains("## Metadata"))
        XCTAssertTrue(markdown.contains("## Configuration"))
        XCTAssertTrue(markdown.contains("## Results"))
    }

    func testMarkdownContainsMetadata() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify metadata section
        XCTAssertTrue(markdown.contains("Timestamp"))
        XCTAssertTrue(markdown.contains("Platform"))
        XCTAssertTrue(markdown.contains("Architecture"))
        XCTAssertTrue(markdown.contains("Processor Count"))
    }

    func testMarkdownContainsConfiguration() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify configuration section
        XCTAssertTrue(markdown.contains("Warmup Iterations"))
        XCTAssertTrue(markdown.contains("Benchmark Iterations"))
        XCTAssertTrue(markdown.contains("Image Size"))
        XCTAssertTrue(markdown.contains("512 × 512"))
    }

    func testMarkdownContainsResultsTable() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify results table structure
        XCTAssertTrue(markdown.contains("| Operation | Iterations | Mean | Std Dev | Min | Max | P95 | P99 | CV | Peak Memory |"))
        XCTAssertTrue(markdown.contains("|-----------|------------|------|---------|-----|-----|-----|-----|----|-------------|"))

        // Verify operation names in table
        XCTAssertTrue(markdown.contains("Lock Overhead"))
        XCTAssertTrue(markdown.contains("Decoder Initialization"))
        XCTAssertTrue(markdown.contains("Windowing (vDSP)"))
        XCTAssertTrue(markdown.contains("Windowing (Metal)"))
    }

    func testMarkdownContainsThroughputMetrics() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify throughput metrics section
        XCTAssertTrue(markdown.contains("## Throughput Metrics"))
        XCTAssertTrue(markdown.contains("| Operation | Pixels/Second | MB/Second |"))
        XCTAssertTrue(markdown.contains("|-----------|---------------|-----------|"))
    }

    func testMarkdownContainsMetalComparison() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Verify Metal vs vDSP comparison section
        XCTAssertTrue(markdown.contains("## Metal vs vDSP Comparison"))
        XCTAssertTrue(markdown.contains("Speedup"))
        XCTAssertTrue(markdown.contains("Performance Improvement"))
    }

    func testMarkdownMetalComparisonUsesMetalAsComparedResult() throws {
        var results: [BenchmarkType: BenchmarkResult] = [:]
        results[.windowingVDSP] = try BenchmarkResult(timings: [0.200])
        results[.windowingMetal] = try BenchmarkResult(timings: [0.100])

        let suiteResult = BenchmarkSuiteResult(results: results, config: BenchmarkConfig())
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        XCTAssertTrue(markdown.contains("- **Speedup**: 2.00x"))
        XCTAssertTrue(markdown.contains("- **Performance Improvement**: +100.0% faster"))
    }

    func testMarkdownMetalComparisonReportsSlowerMetal() throws {
        var results: [BenchmarkType: BenchmarkResult] = [:]
        results[.windowingVDSP] = try BenchmarkResult(timings: [0.100])
        results[.windowingMetal] = try BenchmarkResult(timings: [0.125])

        let suiteResult = BenchmarkSuiteResult(results: results, config: BenchmarkConfig())
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        XCTAssertTrue(markdown.contains("- **Speedup**: 0.80x"))
        XCTAssertTrue(markdown.contains("- **Performance Degradation**: 20.0% slower"))
    }

    func testMarkdownMetalComparisonIndicator() {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let markdown = reporter.generateMarkdown()

        // Should show success indicator since Metal is faster in sample data
        XCTAssertTrue(
            markdown.contains("✅") ||
            markdown.contains("⚠️") ||
            markdown.contains("❌"),
            "Markdown should contain performance indicator"
        )
    }

    // MARK: - File Output Tests

    func testWriteJSONToFile() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Create temporary file path
        let tempDir = NSTemporaryDirectory()
        let filePath = (tempDir as NSString).appendingPathComponent("test_benchmark_\(UUID().uuidString).json")

        // Write JSON to file
        try reporter.writeJSON(to: filePath)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))

        // Read and verify content
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(content.contains("timestamp"))
        XCTAssertTrue(content.contains("results"))

        // Clean up
        try? FileManager.default.removeItem(atPath: filePath)
    }

    func testWriteMarkdownToFile() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Create temporary file path
        let tempDir = NSTemporaryDirectory()
        let filePath = (tempDir as NSString).appendingPathComponent("test_benchmark_\(UUID().uuidString).md")

        // Write markdown to file
        try reporter.writeMarkdown(to: filePath)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))

        // Read and verify content
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(content.contains("# Benchmark Results"))
        XCTAssertTrue(content.contains("## Results"))

        // Clean up
        try? FileManager.default.removeItem(atPath: filePath)
    }

    // MARK: - Convenience Method Tests

    func testGenerateReportWithFormat() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Test JSON format
        let jsonReport = try reporter.generateReport(format: .json)
        XCTAssertTrue(jsonReport.contains("timestamp"))

        // Test Markdown format
        let markdownReport = try reporter.generateReport(format: .markdown)
        XCTAssertTrue(markdownReport.contains("# Benchmark Results"))
    }

    func testWriteReportWithFormat() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        let tempDir = NSTemporaryDirectory()

        // Test JSON format
        let jsonPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).json")
        try reporter.writeReport(format: .json, to: jsonPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath))
        try? FileManager.default.removeItem(atPath: jsonPath)

        // Test Markdown format
        let mdPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).md")
        try reporter.writeReport(format: .markdown, to: mdPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))
        try? FileManager.default.removeItem(atPath: mdPath)
    }

    // MARK: - Edge Cases

    func testEmptyResults() {
        let config = BenchmarkConfig()
        let emptyResults: [BenchmarkType: BenchmarkResult] = [:]
        let suiteResult = BenchmarkSuiteResult(results: emptyResults, config: config)
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Should not crash with empty results
        XCTAssertNoThrow(try reporter.generateJSON())
        XCTAssertNoThrow(reporter.generateMarkdown())
    }

    func testSingleResult() throws {
        let config = BenchmarkConfig()
        let timings = (0..<10).map { _ in 0.001 }
        let result = try BenchmarkResult(timings: timings)
        let results: [BenchmarkType: BenchmarkResult] = [.lockOverhead: result]
        let suiteResult = BenchmarkSuiteResult(results: results, config: config)
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Should handle single result
        let json = try reporter.generateJSON()
        XCTAssertTrue(json.contains("Lock Overhead"))

        let markdown = reporter.generateMarkdown()
        XCTAssertTrue(markdown.contains("Lock Overhead"))
    }

    func testPrettyPrintedJSON() throws {
        let suiteResult = createSampleResults()
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Test pretty printed
        let prettyJSON = try reporter.generateJSON(prettyPrinted: true)
        XCTAssertTrue(prettyJSON.contains("\n"))
        XCTAssertTrue(prettyJSON.contains("  "))

        // Test compact
        let compactJSON = try reporter.generateJSON(prettyPrinted: false)
        let lineCount = compactJSON.components(separatedBy: "\n").count
        XCTAssertLessThan(lineCount, 5, "Compact JSON should have fewer lines")
    }
}
