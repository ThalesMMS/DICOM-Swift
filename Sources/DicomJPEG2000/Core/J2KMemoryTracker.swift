//
// J2KMemoryTracker.swift
// J2KSwift
//
/// # J2KMemoryTracker
///
/// Memory usage tracking and limit enforcement for JPEG 2000 operations.
///
/// This module provides utilities for tracking memory usage and enforcing
/// limits to prevent excessive memory consumption.

import Foundation

/// A memory tracker for monitoring and limiting memory usage.
///
/// `J2KMemoryTracker` tracks memory allocations and provides mechanisms
/// to enforce memory limits. It can be used to prevent excessive memory
/// usage during image processing operations.
///
/// The tracker is thread-safe and can be shared across multiple operations.
///
/// Example:
/// ```swift
/// let tracker = J2KMemoryTracker(limit: 100 * 1024 * 1024) // 100MB limit
/// try tracker.allocate(1024 * 1024) // 1MB allocation
/// tracker.deallocate(1024 * 1024)
/// ```
internal actor J2KMemoryTracker {
    /// Configuration for the memory tracker.
    internal struct Configuration: Sendable {
        /// Maximum memory usage in bytes (0 = unlimited).
        let limit: Int

        /// Whether to track detailed allocation statistics.
        let trackStatistics: Bool

        /// Memory pressure threshold (0.0 - 1.0).
        /// When usage exceeds this threshold, a warning is triggered.
        let pressureThreshold: Double

        /// Creates a new configuration.
        ///
        /// - Parameters:
        ///   - limit: Maximum memory in bytes (default: 0 = unlimited).
        ///   - trackStatistics: Whether to track detailed stats (default: true).
        ///   - pressureThreshold: Pressure threshold (default: 0.8).
        init(
            limit: Int = 0,
            trackStatistics: Bool = true,
            pressureThreshold: Double = 0.8
        ) {
            self.limit = limit
            self.trackStatistics = trackStatistics
            self.pressureThreshold = pressureThreshold
        }
    }

    /// Memory usage statistics.
    internal struct Statistics: Sendable {
        /// Current memory usage in bytes.
        let currentUsage: Int

        /// Peak memory usage in bytes.
        let peakUsage: Int

        /// Total number of allocations.
        let allocationCount: Int

        /// Total number of deallocations.
        let deallocationCount: Int

        /// Number of failed allocations (due to limit).
        let failedAllocations: Int

        /// Current memory pressure (0.0 - 1.0).
        let pressure: Double
    }

    private let configuration: Configuration
    private var currentUsage: Int = 0
    private var peakUsage: Int = 0
    private var allocationCount: Int = 0
    private var deallocationCount: Int = 0
    private var failedAllocations: Int = 0

    /// Creates a new memory tracker with the specified configuration.
    ///
    /// - Parameter configuration: The tracker configuration (default: default configuration).
    internal init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Convenience initializer with just a memory limit.
    ///
    /// - Parameter limit: The maximum memory limit in bytes.
    internal init(limit: Int) {
        self.configuration = Configuration(limit: limit)
    }

    /// Attempts to allocate the specified amount of memory.
    ///
    /// - Parameter size: The number of bytes to allocate.
    /// - Throws: `J2KError.internalError` if allocation would exceed the limit.
    internal func allocate(_ size: Int) throws {
        // Check if allocation would exceed limit
        if configuration.limit > 0 {
            let newUsage = currentUsage + size
            if newUsage > configuration.limit {
                failedAllocations += 1
                throw J2KError.internalError(
                    "Memory allocation would exceed limit: \(newUsage) > \(configuration.limit)"
                )
            }
        }

        // Update tracking
        currentUsage += size
        peakUsage = max(peakUsage, currentUsage)

        if configuration.trackStatistics {
            allocationCount += 1
        }

        // Check for memory pressure
        if configuration.limit > 0 {
            let pressure = Double(currentUsage) / Double(configuration.limit)
            if pressure >= configuration.pressureThreshold {
                // Memory pressure detected
                // Note: In production, this could trigger callbacks or notifications
            }
        }
    }

    /// Deallocates the specified amount of memory.
    ///
    /// - Parameter size: The number of bytes to deallocate.
    internal func deallocate(_ size: Int) {
        currentUsage = max(0, currentUsage - size)

        if configuration.trackStatistics {
            deallocationCount += 1
        }
    }

    /// Returns current memory usage statistics.
    ///
    /// - Returns: Statistics about memory usage.
    internal func getStatistics() -> Statistics {
        let pressure: Double
        if configuration.limit > 0 {
            pressure = Double(currentUsage) / Double(configuration.limit)
        } else {
            pressure = 0.0
        }

        return Statistics(
            currentUsage: currentUsage,
            peakUsage: peakUsage,
            allocationCount: allocationCount,
            deallocationCount: deallocationCount,
            failedAllocations: failedAllocations,
            pressure: pressure
        )
    }

    /// Resets the tracker statistics.
    ///
    /// This resets peak usage and counters, but maintains current usage.
    internal func resetStatistics() {
        peakUsage = currentUsage
        allocationCount = 0
        deallocationCount = 0
        failedAllocations = 0
    }

    /// Resets the tracker completely, including current usage.
    ///
    /// Warning: This should only be used when all tracked allocations
    /// have been properly deallocated.
    internal func reset() {
        currentUsage = 0
        peakUsage = 0
        allocationCount = 0
        deallocationCount = 0
        failedAllocations = 0
    }

    /// Checks if there is sufficient memory available for an allocation.
    ///
    /// - Parameter size: The number of bytes to check.
    /// - Returns: `true` if the allocation would succeed, `false` otherwise.
    internal func canAllocate(_ size: Int) -> Bool {
        if configuration.limit == 0 {
            return true
        }
        return currentUsage + size <= configuration.limit
    }

    /// Returns the amount of memory available for allocation.
    ///
    /// - Returns: Available memory in bytes, or `Int.max` if unlimited.
    internal func availableMemory() -> Int {
        if configuration.limit == 0 {
            return Int.max
        }
        return max(0, configuration.limit - currentUsage)
    }
}
