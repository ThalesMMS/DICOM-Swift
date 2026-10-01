import XCTest
@testable import DicomCore

final class BufferPoolTests: XCTestCase {

    // MARK: - Setup and Teardown

    override func setUp() {
        super.setUp()
        // Clear pool before each test to ensure clean state
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()
    }

    override func tearDown() {
        // Clean up after each test
        BufferPool.shared.clear()
        BufferPool.shared.resetStatistics()
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testSharedInstanceExists() {
        let pool = BufferPool.shared
        XCTAssertNotNil(pool, "Shared pool instance should exist")
    }

    func testSharedInstanceIsSingleton() {
        let pool1 = BufferPool.shared
        let pool2 = BufferPool.shared
        XCTAssertTrue(pool1 === pool2, "Shared instance should be a singleton")
    }

    func testInitialStatisticsAreZero() {
        let stats = BufferPool.shared.statistics
        XCTAssertEqual(stats.hits, 0, "Initial hits should be 0")
        XCTAssertEqual(stats.misses, 0, "Initial misses should be 0")
        XCTAssertEqual(stats.currentPoolSize, 0, "Initial pool size should be 0")
        XCTAssertEqual(stats.peakPoolSize, 0, "Initial peak pool size should be 0")
        XCTAssertEqual(stats.hitRate, 0.0, "Initial hit rate should be 0")
        XCTAssertEqual(stats.totalAcquires, 0, "Initial total acquires should be 0")
    }

    // MARK: - UInt16 Buffer Tests

    func testAcquireUInt16Buffer() {
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)

        XCTAssertFalse(buffer.isEmpty, "Acquired buffer should not be empty")
        XCTAssertGreaterThanOrEqual(buffer.count, 512 * 512, "Buffer should have at least requested capacity")

        let stats = pool.statistics
        XCTAssertEqual(stats.misses, 1, "First acquire should be a miss")
        XCTAssertEqual(stats.hits, 0, "Should have no hits yet")
    }

    func testReleaseAndReuseUInt16Buffer() {
        let pool = BufferPool.shared

        // First acquire (miss)
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        XCTAssertEqual(pool.statistics.misses, 1, "First acquire should miss")

        // Release back to pool
        pool.release(buffer1)
        XCTAssertEqual(pool.statistics.currentPoolSize, 1, "Pool should have 1 buffer after release")

        // Second acquire (hit)
        let buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        XCTAssertEqual(pool.statistics.hits, 1, "Second acquire should hit")
        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Pool should be empty after hit")
        XCTAssertGreaterThanOrEqual(buffer2.count, 512 * 512, "Reused buffer should have correct size")
    }

    func testMultipleAcquireReleaseUInt16Cycles() {
        let pool = BufferPool.shared
        let count = 256 * 256

        for cycle in 1...5 {
            let buffer = pool.acquire(type: [UInt16].self, count: count)
            XCTAssertGreaterThanOrEqual(buffer.count, count, "Buffer should have correct size in cycle \(cycle)")

            pool.release(buffer)
        }

        let stats = pool.statistics
        XCTAssertEqual(stats.misses, 1, "Should have 1 miss (first acquire)")
        XCTAssertEqual(stats.hits, 4, "Should have 4 hits (subsequent acquires)")
        XCTAssertEqual(stats.totalAcquires, 5, "Should have 5 total acquires")
        XCTAssertEqual(stats.hitRate, 80.0, accuracy: 0.1, "Hit rate should be 80%")
    }

    // MARK: - UInt8 Buffer Tests

