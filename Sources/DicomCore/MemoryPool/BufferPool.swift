import Foundation

/// Thread-safe buffer pool for DICOM pixel data recycling.
///
/// **Design Decision: Buffer Pool Architecture**
///
/// This implementation uses size-based bucketing with type-specific pools to reduce
/// allocation overhead when processing series of similar-sized images.
///
/// **Key Design Choices:**
///
/// 1. **Size-Based Bucketing**: Buffers are organized into fixed-size buckets
///    (256×256, 512×512, 1024×1024, 2048×2048) to prevent fragmentation and
///    maximize reuse. Requests are rounded up to the next bucket size.
///
/// 2. **Type-Specific Pools**: Separate pools for UInt16, UInt8, Int16, Float,
///    and Data types prevent type confusion and enable efficient memory reuse
///    without costly conversions.
///
/// 3. **Thread-Safe Access**: Uses `DicomLock` (os_unfair_lock) for synchronization.
///    Pool operations are fast (<1ms) and lock contention is minimal since buffers
///    are typically acquired/released at slice boundaries.
///
/// 4. **Lazy Allocation**: Buffers are created on-demand. The pool starts empty
///    and grows as needed, avoiding upfront memory pressure.
///
/// 5. **Manual Memory Management**: No automatic eviction policy to avoid
///    unpredictable performance. Users call `clear()` explicitly or respond to
///    memory pressure notifications.
///
/// **Performance Characteristics:**
///
/// - Pool hit: ~0.1ms (array reuse)
/// - Pool miss: ~50-200ms (new allocation + initialization)
/// - Target hit rate: >70% for series processing
/// - Expected allocation reduction: <50% of baseline for 100+ slice series
///
/// **Usage Example:**
///
/// ```swift
/// let pool = BufferPool.shared
///
/// // Acquire a buffer from the pool
/// let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
///
/// // Use the buffer...
/// // processPixels(buffer)
///
/// // Release back to pool when done
/// pool.release(buffer)
///
/// // Check pool statistics
/// let stats = pool.statistics
/// print("Hit rate: \(stats.hitRate)%, Current pool size: \(stats.currentPoolSize)")
///
/// // Clear pools under memory pressure
/// pool.clear()
/// ```
///
/// **Memory Pressure Handling:**
///
/// The pool integrates with system memory pressure notifications (added in phase 4):
/// - Warning level: Release 50% of pooled buffers
/// - Critical level: Release all pooled buffers
/// - Manual clearing: Call `clear()` for immediate release
///
/// This design balances performance (avoiding repeated allocations) with memory
/// efficiency (releasing buffers when needed).
/// `BufferPool` is safe to share because every mutable pool, monitor, and
/// statistics field is accessed while holding `lock`.
public final class BufferPool: @unchecked Sendable {
    /// Shared singleton instance for global buffer pooling.
    public static let shared = BufferPool()

    /// Statistics for pool performance diagnostics.
    ///
    /// Useful for tuning pool behavior and understanding allocation patterns.
    public struct Statistics: Sendable {
        /// Total number of buffer acquisitions that found a buffer in the pool.
        public let hits: Int

        /// Total number of buffer acquisitions that required new allocation.
        public let misses: Int

        /// Current number of buffers held in all pools.
        public let currentPoolSize: Int

        /// Peak number of buffers ever held in all pools.
        public let peakPoolSize: Int

        /// Hit rate as a percentage (0-100).
        public var hitRate: Double {
            let total = hits + misses
            guard total > 0 else { return 0.0 }
            return Double(hits) / Double(total) * 100.0
        }

        /// Total number of acquire operations.
        public var totalAcquires: Int {
            return hits + misses
        }
    }

    /// Bucket sizes for image dimensions (pixel count).
    /// Requests are rounded up to the next bucket to minimize fragmentation.
    private enum BucketSize: Int, CaseIterable {
        case small = 65536      // 256×256
        case medium = 262144    // 512×512
        case large = 1048576    // 1024×1024
        case xlarge = 4194304   // 2048×2048

        /// Returns the appropriate bucket for a given buffer size.
        static func bucket(for count: Int) -> BucketSize {
            for size in BucketSize.allCases {
                if count <= size.rawValue {
                    return size
                }
            }
            // For buffers larger than xlarge, use xlarge bucket
            // This prevents unbounded bucket creation
            return .xlarge
        }
    }

