// J2KEncodeTimings.swift
//
// v5.29.0 stage-level encoder timings accumulator. Mirrors the
// `J2KDecodeTimings` pattern (v5.24.0): process-global, NSLock-
// protected, always-on. Per-stage `record(dt:)` calls are wired
// alongside the existing `J2K_PROFILE` env-var prints inside
// `J2KEncoderPipeline`.
//
// Stages tracked match the existing `encode` / `encodeGPU` profile
// boundaries:
//
//   - preprocessing         — extractComponentData + DC level shift
//   - colorTransform        — RCT/ICT (CPU or GPU on encodeGPU)
//   - waveletTransform      — forward 5/3 or 9/7 (CPU or GPU)
//   - quantization          — fused into entropy for HTJ2K, separate
//                             for legacy lossy path
//   - entropyCoding         — EBCOT or HT block coding (CPU only;
//                             this is the dominant stage on encode)
//   - rateControl           — PCRD-opt layer truncation
//   - codestreamGeneration  — packetize + serialise to bytes
//
// Cost: NSLock + one double add per stage. Negligible against the
// millisecond-scale operations bracketed.
//
// Tests/benchmarks reset before an encode and snapshot after to
// extract per-encode breakdowns.

import Foundation

/// Process-global stage-level timings for the J2K encoder pipeline.
/// Increment at the existing `J2K_PROFILE` profile sites; snapshot
/// at test/benchmark boundaries.
public enum J2KEncodeTimings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _preprocessing: TimeInterval = 0
    nonisolated(unsafe) private static var _colorTransform: TimeInterval = 0
    nonisolated(unsafe) private static var _waveletTransform: TimeInterval = 0
    nonisolated(unsafe) private static var _quantization: TimeInterval = 0
    nonisolated(unsafe) private static var _entropyCoding: TimeInterval = 0
    nonisolated(unsafe) private static var _rateControl: TimeInterval = 0
    nonisolated(unsafe) private static var _codestreamGeneration: TimeInterval = 0

    /// Snapshot of all stage accumulators at a point in time.
    public struct Snapshot: Sendable, CustomStringConvertible {
        public let preprocessing: TimeInterval
        public let colorTransform: TimeInterval
        public let waveletTransform: TimeInterval
        public let quantization: TimeInterval
        public let entropyCoding: TimeInterval
        public let rateControl: TimeInterval
        public let codestreamGeneration: TimeInterval

        public var total: TimeInterval {
            preprocessing + colorTransform + waveletTransform
                + quantization + entropyCoding + rateControl
                + codestreamGeneration
        }

        public var description: String {
            let ms = { (t: TimeInterval) in String(format: "%.2f", t * 1000) }
            return "preprocess=\(ms(preprocessing))ms colour=\(ms(colorTransform))ms "
                + "dwt=\(ms(waveletTransform))ms quant=\(ms(quantization))ms "
                + "entropy=\(ms(entropyCoding))ms rateCtrl=\(ms(rateControl))ms "
                + "codestream=\(ms(codestreamGeneration))ms total=\(ms(total))ms"
        }
    }

    public static func recordPreprocessing(_ dt: TimeInterval) {
        lock.lock(); _preprocessing += dt; lock.unlock()
    }
    public static func recordColorTransform(_ dt: TimeInterval) {
        lock.lock(); _colorTransform += dt; lock.unlock()
    }
    public static func recordWaveletTransform(_ dt: TimeInterval) {
        lock.lock(); _waveletTransform += dt; lock.unlock()
    }
    public static func recordQuantization(_ dt: TimeInterval) {
        lock.lock(); _quantization += dt; lock.unlock()
    }
    public static func recordEntropyCoding(_ dt: TimeInterval) {
        lock.lock(); _entropyCoding += dt; lock.unlock()
    }
    public static func recordRateControl(_ dt: TimeInterval) {
        lock.lock(); _rateControl += dt; lock.unlock()
    }
    public static func recordCodestreamGeneration(_ dt: TimeInterval) {
        lock.lock(); _codestreamGeneration += dt; lock.unlock()
    }

    /// Read all accumulators atomically.
    public static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            preprocessing: _preprocessing,
            colorTransform: _colorTransform,
            waveletTransform: _waveletTransform,
            quantization: _quantization,
            entropyCoding: _entropyCoding,
            rateControl: _rateControl,
            codestreamGeneration: _codestreamGeneration)
    }

    /// Reset all accumulators to zero atomically.
    public static func reset() {
        lock.lock()
        _preprocessing = 0
        _colorTransform = 0
        _waveletTransform = 0
        _quantization = 0
        _entropyCoding = 0
        _rateControl = 0
        _codestreamGeneration = 0
        lock.unlock()
    }
}
