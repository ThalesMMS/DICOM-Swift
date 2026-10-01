import XCTest
@testable import DicomCore

/// Tests for DicomLock synchronization primitive.
/// Verifies basic lock functionality, thread safety, and performance characteristics.
final class DicomLockTests: XCTestCase {

    // MARK: - Basic Functionality Tests

    func testLockUnlock() {
        let lock = DicomLock()

        // Should not crash or deadlock
        lock.lock()
        lock.unlock()

        // Multiple lock/unlock cycles
        for _ in 0..<100 {
            lock.lock()
            lock.unlock()
        }
    }

    func testWithLock() {
        let lock = DicomLock()
        var counter = 0

        // Test withLock executes the closure
        lock.withLock {
            counter += 1
        }

        XCTAssertEqual(counter, 1)

        // Test withLock returns value
        let result = lock.withLock {
            return counter * 2
        }

        XCTAssertEqual(result, 2)
    }

    func testWithLockThrows() {
        let lock = DicomLock()

        enum TestError: Error {
            case testFailure
        }

        // Verify withLock properly propagates errors
        do {
            try lock.withLock {
                throw TestError.testFailure
            }
            XCTFail("Should have thrown")
        } catch TestError.testFailure {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWithLockUnlocksOnThrow() {
        let lock = DicomLock()

        enum TestError: Error {
            case testFailure
        }

        // Lock should be released even if closure throws
        do {
            try lock.withLock {
                throw TestError.testFailure
            }
        } catch {
            // Ignore
        }

        // Should be able to acquire lock again
        var counter = 0
        lock.withLock {
            counter = 1
        }

        XCTAssertEqual(counter, 1, "Lock should be released after throw")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentIncrement() {
        let counter = DicomLockTestState(0)
        let iterations = 1000
        let threads = 10

        let expectation = XCTestExpectation(description: "All threads complete")
        expectation.expectedFulfillmentCount = threads

        for _ in 0..<threads {
            DispatchQueue.global().async {
                for _ in 0..<iterations {
                    counter.withValue { $0 += 1 }
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)

        // Without proper locking, this would likely fail
        XCTAssertEqual(counter.value, threads * iterations)
    }

    func testConcurrentReadWrite() {
        let sharedState = DicomLockTestState<[Int]>([])
        let writers = 5
        let readers = 10
        let writerIterations = 100

        let expectation = XCTestExpectation(description: "All operations complete")
        expectation.expectedFulfillmentCount = writers + readers

        // Writers: append to array
        for i in 0..<writers {
            DispatchQueue.global().async {
                for j in 0..<writerIterations {
                    sharedState.withValue { $0.append(i * writerIterations + j) }
                }
                expectation.fulfill()
            }
        }

        // Readers: read array
        for _ in 0..<readers {
            DispatchQueue.global().async {
                for _ in 0..<writerIterations {
                    sharedState.withValue { state in
                        _ = state.count
                        if !state.isEmpty {
                            _ = state[0]
                        }
                    }
                    // Small sleep to allow writers to make progress
                    Thread.sleep(forTimeInterval: 0.0001)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 20.0)

        // Verify all writes completed
        XCTAssertEqual(sharedState.value.count, writers * writerIterations)
    }

    func testConcurrentDictionaryAccess() {
        let dictionary = DicomLockTestState<[Int: String]>([:])
        let operations = 1000
        let threads = 10

        let expectation = XCTestExpectation(description: "All threads complete")
        expectation.expectedFulfillmentCount = threads

        for threadId in 0..<threads {
            DispatchQueue.global().async {
                for i in 0..<operations {
                    dictionary.withValue { dictionary in
                        let key = threadId * operations + i
                        dictionary[key] = "thread\(threadId)-value\(i)"
                    }
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)

        // Verify all writes completed
        XCTAssertEqual(dictionary.value.count, threads * operations)
    }

    // MARK: - Performance Tests

    func testLockPerformance() {
        let lock = DicomLock()
        let iterations = 100_000

        measure {
            for _ in 0..<iterations {
                lock.lock()
                lock.unlock()
            }
        }
    }

    func testWithLockPerformance() {
        let lock = DicomLock()
        var counter = 0
        let iterations = 100_000

        measure {
            for _ in 0..<iterations {
                lock.withLock {
                    counter += 1
                }
            }
        }
    }

    func testWithLockOverheadMinimal() {
        let lock = DicomLock()
        var counter = 0
        let iterations = 10_000

        // Measure unprotected access
        let unprotectedStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            counter += 1
        }
        let unprotectedTime = CFAbsoluteTimeGetCurrent() - unprotectedStart

        // Measure protected access
        counter = 0
        let protectedStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            lock.withLock {
                counter += 1
            }
        }
        let protectedTime = CFAbsoluteTimeGetCurrent() - protectedStart

        // Lock overhead should be less than 10x (typically <2x for os_unfair_lock)
        let overhead = protectedTime / unprotectedTime
        print("Lock overhead: \(overhead)x")
        XCTAssertLessThan(overhead, 10.0, "Lock overhead should be minimal")
    }

    // MARK: - Edge Case Tests

    func testNestedWithLockIsUnsafe() {
        let lock = DicomLock()

        // Note: This test documents unsafe behavior, not recommended usage
        // Nested locking with the same lock will deadlock
        // This test should be skipped in normal runs
        #if false
        let expectation = XCTestExpectation(description: "Deadlock timeout")
        expectation.isInverted = true

        DispatchQueue.global().async {
            lock.withLock {
                // This will deadlock
                lock.withLock {
                    // Never reached
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        #endif
    }

    func testZeroTimeLockHoldingIsCorrect() {
        let lock = DicomLock()

        // Verify lock is properly released even for empty closures
        for _ in 0..<1000 {
            lock.withLock {
                // Empty - lock should still be properly released
            }
        }

        // Should not deadlock
        lock.withLock {
            // Lock is available
        }
    }

    // MARK: - Documentation Tests

    func testLockUsagePattern() {
        // Document the recommended usage pattern
        // `lock` guards every access to `value`.
        final class ThreadSafeCounter: @unchecked Sendable {
            private var value = 0
            private let lock = DicomLock()

            func increment() {
                lock.withLock {
                    value += 1
                }
            }

            func getValue() -> Int {
                lock.withLock {
                    return value
                }
            }
        }

        let counter = ThreadSafeCounter()
        let threads = 10
        let iterations = 100

        let expectation = XCTestExpectation(description: "All threads complete")
        expectation.expectedFulfillmentCount = threads

        for _ in 0..<threads {
            DispatchQueue.global().async {
                for _ in 0..<iterations {
                    counter.increment()
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(counter.getValue(), threads * iterations)
    }
}