    /// Type-safe buffer pool storage.
    private struct BufferPools {
        var uint16: [BucketSize: [[UInt16]]] = [:]
        var uint8: [BucketSize: [[UInt8]]] = [:]
        var int16: [BucketSize: [[Int16]]] = [:]
        var float: [BucketSize: [[Float]]] = [:]
        var data: [BucketSize: [Data]] = [:]
    }

    /// Storage for all buffer pools, protected by lock.
    private var pools = BufferPools()

    /// Lock for thread-safe access to pools.
    private let lock = DicomLock()

    // MARK: - Memory Pressure Monitoring

    /// Memory pressure monitor for automatic buffer cleanup.
    private var memoryPressureMonitor: MemoryPressureMonitor?

    // MARK: - Statistics Tracking

    /// Total number of pool hits (buffer reuse).
    private var statsHits: Int = 0

    /// Total number of pool misses (new allocations).
    private var statsMisses: Int = 0

    /// Current number of buffers in all pools.
    private var statsCurrentPoolSize: Int = 0

    /// Peak number of buffers ever held in all pools.
    private var statsPeakPoolSize: Int = 0

    /// Private initializer for singleton pattern.
    private init() {
        // Initialize empty pools for all bucket sizes
        for bucket in BucketSize.allCases {
            pools.uint16[bucket] = []
            pools.uint8[bucket] = []
            pools.int16[bucket] = []
            pools.float[bucket] = []
            pools.data[bucket] = []
        }
    }

    // MARK: - Public API

    /// Acquires a buffer from the pool or creates a new one if the pool is empty.
    ///
    /// This method attempts to reuse an existing buffer from the appropriate size bucket.
    /// If no buffer is available, a new one is allocated. The buffer is NOT zeroed on
    /// acquisition for performance - callers should overwrite all elements.
    ///
    /// - Parameters:
    ///   - type: The array type to acquire (e.g., `[UInt16].self`)
    ///   - count: The number of elements needed
    /// - Returns: A buffer with capacity >= count
    ///
    /// - Note: Buffers may be larger than requested due to bucketing.
    ///         Always use the `count` parameter to track actual size needed.
    public func acquire<T>(type: [T].Type, count: Int) -> [T] {
        let bucket = BucketSize.bucket(for: count)
        // Above the largest bucket a buffer is exact and never pooled: the
        // largest bucket's buffer would be shorter than asked (issue #2849).
        let pooled = count <= BucketSize.xlarge.rawValue
        let bucketSize = pooled ? bucket.rawValue : count

        return lock.withLock {
            let poolHit: Bool
            let buffer: [T]

            switch T.self {
            case is UInt16.Type:
                if pooled, !pools.uint16[bucket, default: []].isEmpty {
                    poolHit = true
                    statsCurrentPoolSize -= 1
                    buffer = pools.uint16[bucket]!.removeLast() as! [T]
                } else {
                    poolHit = false
                    buffer = Array(repeating: UInt16(0), count: bucketSize) as! [T]
                }

            case is UInt8.Type:
                if pooled, !pools.uint8[bucket, default: []].isEmpty {
                    poolHit = true
                    statsCurrentPoolSize -= 1
                    buffer = pools.uint8[bucket]!.removeLast() as! [T]
                } else {
                    poolHit = false
                    buffer = Array(repeating: UInt8(0), count: bucketSize) as! [T]
                }

            case is Int16.Type:
                if pooled, !pools.int16[bucket, default: []].isEmpty {
                    poolHit = true
                    statsCurrentPoolSize -= 1
                    buffer = pools.int16[bucket]!.removeLast() as! [T]
                } else {
                    poolHit = false
                    buffer = Array(repeating: Int16(0), count: bucketSize) as! [T]
                }

            case is Float.Type:
                if pooled, !pools.float[bucket, default: []].isEmpty {
                    poolHit = true
                    statsCurrentPoolSize -= 1
                    buffer = pools.float[bucket]!.removeLast() as! [T]
                } else {
                    poolHit = false
                    buffer = Array(repeating: Float(0), count: bucketSize) as! [T]
                }

            default:
                poolHit = false
                var unpooled: [T] = []
                unpooled.reserveCapacity(count)
                buffer = unpooled
            }

            // Update statistics
            if poolHit {
                statsHits += 1
            } else {
                statsMisses += 1
            }

            return buffer
        }
    }

