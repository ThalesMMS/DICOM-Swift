// J2KDecodeTimings.swift
//
// v5.24.0 stage-level decoder timings accumulator. Mirrors the
// `J2KMetalUMACounters` pattern: process-global, NSLock-protected,
// always-on. Per-stage `record(dt:)` calls are added alongside the
// existing `J2K_PROFILE_DECODE` env-var prints inside
// `J2KDecoderPipeline`.
//
// Stages tracked match the pipeline's profile boundaries:
//
//   - extractTileData       — codestream → CodeBlockInfo unpacking
//   - entropyDecoding       — HT block decode (CPU or GPU dispatch)
//                             AND the CPU regroup loop into [SubbandInfo]
//   - dequantization        — per-coefficient inverse quant
//   - inverseWaveletTransform — IDWT (CPU or GPU)
//   - inverseColorTransform — RCT/ICT reverse
//   - dcLevelUnshift        — unsigned DC shift
//   - reconstructImage      — pack [Double] back into J2KImage
//
// Cost: NSLock + one double add per stage. ~tens of nanoseconds.
// Negligible against the millisecond-scale operations bracketed.
//
// Tests/benchmarks reset before a decode and snapshot after to
// extract per-decode breakdowns.

import Foundation

/// Process-global stage-level timings for the J2K decoder pipeline.
/// Increment at the existing `J2K_PROFILE_DECODE` profile sites;
/// snapshot at test/benchmark boundaries.
///
/// spent inside the `J2KGPUHTDispatch.decodeBatch` call alone,
/// excluding the CPU regroup loop that follows. Zero on CPU-only
/// decode paths (the call site is gated to `useGPUHT`).
public enum J2KDecodeTimings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _extractTileData: TimeInterval = 0
    nonisolated(unsafe) private static var _entropyDecoding: TimeInterval = 0
    nonisolated(unsafe) private static var _dequantization: TimeInterval = 0
    nonisolated(unsafe) private static var _inverseWaveletTransform: TimeInterval = 0
    nonisolated(unsafe) private static var _inverseColorTransform: TimeInterval = 0
    nonisolated(unsafe) private static var _dcLevelUnshift: TimeInterval = 0
    nonisolated(unsafe) private static var _reconstructImage: TimeInterval = 0

    /// Snapshot of all stage accumulators at a point in time.
    public struct Snapshot: Sendable, CustomStringConvertible {
        public let extractTileData: TimeInterval
        public let entropyDecoding: TimeInterval
        /// Sub-stage of `entropyDecoding`: time inside
        public let dequantization: TimeInterval
        public let inverseWaveletTransform: TimeInterval
        public let inverseColorTransform: TimeInterval
        public let dcLevelUnshift: TimeInterval
        public let reconstructImage: TimeInterval

        public var total: TimeInterval {
            extractTileData + entropyDecoding + dequantization
                + inverseWaveletTransform + inverseColorTransform
                + dcLevelUnshift + reconstructImage
        }

        public var description: String {
            let ms = { (t: TimeInterval) in String(format: "%.2f", t * 1000) }
            return "extract=\(ms(extractTileData))ms entropy=\(ms(entropyDecoding))ms "
                + "dequant=\(ms(dequantization))ms idwt=\(ms(inverseWaveletTransform))ms "
                + "colour=\(ms(inverseColorTransform))ms dcShift=\(ms(dcLevelUnshift))ms "
                + "reconstruct=\(ms(reconstructImage))ms total=\(ms(total))ms"
        }
    }

    public static func recordExtractTileData(_ dt: TimeInterval) {
        lock.lock(); _extractTileData += dt; lock.unlock()
    }
    public static func recordEntropyDecoding(_ dt: TimeInterval) {
        lock.lock(); _entropyDecoding += dt; lock.unlock()
    }
    public static func recordDequantization(_ dt: TimeInterval) {
        lock.lock(); _dequantization += dt; lock.unlock()
    }
    public static func recordInverseWaveletTransform(_ dt: TimeInterval) {
        lock.lock(); _inverseWaveletTransform += dt; lock.unlock()
    }
    public static func recordInverseColorTransform(_ dt: TimeInterval) {
        lock.lock(); _inverseColorTransform += dt; lock.unlock()
    }
    public static func recordDcLevelUnshift(_ dt: TimeInterval) {
        lock.lock(); _dcLevelUnshift += dt; lock.unlock()
    }
    public static func recordReconstructImage(_ dt: TimeInterval) {
        lock.lock(); _reconstructImage += dt; lock.unlock()
    }

    /// Read all accumulators atomically.
    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            extractTileData: _extractTileData,
            entropyDecoding: _entropyDecoding,
            dequantization: _dequantization,
            inverseWaveletTransform: _inverseWaveletTransform,
            inverseColorTransform: _inverseColorTransform,
            dcLevelUnshift: _dcLevelUnshift,
            reconstructImage: _reconstructImage)
    }

    /// Reset all accumulators to zero atomically.
    public static func reset() {
        lock.lock()
        _extractTileData = 0
        _entropyDecoding = 0
        _dequantization = 0
        _inverseWaveletTransform = 0
        _inverseColorTransform = 0
        _dcLevelUnshift = 0
        _reconstructImage = 0
        lock.unlock()
    }
}
