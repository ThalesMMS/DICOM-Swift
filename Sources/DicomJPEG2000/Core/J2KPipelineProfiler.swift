//
// J2KPipelineProfiler.swift
// J2KSwift
//
/// # J2KPipelineProfiler
///
/// Profiling infrastructure for the JPEG 2000 encoding/decoding pipeline.
///
/// This module provides detailed timing and memory profiling for each stage
/// of the encoding and decoding pipelines, enabling identification of
/// performance bottlenecks.

import Foundation

/// Represents a stage in the JPEG 2000 encoding or decoding pipeline.
public enum J2KPipelineStage: String, Sendable, CaseIterable {
    /// Colour transform stage (RCT/ICT).
    case colorTransform = "Color Transform"

    /// Discrete wavelet transform stage.
    case waveletTransform = "Wavelet Transform"

    /// Quantization stage.
    case quantization = "Quantization"

    /// Entropy coding stage (EBCOT/MQ-coder).
    case entropyCoding = "Entropy Coding"

    /// Rate control and layer formation stage.
    case rateControl = "Rate Control"

    /// Tier-2 packet encoding/decoding stage.
    case packetCoding = "Packet Coding"

    /// Tile partitioning or assembly stage.
    case tileProcessing = "Tile Processing"

    /// File format I/O stage.
    case fileIO = "File I/O"
}

/// Metrics collected for a single profiling measurement.
public struct J2KStageMetrics: Sendable {
    /// The pipeline stage that was measured.
    public let stage: J2KPipelineStage

    /// The elapsed wall-clock time in seconds.
    public let elapsedTime: TimeInterval

    /// The estimated memory used in bytes (0 if not measured).
    public let memoryUsed: Int

    /// The number of items processed (e.g., tiles, code-blocks).
    public let itemsProcessed: Int

    /// Optional label for sub-stage identification.
    public let label: String?

    /// Creates a new stage metrics record.
    ///
    /// - Parameters:
    ///   - stage: The pipeline stage.
    ///   - elapsedTime: The elapsed time in seconds.
    ///   - memoryUsed: Memory used in bytes (default: 0).
    ///   - itemsProcessed: Number of items processed (default: 1).
    ///   - label: Optional sub-stage label (default: nil).
    public init(
        stage: J2KPipelineStage,
        elapsedTime: TimeInterval,
        memoryUsed: Int = 0,
        itemsProcessed: Int = 1,
        label: String? = nil
    ) {
        self.stage = stage
        self.elapsedTime = elapsedTime
        self.memoryUsed = memoryUsed
        self.itemsProcessed = itemsProcessed
        self.label = label
    }

    /// Throughput in items per second.
    public var throughput: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(itemsProcessed) / elapsedTime
    }
}

/// A profile report summarizing pipeline performance.
public struct J2KProfileReport: Sendable, CustomStringConvertible {
    /// All collected stage metrics.
    public let metrics: [J2KStageMetrics]

    /// The total elapsed time across all stages.
    public var totalTime: TimeInterval {
        metrics.reduce(0) { $0 + $1.elapsedTime }
    }

    /// The total memory used across all stages.
    public var totalMemory: Int {
        metrics.reduce(0) { $0 + $1.memoryUsed }
    }

    /// Returns metrics grouped by stage.
    public var metricsByStage: [J2KPipelineStage: [J2KStageMetrics]] {
        Dictionary(grouping: metrics, by: \.stage)
    }

    /// Returns the fraction of total time spent in each stage.
    public var timeDistribution: [J2KPipelineStage: Double] {
        let total = totalTime
        guard total > 0 else { return [:] }
        var distribution: [J2KPipelineStage: Double] = [:]
        for (stage, stageMetrics) in metricsByStage {
            let stageTime = stageMetrics.reduce(0) { $0 + $1.elapsedTime }
            distribution[stage] = stageTime / total
        }
        return distribution
    }

    /// Returns the stage that consumed the most time.
    public var bottleneck: J2KPipelineStage? {
        timeDistribution.max(by: { $0.value < $1.value })?.key
    }

    /// A formatted report of the profile results.
    public var description: String {
        var lines: [String] = []
        lines.append("═══════════════════════════════════════════════════════════════")
        lines.append("J2KSwift Pipeline Profile Report")
        lines.append("═══════════════════════════════════════════════════════════════")
        lines.append("")

        let totalMs = totalTime * 1000
        lines.append("Total time: \(String(format: "%.4f", totalMs)) ms")
        lines.append("")

        // Per-stage breakdown
        let distribution = timeDistribution
        let sorted = distribution.sorted { $0.value > $1.value }
        for (stage, fraction) in sorted {
            let stageMetrics = metricsByStage[stage] ?? []
            let stageTimeMs = stageMetrics.reduce(0) { $0 + $1.elapsedTime } * 1000
            let percent = fraction * 100
            let memoryKB = stageMetrics.reduce(0) { $0 + $1.memoryUsed } / 1024
            lines.append("  \(stage.rawValue):")
            lines.append("    Time:    \(String(format: "%.4f", stageTimeMs)) ms (\(String(format: "%.1f", percent))%)")
            lines.append("    Memory:  \(memoryKB) KB")
            lines.append("    Calls:   \(stageMetrics.count)")
        }

        if let bottleneck = bottleneck {
            lines.append("")
            lines.append("Bottleneck: \(bottleneck.rawValue)")
        }

        lines.append("═══════════════════════════════════════════════════════════════")
        return lines.joined(separator: "\n")
    }
}