    /// Acquires a Data buffer from the pool or creates a new one if the pool is empty.
    ///
    /// - Parameter count: The number of bytes needed
    /// - Returns: A Data buffer with capacity >= count
    public func acquireData(count: Int) -> Data {
        let bucket = BucketSize.bucket(for: count)
        let pooled = count <= BucketSize.xlarge.rawValue
        let bucketSize = pooled ? bucket.rawValue : count

        return lock.withLock {
            let poolHit: Bool
            let buffer: Data

            if pooled, !pools.data[bucket, default: []].isEmpty {
                poolHit = true
                statsCurrentPoolSize -= 1
                buffer = pools.data[bucket]!.removeLast()
            } else {
                poolHit = false
                buffer = Data(count: bucketSize)
            }

            // Update statistics
            if poolHit {
                statsHits += 1
            } else {
                statsMisses += 1
            }

            return buffer
        }
    }

    /// Releases a buffer back to the pool for reuse.
    ///
    /// The buffer is NOT cleared or zeroed before returning to the pool.
    /// This avoids unnecessary overhead since the next user will overwrite
    /// the contents anyway.
    ///
    /// - Parameter buffer: The buffer to release
    ///
    /// - Note: Do not use the buffer after releasing it. The contents may
    ///         be overwritten by future users of the pool.
    public func release<T>(_ buffer: [T]) {
        let bucket = BucketSize.bucket(for: buffer.count)
        // Only a buffer of a bucket's exact size is pooled: any other would be
        // handed out for that bucket shorter than asked (issue #2849).
        guard buffer.count == bucket.rawValue else { return }

        lock.withLock {
            switch T.self {
            case is UInt16.Type:
                pools.uint16[bucket, default: []].append(buffer as! [UInt16])
                statsCurrentPoolSize += 1

            case is UInt8.Type:
                pools.uint8[bucket, default: []].append(buffer as! [UInt8])
                statsCurrentPoolSize += 1

            case is Int16.Type:
                pools.int16[bucket, default: []].append(buffer as! [Int16])
                statsCurrentPoolSize += 1

            case is Float.Type:
                pools.float[bucket, default: []].append(buffer as! [Float])
                statsCurrentPoolSize += 1

            default:
                // Unsupported types are not pooled
                break
            }

            // Update peak pool size if needed
            if statsCurrentPoolSize > statsPeakPoolSize {
                statsPeakPoolSize = statsCurrentPoolSize
            }
        }
    }

    /// Releases a Data buffer back to the pool for reuse.
    ///
    /// - Parameter buffer: The Data buffer to release
    public func releaseData(_ buffer: Data) {
        let bucket = BucketSize.bucket(for: buffer.count)
        guard buffer.count == bucket.rawValue else { return }

        lock.withLock {
            pools.data[bucket, default: []].append(buffer)
            statsCurrentPoolSize += 1

            // Update peak pool size if needed
            if statsCurrentPoolSize > statsPeakPoolSize {
                statsPeakPoolSize = statsCurrentPoolSize
            }
        }
    }

    /// Clears all pooled buffers, releasing memory back to the system.
    ///
    /// This should be called:
    /// - When receiving memory pressure warnings
    /// - When transitioning between studies/series
    /// - Before entering a memory-constrained operation
    ///
    /// After clearing, the pool will rebuild as new buffers are acquired.
    ///
    /// - Note: This is a blocking operation that holds the lock while clearing.
    ///         Avoid calling from performance-critical paths.
    public func clear() {
        lock.withLock {
            for bucket in BucketSize.allCases {
                pools.uint16[bucket] = []
                pools.uint8[bucket] = []
                pools.int16[bucket] = []
                pools.float[bucket] = []
                pools.data[bucket] = []
            }
            statsCurrentPoolSize = 0
        }
    }

