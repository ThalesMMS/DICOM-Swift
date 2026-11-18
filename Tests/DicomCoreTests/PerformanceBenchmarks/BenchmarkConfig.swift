//
//  BenchmarkConfig.swift
//  DicomCoreTests
//
//  Configuration for benchmark execution. Defines parameters for benchmark iterations, image
//  dimensions, windowing parameters, and output verbosity.
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

    /// Initialize benchmark configuration with default values
    public init() {}

    /// Initialize benchmark configuration with custom values
    ///
    /// - Parameters:
    ///   - warmupIterations: Number of warmup iterations (default 20)
    ///   - benchmarkIterations: Number of benchmark iterations (default 100)
    ///   - imageWidth: Image width in pixels (default 1024)
    ///   - imageHeight: Image height in pixels (default 1024)
    ///   - windowCenter: Window center for windowing (default 2048.0)
    ///   - windowWidth: Window width for windowing (default 4096.0)
    ///   - verbose: Enable verbose output (default false)
    public init(
        warmupIterations: Int = 20,
        benchmarkIterations: Int = 100,
        imageWidth: Int = 1024,
        imageHeight: Int = 1024,
        windowCenter: Double = 2048.0,
        windowWidth: Double = 4096.0,
        verbose: Bool = false
    ) {
        self.warmupIterations = warmupIterations
        self.benchmarkIterations = benchmarkIterations
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.verbose = verbose
    }

    /// Total pixel count (width × height)
    public var totalPixels: Int {
        return imageWidth * imageHeight
    }

    /// Validate configuration parameters
    ///
    /// - Throws: Error if configuration is invalid
    public func validate() throws {
        guard warmupIterations >= 0 else {
            throw BenchmarkError.invalidConfiguration("warmupIterations must be non-negative")
        }
        guard benchmarkIterations > 0 else {
            throw BenchmarkError.invalidConfiguration("benchmarkIterations must be positive")
        }
        guard imageWidth > 0 else {
            throw BenchmarkError.invalidConfiguration("imageWidth must be positive")
        }
        guard imageHeight > 0 else {
            throw BenchmarkError.invalidConfiguration("imageHeight must be positive")
        }
        guard windowWidth > 0 else {
            throw BenchmarkError.invalidConfiguration("windowWidth must be positive")
        }
    }
}

/// Errors that can occur during benchmarking
public enum BenchmarkError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case benchmarkFailed(String)
    case insufficientData(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .benchmarkFailed(let message):
            return "Benchmark failed: \(message)"
        case .insufficientData(let message):
            return "Insufficient data: \(message)"
        }
    }
}
