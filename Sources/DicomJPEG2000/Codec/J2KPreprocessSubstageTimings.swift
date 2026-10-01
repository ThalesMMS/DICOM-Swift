// J2KPreprocessSubstageTimings.swift
//
// v6.3.0 F3 — sub-stage timing accumulators for the encoder
// preprocessing stage. Mirror of v6-alpha7 phase 1 (PR #308's
// `J2KTier2Timings`) and v6.3.0 F1 (PR #324's
// `J2KCodestreamMarkerTimings`) but for the preprocess stage's
// internal sub-stages.
//
// Why this exists
//
//   v6.2.0 plan baseline put preprocessing at ~4.8 % of DX encode
//   wall (~2.4 ms in v6.2.0 measurement). The existing
//   `J2KEncodeTimings.preprocessing` lumps `extractComponentData`
//   + DC level shift into one number; F3 splits them so we can see
//   which sub-stage owns the time and decide whether explicit
//   vDSP / NEON would help.
//
// Sub-stages tracked:
//
//   - imageValidate   — `image.validate()`
//   - extractComponentData8  — `extractComponentData` 8-bit branch
//                              (per-pixel sign-cast loop)
//   - extractComponentData16 — `extractComponentData` 16-bit branch
//                              (4 specialised UInt16 → Int32 loops)
//   - dcLevelShift    — per-component `&-= dcOffset` loop on unsigned
//                       components (ISO 15444-1 Annex F)
//
// Cost: NSLock + one Double add per sub-stage per encode. ~4 lock
// acquires per single-tile encode. Negligible vs the per-block
// counts in `J2KTier2Timings`. Always-on; mirrors `J2KEncodeTimings`
// and `J2KCodestreamMarkerTimings` patterns.

import Foundation

/// Process-global sub-stage timings for the encoder preprocessing
/// stage. Increment from inside the encoder pipeline's preprocess
/// stage; snapshot at test/benchmark boundaries to see where the
/// stage's wall is actually spent.
public enum J2KPreprocessSubstageTimings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _imageValidate: TimeInterval = 0
    nonisolated(unsafe) private static var _extractComponentData8: TimeInterval = 0
    nonisolated(unsafe) private static var _extractComponentData16: TimeInterval = 0
    nonisolated(unsafe) private static var _dcLevelShift: TimeInterval = 0
    nonisolated(unsafe) private static var _encodeCount: Int = 0
    nonisolated(unsafe) private static var _pixelsProcessed: Int = 0

    public struct Snapshot: Sendable, CustomStringConvertible {
        public let imageValidate: TimeInterval
        public let extractComponentData8: TimeInterval
        public let extractComponentData16: TimeInterval
        public let dcLevelShift: TimeInterval
        public let encodeCount: Int
        public let pixelsProcessed: Int

        /// Sum of all sub-stage accumulators. Approximates the
        /// preprocess stage wall time within ~1–2 % (the gap is
        /// per-sub-stage NSLock overhead + glue code outside the
        /// timed regions).
        public var total: TimeInterval {
            imageValidate + extractComponentData8 + extractComponentData16 + dcLevelShift
        }

        public var description: String {
            let ms = { (t: TimeInterval) in String(format: "%.3f", t * 1000) }
            return "validate=\(ms(imageValidate))ms "
                + "extract8=\(ms(extractComponentData8))ms "
                + "extract16=\(ms(extractComponentData16))ms "
                + "dcShift=\(ms(dcLevelShift))ms "
                + "total=\(ms(total))ms "
                + "encodes=\(encodeCount) px=\(pixelsProcessed)"
        }
    }

    public static func recordImageValidate(_ dt: TimeInterval) {
        lock.lock(); _imageValidate += dt; lock.unlock()
    }
    public static func recordExtractComponentData8(_ dt: TimeInterval) {
        lock.lock(); _extractComponentData8 += dt; lock.unlock()
    }
    public static func recordExtractComponentData16(_ dt: TimeInterval) {
        lock.lock(); _extractComponentData16 += dt; lock.unlock()
    }
    public static func recordDCLevelShift(_ dt: TimeInterval) {
        lock.lock(); _dcLevelShift += dt; lock.unlock()
    }
    public static func recordEncodeCall(pixels: Int) {
        lock.lock()
        _encodeCount += 1
        _pixelsProcessed += pixels
        lock.unlock()
    }

    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            imageValidate: _imageValidate,
            extractComponentData8: _extractComponentData8,
            extractComponentData16: _extractComponentData16,
            dcLevelShift: _dcLevelShift,
            encodeCount: _encodeCount,
            pixelsProcessed: _pixelsProcessed)
    }

    public static func reset() {
        lock.lock()
        _imageValidate = 0
        _extractComponentData8 = 0
        _extractComponentData16 = 0
        _dcLevelShift = 0
        _encodeCount = 0
        _pixelsProcessed = 0
        lock.unlock()
    }
}