    /// Releases approximately 50% of pooled buffers to reduce memory pressure.
    ///
    /// This method removes half of the buffers from each pool, prioritizing
    /// larger buffers first (by removing from the end of each pool array).
    ///
    /// Called automatically when system reports memory warning level pressure
    /// if memory pressure monitoring is enabled.
    ///
    /// After releasing, the pool can still serve requests from remaining buffers
    /// and will allocate new ones as needed.
    ///
    /// - Note: This is a blocking operation that holds the lock while releasing.
    public func releaseHalf() {
        lock.withLock {
            var releasedCount = 0

            for bucket in BucketSize.allCases {
                // Release half of each pool type
                let uint16Count = pools.uint16[bucket, default: []].count
                if uint16Count > 0 {
                    let toRemove = uint16Count / 2
                    pools.uint16[bucket]?.removeLast(toRemove)
                    releasedCount += toRemove
                }

                let uint8Count = pools.uint8[bucket, default: []].count
                if uint8Count > 0 {
                    let toRemove = uint8Count / 2
                    pools.uint8[bucket]?.removeLast(toRemove)
                    releasedCount += toRemove
                }

                let int16Count = pools.int16[bucket, default: []].count
                if int16Count > 0 {
                    let toRemove = int16Count / 2
                    pools.int16[bucket]?.removeLast(toRemove)
                    releasedCount += toRemove
                }

                let floatCount = pools.float[bucket, default: []].count
                if floatCount > 0 {
                    let toRemove = floatCount / 2
                    pools.float[bucket]?.removeLast(toRemove)
                    releasedCount += toRemove
                }

                let dataCount = pools.data[bucket, default: []].count
                if dataCount > 0 {
                    let toRemove = dataCount / 2
                    pools.data[bucket]?.removeLast(toRemove)
                    releasedCount += toRemove
                }
            }

            statsCurrentPoolSize -= releasedCount
        }
    }

    // MARK: - Memory Pressure Integration

    /// Enables automatic memory pressure monitoring for the buffer pool.
    ///
    /// When enabled, the pool will automatically respond to system memory pressure:
    /// - **Warning level**: Releases 50% of pooled buffers via `releaseHalf()`
    /// - **Critical level**: Releases all pooled buffers via `clear()`
    ///
    /// This should be called once during application initialization. The monitoring
    /// continues until the BufferPool instance is deallocated or explicitly stopped.
    ///
    /// **Usage Example:**
    ///
    /// ```swift
    /// // Enable monitoring at app launch
    /// BufferPool.shared.enableMemoryPressureMonitoring()
    /// ```
    ///
    /// - Note: This method is idempotent - calling it multiple times has no effect
    ///         after the first call. The monitor is automatically stopped on deinitialization.
    public func enableMemoryPressureMonitoring() {
        lock.withLock {
            // Only create monitor if not already monitoring
            guard memoryPressureMonitor == nil else { return }

            let monitor = MemoryPressureMonitor { [weak self] level in
                guard let self = self else { return }

                switch level {
                case .warning:
                    // Release 50% of buffers under moderate pressure
                    self.releaseHalf()

                case .critical:
                    // Release all buffers under critical pressure
                    self.clear()
                }
            }

            monitor.start()
            self.memoryPressureMonitor = monitor
        }
    }

    /// Disables memory pressure monitoring.
    ///
    /// Stops the memory pressure monitor if it is currently active. After calling
    /// this method, the pool will no longer automatically respond to system memory
    /// pressure events.
    ///
    /// - Note: This is called automatically on deinitialization, so explicit calls
    ///         are typically not needed unless you want to stop monitoring earlier.
    public func disableMemoryPressureMonitoring() {
        lock.withLock {
            memoryPressureMonitor?.stop()
            memoryPressureMonitor = nil
        }
    }

    // MARK: - Statistics API

    /// Returns the current pool statistics for diagnostics and tuning.
    ///
    /// Statistics include:
    /// - Total hits and misses
    /// - Hit rate percentage
    /// - Current and peak pool sizes
    ///
    /// Useful for understanding pool effectiveness and identifying optimization opportunities.
    ///
    /// - Returns: Current statistics snapshot
    public var statistics: Statistics {
        return lock.withLock {
            Statistics(
                hits: statsHits,
                misses: statsMisses,
                currentPoolSize: statsCurrentPoolSize,
                peakPoolSize: statsPeakPoolSize
            )
        }
    }

    /// Resets all statistics counters to zero.
    ///
    /// Useful for:
    /// - Starting a fresh measurement period
    /// - Testing pool behavior in isolation
    /// - Benchmarking specific workflows
    ///
    /// - Note: Does NOT clear the pool itself, only resets statistics.
    ///         Use `clear()` to release pooled buffers.
    public func resetStatistics() {
        lock.withLock {
            statsHits = 0
            statsMisses = 0
            // Note: currentPoolSize is not reset as it reflects actual pool state
            statsPeakPoolSize = statsCurrentPoolSize
        }
    }

    // MARK: - Deinitialization

    deinit {
        // Ensure memory pressure monitor is stopped
        memoryPressureMonitor?.stop()
    }
}
