//
//  BenchmarkReporter.swift
//  DicomCore
//
//  Reporter for benchmark results with JSON and markdown output.
//  Generates formatted reports for CI artifact storage and documentation.
//
//  Follows patterns from DCMWindowingProcessorPerformanceTests.swift for
//  formatted output and statistical reporting.
//
//  Created by automated performance benchmarking suite.
//

import Foundation

// MARK: - Report Format Types

/// Output format for benchmark reports
public enum ReportFormat {
    case json
    case markdown
}

// MARK: - Platform Information

/// System information for benchmark context
public struct PlatformInfo: Codable {
    public let operatingSystem: String
    public let osVersion: String
    public let architecture: String
    public let processorCount: Int
    public let physicalMemoryBytes: UInt64?
    public let modelIdentifier: String

    /// Initialize with current system information
    public init() {
        #if os(macOS)
        self.operatingSystem = "macOS"
        #elseif os(iOS)
        self.operatingSystem = "iOS"
        #elseif os(watchOS)
        self.operatingSystem = "watchOS"
        #elseif os(tvOS)
        self.operatingSystem = "tvOS"
        #elseif os(Linux)
        self.operatingSystem = "Linux"
        #else
        self.operatingSystem = "Unknown"
        #endif

        let processInfo = ProcessInfo.processInfo
        self.osVersion = processInfo.operatingSystemVersionString
        self.physicalMemoryBytes = processInfo.physicalMemory

        #if arch(x86_64)
        self.architecture = "x86_64"
        #elseif arch(arm64)
        self.architecture = "arm64"
        #elseif arch(arm)
        self.architecture = "arm"
        #else
        self.architecture = "unknown"
        #endif

        self.processorCount = processInfo.processorCount

        // Get model identifier (e.g., "MacBookPro18,1")
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        self.modelIdentifier = Self.decodeModelIdentifier(machine)
        #else
        self.modelIdentifier = "Unknown"
        #endif
    }

