// J2KTier2Timings.swift
//
// v6-alpha7 phase 1 — sub-stage timing accumulators for the
// `writePacket` tier-2 packet header writer. Mirrors the
// `J2KEncodeTimings` pattern (process-global, NSLock-protected,
// opt-in). Used by the v6-alpha7 perf arc to identify which
// `writePacket` sub-stage owns the 9 % of DX wall the codestream-
// generation stage consumes (PR #307 measurement).
//
// Sub-stages tracked (ISO/IEC 15444-1 B.10):
//
//   - tagTreeBuild           — `J2KTagTree(width:height:)` construction
//                              + `setValue(...)` per block (one tree
//                              for inclusion, one for zero-bit-planes
//                              per band)
//   - tagTreeInclusionEncode — inclusion-tree `encode(writer:...)` per
//                              block (raster scan within each band)
//   - tagTreeZBPEncode       — zero-bit-plane tree `encode(writer:...)`
//                              per included block
//   - passesEncoding         — Table B.4 prefix-code writes for the
//                              codingPasses count per included block
//   - lengthSignaling        — Lblock adjustment loop + `writeBits`
//                              of the block-data byte length
//   - rawDataAppend          — `writer.appendRawBytes(block.data)`
//                              for the included block payload
//
// Cost when enabled: NSLock + one Double add per sub-stage. For DX 12 MP encode
// that's ~10 K lock acquires per encode (1,600 blocks × 6 sub-
// stages). The production hot path skips the lock by default.
//
// Tests/benchmarks enable and reset before an encode and snapshot after to
// extract per-encode breakdowns.

import Foundation
import Synchronization

/// Process-global sub-stage timings for `writePacket` (the tier-2
/// packet header writer). Increment from inside `writePacket`;
/// snapshot at test/benchmark boundaries to see where its 9 % of
/// DX wall is actually spent.
public enum J2KTier2Timings {
    private static let enabled = Atomic(false)

    /// Enable only while collecting a diagnostic snapshot.
    public static var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _tagTreeBuild: TimeInterval = 0
    nonisolated(unsafe) private static var _tagTreeInclusionEncode: TimeInterval = 0
    nonisolated(unsafe) private static var _tagTreeZBPEncode: TimeInterval = 0
    nonisolated(unsafe) private static var _passesEncoding: TimeInterval = 0
    nonisolated(unsafe) private static var _lengthSignaling: TimeInterval = 0
    nonisolated(unsafe) private static var _rawDataAppend: TimeInterval = 0
    nonisolated(unsafe) private static var _writePacketCount: Int = 0
    nonisolated(unsafe) private static var _includedBlockCount: Int = 0

    public struct Snapshot: Sendable, CustomStringConvertible {
        public let tagTreeBuild: TimeInterval
        public let tagTreeInclusionEncode: TimeInterval
        public let tagTreeZBPEncode: TimeInterval
        public let passesEncoding: TimeInterval
        public let lengthSignaling: TimeInterval
        public let rawDataAppend: TimeInterval
        public let writePacketCount: Int
        public let includedBlockCount: Int

        /// Sum of all sub-stage accumulators. Approximates the total
        /// `writePacket` wall time within ~1-2 % of the actual stage
        /// total (the gap is per-substage NSLock overhead +
        /// `writePacket`'s own glue code outside the timed regions).
        public var total: TimeInterval {
            tagTreeBuild + tagTreeInclusionEncode + tagTreeZBPEncode
                + passesEncoding + lengthSignaling + rawDataAppend
        }

        public var description: String {
            let ms = { (t: TimeInterval) in String(format: "%.2f", t * 1000) }
            return "tagTreeBuild=\(ms(tagTreeBuild))ms "
                + "tagTreeInclusion=\(ms(tagTreeInclusionEncode))ms "
                + "tagTreeZBP=\(ms(tagTreeZBPEncode))ms "
                + "passes=\(ms(passesEncoding))ms "
                + "length=\(ms(lengthSignaling))ms "
                + "rawData=\(ms(rawDataAppend))ms "
                + "total=\(ms(total))ms "
                + "packets=\(writePacketCount) "
                + "incBlocks=\(includedBlockCount)"
        }
    }

    public static func recordTagTreeBuild(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _tagTreeBuild += dt; lock.unlock()
    }
    public static func recordTagTreeInclusionEncode(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _tagTreeInclusionEncode += dt; lock.unlock()
    }
    public static func recordTagTreeZBPEncode(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _tagTreeZBPEncode += dt; lock.unlock()
    }
    public static func recordPassesEncoding(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _passesEncoding += dt; lock.unlock()
    }
    public static func recordLengthSignaling(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _lengthSignaling += dt; lock.unlock()
    }
    public static func recordRawDataAppend(_ dt: TimeInterval) {
        guard isEnabled else { return }
        lock.lock(); _rawDataAppend += dt; lock.unlock()
    }
    public static func recordWritePacketCall(includedBlocks: Int) {
        guard isEnabled else { return }
        lock.lock()
        _writePacketCount += 1
        _includedBlockCount += includedBlocks
        lock.unlock()
    }

    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            tagTreeBuild: _tagTreeBuild,
            tagTreeInclusionEncode: _tagTreeInclusionEncode,
            tagTreeZBPEncode: _tagTreeZBPEncode,
            passesEncoding: _passesEncoding,
            lengthSignaling: _lengthSignaling,
            rawDataAppend: _rawDataAppend,
            writePacketCount: _writePacketCount,
            includedBlockCount: _includedBlockCount)
    }

    public static func reset() {
        lock.lock()
        _tagTreeBuild = 0
        _tagTreeInclusionEncode = 0
        _tagTreeZBPEncode = 0
        _passesEncoding = 0
        _lengthSignaling = 0
        _rawDataAppend = 0
        _writePacketCount = 0
        _includedBlockCount = 0
        lock.unlock()
    }
}
