//
//  Synchronization.swift
//  DicomCore
//
//  Lightweight lock abstraction used for decoder synchronization.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
#if canImport(os)
import os.lock
#endif

/// Lightweight lock abstraction used for decoder synchronization.
///
/// **Design Decision: os_unfair_lock vs Read-Write Locks**
///
/// This implementation uses `os_unfair_lock` (with NSLock fallback) for all synchronization
/// rather than read-write locks (pthread_rwlock). This decision is based on:
///
/// 1. **I/O-Bound Operations**: DICOM decoding is dominated by file I/O (~50-200ms),
///    making lock overhead (<1ms) negligible regardless of lock type.
///
/// 2. **Write-Once Pattern**: 39 of 45 DCMDecoder properties are write-once, read-many.
///    After initialization, most operations are pure reads with no contention.
///
/// 3. **Measured Overhead**: Tests show 1.14x overhead (100,000 lock/unlock cycles),
///    well below the <10% performance degradation target.
///
/// 4. **Simplicity**: Single lock eliminates deadlock risk and makes reasoning about
///    thread safety straightforward.
///
/// 5. **Cache Behavior**: The one read-write cache (cachedInfo) has low contention
///    since most tags are write-once parsed.
///
/// **When to Consider Read-Write Locks:**
/// - If profiling shows lock contention (>5% of execution time)
/// - If a property becomes truly high-contention read-write
/// - If CPU-bound operations under lock exceed 10ms
///
/// For now, `os_unfair_lock` provides optimal performance with minimal complexity.
/// See state-audit.md for detailed property analysis.
final class DicomLock {
    #if canImport(os)
    private var unfairLock = os_unfair_lock_s()

    @inline(__always)
    func lock() {
        os_unfair_lock_lock(&unfairLock)
    }

    @inline(__always)
    func unlock() {
        os_unfair_lock_unlock(&unfairLock)
    }
    #else
    private let lockImpl = NSLock()

    @inline(__always)
    func lock() {
        lockImpl.lock()
    }

    /// Releases the underlying lock, allowing another thread to acquire it.
    /// 
    /// Call this after a matching `lock()` to relinquish ownership of the lock. Undefined behavior may occur if the current thread does not hold the lock when calling this method.
    @inline(__always)
    func unlock() {
        lockImpl.unlock()
    }
    #endif

    /// Executes a closure while holding the lock.
    ///
    /// This is the preferred way to use the lock as it ensures proper cleanup even if
    /// the closure throws an error.
    ///
    /// - Parameter body: The closure to execute while holding the lock.
    /// - Returns: The value returned by the closure.
    /// Executes `body` while holding the lock.
    /// Ensures the lock is released after `body` returns or throws.
    /// - Parameters:
    ///   - body: Closure to execute while the lock is held.
    /// - Returns: The value returned by `body`.
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Read-Write Lock Reference Implementation

/// Read-write lock abstraction for future use if read-heavy contention is detected.
///
/// **Note:** Currently unused. Kept as reference for potential future optimization.
/// Only consider using if profiling shows lock contention in read-heavy scenarios.
///
/// Example usage:
/// ```swift
/// let rwlock = DicomReadWriteLock()
/// rwlock.withReadLock { value = sharedState }
/// rwlock.withWriteLock { sharedState = newValue }
/// ```
#if false  // Disabled - use DicomLock instead
final class DicomReadWriteLock {
    private var rwlock = pthread_rwlock_t()

    init() {
        pthread_rwlock_init(&rwlock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&rwlock)
    }

    /// Acquires a shared (read) lock on the underlying read–write lock.
    /// - Note: Blocks the calling thread until the read lock is obtained; multiple readers may hold the lock concurrently and writers will be blocked until all readers release it.
    @inline(__always)
    func readLock() {
        pthread_rwlock_rdlock(&rwlock)
    }

    /// Acquires the lock for exclusive (write) access.
    /// 
    /// Blocks the calling thread until the write lock is obtained. While held, other readers and writers are blocked until `unlock()` is called.
    @inline(__always)
    func writeLock() {
        pthread_rwlock_wrlock(&rwlock)
    }

    /// Releases a previously acquired reader or writer lock on the underlying `pthread_rwlock_t`.
    /// 
    /// This function unlocks `rwlock`, allowing other threads to acquire read or write access.
    @inline(__always)
    func unlock() {
        pthread_rwlock_unlock(&rwlock)
    }

    /// Executes the given closure while holding the read lock.
    /// - Parameter body: Closure to run while the lock is held.
    /// - Returns: The result produced by `body`.
    @inline(__always)
    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        readLock()
        defer { unlock() }
        return try body()
    }

    /// Execute a closure while holding the write (exclusive) lock.
    /// - Parameters:
    ///   - body: Closure to execute while the write lock is held; may throw.
    /// - Returns: The value returned by `body`.
    @inline(__always)
    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        writeLock()
        defer { unlock() }
        return try body()
    }
}
#endif