// J2KHTEntropyEncoderProfile.swift
//
// v9.1 Path B Phase 0 — encoder-side counter + coarse-wall instrumentation
// for the HT block-encoder hot path. Mirror of `J2KHTEntropyProfile.swift`
// (decoder side).
//
// The mission: close the 3× CPU efficiency gap with Kakadu's HT encoder
// on Apple M2. v8.4 stage breakdown showed entropy at ~57% of total
// encode CPU on DX 2800×2288 (~353 ms accumulated). Phase 0 of Path B
// subdivides that 353 ms across the per-quad sub-stages so we know
// which sub-stage to attack first.
//
// Methodology:
//
//   1. Counters (always-on, lock-less UInt64 increments) tally the
//      number of calls to each per-quad inner-loop primitive across
//      the whole encode of a fixture:
//
//        - `processQuadCallCount`   — quads classified
//        - `vlcEncodeCallCount`     — VLC quad-tuple emissions
//        - `vlcUVLCEncodeCallCount` — UVLC u-value emissions
//        - `melEncodeCallCount`     — MEL binary events
//        - `magsgnEncodeCallCount`  — MagSgn payload emissions
//        - `magsgnEncodeBitsTotal`  — total bits emitted (gives
//                                     avg-bits-per-call)
//
//   2. Per-block coarse wall timers (one timer pair per block — not
//      per quad — overhead negligible vs per-block work):
//
//        - `blockTotalNs`     — wall time inside `encode()`
//        - `blockClassifyNs`  — wall time inside row-quad loop only
//        - `blockFinishNs`    — wall time inside `magsgnEnc.finish()`
//                               + `melEnc.finish()` + `vlcEnc.finish()`
//
//   3. Companion microbench (`HTPathBPhase0Microbench`) characterises
//      per-call cost (ns/call) for each engine in isolation. Combined
//      with the counter totals, computes per-stage CPU share:
//
//        per_stage_cpu = call_count × avg_ns_per_call
//
//      Residual (block_classify_ns − Σ per_stage_cpu) is "loop
//      overhead + memory writes + LUT lookups" not in any engine call.
//
// Why not per-quad wall timers? `mach_absolute_time()` ≈ 6-7 ns/call.
// 200 K quads × 6 sub-stages × 6 ns ≈ 7.2 ms of pure timing overhead
// per DX encode (~14 % of the 51 ms wall budget). Counters at 0.5 ns/
// call only add ~1 ms total. The trade is "exact per-stage time" for
// "low overhead" — Phase 0 pays the cost of computing ratios offline.
//
// v9.2 Path B Phase 0 — counters are now **opt-in**.
//
// The Phase 0 instrumentation was always-on during Phase 1A/1B/2 of the
// research arc, so production builds paid the per-quad counter store
// cost (~16 M `&+=` per DX encode against shared statics). Under
// concurrent encode workers, these stores cause cache-line invalidation
// across all CPU cores — the false sharing was a likely contributor
// to the 5× per-block inflation observed in V91Phase2ConcurrentContentionProbe.
//
// Now: production reads `isEnabled` (a single read-only static load,
// cached locally per-core, no contention). When `false` (default), all
// `bump*` and `record*Ns` calls return immediately without touching
// the counter statics. Tests that want the metrics call
// `J2KHTEntropyEncoderProfile.setEnabled(true)` at setUp time.
//
// This file STILL exists (counters and snapshot API unchanged) so future
// research phases can re-enable profiling without code surgery — but
// production hot paths are no longer paying for diagnostic-only counters.

import Foundation

public enum J2KHTEntropyEncoderProfile {
    /// v9.2 Path B Phase 0 — opt-in flag. Default `false`.
    /// When `false`, all `bump*` and `record*Ns` calls are early-exit
    /// no-ops. Tests that consume the counters must call
    /// `setEnabled(true)` before exercising the encoder.
    nonisolated(unsafe) private static var _isEnabled: Bool = false

    nonisolated(unsafe) private static var _processQuadCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _vlcEncodeCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _vlcUVLCEncodeCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _melEncodeCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _magsgnEncodeCallCount: UInt64 = 0
    nonisolated(unsafe) private static var _magsgnEncodeBitsTotal: UInt64 = 0

    nonisolated(unsafe) private static var _blockTotalNs: UInt64 = 0
    nonisolated(unsafe) private static var _blockClassifyNs: UInt64 = 0
    nonisolated(unsafe) private static var _blockFinishNs: UInt64 = 0
    nonisolated(unsafe) private static var _blockCount: UInt64 = 0

