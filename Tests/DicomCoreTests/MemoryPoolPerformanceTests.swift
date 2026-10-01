import XCTest
@testable import DicomCore

/// Performance tests to verify that buffer pooling optimization delivers expected allocation reduction.
/// Acceptance criteria: <50% allocations vs baseline for 100+ slice series with >70% pool hit rate.
final class MemoryPoolPerformanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear pool to ensure clean baseline
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()
    }

    override func tearDown() {
        // Clean up after tests
        BufferPool.shared.clear()
        super.tearDown()
    }

    // MARK: - Buffer Pool Hit Rate Benchmark

    /// Measures buffer pool hit rate during repeated buffer acquisition.
    /// Expected: >70% hit rate for typical series loading workflow.
    func testBufferPoolHitRate() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let sliceCount = 100
        let pixelCount = 512 * 512

        // Simulate series loading: acquire and release same-sized buffers
        for _ in 0..<sliceCount {
            let buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
            // Simulate pixel processing
            XCTAssertGreaterThanOrEqual(buffer.count, pixelCount)
            pool.release(buffer)
        }

        let stats = pool.statistics

        print("""

        ========== Buffer Pool Hit Rate Benchmark ==========
        Slice count: \(sliceCount)
        Total acquires: \(stats.totalAcquires)
        Pool hits: \(stats.hits)
        Pool misses: \(stats.misses)
        Hit rate: \(String(format: "%.1f", stats.hitRate))%
        Peak pool size: \(stats.peakPoolSize)
        Allocation reduction: \(String(format: "%.1f", (Double(stats.hits) / Double(sliceCount)) * 100.0))%
        ======================================================

        """)

        // Acceptance criteria: hit rate should be >70%
        XCTAssertGreaterThan(stats.hitRate, 70.0, "Pool hit rate should exceed 70%")

        // First acquisition is always a miss, rest should be hits
        XCTAssertEqual(stats.misses, 1, "Should have exactly 1 miss (first acquisition)")
        XCTAssertEqual(stats.hits, sliceCount - 1, "Should reuse buffer for all subsequent acquisitions")
    }

    // MARK: - Allocation Reduction Benchmark

    /// Measures allocation reduction compared to baseline (no pooling).
    /// Expected: <50% allocations when using buffer pool.
    func testAllocationReduction() {
        let pool = BufferPool.shared
        let iterations = 3
        let slicesPerSeries = 100
        let pixelCount = 512 * 512

        var pooledAllocations = 0
        let baselineAllocations = slicesPerSeries * iterations // One allocation per slice without pooling

        // Measure pooled allocations
        for _ in 0..<iterations {
            pool.clear()
            pool.resetStatistics()

            for _ in 0..<slicesPerSeries {
                let buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
                pool.release(buffer)
            }

            pooledAllocations += pool.statistics.misses
        }

        let avgPooledAllocations = Double(pooledAllocations) / Double(iterations)
        let avgBaselineAllocations = Double(baselineAllocations) / Double(iterations)
        let reductionPercentage = (1.0 - (avgPooledAllocations / avgBaselineAllocations)) * 100.0

        print("""

        ========== Allocation Reduction Benchmark ==========
        Iterations: \(iterations)
        Slices per series: \(slicesPerSeries)
        Baseline allocations (avg): \(String(format: "%.1f", avgBaselineAllocations))
        Pooled allocations (avg): \(String(format: "%.1f", avgPooledAllocations))
        Allocation reduction: \(String(format: "%.1f", reductionPercentage))%
        ====================================================

        """)

        // Acceptance criteria: pooled allocations should be <50% of baseline
        let allocationRatio = avgPooledAllocations / avgBaselineAllocations
        XCTAssertLessThan(allocationRatio, 0.5, "Pooled allocations should be <50% of baseline")

        // With perfect pooling, should only allocate once per series
        XCTAssertLessThanOrEqual(avgPooledAllocations, Double(iterations), "Should allocate at most once per series")
    }

    // MARK: - Multi-Size Buffer Management

    /// Verifies pool handles multiple buffer sizes efficiently.
    /// Tests that different size buckets don't interfere with each other.
    func testMultiSizeBufferPooling() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        // Simulate series with different image sizes
        let smallSize = 256 * 256
        let mediumSize = 512 * 512
        let largeSize = 1024 * 1024

        let iterations = 10

        for _ in 0..<iterations {
            // Acquire and release different sized buffers
            let small = pool.acquire(type: [UInt16].self, count: smallSize)
            let medium = pool.acquire(type: [UInt16].self, count: mediumSize)
            let large = pool.acquire(type: [UInt16].self, count: largeSize)

            pool.release(small)
            pool.release(medium)
            pool.release(large)
        }

        let stats = pool.statistics

        print("""

        ========== Multi-Size Buffer Management ==========
        Iterations: \(iterations)
        Buffer sizes: 256×256, 512×512, 1024×1024
        Total acquires: \(stats.totalAcquires)
        Pool hits: \(stats.hits)
        Pool misses: \(stats.misses)
        Hit rate: \(String(format: "%.1f", stats.hitRate))%
        ==================================================

        """)

        // Should have 3 misses (one per size) in first iteration, rest are hits
        XCTAssertEqual(stats.misses, 3, "Should miss once per buffer size")
        XCTAssertEqual(stats.hits, (iterations * 3) - 3, "Should hit for all subsequent iterations")
    }

    // MARK: - Series Loading Performance

    /// Benchmarks series loading performance with buffer pooling.
    /// Measures the impact of pooling on real-world series loading workflow.
    func testSeriesLoadingWithPooling() {
        let pool = BufferPool.shared
        let sliceCount = 100
        let pixelCount = 512 * 512
        let iterations = 5

        var totalLoadTime: CFAbsoluteTime = 0

        for iteration in 0..<iterations {
            pool.clear()
            pool.resetStatistics()

            let start = CFAbsoluteTimeGetCurrent()

            // Simulate series loading workflow
            for _ in 0..<sliceCount {
                let buffer = pool.acquire(type: [Int16].self, count: pixelCount)
                // Simulate pixel processing (minimal work)
                _ = buffer[0]
                pool.release(buffer)
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            totalLoadTime += elapsed

            if iteration == 0 {
                // Log first iteration for detailed analysis
                let stats = pool.statistics
                print("""

                ========== First Iteration Statistics ==========
                Slices: \(sliceCount)
                Elapsed time: \(String(format: "%.6f", elapsed))s
                Pool hits: \(stats.hits)
                Pool misses: \(stats.misses)
                Hit rate: \(String(format: "%.1f", stats.hitRate))%
                ================================================

                """)
            }
        }

        let avgLoadTime = totalLoadTime / Double(iterations)
        let avgTimePerSlice = (avgLoadTime / Double(sliceCount)) * 1000.0 // in milliseconds

        print("""

        ========== Series Loading Performance ==========
        Iterations: \(iterations)
        Slices per series: \(sliceCount)
        Avg total time: \(String(format: "%.6f", avgLoadTime))s
        Avg time per slice: \(String(format: "%.3f", avgTimePerSlice))ms
        ================================================

        """)

        // Pool operations should be fast (<10ms per slice including loop overhead)
        XCTAssertLessThan(avgTimePerSlice, 10.0, "Pool acquire/release should be <10ms per slice")
    }

    // MARK: - Memory Pressure Handling

    /// Verifies pool releases buffers correctly under memory pressure.
    /// Tests that clear() and releaseHalf() reduce pool size as expected.
    func testMemoryPressureRelease() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let bufferCount = 10
        let pixelCount = 512 * 512

        // Build up pool with multiple buffers of different sizes
        var buffers: [[UInt16]] = []
        for _ in 0..<bufferCount {
            let buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
            buffers.append(buffer)
        }
        // Release all to populate pool
        for buffer in buffers {
            pool.release(buffer)
        }

        let statsBeforeRelease = pool.statistics
        let initialPoolSize = statsBeforeRelease.currentPoolSize
        XCTAssertGreaterThan(initialPoolSize, 0, "Pool should contain buffers")

        // Test releaseHalf() - should reduce pool size by ~50%
        pool.releaseHalf()
        let statsAfterHalf = pool.statistics
        let halfPoolSize = statsAfterHalf.currentPoolSize

        // releaseHalf should release approximately half (may be less due to integer division)
        XCTAssertLessThanOrEqual(halfPoolSize, initialPoolSize / 2 + 1, "releaseHalf() should reduce pool size by ~50%")

        // Test clear()
        pool.clear()
        let statsAfterClear = pool.statistics
        XCTAssertEqual(statsAfterClear.currentPoolSize, 0, "clear() should remove all buffers")

        print("""

        ========== Memory Pressure Handling ==========
        Initial pool size: \(initialPoolSize)
        After releaseHalf(): \(halfPoolSize) (~\(String(format: "%.0f", Double(halfPoolSize) / Double(initialPoolSize) * 100.0))%)
        After clear(): \(statsAfterClear.currentPoolSize)
        ==============================================

        """)
    }

    // MARK: - Concurrent Access Performance

    /// Measures pool performance under concurrent access.
    /// Verifies thread safety and acceptable contention.
    @MainActor
    func testConcurrentAccess() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let threadCount = 4
        let iterationsPerThread = 25
        let pixelCount = 512 * 512

        let expectation = self.expectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = threadCount

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<threadCount {
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<iterationsPerThread {
                    let buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
                    // Simulate minimal processing
                    _ = buffer[0]
                    pool.release(buffer)
                }
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let stats = pool.statistics
        let totalOperations = threadCount * iterationsPerThread

        print("""

        ========== Concurrent Access Performance ==========
        Threads: \(threadCount)
        Iterations per thread: \(iterationsPerThread)
        Total operations: \(totalOperations)
        Elapsed time: \(String(format: "%.6f", elapsed))s
        Avg time per operation: \(String(format: "%.3f", (elapsed / Double(totalOperations)) * 1000.0))ms
        Pool hits: \(stats.hits)
        Pool misses: \(stats.misses)
        Hit rate: \(String(format: "%.1f", stats.hitRate))%
        ====================================================

        """)

        // Concurrent access should still maintain high hit rate
        XCTAssertGreaterThan(stats.hitRate, 70.0, "Hit rate should remain >70% under concurrent access")
    }

    // MARK: - Type-Specific Pool Isolation

    /// Verifies that different buffer types maintain separate pools.
    /// Tests that UInt16, UInt8, Int16, Float pools don't interfere.
    func testTypeSpecificPoolIsolation() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let pixelCount = 512 * 512
        let iterations = 5

        // Acquire different types in sequence
        for _ in 0..<iterations {
            let uint16Buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
            let uint8Buffer = pool.acquire(type: [UInt8].self, count: pixelCount)
            let int16Buffer = pool.acquire(type: [Int16].self, count: pixelCount)
            let floatBuffer = pool.acquire(type: [Float].self, count: pixelCount)

            pool.release(uint16Buffer)
            pool.release(uint8Buffer)
            pool.release(int16Buffer)
            pool.release(floatBuffer)
        }

        let stats = pool.statistics

        print("""

        ========== Type-Specific Pool Isolation ==========
        Iterations: \(iterations)
        Types tested: UInt16, UInt8, Int16, Float
        Total acquires: \(stats.totalAcquires)
        Pool misses: \(stats.misses)
        Pool hits: \(stats.hits)
        Expected misses: 4 (one per type)
        ==================================================

        """)

        // Should have 4 misses (one per type) in first iteration
        XCTAssertEqual(stats.misses, 4, "Should miss once per buffer type")
        XCTAssertEqual(stats.hits, (iterations * 4) - 4, "Should hit for all subsequent type acquisitions")
    }

    // MARK: - Large Series Stress Test

    /// Stress test with large series to verify sustained performance.
    /// Tests 200-slice series to validate acceptance criteria at scale.
    func testLargeSeriesAllocationReduction() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let sliceCount = 200
        let pixelCount = 512 * 512

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<sliceCount {
            let buffer = pool.acquire(type: [UInt16].self, count: pixelCount)
            pool.release(buffer)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let stats = pool.statistics

        let baselineAllocations = sliceCount
        let allocationReduction = (1.0 - (Double(stats.misses) / Double(baselineAllocations))) * 100.0

        print("""

        ========== Large Series Stress Test ==========
        Slice count: \(sliceCount)
        Elapsed time: \(String(format: "%.6f", elapsed))s
        Baseline allocations: \(baselineAllocations)
        Pooled allocations: \(stats.misses)
        Allocation reduction: \(String(format: "%.1f", allocationReduction))%
        Hit rate: \(String(format: "%.1f", stats.hitRate))%
        ==============================================

        """)

        // Acceptance criteria for 200+ slice series
        XCTAssertLessThan(Double(stats.misses) / Double(baselineAllocations), 0.5,
                         "Allocations should be <50% of baseline for large series")
        XCTAssertGreaterThan(stats.hitRate, 70.0, "Hit rate should exceed 70% for large series")
    }
}