    static func decodeModelIdentifier(_ machine: [CChar]) -> String {
        let bytes = machine.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Serializable Result

/// Serializable version of BenchmarkResult for JSON output
struct SerializableBenchmarkResult: Codable {
    let operation: String
    let iterations: Int
    let meanTimeSeconds: Double
    let meanTimeMilliseconds: Double
    let stdDevSeconds: Double
    let minTimeSeconds: Double
    let maxTimeSeconds: Double
    let medianTimeSeconds: Double
    let p95TimeSeconds: Double
    let p99TimeSeconds: Double
    let coefficientOfVariation: Double
    let throughputPixelsPerSecond: Double?
    let peakMemoryBytes: UInt64?

    /// Initialize from BenchmarkResult and type
    init(type: BenchmarkType, result: BenchmarkResult, config: BenchmarkConfig) {
        self.operation = type.rawValue
        self.iterations = result.iterationCount
        self.meanTimeSeconds = result.meanTime
        self.meanTimeMilliseconds = result.meanTime * 1000.0
        self.stdDevSeconds = result.stdDevTime
        self.minTimeSeconds = result.minTime
        self.maxTimeSeconds = result.maxTime
        self.medianTimeSeconds = result.medianTime
        self.p95TimeSeconds = result.p95Time
        self.p99TimeSeconds = result.p99Time
        self.coefficientOfVariation = result.coefficientOfVariation
        self.peakMemoryBytes = result.peakMemoryBytes

        // Calculate throughput for windowing operations
        if type == .windowingVDSP || type == .windowingMetal {
            let pixelCount = Double(config.totalPixels)
            self.throughputPixelsPerSecond = pixelCount / result.meanTime
        } else {
            self.throughputPixelsPerSecond = nil
        }
    }
}

// MARK: - Full Report

/// Complete benchmark report with metadata
struct BenchmarkReport: Codable {
    let timestamp: String
    let platform: PlatformInfo
    let configuration: ReportConfiguration
    let results: [SerializableBenchmarkResult]

    /// Configuration parameters used in benchmarks
    struct ReportConfiguration: Codable {
        let warmupIterations: Int
        let benchmarkIterations: Int
        let imageWidth: Int
        let imageHeight: Int
        let totalPixels: Int
        let windowCenter: Double
        let windowWidth: Double
        let buildConfiguration: String?

        init(config: BenchmarkConfig) {
            self.warmupIterations = config.warmupIterations
            self.benchmarkIterations = config.benchmarkIterations
            self.imageWidth = config.imageWidth
            self.imageHeight = config.imageHeight
            self.totalPixels = config.totalPixels
            self.windowCenter = config.windowCenter
            self.windowWidth = config.windowWidth
            #if DEBUG
            self.buildConfiguration = "debug"
            #else
            self.buildConfiguration = "release"
            #endif
        }
    }
}

// MARK: - Benchmark Reporter

/// Reporter for generating benchmark reports in various formats
public final class BenchmarkReporter {

    private let suiteResult: BenchmarkSuiteResult
    private let platformInfo: PlatformInfo

    // MARK: - Initialization

    /// Initialize reporter with benchmark suite results
    ///
    /// - Parameter suiteResult: Results from a complete benchmark suite run
    public init(suiteResult: BenchmarkSuiteResult) {
        self.suiteResult = suiteResult
        self.platformInfo = PlatformInfo()
    }

    // MARK: - JSON Output

    /// Generate JSON report
    ///
    /// Suitable for CI artifact storage and historical tracking.
    ///
    /// - Parameter prettyPrinted: Enable pretty printing (default: true)
    /// - Returns: JSON string representation of benchmark results
    /// - Throws: Error if JSON encoding fails
    public func generateJSON(prettyPrinted: Bool = true) throws -> String {
        let report = buildReport()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        let data = try encoder.encode(report)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw BenchmarkError.benchmarkFailed("Failed to convert JSON data to string")
        }

        return jsonString
    }

    /// Write JSON report to file
    ///
    /// - Parameters:
    ///   - path: File path to write JSON report
    ///   - prettyPrinted: Enable pretty printing (default: true)
    /// - Throws: Error if writing fails
    public func writeJSON(to path: String, prettyPrinted: Bool = true) throws {
        let jsonString = try generateJSON(prettyPrinted: prettyPrinted)
        try jsonString.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Markdown Output

    /// Generate markdown report
    ///
    /// Suitable for GitHub Actions summaries and documentation.
    ///
    /// - Returns: Markdown formatted string with benchmark results
    public func generateMarkdown() -> String {
        var markdown = [String]()

        // Header
        markdown.append("# Benchmark Results\n")

        // Metadata
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: suiteResult.timestamp)

        markdown.append("## Metadata\n")
        markdown.append("- **Timestamp**: \(timestamp)")
        markdown.append("- **Platform**: \(platformInfo.operatingSystem) \(platformInfo.osVersion)")
        markdown.append("- **Architecture**: \(platformInfo.architecture)")
        markdown.append("- **Processor Count**: \(platformInfo.processorCount)")
        if let physicalMemoryBytes = platformInfo.physicalMemoryBytes {
            markdown.append("- **Physical Memory**: \(BenchmarkResult.formatBytes(physicalMemoryBytes))")
        }
        markdown.append("- **Model**: \(platformInfo.modelIdentifier)")
        markdown.append("")

        // Configuration
        let config = suiteResult.config
        markdown.append("## Configuration\n")
        markdown.append("- **Warmup Iterations**: \(config.warmupIterations)")
        markdown.append("- **Benchmark Iterations**: \(config.benchmarkIterations)")
        markdown.append("- **Image Size**: \(config.imageWidth) × \(config.imageHeight) (\(config.totalPixels) pixels)")
        markdown.append("- **Window Center**: \(config.windowCenter)")
        markdown.append("- **Window Width**: \(config.windowWidth)")
        markdown.append("- **Build Configuration**: \(BenchmarkReport.ReportConfiguration(config: config).buildConfiguration ?? "unknown")")
        markdown.append("")

        // Results table
        markdown.append("## Results\n")
        markdown.append("| Operation | Iterations | Mean | Std Dev | Min | Max | P95 | P99 | CV | Peak Memory |")
        markdown.append("|-----------|------------|------|---------|-----|-----|-----|-----|----|-------------|")

        // Sort results by operation name for consistent output
        let sortedTypes = BenchmarkType.allCases.filter { suiteResult.results[$0] != nil }

        for type in sortedTypes {
            guard let result = suiteResult.results[type] else { continue }

            let operation = type.rawValue
            let iterations = result.iterationCount
            let mean = BenchmarkResult.formatMilliseconds(result.meanTime)
            let stdDev = BenchmarkResult.formatMilliseconds(result.stdDevTime)
            let min = BenchmarkResult.formatMilliseconds(result.minTime)
            let max = BenchmarkResult.formatMilliseconds(result.maxTime)
            let p95 = BenchmarkResult.formatMilliseconds(result.p95Time)
            let p99 = BenchmarkResult.formatMilliseconds(result.p99Time)
            let cv = String(format: "%.1f%%", result.coefficientOfVariation)
            let peakMemory = result.peakMemoryBytes.map(BenchmarkResult.formatBytes) ?? "n/a"

            markdown.append("| \(operation) | \(iterations) | \(mean) | \(stdDev) | \(min) | \(max) | \(p95) | \(p99) | \(cv) | \(peakMemory) |")
        }

        markdown.append("")

        // Throughput metrics for windowing operations
        let windowingTypes: [BenchmarkType] = [.windowingVDSP, .windowingMetal]
        let hasWindowingResults = windowingTypes.contains { suiteResult.results[$0] != nil }

        if hasWindowingResults {
            markdown.append("## Throughput Metrics\n")
            markdown.append("| Operation | Pixels/Second | MB/Second |")
            markdown.append("|-----------|---------------|-----------|")

            for type in windowingTypes {
                guard let result = suiteResult.results[type] else { continue }

                let operation = type.rawValue
                let pixelsPerSecond = Double(config.totalPixels) / result.meanTime
                let mbPerSecond = Double(config.totalPixels * 2) / result.meanTime / (1024 * 1024)

                let pixelsFormatted = String(format: "%.0f", pixelsPerSecond)
                let mbFormatted = String(format: "%.2f", mbPerSecond)

                markdown.append("| \(operation) | \(pixelsFormatted) | \(mbFormatted) |")
            }

            markdown.append("")
        }

        // Metal vs vDSP comparison if both results exist
        if let vdspResult = suiteResult.results[.windowingVDSP],
           let metalResult = suiteResult.results[.windowingMetal] {
            markdown.append("## Metal vs vDSP Comparison\n")

            let speedup = metalResult.speedup(comparedTo: vdspResult)
            let percentFaster = metalResult.percentageDifference(comparedTo: vdspResult)
            let performanceLabel = percentFaster >= 0 ? "Performance Improvement" : "Performance Degradation"
            let performanceDirection = percentFaster >= 0 ? "faster" : "slower"
            let speedupFormatted = formatSpeedup(speedup)
            let percentPrefix = percentFaster >= 0.05 ? "+" : ""

            markdown.append("- **Speedup**: \(speedupFormatted)")
            markdown.append("- **\(performanceLabel)**: \(percentPrefix)\(String(format: "%.1f%%", abs(percentFaster))) \(performanceDirection)")
            markdown.append("")

            if speedup >= 2.0 {
                markdown.append("> ✅ **Metal acceleration successful** - Achieved ≥2x speedup")
            } else if speedup >= 1.5 {
                markdown.append("> ⚠️ **Metal acceleration moderate** - Achieved \(String(format: "%.1fx", speedup)) speedup (target: ≥2x)")
            } else if speedup >= 1.0 {
                markdown.append("> ⚠️ **Metal faster but below target** - \(speedupFormatted) speedup (target: ≥2x)")
            } else {
                markdown.append("> ❌ **Metal acceleration below target** - Only \(speedupFormatted) speed (target: ≥2x); Metal is slower in mean latency and throughput")
            }
            markdown.append("")
        }

        return markdown.joined(separator: "\n")
    }

    private func formatSpeedup(_ speedup: Double) -> String {
        if speedup != 1.0 && abs(speedup - 1.0) < 0.005 {
            return String(format: "%.3fx", speedup)
        }
        return String(format: "%.2fx", speedup)
    }

    /// Write markdown report to file
    ///
    /// - Parameter path: File path to write markdown report
    /// - Throws: Error if writing fails
    public func writeMarkdown(to path: String) throws {
        let markdownString = generateMarkdown()
        try markdownString.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private Helpers

    private func buildReport() -> BenchmarkReport {
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: suiteResult.timestamp)

        let configuration = BenchmarkReport.ReportConfiguration(config: suiteResult.config)

        // Convert results to serializable format, sorted by operation name
        let sortedTypes = BenchmarkType.allCases.filter { suiteResult.results[$0] != nil }
        let results = sortedTypes.map { type in
            let result = suiteResult.results[type]!
            return SerializableBenchmarkResult(type: type, result: result, config: suiteResult.config)
        }

        return BenchmarkReport(
            timestamp: timestamp,
            platform: platformInfo,
            configuration: configuration,
            results: results
        )
    }
}

// MARK: - Convenience Extensions

extension BenchmarkReporter {
    /// Generate report in specified format
    ///
    /// - Parameter format: Output format (JSON or Markdown)
    /// - Returns: Formatted report string
    /// - Throws: Error if generation fails
    public func generateReport(format: ReportFormat) throws -> String {
        switch format {
        case .json:
            return try generateJSON()
        case .markdown:
            return generateMarkdown()
        }
    }

    /// Write report to file in specified format
    ///
    /// - Parameters:
    ///   - format: Output format (JSON or Markdown)
    ///   - path: File path to write report
    /// - Throws: Error if writing fails
    public func writeReport(format: ReportFormat, to path: String) throws {
        switch format {
        case .json:
            try writeJSON(to: path)
        case .markdown:
            try writeMarkdown(to: path)
        }
    }
}
