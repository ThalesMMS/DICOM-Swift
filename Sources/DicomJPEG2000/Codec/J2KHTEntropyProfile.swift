// J2KHTEntropyProfile.swift
//
// v7.3.0 Phase 0 — call-count instrumentation for the HT entropy
// inner-loop engines. Combined with a standalone micro-benchmark
// (`V730Phase0EntropyMicrobench`) that times each engine operation
// in isolation, the per-engine attribution of decode wall-time is
// `(count × avg-cost-per-call)` summed across engines.
//
// This shape avoids the nano-level timing overhead that wrapping
// each engine call with `DispatchTime.now()` would impose on the
// hot loop (~6 timer calls × 200 K quad-pair iterations on DX 4x4
// = 36 ms of pure timing overhead, which would dwarf the 75 ms
// actual decode wall).
//
// Engines counted:
//
//   - `melCallCount`           — `nextMELEvent()` invocations
//   - `vlcReadBitsCount`       — `vlcReader.peek + read` pair (one
//                                logical VLC consumption)
//   - `vlcLookupCount`         — `lookupVLC` table reads
//   - `uvlcCount`              — `decodeUVLCPair*` invocations
//   - `magsgnReadBitsCount`    — `magsgnDec.read(count:)` calls
//                                (per-bit-read; total bits ≈ count
//                                × avg-bits-per-call)
//   - `magsgnReadBitsTotal`    — total bits consumed across all
//                                magsgn reads (lets us compute
//                                avg-bits-per-call)
//   - `quadSamplesCallCount`   — `readQuadSamples` invocations
//                                (significant-sample reconstruction
//                                blocks)
//
// **Lockless** counters (`nonisolated(unsafe)` UInt64). Multiple
// tile tasks may race; lost increments make absolute counts
// approximate but the *proportions* between engines stay correct,
// which is the only signal the v7.3 plan reads.
//
// This file is designed to be deleted as a unit after v7.3 ships:
// `git rm Sources/J2KCodec/J2KHTEntropyProfile.swift` plus a regex
// sweep of `J2KHTEntropyProfile.bump*` call sites returns the
// codebase to its pre-probe shape.

import Foundation

public enum J2KHTEntropyProfile {
    nonisolated(unsafe) private static var _melCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _vlcReadBitsCount: UInt64 = 0
    nonisolated(unsafe) private static var _vlcLookupCount: UInt64 = 0
    nonisolated(unsafe) private static var _uvlcCount: UInt64 = 0
    nonisolated(unsafe) private static var _magsgnReadBitsCount: UInt64 = 0
    nonisolated(unsafe) private static var _magsgnReadBitsTotal: UInt64 = 0
    nonisolated(unsafe) private static var _quadSamplesCallCount: UInt64 = 0

    // Function-level wall timing for decodeInitialRow + decodeSubsequentRow
    // (called O(height/2) per tile; one timer pair each — negligible
    // overhead vs the per-quad work the function performs).
    nonisolated(unsafe) private static var _initialRowTotalNs: UInt64 = 0
    nonisolated(unsafe) private static var _subsequentRowTotalNs: UInt64 = 0

    public struct Snapshot: Sendable, CustomStringConvertible {
        public let melCallCount: UInt64
        public let vlcReadBitsCount: UInt64
        public let vlcLookupCount: UInt64
        public let uvlcCount: UInt64
        public let magsgnReadBitsCount: UInt64
        public let magsgnReadBitsTotal: UInt64
        public let quadSamplesCallCount: UInt64
        public let initialRowTotalNs: UInt64
        public let subsequentRowTotalNs: UInt64

        public var avgMagsgnBitsPerCall: Double {
            magsgnReadBitsCount == 0 ? 0
                : Double(magsgnReadBitsTotal) / Double(magsgnReadBitsCount)
        }

        public var rowDecodeTotalMs: Double {
            Double(initialRowTotalNs + subsequentRowTotalNs) / 1_000_000
        }

        public var description: String {
            "mel=\(melCallCount) vlcRead=\(vlcReadBitsCount) "
                + "vlcLookup=\(vlcLookupCount) uvlc=\(uvlcCount) "
                + "magsgn=\(magsgnReadBitsCount) (avg=\(String(format: "%.2f", avgMagsgnBitsPerCall)) bits) "
                + "readQuadSamples=\(quadSamplesCallCount) "
                + "rowDecodeTotal=\(String(format: "%.2f", rowDecodeTotalMs))ms"
        }
    }

    @inline(__always) public static func bumpMel() { _melCallCount &+= 1 }
    @inline(__always) public static func bumpVlcReadBits() { _vlcReadBitsCount &+= 1 }
    @inline(__always) public static func bumpVlcLookup() { _vlcLookupCount &+= 1 }
    @inline(__always) public static func bumpUvlc() { _uvlcCount &+= 1 }
    @inline(__always) public static func bumpMagsgnReadBits(_ bits: Int) {
        _magsgnReadBitsCount &+= 1
        _magsgnReadBitsTotal &+= UInt64(bits)
    }
    @inline(__always) public static func bumpQuadSamples() { _quadSamplesCallCount &+= 1 }
    @inline(__always) public static func recordInitialRowNs(_ ns: UInt64) { _initialRowTotalNs &+= ns }
    @inline(__always) public static func recordSubsequentRowNs(_ ns: UInt64) { _subsequentRowTotalNs &+= ns }

    public static func snapshot() -> Snapshot {
        Snapshot(
            melCallCount: _melCallCount,
            vlcReadBitsCount: _vlcReadBitsCount,
            vlcLookupCount: _vlcLookupCount,
            uvlcCount: _uvlcCount,
            magsgnReadBitsCount: _magsgnReadBitsCount,
            magsgnReadBitsTotal: _magsgnReadBitsTotal,
            quadSamplesCallCount: _quadSamplesCallCount,
            initialRowTotalNs: _initialRowTotalNs,
            subsequentRowTotalNs: _subsequentRowTotalNs)
    }

    public static func reset() {
        _melCallCount = 0
        _vlcReadBitsCount = 0
        _vlcLookupCount = 0
        _uvlcCount = 0
        _magsgnReadBitsCount = 0
        _magsgnReadBitsTotal = 0
        _quadSamplesCallCount = 0
        _initialRowTotalNs = 0
        _subsequentRowTotalNs = 0
    }
}