    func testAcquireUInt8Buffer() {
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt8].self, count: 512 * 512)

        XCTAssertFalse(buffer.isEmpty, "Acquired buffer should not be empty")
        XCTAssertGreaterThanOrEqual(buffer.count, 512 * 512, "Buffer should have at least requested capacity")
    }

    func testReleaseAndReuseUInt8Buffer() {
        let pool = BufferPool.shared

        let buffer1 = pool.acquire(type: [UInt8].self, count: 256 * 256)
        pool.release(buffer1)

        let buffer2 = pool.acquire(type: [UInt8].self, count: 256 * 256)
        XCTAssertEqual(pool.statistics.hits, 1, "Should reuse UInt8 buffer")
        XCTAssertGreaterThanOrEqual(buffer2.count, 256 * 256, "Reused buffer should have correct size")
    }

    // MARK: - Int16 Buffer Tests

    func testAcquireInt16Buffer() {
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [Int16].self, count: 1024 * 1024)

        XCTAssertFalse(buffer.isEmpty, "Acquired buffer should not be empty")
        XCTAssertGreaterThanOrEqual(buffer.count, 1024 * 1024, "Buffer should have at least requested capacity")
    }

    func testReleaseAndReuseInt16Buffer() {
        let pool = BufferPool.shared

        let buffer1 = pool.acquire(type: [Int16].self, count: 512 * 512)
        pool.release(buffer1)

        let buffer2 = pool.acquire(type: [Int16].self, count: 512 * 512)
        XCTAssertEqual(pool.statistics.hits, 1, "Should reuse Int16 buffer")
        XCTAssertGreaterThanOrEqual(buffer2.count, 512 * 512, "Reused buffer should have correct size")
    }

    // MARK: - Float Buffer Tests

    func testAcquireFloatBuffer() {
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [Float].self, count: 512 * 512)

        XCTAssertFalse(buffer.isEmpty, "Acquired buffer should not be empty")
        XCTAssertGreaterThanOrEqual(buffer.count, 512 * 512, "Buffer should have at least requested capacity")
    }

    func testReleaseAndReuseFloatBuffer() {
        let pool = BufferPool.shared

        let buffer1 = pool.acquire(type: [Float].self, count: 256 * 256)
        pool.release(buffer1)

        let buffer2 = pool.acquire(type: [Float].self, count: 256 * 256)
        XCTAssertEqual(pool.statistics.hits, 1, "Should reuse Float buffer")
        XCTAssertGreaterThanOrEqual(buffer2.count, 256 * 256, "Reused buffer should have correct size")
    }

    // MARK: - Data Buffer Tests

    func testAcquireDataBuffer() {
        let pool = BufferPool.shared
        let buffer = pool.acquireData(count: 512 * 512 * 2) // 512×512 UInt16 = 524288 bytes

        XCTAssertFalse(buffer.isEmpty, "Acquired data buffer should not be empty")
        XCTAssertGreaterThanOrEqual(buffer.count, 512 * 512 * 2, "Data buffer should have at least requested capacity")
    }

    func testReleaseAndReuseDataBuffer() {
        let pool = BufferPool.shared

        let buffer1 = pool.acquireData(count: 256 * 256)
        pool.releaseData(buffer1)
        XCTAssertEqual(pool.statistics.currentPoolSize, 1, "Pool should have 1 data buffer")

        let buffer2 = pool.acquireData(count: 256 * 256)
        XCTAssertEqual(pool.statistics.hits, 1, "Should reuse Data buffer")
        XCTAssertGreaterThanOrEqual(buffer2.count, 256 * 256, "Reused data buffer should have correct size")
    }

    func testMultipleDataBufferCycles() {
        let pool = BufferPool.shared
        let count = 512 * 512

        for _ in 1...3 {
            let buffer = pool.acquireData(count: count)
            pool.releaseData(buffer)
        }

        let stats = pool.statistics
        XCTAssertEqual(stats.misses, 1, "Should have 1 miss for data buffers")
        XCTAssertEqual(stats.hits, 2, "Should have 2 hits for data buffers")
    }

    // MARK: - Bucket Size Tests

    func testSmallBucket() {
        // 256×256 = 65536
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 256 * 256)

        XCTAssertGreaterThanOrEqual(buffer.count, 256 * 256, "Small bucket should accommodate 256×256")
        XCTAssertEqual(buffer.count, 65536, "Small bucket should be exactly 65536 elements")
    }

    func testMediumBucket() {
        // 512×512 = 262144
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)

        XCTAssertGreaterThanOrEqual(buffer.count, 512 * 512, "Medium bucket should accommodate 512×512")
        XCTAssertEqual(buffer.count, 262144, "Medium bucket should be exactly 262144 elements")
    }

    func testLargeBucket() {
        // 1024×1024 = 1048576
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 1024 * 1024)

        XCTAssertGreaterThanOrEqual(buffer.count, 1024 * 1024, "Large bucket should accommodate 1024×1024")
        XCTAssertEqual(buffer.count, 1048576, "Large bucket should be exactly 1048576 elements")
    }

    func testXLargeBucket() {
        // 2048×2048 = 4194304
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 2048 * 2048)

        XCTAssertGreaterThanOrEqual(buffer.count, 2048 * 2048, "XLarge bucket should accommodate 2048×2048")
        XCTAssertEqual(buffer.count, 4194304, "XLarge bucket should be exactly 4194304 elements")
    }

    func testBucketRoundingUp() {
        // Request 300×300 = 90000, should round up to medium bucket (262144)
        let pool = BufferPool.shared
        let buffer = pool.acquire(type: [UInt16].self, count: 300 * 300)

        XCTAssertGreaterThanOrEqual(buffer.count, 300 * 300, "Should accommodate requested size")
        XCTAssertEqual(buffer.count, 262144, "Should round up to medium bucket")
    }

    /// Issue #2849: above the largest bucket the buffer is exact, never the
    /// largest bucket's shorter one, and it does not return to the pool.
    func testOversizedRequestGetsAnExactUnpooledBuffer() {
        let pool = BufferPool.shared
        let count = 2964 * 2364
        let buffer = pool.acquire(type: [Float].self, count: count)
        XCTAssertEqual(buffer.count, count)
        XCTAssertEqual(pool.acquireData(count: count).count, count)
        pool.release(buffer)
        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "an oversized buffer is not pooled")
    }

    /// Issue #2849: a buffer of no bucket's exact size is not pooled, so a
    /// later request never receives one shorter than its bucket.
    func testBufferOfNoBucketSizeIsNotPooled() {
        let pool = BufferPool.shared
        pool.release([UInt16](repeating: 0, count: 70_000))
        XCTAssertEqual(pool.statistics.currentPoolSize, 0)
        XCTAssertEqual(pool.acquire(type: [UInt16].self, count: 200_000).count, 262_144)
    }

    // MARK: - Type-Specific Pool Isolation Tests

    func testDifferentTypesUseSeparatePools() {
        let pool = BufferPool.shared

        // Acquire and release UInt16 buffer
        let uint16Buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(uint16Buffer)

        // Acquire UInt8 buffer - should miss because it's a different pool
        let _ = pool.acquire(type: [UInt8].self, count: 512 * 512)

        let stats = pool.statistics
        XCTAssertEqual(stats.misses, 2, "Different types should use separate pools (2 misses)")
        XCTAssertEqual(stats.hits, 0, "Should have no hits when switching types")
    }

    func testSameTypeBuffersSharePool() {
        let pool = BufferPool.shared

        // Acquire and release two UInt16 buffers
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer1)

        let buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer2)

        let buffer3 = pool.acquire(type: [UInt16].self, count: 512 * 512)

        let stats = pool.statistics
        XCTAssertEqual(stats.hits, 2, "Same type buffers should share pool")
        XCTAssertEqual(stats.misses, 1, "Should have 1 miss for initial acquire")
        XCTAssertGreaterThanOrEqual(buffer3.count, 512 * 512, "Reused buffer should work")
    }

    func testDataBuffersIndependentFromArrayBuffers() {
        let pool = BufferPool.shared

        // Acquire and release UInt8 array buffer
        let arrayBuffer = pool.acquire(type: [UInt8].self, count: 512 * 512)
        pool.release(arrayBuffer)

        // Acquire Data buffer - should miss
        let _ = pool.acquireData(count: 512 * 512)

        let stats = pool.statistics
        XCTAssertEqual(stats.misses, 2, "Data and array buffers use separate pools")
    }

    // MARK: - Statistics Tests

    func testHitRateCalculation() {
        let pool = BufferPool.shared

        // Create a known pattern: 1 miss, 4 hits = 80% hit rate
        let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer)

        for _ in 1...4 {
            let b = pool.acquire(type: [UInt16].self, count: 512 * 512)
            pool.release(b)
        }

        let stats = pool.statistics
        XCTAssertEqual(stats.hitRate, 80.0, accuracy: 0.1, "Hit rate should be 80%")
    }

    func testHitRateWithNoAcquires() {
        let pool = BufferPool.shared
        let stats = pool.statistics

        XCTAssertEqual(stats.hitRate, 0.0, "Hit rate should be 0 with no acquires")
    }

    func testTotalAcquiresCalculation() {
        let pool = BufferPool.shared

        let _ = pool.acquire(type: [UInt16].self, count: 256 * 256)
        let _ = pool.acquire(type: [UInt8].self, count: 512 * 512)
        let _ = pool.acquireData(count: 1024 * 1024)

        let stats = pool.statistics
        XCTAssertEqual(stats.totalAcquires, 3, "Total acquires should count all operations")
    }

    func testCurrentPoolSizeTracking() {
        let pool = BufferPool.shared

        // Acquire and release 3 buffers
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let buffer3 = pool.acquire(type: [UInt16].self, count: 512 * 512)

        pool.release(buffer1)
        XCTAssertEqual(pool.statistics.currentPoolSize, 1, "Pool should have 1 buffer")

        pool.release(buffer2)
        XCTAssertEqual(pool.statistics.currentPoolSize, 2, "Pool should have 2 buffers")

        pool.release(buffer3)
        XCTAssertEqual(pool.statistics.currentPoolSize, 3, "Pool should have 3 buffers")

        // Acquire one back
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)
        XCTAssertEqual(pool.statistics.currentPoolSize, 2, "Pool should have 2 buffers after acquire")
    }

    func testPeakPoolSizeTracking() {
        let pool = BufferPool.shared

        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let buffer3 = pool.acquire(type: [UInt16].self, count: 512 * 512)

        pool.release(buffer1)
        pool.release(buffer2)
        pool.release(buffer3)

        XCTAssertEqual(pool.statistics.peakPoolSize, 3, "Peak should be 3")

        // Acquire 2 back
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)

        XCTAssertEqual(pool.statistics.currentPoolSize, 1, "Current should be 1")
        XCTAssertEqual(pool.statistics.peakPoolSize, 3, "Peak should still be 3")
    }

    func testResetStatistics() {
        let pool = BufferPool.shared

        // Generate some statistics
        let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer)
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)

        // Reset
        pool.resetStatistics()

        let stats = pool.statistics
        XCTAssertEqual(stats.hits, 0, "Hits should be reset to 0")
        XCTAssertEqual(stats.misses, 0, "Misses should be reset to 0")
        // Note: currentPoolSize is not reset as it reflects actual state
        XCTAssertEqual(stats.peakPoolSize, stats.currentPoolSize, "Peak should reset to current size")
    }

    func testStatisticsAfterReset() {
        let pool = BufferPool.shared

        // Initial operations
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer1)

        pool.resetStatistics()

        // New operations after reset
        let buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer2)

        let stats = pool.statistics
        XCTAssertEqual(stats.hits, 1, "Should count hit after reset")
        XCTAssertEqual(stats.misses, 0, "Should have no misses after reset")
    }

    // MARK: - Clear and Memory Management Tests

    func testClearReleasesAllBuffers() {
        let pool = BufferPool.shared

        // Add some buffers to pool
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let buffer2 = pool.acquire(type: [UInt8].self, count: 256 * 256)
        let buffer3 = pool.acquireData(count: 1024 * 1024)

        pool.release(buffer1)
        pool.releaseData(buffer3)
        pool.release(buffer2)

        XCTAssertEqual(pool.statistics.currentPoolSize, 3, "Pool should have 3 buffers")

        // Clear pool
        pool.clear()

        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Pool should be empty after clear")
    }

    func testClearDoesNotResetStatistics() {
        let pool = BufferPool.shared

        let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer)
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)

        let statsBefore = pool.statistics
        pool.clear()
        let statsAfter = pool.statistics

        XCTAssertEqual(statsAfter.hits, statsBefore.hits, "Hits should not change after clear")
        XCTAssertEqual(statsAfter.misses, statsBefore.misses, "Misses should not change after clear")
        XCTAssertEqual(statsAfter.currentPoolSize, 0, "Pool size should be 0 after clear")
    }

    func testAcquireAfterClearCreatesNewBuffer() {
        let pool = BufferPool.shared

        // Acquire, release, clear
        let buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        pool.release(buffer1)
        pool.clear()

        // Next acquire should miss (pool is empty)
        pool.resetStatistics()
        let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)

        XCTAssertEqual(pool.statistics.misses, 1, "Acquire after clear should miss")
        XCTAssertEqual(pool.statistics.hits, 0, "Should have no hits")
    }

    func testReleaseHalfReducesPoolSize() {
        let pool = BufferPool.shared

        // Add 10 buffers to pool
        var buffers: [[UInt16]] = []
        for _ in 1...10 {
            buffers.append(pool.acquire(type: [UInt16].self, count: 512 * 512))
        }

        for buffer in buffers {
            pool.release(buffer)
        }

        XCTAssertEqual(pool.statistics.currentPoolSize, 10, "Pool should have 10 buffers")

        // Release half
        pool.releaseHalf()

        XCTAssertEqual(pool.statistics.currentPoolSize, 5, "Pool should have 5 buffers after releaseHalf")
    }

    func testReleaseHalfWithOddNumberOfBuffers() {
        let pool = BufferPool.shared

        // Add 7 buffers
        var buffers: [[UInt16]] = []
        for _ in 1...7 {
            buffers.append(pool.acquire(type: [UInt16].self, count: 512 * 512))
        }

        for buffer in buffers {
            pool.release(buffer)
        }

        pool.releaseHalf()

        // 7 / 2 = 3, so should have 4 remaining (7 - 3 = 4)
        XCTAssertEqual(pool.statistics.currentPoolSize, 4, "Pool should have 4 buffers after releaseHalf")
    }

    func testReleaseHalfWithMixedTypes() {
        let pool = BufferPool.shared

        // Add buffers of different types
        let uint16Buffer1 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let uint16Buffer2 = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let uint8Buffer1 = pool.acquire(type: [UInt8].self, count: 256 * 256)
        let uint8Buffer2 = pool.acquire(type: [UInt8].self, count: 256 * 256)

        pool.release(uint16Buffer1)
        pool.release(uint16Buffer2)
        pool.release(uint8Buffer1)
        pool.release(uint8Buffer2)

        XCTAssertEqual(pool.statistics.currentPoolSize, 4, "Pool should have 4 buffers")

        pool.releaseHalf()

        XCTAssertEqual(pool.statistics.currentPoolSize, 2, "Pool should have 2 buffers after releaseHalf")
    }

    func testReleaseHalfOnEmptyPool() {
        let pool = BufferPool.shared

        pool.clear()
        pool.releaseHalf()

        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Empty pool should remain empty")
    }

    // MARK: - Edge Case Tests

    func testReleaseEmptyBuffer() {
        let pool = BufferPool.shared

        let emptyBuffer: [UInt16] = []
        pool.release(emptyBuffer)

        // Should be a no-op
        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Releasing empty buffer should be no-op")
    }

    func testReleaseEmptyDataBuffer() {
        let pool = BufferPool.shared

        let emptyData = Data()
        pool.releaseData(emptyData)

        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Releasing empty data should be no-op")
    }

    func testAcquireVerySmallBuffer() {
        let pool = BufferPool.shared

        // Request very small buffer (should use small bucket)
        let buffer = pool.acquire(type: [UInt16].self, count: 10)

        XCTAssertEqual(buffer.count, 65536, "Small request should use small bucket")
        XCTAssertGreaterThanOrEqual(buffer.count, 10, "Should accommodate requested size")
    }

    func testAcquireExactBucketSize() {
        let pool = BufferPool.shared

        // Request exactly 512×512
        let buffer = pool.acquire(type: [UInt16].self, count: 262144)

        XCTAssertEqual(buffer.count, 262144, "Exact bucket size request should match")
    }

    func testMultipleBuffersSameSizeInPool() {
        let pool = BufferPool.shared

        // Acquire and release 5 buffers of same size
        var buffers: [[UInt16]] = []
        for _ in 1...5 {
            buffers.append(pool.acquire(type: [UInt16].self, count: 512 * 512))
        }

        for buffer in buffers {
            pool.release(buffer)
        }

        XCTAssertEqual(pool.statistics.currentPoolSize, 5, "Pool should hold multiple buffers")

        // Acquire them back
        for _ in 1...5 {
            let _ = pool.acquire(type: [UInt16].self, count: 512 * 512)
        }

        let stats = pool.statistics
        XCTAssertEqual(stats.hits, 5, "Should reuse all 5 buffers")
    }

    func testMixedSizesUseDifferentBuckets() {
        let pool = BufferPool.shared

        // Acquire and release different sized buffers
        let small = pool.acquire(type: [UInt16].self, count: 256 * 256)
        let medium = pool.acquire(type: [UInt16].self, count: 512 * 512)
        let large = pool.acquire(type: [UInt16].self, count: 1024 * 1024)

        pool.release(small)
        pool.release(medium)
        pool.release(large)

        XCTAssertEqual(pool.statistics.currentPoolSize, 3, "Should have 3 buffers in different buckets")

        // Acquire small buffer - should hit small bucket
        pool.resetStatistics()
        let _ = pool.acquire(type: [UInt16].self, count: 256 * 256)
        XCTAssertEqual(pool.statistics.hits, 1, "Should hit small bucket")

        // Acquire large buffer - should hit large bucket
        let _ = pool.acquire(type: [UInt16].self, count: 1024 * 1024)
        XCTAssertEqual(pool.statistics.hits, 2, "Should hit large bucket")
    }

    // MARK: - Concurrent Access Tests

    @MainActor
    func testConcurrentAcquireRelease() {
        let pool = BufferPool.shared
        let expectation = self.expectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 10

        // Simulate concurrent access from multiple threads
        for _ in 1...10 {
            DispatchQueue.global().async {
                let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
                // Simulate some work
                Thread.sleep(forTimeInterval: 0.001)
                pool.release(buffer)
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0) { error in
            XCTAssertNil(error, "Concurrent operations should complete without error")
        }

        // Pool should be consistent after concurrent access
        let stats = pool.statistics
        XCTAssertGreaterThan(stats.totalAcquires, 0, "Should have recorded acquires")
        XCTAssertGreaterThanOrEqual(stats.currentPoolSize, 0, "Pool size should be non-negative")
    }

    @MainActor
    func testConcurrentStatisticsAccess() {
        let pool = BufferPool.shared
        let expectation = self.expectation(description: "Concurrent statistics access")
        expectation.expectedFulfillmentCount = 20

        // Some threads acquire/release, others read statistics
        for i in 1...20 {
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
                    pool.release(buffer)
                } else {
                    let _ = pool.statistics
                }
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0) { error in
            XCTAssertNil(error, "Concurrent statistics access should be safe")
        }
    }

    @MainActor
    func testConcurrentClearOperations() {
        let pool = BufferPool.shared
        let expectation = self.expectation(description: "Concurrent clear operations")
        expectation.expectedFulfillmentCount = 5

        // Add some buffers
        for _ in 1...10 {
            let buffer = pool.acquire(type: [UInt16].self, count: 512 * 512)
            pool.release(buffer)
        }

        // Clear from multiple threads
        for _ in 1...5 {
            DispatchQueue.global().async {
                pool.clear()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0) { error in
            XCTAssertNil(error, "Concurrent clear operations should be safe")
        }

        XCTAssertEqual(pool.statistics.currentPoolSize, 0, "Pool should be empty after concurrent clears")
    }

    // MARK: - Statistics Structure Tests

    func testStatisticsStructure() {
        let stats = BufferPool.Statistics(
            hits: 80,
            misses: 20,
            currentPoolSize: 10,
            peakPoolSize: 15
        )

        XCTAssertEqual(stats.hits, 80, "Hits should match")
        XCTAssertEqual(stats.misses, 20, "Misses should match")
        XCTAssertEqual(stats.currentPoolSize, 10, "Current pool size should match")
        XCTAssertEqual(stats.peakPoolSize, 15, "Peak pool size should match")
        XCTAssertEqual(stats.totalAcquires, 100, "Total acquires should be 100")
        XCTAssertEqual(stats.hitRate, 80.0, accuracy: 0.1, "Hit rate should be 80%")
    }

    func testStatisticsHitRateWithZeroTotal() {
        let stats = BufferPool.Statistics(
            hits: 0,
            misses: 0,
            currentPoolSize: 0,
            peakPoolSize: 0
        )

        XCTAssertEqual(stats.hitRate, 0.0, "Hit rate should be 0 when no acquires")
    }

    func testStatisticsHitRatePerfectHits() {
        let stats = BufferPool.Statistics(
            hits: 100,
            misses: 0,
            currentPoolSize: 5,
            peakPoolSize: 10
        )

        XCTAssertEqual(stats.hitRate, 100.0, accuracy: 0.1, "Hit rate should be 100% with no misses")
    }

    func testStatisticsHitRateNoHits() {
        let stats = BufferPool.Statistics(
            hits: 0,
            misses: 100,
            currentPoolSize: 0,
            peakPoolSize: 0
        )

        XCTAssertEqual(stats.hitRate, 0.0, accuracy: 0.1, "Hit rate should be 0% with no hits")
    }
}
