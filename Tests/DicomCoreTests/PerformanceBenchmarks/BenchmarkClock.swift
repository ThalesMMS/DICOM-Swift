//
//  BenchmarkClock.swift
//  DicomCoreTests
//
//  Monotonic, nanosecond-resolution timing source for the benchmark suite.
//
//  CFAbsoluteTimeGetCurrent() is unsuitable for sub-microsecond work: it returns seconds since 2001
//  as a Double, and at the current epoch offset (~7.9e8 s) one ulp is 2^-23 s ≈ 119 ns. Anything
//  faster than that rounds to exactly 0.0 no matter how precise the underlying clock is. It is also
//  wall-clock based, so a clock adjustment mid-run can produce a negative interval.
//
//  DispatchTime reads the mach timebase and keeps the value in integer nanoseconds, so it is both
//  monotonic and free of that precision floor.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Dispatch
import Foundation

/// Monotonic nanosecond clock used for all benchmark measurements
public enum BenchmarkClock {
    /// Current monotonic timestamp in nanoseconds
    ///
    /// - Returns: Nanoseconds since an arbitrary fixed point (does not advance while asleep)
    @inline(__always)
    public static func now() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }

    /// Seconds elapsed since a timestamp taken with `now()`
    ///
    /// - Parameter start: Timestamp returned by a previous call to `now()`
    /// - Returns: Elapsed time in seconds
    @inline(__always)
    public static func secondsElapsed(since start: UInt64) -> Double {
        return Double(now() &- start) / 1_000_000_000.0
    }
}

/// Keep a benchmarked value alive so the optimizer cannot delete the work that produced it
///
/// - Parameter value: Result of the operation being measured
@inline(never)
public func benchmarkBlackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
