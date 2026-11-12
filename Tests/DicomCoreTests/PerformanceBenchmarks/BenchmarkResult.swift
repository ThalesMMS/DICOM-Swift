//
//  BenchmarkResult.swift
//  DicomCoreTests
//
//  Results from a single benchmark run. Contains timing measurements and statistical analysis
//  including mean, standard deviation, coefficient of variation, and percentiles.
//
//  Timing samples are produced by BenchmarkRunner using BenchmarkClock, a monotonic nanosecond
//  clock.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

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

    /// Peak resident memory observed for the process during or after the benchmark.
    public let peakMemoryBytes: UInt64?

    /// Initialize benchmark result with timing measurements
    ///
    /// - Parameter timings: Array of timing measurements in seconds
    /// - Throws: BenchmarkError.insufficientData if timings array is empty
    public init(timings: [Double], peakMemoryBytes: UInt64? = nil) throws {
        guard !timings.isEmpty else {
            throw BenchmarkError.insufficientData("Cannot create BenchmarkResult with empty timings array")
        }

        self.timings = timings
        self.iterationCount = timings.count
        self.peakMemoryBytes = peakMemoryBytes

        // Calculate mean
        let sum = timings.reduce(0.0, +)
        let mean = sum / Double(timings.count)
        self.meanTime = mean

        // Calculate standard deviation
        if timings.count > 1 {
            let variance = timings.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(timings.count - 1)
            self.stdDevTime = sqrt(variance)
        } else {
            self.stdDevTime = 0.0
        }
    }

    /// Initialize benchmark result with pre-calculated statistics
    ///
    /// - Parameters:
    ///   - meanTime: Mean execution time in seconds
    ///   - stdDevTime: Standard deviation of execution time
    ///   - timings: Array of timing measurements
    ///   - iterationCount: Number of iterations performed
    public init(meanTime: Double,
                stdDevTime: Double,
                timings: [Double],
                iterationCount: Int,
                peakMemoryBytes: UInt64? = nil) {
        self.meanTime = meanTime
        self.stdDevTime = stdDevTime
        self.timings = timings
        self.iterationCount = iterationCount
        self.peakMemoryBytes = peakMemoryBytes
    }

    // MARK: - Statistical Metrics

    /// Coefficient of variation (stddev/mean as percentage)
    public var coefficientOfVariation: Double {
        guard meanTime > 0 else { return 0 }
        return (stdDevTime / meanTime) * 100.0
    }

    /// Minimum execution time in seconds
    public var minTime: Double {
        return timings.min() ?? 0
    }

    /// Maximum execution time in seconds
    public var maxTime: Double {
        return timings.max() ?? 0
    }

    /// Median execution time in seconds
    public var medianTime: Double {
        let sorted = timings.sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        } else {
            return sorted[count / 2]
        }
    }

    /// 95th percentile execution time in seconds
    public var p95Time: Double {
        return percentile(95.0)
    }

    /// 99th percentile execution time in seconds
    public var p99Time: Double {
        return percentile(99.0)
    }

    /// Calculate percentile value
    ///
    /// - Parameter percentile: Percentile to calculate (0-100)
    /// - Returns: Timing value at the specified percentile
    public func percentile(_ percentile: Double) -> Double {
        guard !timings.isEmpty else { return 0 }
        let sorted = timings.sorted()
        let index = Int(ceil(percentile / 100.0 * Double(sorted.count))) - 1
        let clampedIndex = max(0, min(sorted.count - 1, index))
        return sorted[clampedIndex]
    }

    /// Standard error of the mean
    public var standardError: Double {
        guard iterationCount > 0 else { return 0 }
        return stdDevTime / sqrt(Double(iterationCount))
    }

    // MARK: - Formatted Output

    /// Format timing value in milliseconds
    ///
    /// - Parameter time: Time in seconds
    /// - Returns: Formatted string with ms suffix
    public static func formatMilliseconds(_ time: Double) -> String {
        return String(format: "%.3f ms", time * 1000.0)
    }

    /// Format timing value in microseconds
    ///
    /// - Parameter time: Time in seconds
    /// - Returns: Formatted string with µs suffix
    public static func formatMicroseconds(_ time: Double) -> String {
        return String(format: "%.1f µs", time * 1_000_000.0)
    }

    /// Format a byte count with binary units.
    ///
    /// - Parameter bytes: Byte count to format
    /// - Returns: Formatted string with B/KiB/MiB/GiB suffix
    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024.0 && unitIndex < units.count - 1 {
            value /= 1024.0
            unitIndex += 1
        }
        return unitIndex == 0
            ? "\(bytes) \(units[unitIndex])"
            : String(format: "%.2f %@", value, units[unitIndex])
    }

    /// Generate summary statistics string
    ///
    /// - Returns: Multi-line string with statistical summary
    public func summary() -> String {
        var lines = [String]()
        lines.append("Iterations: \(iterationCount)")
        lines.append("Mean: \(Self.formatMilliseconds(meanTime))")
        lines.append("Std Dev: \(Self.formatMilliseconds(stdDevTime))")
        lines.append("Min: \(Self.formatMilliseconds(minTime))")
        lines.append("Median: \(Self.formatMilliseconds(medianTime))")
        lines.append("Max: \(Self.formatMilliseconds(maxTime))")
        lines.append("P95: \(Self.formatMilliseconds(p95Time))")
        lines.append("P99: \(Self.formatMilliseconds(p99Time))")
        lines.append("CV: \(String(format: "%.2f%%", coefficientOfVariation))")
        if let peakMemoryBytes {
            lines.append("Peak Memory: \(Self.formatBytes(peakMemoryBytes))")
        }
        return lines.joined(separator: "\n")
    }

    /// Compare this result with another and calculate speedup
    ///
    /// - Parameter other: Other benchmark result to compare with
    /// - Returns: Speedup ratio. Values above 1 mean this result is faster.
    public func speedup(comparedTo other: BenchmarkResult) -> Double {
        guard meanTime > 0, other.meanTime > 0 else { return 0 }
        return other.meanTime / self.meanTime
    }

    /// Calculate relative performance difference as percentage
    ///
    /// - Parameter other: Other benchmark result to compare with
    /// - Returns: Percentage difference based on speedup (positive = this is faster)
    public func percentageDifference(comparedTo other: BenchmarkResult) -> Double {
        let speedup = speedup(comparedTo: other)
        guard speedup > 0 else { return .nan }
        return (speedup - 1.0) * 100.0
    }
}

// MARK: - Codable Conformance

extension BenchmarkResult: Codable {
    enum CodingKeys: String, CodingKey {
        case meanTime
        case stdDevTime
        case timings
        case iterationCount
        case peakMemoryBytes
    }
}

// MARK: - CustomStringConvertible

extension BenchmarkResult: CustomStringConvertible {
    public var description: String {
        return summary()
    }
}
