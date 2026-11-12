//
//  BenchmarkMemorySampler.swift
//  DicomCoreTests
//
//  Lightweight process memory sampling for benchmark reports.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum BenchmarkMemorySampler {
    static func currentPeakResidentMemoryBytes() -> UInt64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }

        let peakResidentSize = usage.ru_maxrss
        guard peakResidentSize > 0 else {
            return nil
        }

        #if os(Linux)
        return UInt64(peakResidentSize) * 1024
        #else
        return UInt64(peakResidentSize)
        #endif
    }
}