    public static var isEnabled: Bool { _isEnabled }

    public static func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
    }

    public struct Snapshot: Sendable, CustomStringConvertible {
        public let processQuadCallCount: UInt64
        public let vlcEncodeCallCount: UInt64
        public let vlcUVLCEncodeCallCount: UInt64
        public let melEncodeCallCount: UInt64
        public let magsgnEncodeCallCount: UInt64
        public let magsgnEncodeBitsTotal: UInt64

        public let blockTotalNs: UInt64
        public let blockClassifyNs: UInt64
        public let blockFinishNs: UInt64
        public let blockCount: UInt64

        public var avgMagsgnBitsPerCall: Double {
            magsgnEncodeCallCount == 0 ? 0
                : Double(magsgnEncodeBitsTotal) / Double(magsgnEncodeCallCount)
        }

        public var blockTotalMs: Double {
            Double(blockTotalNs) / 1_000_000
        }
        public var blockClassifyMs: Double {
            Double(blockClassifyNs) / 1_000_000
        }
        public var blockFinishMs: Double {
            Double(blockFinishNs) / 1_000_000
        }

        public var description: String {
            "blocks=\(blockCount) "
                + "processQuad=\(processQuadCallCount) "
                + "vlcEnc=\(vlcEncodeCallCount) "
                + "uvlc=\(vlcUVLCEncodeCallCount) "
                + "melEnc=\(melEncodeCallCount) "
                + "magsgnEnc=\(magsgnEncodeCallCount) "
                + "(avg=\(String(format: "%.2f", avgMagsgnBitsPerCall)) bits) "
                + "blockTotal=\(String(format: "%.2f", blockTotalMs))ms "
                + "classify=\(String(format: "%.2f", blockClassifyMs))ms "
                + "finish=\(String(format: "%.2f", blockFinishMs))ms"
        }
    }

    @inline(__always) public static func bumpProcessQuad() {
        if _isEnabled { _processQuadCallCount &+= 1 }
    }
    @inline(__always) public static func bumpVlcEncode() {
        if _isEnabled { _vlcEncodeCallCount &+= 1 }
    }
    @inline(__always) public static func bumpVlcUVLCEncode() {
        if _isEnabled { _vlcUVLCEncodeCallCount &+= 1 }
    }
    @inline(__always) public static func bumpMelEncode() {
        if _isEnabled { _melEncodeCallCount &+= 1 }
    }
    @inline(__always) public static func bumpMagsgnEncode(_ bits: Int) {
        if _isEnabled {
            _magsgnEncodeCallCount &+= 1
            _magsgnEncodeBitsTotal &+= UInt64(bits)
        }
    }
    @inline(__always) public static func recordBlockTotalNs(_ ns: UInt64) {
        if _isEnabled {
            _blockTotalNs &+= ns
            _blockCount &+= 1
        }
    }
    @inline(__always) public static func recordBlockClassifyNs(_ ns: UInt64) {
        if _isEnabled { _blockClassifyNs &+= ns }
    }
    @inline(__always) public static func recordBlockFinishNs(_ ns: UInt64) {
        if _isEnabled { _blockFinishNs &+= ns }
    }

    public static func snapshot() -> Snapshot {
        Snapshot(
            processQuadCallCount: _processQuadCallCount,
            vlcEncodeCallCount: _vlcEncodeCallCount,
            vlcUVLCEncodeCallCount: _vlcUVLCEncodeCallCount,
            melEncodeCallCount: _melEncodeCallCount,
            magsgnEncodeCallCount: _magsgnEncodeCallCount,
            magsgnEncodeBitsTotal: _magsgnEncodeBitsTotal,
            blockTotalNs: _blockTotalNs,
            blockClassifyNs: _blockClassifyNs,
            blockFinishNs: _blockFinishNs,
            blockCount: _blockCount)
    }

    public static func reset() {
        _processQuadCallCount = 0
        _vlcEncodeCallCount = 0
        _vlcUVLCEncodeCallCount = 0
        _melEncodeCallCount = 0
        _magsgnEncodeCallCount = 0
        _magsgnEncodeBitsTotal = 0
        _blockTotalNs = 0
        _blockClassifyNs = 0
        _blockFinishNs = 0
        _blockCount = 0
    }
}
