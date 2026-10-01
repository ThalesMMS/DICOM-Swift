//
// J2KHTBlockCoderMemoryTracker.swift
// J2KSwift
//
// J2KHTBlockCoderMemoryTracker.swift
// J2KSwift
//
// Memory allocation tracking for HTJ2K block coder
//

import Foundation

/// Tracks memory allocations in the HTJ2K block coder for profiling and optimisation.
///
/// This actor provides thread-safe tracking of memory allocations during encoding and
/// decoding operations, enabling identification of hot allocation paths and validation
/// of memory optimisation improvements.
///
/// ## Usage
///
/// ```swift
/// let tracker = HTBlockCoderMemoryTracker.shared
/// await tracker.recordAllocation(size: 1024, type: .melBuffer)
/// let stats = await tracker.statistics()
/// ```
public actor HTBlockCoderMemoryTracker {
    /// Shared instance for global memory tracking.
    public static let shared = HTBlockCoderMemoryTracker()

    /// Types of allocations tracked in the HT block coder.
    public enum AllocationType: String, Sendable {
        /// MEL coder buffer allocation.
        case melBuffer

        /// VLC coder buffer allocation.
        case vlcBuffer

        /// MagSgn coder buffer allocation.
        case magsgnBuffer

        /// Coefficient array allocation.
        case coefficientArray

        /// Significance state array allocation.
        case significanceState

        /// Temporary scratch buffer allocation.
        case scratchBuffer

        /// Data stream allocation.
        case dataStream
    }

    /// Statistics for a specific allocation type.
    public struct AllocationStats: Sendable {
        /// Total number of allocations.
        public let count: Int

        /// Total bytes allocated.
        public let totalBytes: Int

        /// Average allocation size.
        public var averageSize: Int {
            count > 0 ? totalBytes / count : 0 // swiftlint:disable:this empty_count
        }

        /// Minimum allocation size.
        public let minSize: Int

        /// Maximum allocation size.
        public let maxSize: Int
    }

    /// Tracking data per allocation type.
    private struct TrackingData {
        var count: Int = 0
        var totalBytes: Int = 0
        var minSize = Int.max
        var maxSize: Int = 0

        var isEmpty: Bool { count == 0 } // swiftlint:disable:this empty_count
    }

    /// Whether tracking is enabled.
    private var enabled: Bool = false

    /// Allocation tracking data by type.
    private var tracking: [AllocationType: TrackingData] = [:]

    /// Peak memory usage across all tracked allocations.
    private var peakMemory: Int = 0

    /// Current active memory (not yet released).
    private var currentMemory: Int = 0

    /// Creates a new memory tracker.
    public init() {}

    /// Enables memory tracking.
    public func enable() {
        enabled = true
    }

    /// Disables memory tracking.
    public func disable() {
        enabled = false
    }

    /// Records an allocation.
    ///
    /// - Parameters:
    ///   - size: Size of the allocation in bytes.
    ///   - type: Type of allocation.
    public func recordAllocation(size: Int, type: AllocationType) {
        guard enabled else { return }

        var data = tracking[type] ?? TrackingData()
        data.count += 1
        data.totalBytes += size
        data.minSize = min(data.minSize, size)
        data.maxSize = max(data.maxSize, size)
        tracking[type] = data

        currentMemory += size
        peakMemory = max(peakMemory, currentMemory)
    }

    /// Records a deallocation.
    ///
    /// - Parameter size: Size of the deallocation in bytes.
    public func recordDeallocation(size: Int) {
        guard enabled else { return }
        currentMemory = max(0, currentMemory - size)
    }

    /// Returns statistics for a specific allocation type.
    ///
    /// - Parameter type: The allocation type to query.
    /// - Returns: Statistics for the allocation type, or nil if no allocations recorded.
    public func statistics(for type: AllocationType) -> AllocationStats? {
        guard let data = tracking[type], !data.isEmpty else { return nil }
        return AllocationStats(
            count: data.count,
            totalBytes: data.totalBytes,
            minSize: data.minSize,
            maxSize: data.maxSize
        )
    }

    /// Returns statistics for all allocation types.
    ///
    /// - Returns: Dictionary mapping allocation types to their statistics.
    public func allStatistics() -> [AllocationType: AllocationStats] {
        var result: [AllocationType: AllocationStats] = [:]
        for (type, data) in tracking where !data.isEmpty {
            result[type] = AllocationStats(
                count: data.count,
                totalBytes: data.totalBytes,
                minSize: data.minSize,
                maxSize: data.maxSize
            )
        }
        return result
    }

    /// Returns peak memory usage across all tracked allocations.
    ///
    /// - Returns: Peak memory in bytes.
    public func peakMemoryUsage() -> Int {
        peakMemory
    }

    /// Returns current active memory (not yet released).
    ///
    /// - Returns: Current memory in bytes.
    public func currentMemoryUsage() -> Int {
        currentMemory
    }

    /// Resets all tracking data.
    public func reset() {
        tracking.removeAll()
        peakMemory = 0
        currentMemory = 0
    }

    /// Prints a formatted summary of allocation statistics.
    public func printSummary() {
        print("HTBlockCoder Memory Allocation Summary")
        print("========================================")
        print("Peak Memory: \(peakMemory) bytes (\(Double(peakMemory) / 1024.0) KB)")
        print("Current Memory: \(currentMemory) bytes")
        print("")

        let stats = allStatistics()
        guard !stats.isEmpty else {
            print("No allocations recorded.")
            return
        }

        for type in AllocationType.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let stat = stats[type] else { continue }
            print("\(type.rawValue):")
            print("  Count: \(stat.count)")
            print("  Total: \(stat.totalBytes) bytes (\(Double(stat.totalBytes) / 1024.0) KB)")
            print("  Average: \(stat.averageSize) bytes")
            print("  Range: \(stat.minSize) - \(stat.maxSize) bytes")
        }
    }
}

extension HTBlockCoderMemoryTracker.AllocationType: CaseIterable {}
