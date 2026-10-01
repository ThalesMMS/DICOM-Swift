// J2KCodestreamMarkerTimings.swift
//
// v6.3.0 F1 — sub-stage timing accumulators for codestream marker
// writes. Mirror of `J2KTier2Timings` (v6-alpha7 phase 1, PR #308)
// but for the marker-write sub-stages of the codestream-generation
// stage.
//
// Why this exists
//
//   The v6.2.0 codestream stage breakdown (per `docs/V6_3_0_PLAN.md`)
//   had `writePacket` (tier-2) at 2.5 % of DX wall and the remaining
//   ~5.5 ms (8 % wall) of the codestream stage unprofiled. F1 fills
//   in the remaining markers per the F1 work item.
//
// Sub-stages tracked (ISO/IEC 15444-1 A.5–A.10):
//
//   - soc — Start of Codestream marker (2 bytes, no segment)
//   - siz — Image and Tile Size segment
//   - cap — Extended Capabilities (HTJ2K Part 15)
//   - cpf — Corresponding Profile (HTJ2K Part 15)
//   - cod — Coding Style Default
//   - qcd — Quantization Default
//   - com — J2KSwift-private block-format signal (HT conformant)
//   - sot — Start of Tile-part
//   - sod — Start of Data marker (2 bytes, no segment)
//   - tileDataAppend — `writer.writeBytes(tileData)` (the actual
//                      payload bytes for the tile)
//   - eoc — End of Codestream marker (2 bytes, no segment)
//
// Cost: NSLock + one Double add per sub-stage per encode. ~10
// additional lock acquires per single-tile encode. Negligible vs
// the writePacket count from `J2KTier2Timings` (1.6 K acquires
// for DX). Always-on; mirrors `J2KEncodeTimings` and `J2KTier2Timings`.
//
// Tests/benchmarks reset before an encode and snapshot after to
// extract per-encode breakdowns.

import Foundation

/// Process-global sub-stage timings for codestream marker writes.
/// Increment from inside the encoder pipeline's codestream stage;
/// snapshot at test/benchmark boundaries to see where the codestream-
/// generation stage's wall is actually spent.
public enum J2KCodestreamMarkerTimings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _soc: TimeInterval = 0
    nonisolated(unsafe) private static var _siz: TimeInterval = 0
    nonisolated(unsafe) private static var _cap: TimeInterval = 0
    nonisolated(unsafe) private static var _cpf: TimeInterval = 0
    nonisolated(unsafe) private static var _cod: TimeInterval = 0
    nonisolated(unsafe) private static var _qcd: TimeInterval = 0
    nonisolated(unsafe) private static var _com: TimeInterval = 0
    nonisolated(unsafe) private static var _sot: TimeInterval = 0
    nonisolated(unsafe) private static var _sod: TimeInterval = 0
    nonisolated(unsafe) private static var _tileDataAppend: TimeInterval = 0
    nonisolated(unsafe) private static var _eoc: TimeInterval = 0
    nonisolated(unsafe) private static var _encodeCount: Int = 0
    nonisolated(unsafe) private static var _tileDataBytes: Int = 0

    public struct Snapshot: Sendable, CustomStringConvertible {
        public let soc: TimeInterval
        public let siz: TimeInterval
        public let cap: TimeInterval
        public let cpf: TimeInterval
        public let cod: TimeInterval
        public let qcd: TimeInterval
        public let com: TimeInterval
        public let sot: TimeInterval
        public let sod: TimeInterval
        public let tileDataAppend: TimeInterval
        public let eoc: TimeInterval
        public let encodeCount: Int
        public let tileDataBytes: Int

        /// Sum of all marker / append accumulators. Approximates the
        /// codestream-generation stage wall time within ~1–2 %
        /// (the gap is per-sub-stage NSLock overhead + glue code
        /// outside the timed regions).
        public var total: TimeInterval {
            soc + siz + cap + cpf + cod + qcd + com + sot + sod
                + tileDataAppend + eoc
        }

        public var description: String {
            let ms = { (t: TimeInterval) in String(format: "%.3f", t * 1000) }
            return "soc=\(ms(soc))ms siz=\(ms(siz))ms cap=\(ms(cap))ms "
                + "cpf=\(ms(cpf))ms cod=\(ms(cod))ms qcd=\(ms(qcd))ms "
                + "com=\(ms(com))ms sot=\(ms(sot))ms sod=\(ms(sod))ms "
                + "tileData=\(ms(tileDataAppend))ms eoc=\(ms(eoc))ms "
                + "total=\(ms(total))ms encodes=\(encodeCount) "
                + "tileBytes=\(tileDataBytes)"
        }
    }

    public static func recordSOC(_ dt: TimeInterval) {
        lock.lock(); _soc += dt; lock.unlock()
    }
    public static func recordSIZ(_ dt: TimeInterval) {
        lock.lock(); _siz += dt; lock.unlock()
    }
    public static func recordCAP(_ dt: TimeInterval) {
        lock.lock(); _cap += dt; lock.unlock()
    }
    public static func recordCPF(_ dt: TimeInterval) {
        lock.lock(); _cpf += dt; lock.unlock()
    }
    public static func recordCOD(_ dt: TimeInterval) {
        lock.lock(); _cod += dt; lock.unlock()
    }
    public static func recordQCD(_ dt: TimeInterval) {
        lock.lock(); _qcd += dt; lock.unlock()
    }
    public static func recordCOM(_ dt: TimeInterval) {
        lock.lock(); _com += dt; lock.unlock()
    }
    public static func recordSOT(_ dt: TimeInterval) {
        lock.lock(); _sot += dt; lock.unlock()
    }
    public static func recordSOD(_ dt: TimeInterval) {
        lock.lock(); _sod += dt; lock.unlock()
    }
    public static func recordTileDataAppend(_ dt: TimeInterval, bytes: Int) {
        lock.lock()
        _tileDataAppend += dt
        _tileDataBytes += bytes
        lock.unlock()
    }
    public static func recordEOC(_ dt: TimeInterval) {
        lock.lock(); _eoc += dt; lock.unlock()
    }
    public static func recordEncodeCall() {
        lock.lock(); _encodeCount += 1; lock.unlock()
    }

    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            soc: _soc, siz: _siz, cap: _cap, cpf: _cpf,
            cod: _cod, qcd: _qcd, com: _com,
            sot: _sot, sod: _sod,
            tileDataAppend: _tileDataAppend, eoc: _eoc,
            encodeCount: _encodeCount,
            tileDataBytes: _tileDataBytes)
    }

    public static func reset() {
        lock.lock()
        _soc = 0; _siz = 0; _cap = 0; _cpf = 0
        _cod = 0; _qcd = 0; _com = 0
        _sot = 0; _sod = 0
        _tileDataAppend = 0; _eoc = 0
        _encodeCount = 0
        _tileDataBytes = 0
        lock.unlock()
    }
}