/// Profiler for instrumenting the JPEG 2000 encoding/decoding pipeline.
///
/// `J2KPipelineProfiler` collects timing and memory metrics for each stage
/// of the pipeline. It uses actor isolation to provide thread-safe access
/// to its mutable metrics collection.
///
/// Example:
/// ```swift
/// let profiler = J2KPipelineProfiler()
/// let metrics = await profiler.measure(stage: .waveletTransform) {
///     // Perform DWT...
/// }
/// await profiler.record(metrics)
/// let report = await profiler.generateReport()
/// print(report)
/// ```
public actor J2KPipelineProfiler {
    /// Collected metrics.
    private var metrics: [J2KStageMetrics] = []

    /// Whether profiling is enabled.
    public let enabled: Bool

    /// Creates a new pipeline profiler.
    ///
    /// - Parameter enabled: Whether profiling is active (default: true).
    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Measures a synchronous operation and returns its metrics.
    ///
    /// - Parameters:
    ///   - stage: The pipeline stage being measured.
    ///   - itemsProcessed: Number of items processed (default: 1).
    ///   - label: Optional sub-stage label.
    ///   - operation: The operation to measure.
    /// - Returns: The collected metrics for this measurement.
    public func measure(
        stage: J2KPipelineStage,
        itemsProcessed: Int = 1,
        label: String? = nil,
        operation: () -> Void
    ) -> J2KStageMetrics {
        guard enabled else {
            operation()
            return J2KStageMetrics(stage: stage, elapsedTime: 0, itemsProcessed: itemsProcessed, label: label)
        }

        let startMemory = currentMemoryUsage()
        let startTime = ProcessInfo.processInfo.systemUptime
        operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let endMemory = currentMemoryUsage()
        let memoryUsed = max(0, endMemory - startMemory)

        return J2KStageMetrics(
            stage: stage,
            elapsedTime: elapsed,
            memoryUsed: memoryUsed,
            itemsProcessed: itemsProcessed,
            label: label
        )
    }

    /// Measures a throwing operation and returns its metrics.
    ///
    /// - Parameters:
    ///   - stage: The pipeline stage being measured.
    ///   - itemsProcessed: Number of items processed (default: 1).
    ///   - label: Optional sub-stage label.
    ///   - operation: The throwing operation to measure.
    /// - Returns: The collected metrics for this measurement.
    /// - Throws: Any error thrown by the operation.
    public func measureThrowing(
        stage: J2KPipelineStage,
        itemsProcessed: Int = 1,
        label: String? = nil,
        operation: () throws -> Void
    ) throws -> J2KStageMetrics {
        guard enabled else {
            try operation()
            return J2KStageMetrics(stage: stage, elapsedTime: 0, itemsProcessed: itemsProcessed, label: label)
        }

        let startMemory = currentMemoryUsage()
        let startTime = ProcessInfo.processInfo.systemUptime
        try operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let endMemory = currentMemoryUsage()
        let memoryUsed = max(0, endMemory - startMemory)

        return J2KStageMetrics(
            stage: stage,
            elapsedTime: elapsed,
            memoryUsed: memoryUsed,
            itemsProcessed: itemsProcessed,
            label: label
        )
    }

    /// Records a metrics result.
    ///
    /// - Parameter metric: The metrics to record.
    public func record(_ metric: J2KStageMetrics) {
        metrics.append(metric)
    }

    /// Measures an operation and automatically records the result.
    ///
    /// - Parameters:
    ///   - stage: The pipeline stage being measured.
    ///   - itemsProcessed: Number of items processed (default: 1).
    ///   - label: Optional sub-stage label.
    ///   - operation: The operation to measure.
    public func profile(
        stage: J2KPipelineStage,
        itemsProcessed: Int = 1,
        label: String? = nil,
        operation: () -> Void
    ) {
        let metric = measure(stage: stage, itemsProcessed: itemsProcessed, label: label, operation: operation)
        record(metric)
    }

    /// Generates a profile report from all collected metrics.
    ///
    /// - Returns: A profile report summarizing pipeline performance.
    public func generateReport() -> J2KProfileReport {
        J2KProfileReport(metrics: metrics)
    }

    /// Clears all collected metrics.
    public func reset() {
        metrics.removeAll()
    }

    /// Returns the number of recorded metrics.
    public var metricsCount: Int {
        metrics.count
    }

    // MARK: - Private Helpers

    private func currentMemoryUsage() -> Int {
        J2KMemoryInfo.currentResidentMemory()
    }
}
