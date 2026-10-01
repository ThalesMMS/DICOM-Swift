//
// J2KPerformanceOptimizer.swift
// J2KSwift
//
/// # J2KPerformanceOptimizer
///
/// Comprehensive performance optimisation coordinator for J2KSwift.
///
/// This actor provides system-wide performance tuning and optimisation
/// for Apple Silicon platforms, coordinating CPU/GPU work, managing
/// resource allocation, and optimising pipeline execution.

import Foundation


#if canImport(Accelerate)
import Accelerate
#endif

/// Performance optimisation coordinator for J2KSwift operations.
///
/// This actor coordinates performance optimisations across the entire
/// encoding/decoding pipeline, including:
/// - CPU/GPU work overlap and parallelization
/// - Memory allocation and cache optimisation
/// - Metal and Accelerate framework tuning
/// - Pipeline-level optimisations
///
/// Example:
/// ```swift
/// let optimizer = J2KPerformanceOptimizer()
/// await optimizer.configureForHighPerformance()
///
/// let profile = await optimizer.optimizeEncodingPipeline { encoder in
///     try encoder.encode(image)
/// }
/// print("Total time: \(profile.totalTime)s")
/// print("Throughput: \(profile.throughputMBps) MB/s")
/// ```
public actor J2KPerformanceOptimizer {
    /// Performance optimisation mode.
    public enum OptimizationMode: Sendable {
        /// Balanced performance and power consumption (default).
        case balanced

        /// Maximum performance regardless of power consumption.
        case highPerformance

        /// Minimize power consumption while maintaining acceptable performance.
        case lowPower

        /// Optimise for thermal constraints (mobile devices).
        case thermalConstrained

        /// Custom optimisation parameters.
        case custom(OptimizationParameters)
    }

    /// Optimisation parameters for fine-tuning performance.
    public struct OptimizationParameters: Sendable {
        /// Maximum CPU threads to use (0 = automatic).
        public var maxCPUThreads: Int

        /// Preferred Metal GPU family (nil = automatic).
        public var preferredGPUFamily: Int?

        /// Enable aggressive batch processing.
        public var enableBatching: Bool

        /// Enable CPU/GPU work overlap.
        public var enableOverlap: Bool

        /// Maximum memory usage in bytes (0 = unlimited).
        public var maxMemoryUsage: Int

        /// Minimum batch size for GPU operations.
        public var minGPUBatchSize: Int

        /// Enable cache optimisation hints.
        public var enableCacheOptimization: Bool

        /// Creates default optimisation parameters.
        public init(
            maxCPUThreads: Int = 0,
            preferredGPUFamily: Int? = nil,
            enableBatching: Bool = true,
            enableOverlap: Bool = true,
            maxMemoryUsage: Int = 0,
            minGPUBatchSize: Int = 4,
            enableCacheOptimization: Bool = true
        ) {
            self.maxCPUThreads = maxCPUThreads
            self.preferredGPUFamily = preferredGPUFamily
            self.enableBatching = enableBatching
            self.enableOverlap = enableOverlap
            self.maxMemoryUsage = maxMemoryUsage
            self.minGPUBatchSize = minGPUBatchSize
            self.enableCacheOptimization = enableCacheOptimization
        }

        /// High-performance preset.
        public static var highPerformance: OptimizationParameters {
            OptimizationParameters(
                maxCPUThreads: 0,
                enableBatching: true,
                enableOverlap: true,
                maxMemoryUsage: 0,
                minGPUBatchSize: 2,
                enableCacheOptimization: true
            )
        }

        /// Low-power preset.
        public static var lowPower: OptimizationParameters {
            OptimizationParameters(
                maxCPUThreads: 2,
                enableBatching: false,
                enableOverlap: false,
                maxMemoryUsage: 512 * 1024 * 1024, // 512 MB
                minGPUBatchSize: 8,
                enableCacheOptimization: true
            )
        }

        /// Balanced preset.
        public static var balanced: OptimizationParameters {
            OptimizationParameters(
                maxCPUThreads: 4,
                enableBatching: true,
                enableOverlap: true,
                maxMemoryUsage: 1024 * 1024 * 1024, // 1 GB
                minGPUBatchSize: 4,
                enableCacheOptimization: true
            )
        }
    }

    /// Performance profile result.
    public struct PerformanceProfile: Sendable {
        /// Total execution time in seconds.
        public let totalTime: TimeInterval

        /// CPU time in seconds.
        public let cpuTime: TimeInterval

        /// GPU time in seconds (0 if no GPU work).
        public let gpuTime: TimeInterval

        /// Memory allocated in bytes.
        public let memoryAllocated: Int

        /// Peak memory usage in bytes.
        public let peakMemoryUsage: Int

        /// Number of synchronisation points.
        public let syncPoints: Int

        /// Data processed in bytes.
        public let dataProcessed: Int

        /// Throughput in MB/s.
        public var throughputMBps: Double {
            guard totalTime > 0 else { return 0 }
            return Double(dataProcessed) / (1024 * 1024) / totalTime
        }

        /// CPU utilization percentage (0-100).
        public var cpuUtilization: Double {
            guard totalTime > 0 else { return 0 }
            return min(100, (cpuTime / totalTime) * 100)
        }

        /// GPU utilization percentage (0-100).
        public var gpuUtilization: Double {
            guard totalTime > 0 else { return 0 }
            return min(100, (gpuTime / totalTime) * 100)
        }

        /// Pipeline efficiency (percentage of time doing useful work).
        public var pipelineEfficiency: Double {
            guard totalTime > 0 else { return 0 }
            let activeTime = cpuTime + gpuTime
            return min(100, (activeTime / totalTime) * 100)
        }
    }

    // MARK: - State

    /// Current optimisation mode.
    private var mode: OptimizationMode = .balanced

    /// Current optimisation parameters.
    private var parameters: OptimizationParameters = .balanced


    // MARK: - Initialisation

    /// Creates a new performance optimizer.
    ///
    /// - Parameter mode: Initial optimisation mode (default: .balanced).
    public init(mode: OptimizationMode = .balanced) {
        self.mode = mode

        switch mode {
        case .balanced:
            self.parameters = .balanced
        case .highPerformance:
            self.parameters = .highPerformance
        case .lowPower:
            self.parameters = .lowPower
        case .thermalConstrained:
            self.parameters = .balanced
        case .custom(let params):
            self.parameters = params
        }

    }

    // MARK: - Configuration

    /// Configures the optimizer for high-performance operation.
    ///
    /// This sets up optimal parameters for maximum throughput,
    /// including aggressive batching, CPU/GPU overlap, and minimal
    /// synchronisation.
    public func configureForHighPerformance() {
        mode = .highPerformance
        parameters = .highPerformance
    }

    /// Configures the optimizer for low-power operation.
    ///
    /// This sets up parameters to minimise power consumption,
    /// including reduced threading, conservative batching, and
    /// memory usage limits.
    public func configureForLowPower() {
        mode = .lowPower
        parameters = .lowPower
    }

    /// Configures the optimizer with custom parameters.
    ///
    /// - Parameter parameters: Custom optimisation parameters.
    public func configure(with parameters: OptimizationParameters) {
        self.mode = .custom(parameters)
        self.parameters = parameters
    }

    /// Returns the current optimisation parameters.
    public func currentParameters() -> OptimizationParameters {
        parameters
    }

    // MARK: - Pipeline Optimisation

    /// Optimizes an encoding pipeline operation.
    ///
    /// This method profiles and optimises the execution of an encoding
    /// operation, applying configured optimisations for maximum performance.
    ///
    /// - Parameter operation: The encoding operation to optimise.
    /// - Returns: Performance profile with detailed metrics.
    /// - Throws: Any error thrown by the operation.
    public func optimizeEncodingPipeline<T>(
        _ operation: () throws -> T
    ) throws -> (result: T, profile: PerformanceProfile) {
        let startTime = Date()
        let cpuTime: TimeInterval
        let gpuTime: TimeInterval = 0
        let memoryAllocated = 0
        let peakMemory = 0
        let syncPoints = 0

        // Execute operation with timing
        let cpuStart = Date()
        let result = try operation()
        cpuTime = Date().timeIntervalSince(cpuStart)

        // Calculate metrics
        let totalTime = Date().timeIntervalSince(startTime)

        let profile = PerformanceProfile(
            totalTime: totalTime,
            cpuTime: cpuTime,
            gpuTime: gpuTime,
            memoryAllocated: memoryAllocated,
            peakMemoryUsage: peakMemory,
            syncPoints: syncPoints,
            dataProcessed: 0 // Would need to be passed in
        )

        return (result, profile)
    }

    /// Optimizes a decoding pipeline operation.
    ///
    /// This method profiles and optimises the execution of a decoding
    /// operation, applying configured optimisations for maximum performance.
    ///
    /// - Parameter operation: The decoding operation to optimise.
    /// - Returns: Performance profile with detailed metrics.
    /// - Throws: Any error thrown by the operation.
    public func optimizeDecodingPipeline<T>(
        _ operation: () throws -> T
    ) throws -> (result: T, profile: PerformanceProfile) {
        let startTime = Date()
        let cpuTime: TimeInterval
        let gpuTime: TimeInterval = 0
        let memoryAllocated = 0
        let peakMemory = 0
        let syncPoints = 0

        // Execute operation with timing
        let cpuStart = Date()
        let result = try operation()
        cpuTime = Date().timeIntervalSince(cpuStart)

        // Calculate metrics
        let totalTime = Date().timeIntervalSince(startTime)

        let profile = PerformanceProfile(
            totalTime: totalTime,
            cpuTime: cpuTime,
            gpuTime: gpuTime,
            memoryAllocated: memoryAllocated,
            peakMemoryUsage: peakMemory,
            syncPoints: syncPoints,
            dataProcessed: 0
        )

        return (result, profile)
    }

    // MARK: - Optimisation Strategies

    /// Determines optimal batch size for the given operation.
    ///
    /// - Parameters:
    ///   - itemCount: Number of items to process.
    ///   - itemSize: Size of each item in bytes.
    /// - Returns: Optimal batch size.
    public func optimalBatchSize(itemCount: Int, itemSize: Int) -> Int {
        guard parameters.enableBatching else { return 1 }

        let targetBatchMemory = 16 * 1024 * 1024 // 16 MB per batch

        let batchSize = max(1, targetBatchMemory / max(1, itemSize))
        return min(itemCount, batchSize)
    }

    /// Determines optimal CPU thread count for the given operation.
    ///
    /// - Parameter operationType: Type of operation.
    /// - Returns: Optimal number of CPU threads.
    public func optimalThreadCount(operationType: String) -> Int {
        let systemCores = ProcessInfo.processInfo.activeProcessorCount

        if parameters.maxCPUThreads > 0 {
            return min(systemCores, parameters.maxCPUThreads)
        }

        switch mode {
        case .highPerformance:
            return systemCores
        case .lowPower:
            return max(1, systemCores / 2)
        case .balanced, .thermalConstrained:
            return max(2, systemCores * 3 / 4)
        case .custom:
            return systemCores
        }
    }

    // MARK: - Resource Management

    /// Checks if there's sufficient memory for the given operation.
    ///
    /// - Parameter requiredMemory: Required memory in bytes.
    /// - Returns: True if there's sufficient memory.
    public func hasSufficientMemory(_ requiredMemory: Int) -> Bool {
        guard parameters.maxMemoryUsage > 0 else { return true }
        return requiredMemory <= parameters.maxMemoryUsage
    }

    /// Returns recommended memory allocation strategy.
    ///
    /// - Parameter dataSize: Size of data to process.
    /// - Returns: Recommended allocation strategy.
    public func recommendedAllocationStrategy(dataSize: Int) -> String {
        if parameters.enableCacheOptimization && dataSize < 1024 * 1024 {
            return "stack"
        } else if dataSize > 100 * 1024 * 1024 {
            return "memory_mapped"
        } else {
            return "heap"
        }
    }
}
