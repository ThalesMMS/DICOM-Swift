// J2KHTBlockEncoderConformant.swift
// ISO/IEC 15444-15 cleanup-pass codeblock encoder (scalar, 32-bit).
//
// Ports OpenJPH 0.26's `ojph_encode_codeblock32` from
// `ojph_block_encoder.cpp`. Walks a codeblock as pairs of 2x2 sample
// quads, building up rho/eps/u context per quad, then emits through
// the M1–M4 stream coders. Outputs a byte tuple that the block
// assembler (M5a) can wrap with the Scup trailer.
//
// Sample input convention matches OpenJPH: one `UInt32` per
// coefficient, with bit 31 holding the sign (1 = negative) and the
// magnitude in the bits below `p = 30 - missingMSBs`. A value of 0
// (including sign bit 0) means "zero coefficient, not significant".
//
// This implementation covers the cleanup pass only — SigProp / MagRef
// refinement passes are not emitted, matching OpenJPH's scalar path
// (`num_passes == 1`).

import Foundation
import DicomJPEG2000NEON

/// Cleanup-pass codeblock encoder (32-bit signed-magnitude path).
/// Produces the three Part-15 sub-streams separately; wrap with
/// `HTBlockLayoutConformant.assemble` to get the final on-wire block.
public enum HTBlockEncoderConformant {

    /// v9.4.0 — custom C+NEON hot-path gate. **Default ON** for the
    /// production release after the v9.4-research arc validated bit-
    /// exact equivalence across 548+ byte-equality assertions
    /// (including codestream MD5 byte-identity vs OpenJPH + OpenJPEG +
    /// Kakadu reference encoders) and measured -14% warm in-proc DX
    /// encode wall on M4. Override via env var `J2K_NEON_HOT_PATH=0`
    /// to force the legacy Swift path for diagnostic comparisons or
    /// if a downstream user discovers a workload-specific regression.
    ///
    /// The C path activates ONLY when the block fits its supported
    /// envelope: width/height ≤ 64, missingMSBs < 30, no
    /// preClassifiedTuples, no useSIMDClassification. All other code
    /// paths (including Raw-pointer engines, GPU-pre-classified-tuples,
    /// SIMD-classifier opt-in) fall through to the Swift
    /// `encodeLoopGeneric` path unchanged.
    public static let useNEONHotPath: Bool = {
        if let v = ProcessInfo.processInfo.environment["J2K_NEON_HOT_PATH"] {
            switch v.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: break
            }
        }
        return true  // v9.4.0 default-on
    }()

    /// v9.4-research — build identifier for the C+NEON path (or stub).
    /// Exposed for telemetry / research-finding traceability.
    public static var neonHotPathVersion: String {
        return String(cString: dcmj2knhe_version())
    }

    /// v9.4-research — NEON hot path dispatch for the Array-engine
    /// encode wrapper. When `useNEONHotPath` is set and the block fits
    /// the C entry point's supported envelope (width/height ≤ 64,
    /// missing_msbs < 30, no pre-classified tuples, no SIMD opt-in),
    /// routes the entire row-quad loop into the
    /// `dcmj2knhe_encode_block_ht32` C entry point. Bit-exact equivalent of
    /// the Swift path — verified by V94NEONHotPathParityTests.
    ///
    /// Day 7b: switched the internal triple-buffer alloc from `[UInt8]`
    /// (which zero-fills 48 KB per call) to raw `UnsafeMutablePointer`
    /// (no zero-fill; C entry point writes the bytes that matter). Drops
    /// the per-block zero-fill cost and the ARC + capacity-check overhead.
    /// The 16 KB per-stream capacity is sized for any 64×64 block at
    /// 30-bit precision per the v9.1 Phase 2c _rawEngineBufferCapacity.
    ///
    /// Future v9.5 work: hoist these per-call allocations to per-worker
    /// scope via J2KEncoderPipeline (mirrors the Phase 2d raw-engine
    /// buffer hoist), eliminating ~9500 allocs per DX encode.
    /// v9.5 Phase 5E — direct NEON dispatch with caller-owned hoisted
    /// buffers. Used by J2KEncoderPipeline's per-worker scope to
    /// eliminate the per-block allocation of three 16 KB buffers
    /// (~9500 allocs per DX encode on the per-call path).
    ///
    /// Caller is responsible for:
    ///   1. Allocating each output buffer (16 KB is safe for any 64×64
    ///      HT block at 30-bit precision per
    ///      J2KEncoderPipeline._rawEngineBufferCapacity).
    ///   2. After this call returns, copying or passing
    ///      `buf[0..<count]` into the downstream pipeline. VLC is in
    ///      FORWARD on-wire order (matches Swift's
    ///      `HTReverseBitEmitterConformant.finish()` output) —
    ///      `assembleDataFromRaw` should be called with
    ///      `vlcReversed: false` for the NEON path.
    @inline(__always)
    internal static func encodeNEONIntoBuffers(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int, height: Int, missingMSBs: Int,
        magsgnBuf: UnsafeMutablePointer<UInt8>, magsgnCap: Int,
        melBuf: UnsafeMutablePointer<UInt8>, melCap: Int,
        vlcBuf: UnsafeMutablePointer<UInt8>, vlcCap: Int
    ) -> (magsgnCount: Int, melCount: Int, vlcCount: Int) {
        var magLen = 0, melLen = 0, vlcLen = 0
        let coefPtr = coefficients.baseAddress!
        let rc = dcmj2knhe_encode_block_ht32(
            coefPtr, UInt32(width), UInt32(height),
            UInt32(missingMSBs),
            magsgnBuf, magsgnCap, &magLen,
            melBuf, melCap, &melLen,
            vlcBuf, vlcCap, &vlcLen)
        precondition(rc == 0,
                     "dcmj2knhe NEON hot path returned non-zero: \(rc)")
        return (magLen, melLen, vlcLen)
    }

    @inline(__always)
    internal static func encodeViaNEONHotPath(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int, height: Int, missingMSBs: Int
    ) -> (magsgn: [UInt8], mel: [UInt8], vlc: [UInt8]) {
        let cap = 16384
        let magBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        let melBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        let vlcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer {
            magBuf.deallocate()
            melBuf.deallocate()
            vlcBuf.deallocate()
        }
        var magLen = 0, melLen = 0, vlcLen = 0
        let coefPtr = coefficients.baseAddress!
        let rc = dcmj2knhe_encode_block_ht32(
            coefPtr, UInt32(width), UInt32(height),
            UInt32(missingMSBs),
            magBuf, cap, &magLen,
            melBuf, cap, &melLen,
            vlcBuf, cap, &vlcLen)
        precondition(rc == 0,
                     "dcmj2knhe NEON hot path returned non-zero: \(rc)")
        // Wrap into Array via UnsafeBufferPointer — single copy, no
        // intermediate Array. Matches the existing return contract.
        return (
            Array(UnsafeBufferPointer(start: magBuf, count: magLen)),
            Array(UnsafeBufferPointer(start: melBuf, count: melLen)),
            Array(UnsafeBufferPointer(start: vlcBuf, count: vlcLen)))
    }

    /// Encode a codeblock's cleanup pass.
    ///
    /// - Parameters:
    ///   - coefficients: `width * height` sign-magnitude coefficients
    ///     in row-major order.
    ///   - width: block width, in samples (must be >= 1).
    ///   - height: block height, in samples (must be >= 1).
    ///   - missingMSBs: number of insignificant leading bits in the
    ///     sign-magnitude representation (= `Kmsbs` / "missing MSBs"
    ///     from ITU T.814).
    /// - Returns: `(magsgn, mel, vlc)` tuple, each ready to hand to
    ///   `HTBlockLayoutConformant.assemble`. Note: `vlc` is in forward
    ///   on-wire byte order (ending with `0xFF` sentinel).
    public static func encode(
        coefficients: [UInt32],
        width: Int,
        height: Int,
        missingMSBs: Int
    ) -> (magsgn: [UInt8], mel: [UInt8], vlc: [UInt8]) {
        var magsgnEnc = HTMagSgnEncoderConformant()
        var melEnc = HTMELEncoderConformant()
        var vlcEnc = HTReverseBitEmitterConformant()
        return coefficients.withUnsafeBufferPointer { buf in
            encode(
                coefficients: buf, width: width, height: height,
                missingMSBs: missingMSBs,
                magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc)
        }
    }

    /// v5.38 M8/M9: in-place encode variant.
    ///
    /// **M8** (caller-provided encoders): the three byte-stream
    /// encoders are passed `inout` so their internal `[UInt8]` buffers
    /// can be reused across blocks. Each encoder is `reset()` here
    /// before use, so prior block contents cannot leak into this
    /// output.
    ///
    /// **M9** (pointer-based coefficients): `coefficients` is now an
    /// `UnsafeBufferPointer<UInt32>` instead of `[UInt32]`. This lets
    /// callers pass a pointer + count pair derived from a reusable
    /// buffer (e.g. a max-block-sized `[UInt32]` shared across an
    /// entire chunk) without the encoder asserting the underlying
    /// array's `count` matches `width * height`. The body uses
    /// pointer-direct `coefficients[idx]` access, which skips Swift's
    /// `Array` bounds check inside the per-quad hot loop.
    ///
    /// **Bit-exact equivalent** of the [UInt32] non-inout overload.
    public static func encode(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int,
        height: Int,
        missingMSBs: Int,
        magsgnEnc: inout HTMagSgnEncoderConformant,
        melEnc: inout HTMELEncoderConformant,
        vlcEnc: inout HTReverseBitEmitterConformant
    ) -> (magsgn: [UInt8], mel: [UInt8], vlc: [UInt8]) {
        return encode(
            coefficients: coefficients,
            width: width, height: height,
            missingMSBs: missingMSBs,
            magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc,
            useSIMDClassification: false)
    }

    /// v5.39 M1: same as the inout encode overload above, but with an
    /// explicit `useSIMDClassification` toggle controlling the per-quad
    /// `sampleInfo` path.
    ///
    /// - When `false` (production default until v5.39 ships proven):
    ///   the existing scalar `sampleInfo` runs four times per quad.
    ///
    /// - When `true`: a SIMD4<UInt32> classifier processes all four
    ///   samples of the quad in one pass. Math validated against the
    ///   scalar reference in `HTSampleInfoSIMDPrototypeTests` over a
    ///   180K random-input sweep (p ∈ {3, 5, 10, 15, 20, 25, 28, 29,
    ///   30}) and a hand-picked edge-case set; the classifier
    ///   produces lane-identical `(sig, eQ, payload)` tuples to the
    ///   scalar function for every input.
    ///
    /// **Correctness invariant**: the encoded
    /// `(magsgn, mel, vlc)` byte tuple is bit-identical between the
    /// two paths on every input, because:
    ///   1. SIMD only replaces the per-sample classification, not
    ///      the rho / eQMax accumulation or the MEL/VLC/MagSgn
    ///      emission.
    ///   2. The classification has been proven lane-identical at
    ///      the prototype level; downstream bookkeeping is the same
    ///      scalar code on the same inputs.
    /// Verified end-to-end by `HTSIMDIntegrationTests.testSIMDvsScalarBlockBytesIdentical`.
    public static func encode(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int,
        height: Int,
        missingMSBs: Int,
        magsgnEnc: inout HTMagSgnEncoderConformant,
        melEnc: inout HTMELEncoderConformant,
        vlcEnc: inout HTReverseBitEmitterConformant,
        useSIMDClassification: Bool
    ) -> (magsgn: [UInt8], mel: [UInt8], vlc: [UInt8]) {
        return encode(
            coefficients: coefficients,
            width: width, height: height, missingMSBs: missingMSBs,
            magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc,
            useSIMDClassification: useSIMDClassification,
            preClassifiedTuples: nil)
    }

    /// v6-alpha6 phase 1.1: encode-from-pre-classified-tuples variant.
    ///
    /// When `preClassifiedTuples` is non-nil, the per-sample
    /// `(sig, eQ, payload)` tuples that `sampleInfo` would compute are
    /// instead read from the supplied UInt64 buffer (one tuple per
    /// sample, indexed `[y * width + x]`, layout matching what
    /// `J2KMetalHTForwardClassifier` emits — `sig:1 | eQ:7 | payload:32`).
    /// The CPU still walks the codeblock as quads and emits MagSgn /
    /// MEL / VLC bytes serially per block (unchanged from the scalar
    /// path); only the per-sample classification step is replaced.
    ///
    /// **Bit-exact correctness invariant** vs the scalar / SIMD paths:
    /// the (rho / eQMax / payload) shape that `processQuad` returns
    /// is byte-identical regardless of where the per-sample tuples
    /// come from, because:
    ///   1. The tuple layout is the same `(sig, eQ, payload)` triple.
    ///   2. The downstream emit logic (rho accumulation, MEL/VLC/
    ///      MagSgn emission) is the same scalar code on the same
    ///      inputs.
    ///   3. `J2KMetalHTForwardClassifier` is bit-exact validated
    ///      against the production `sampleInfo` reference over
    ///      73,728 random samples plus the SIMD prototype's
    ///      hand-picked edge-case set (`HTGPUForwardClassifierBitExactTests`).
    ///
    /// When `preClassifiedTuples` is nil, this overload behaves
    /// identically to the SIMD-toggle overload above. Callers that
    /// don't need the tuple path can keep using the existing 3-emitter
    /// overload — both forward to this implementation.
    /// v9.1 Path B Phase 2c — internal generic encode-loop helper.
    ///
    /// Contains the per-quad classification + bit-emission logic, shared
    /// between the Array-backed (HTMagSgnEncoderConformant) and raw-
    /// pointer-backed (HTMagSgnEncoderRawConformant) variants. Each
    /// public `encode` wrapper calls this helper then handles its own
    /// finalization: the Array variant returns `[UInt8]` tuples via
    /// `finish()`; the Raw variant returns `Int` byte counts via
    /// `finishCount()`.
    ///
    /// **Bit-exact equivalent** between Array and Raw paths because the
    /// loop body uses only protocol methods (`reset`, `encode(codeword:
    /// count:)`, `encode(eventIsOne:)`) which both engine families
    /// implement byte-for-byte identically. Verified by 200-trial
    /// random-input sweeps in `V91Phase2aRawPointerPrototype` and
    /// `V91Phase2bAllEnginesRawPrototype`.
    ///
    /// Wall instrumentation: the public wrappers measure block-total
    /// and finish-time wall; this helper measures the row-loop wall
    /// (recorded as `blockClassifyNs`).
    @inline(__always)
    internal static func encodeLoopGeneric<M: HTMagSgnEmitting,
                                           L: HTMELEmitting,
                                           V: HTVLCEmitting>(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int,
        height: Int,
        missingMSBs: Int,
        magsgnEnc: inout M,
        melEnc: inout L,
        vlcEnc: inout V,
        useSIMDClassification: Bool,
        preClassifiedTuples: UnsafeBufferPointer<UInt64>?
    ) {
        magsgnEnc.reset()
        melEnc.reset()
        vlcEnc.reset()

        let p = UInt32(30 - missingMSBs)

        // v9.2 Path B Phase 0b — stack-allocated scratch + direct-
        // pointer hot path.
        //
        // The pre-Phase-0b path allocated `[UInt8](repeating: 0, count:
        // guardedWidth)` on the heap twice per block. For DX with ~1584
        // codeblocks that's 3168 small heap allocations per encode, each
        // ~100 ns under low contention and 3-5× more under concurrent
        // encoder workers. The new path uses `withUnsafeTemporaryAllocation`
        // which stack-allocates (or escapes only if too large) and the
        // explicit zero-init is bounded to `guardedWidth` bytes (typically
        // ≤ 34 for a 64-wide block).
        //
        // The hot scalar `processQuad` path now reads the coefficient
        // buffer through a row-base pointer + nextRowOffset (rather than
        // the fetch(x,y) closure that did per-sample bounds checks).
        // Inspired by OpenJPH's `sp[0] / sp[stride] / ++sp` pattern in
        // ojph_encode_codeblock32 — see /tmp/openjph-src/src/core/coding/
        // ojph_block_encoder.cpp:586-728. Same bit-exact output.
        let guardedWidth = ((width + 3) / 4) * 2 + 2
        let coefBase = coefficients.baseAddress!

        // Stack-allocated scratch via withUnsafeTemporaryAllocation —
        // wraps the original body in a do-block-like scope. The closures
        // and emit logic below capture these pointers via `eValPtr` /
        // `cxValPtr`. Bounded by guardedWidth (≤ 34 for 64-wide block).
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: guardedWidth)
        { (eValPtr: UnsafeMutableBufferPointer<UInt8>) in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: guardedWidth)
        { (cxValPtr: UnsafeMutableBufferPointer<UInt8>) in

        // Zero-init the guardedWidth bytes (caller never zeros them).
        eValPtr.initialize(repeating: 0)
        cxValPtr.initialize(repeating: 0)

        // Fetch one sample's magnitude-exponent and signed payload.
        // Returns (significant: Bool, eQ: Int, payload: UInt32).
        // The "payload" is `v_n = 2*(mu_p - 1) + sign` as documented in
        // T.814 eqn. 5.
        // v9.2 Path B Phase 0b — marked `@inline(__always)` so the
        // optimizer inlines all 4 per-quad calls. (Pre-0b this was an
        // un-annotated nested closure; LLVM was inlining it but the
        // annotation makes the choice deterministic across builds.)
        @inline(__always)
        func sampleInfo(_ t: UInt32) -> (Bool, Int, UInt32) {
            // val = 2*t >> p & ~1 — isolate 2μ_p, clearing the sign
            // bit's contribution.
            var val = (t &+ t) >> p
            val &= ~UInt32(1)
            if val == 0 { return (false, 0, 0) }
            val &-= 1                     // 2μ_p - 1
            let lz = val.leadingZeroBitCount
            let eQ = 32 - lz
            let sign = UInt32((t >> 31) & 1)
            let payload = (val &- 1) &+ sign
            return (true, eQ, payload)
        }

        // Read one sample at (x, y), returning zero info if out of
        // bounds on either axis. v9.2: kept for the SIMD and pre-
        // classified-tuples paths (non-default, non-hot). The scalar
        // path now reads `coefBase[idx]` directly with pre-computed
        // offsets — see `processQuadScalarDirect` below.
        @inline(__always)
        func fetch(_ x: Int, _ y: Int) -> UInt32 {
            guard x < width, y < height else { return 0 }
            return coefBase[y * width + x]
        }

        // Process a single quad (4 samples in a 2x2 block at
        // (baseX, baseY)). Returns the four eQ values and four
        // payload samples as fixed-size tuples — Swift stack-allocates
        // these inline, dropping the two `[Int]` / `[UInt32]` array
        // allocations that the previous implementation paid on every
        // quad (~1024 quads in a 64×64 codeblock × thousands of
        // codeblocks per 1024×1024 input).
        //
        // Sample layout within a quad: (col, row) in
        // [(0,0), (0,1), (1,0), (1,1)] — OpenJPH walks the
        // (col, row) positions as index = 2*col + row (column-major
        // within the quad).
        // v5.39 M1: SIMD per-quad classification. Loads the four
        // sample t-values into a SIMD4<UInt32>, computes
        // val/sig/eQ/payload lane-parallel, then assembles the same
        // scalar return tuple as the scalar processQuad. The clz
        // (`leadingZeroBitCount`) is per-lane scalar because Swift's
        // `SIMD4<UInt32>` does not expose a lane-wise clz primitive
        // (NEON `vclz` is not surfaced through the public `simd`
        // module); the scalar clz still maps to a single NEON
        // instruction per lane on Apple Silicon. Bit-identical to
        // the scalar path — verified by per-sample 180K random sweep
        // (HTSampleInfoSIMDPrototypeTests) and per-block byte sweep
        // (HTSIMDIntegrationTests).
        @inline(__always)
        func processQuadSIMD(baseX: Int, baseY: Int)
            -> (rho: Int, eQMax: Int,
                eQ0: Int, eQ1: Int, eQ2: Int, eQ3: Int,
                s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32)
        {
            // Load 4 samples (still through fetch for boundary safety).
            let t = SIMD4<UInt32>(
                fetch(baseX,     baseY),
                fetch(baseX,     baseY + 1),
                fetch(baseX + 1, baseY),
                fetch(baseX + 1, baseY + 1))

            // val = (2*t >> p) & ~1  —  SIMD lane-parallel.
            var val = (t &<< 1) &>> SIMD4<UInt32>(repeating: p)
            val &= SIMD4<UInt32>(repeating: ~UInt32(1))

            // Per-lane significance.
            let sig0 = val[0] != 0
            let sig1 = val[1] != 0
            let sig2 = val[2] != 0
            let sig3 = val[3] != 0

            // For non-significant lanes, sub `safeVal = 1` so
            // `valMinus1 = 0` and clz = 32 (eQ = 0); the per-lane
            // mask below zeros these regardless, but keeping the
            // intermediate values sane lets LLVM emit straight-line
            // SIMD without lane-conditional branches.
            let safeVal = SIMD4<UInt32>(
                sig0 ? val[0] : 1,
                sig1 ? val[1] : 1,
                sig2 ? val[2] : 1,
                sig3 ? val[3] : 1)
            let valMinus1 = safeVal &- SIMD4<UInt32>(repeating: 1)

            // eQ = 32 - clz(val - 1), per lane.
            let lz = SIMD4<Int32>(
                Int32(valMinus1[0].leadingZeroBitCount),
                Int32(valMinus1[1].leadingZeroBitCount),
                Int32(valMinus1[2].leadingZeroBitCount),
                Int32(valMinus1[3].leadingZeroBitCount))
            let eQv = SIMD4<Int32>(repeating: 32) &- lz

            // sign = (t >> 31) & 1; payload = (val - 2) + sign.
            let sign = (t &>> SIMD4<UInt32>(repeating: 31))
                     & SIMD4<UInt32>(repeating: 1)
            let payload = (valMinus1 &- SIMD4<UInt32>(repeating: 1)) &+ sign

            // Reduce SIMD lanes back to scalar tuple — same shape
            // and same conditional logic as the scalar processQuad.
            var rho = 0
            var eQMax = 0
            var eQ0 = 0, eQ1 = 0, eQ2 = 0, eQ3 = 0
            var s0: UInt32 = 0, s1: UInt32 = 0
            var s2: UInt32 = 0, s3: UInt32 = 0
            if sig0 { rho |= 1; eQ0 = Int(eQv[0]); s0 = payload[0]; if eQ0 > eQMax { eQMax = eQ0 } }
            if sig1 { rho |= 2; eQ1 = Int(eQv[1]); s1 = payload[1]; if eQ1 > eQMax { eQMax = eQ1 } }
            if sig2 { rho |= 4; eQ2 = Int(eQv[2]); s2 = payload[2]; if eQ2 > eQMax { eQMax = eQ2 } }
            if sig3 { rho |= 8; eQ3 = Int(eQv[3]); s3 = payload[3]; if eQ3 > eQMax { eQMax = eQ3 } }
            return (rho, eQMax, eQ0, eQ1, eQ2, eQ3, s0, s1, s2, s3)
        }

        // v6-alpha6 phase 1.1: per-sample tuple unpacker. Reads the
        // GPU-classifier output format (`sig:1 | eQ:7 | payload:32`).
        // Out-of-bounds samples return the zero tuple, matching the
        // existing `fetch` semantics for the scalar / SIMD paths.
        @inline(__always)
        func sampleInfoFromTuple(_ x: Int, _ y: Int) -> (Bool, Int, UInt32) {
            guard let tuples = preClassifiedTuples,
                  x < width, y < height else {
                return (false, 0, 0)
            }
            let raw = tuples[y * width + x]
            let sig = (raw >> 63) & 1 != 0
            let eQ = Int((raw >> 56) & 0x7F)
            let payload = UInt32(raw & 0xFFFF_FFFF)
            return (sig, eQ, payload)
        }

        @inline(__always)
        func processQuadFromTuples(baseX: Int, baseY: Int)
            -> (rho: Int, eQMax: Int,
                eQ0: Int, eQ1: Int, eQ2: Int, eQ3: Int,
                s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32)
        {
            var rho = 0
            var eQMax = 0
            var eQ0 = 0, eQ1 = 0, eQ2 = 0, eQ3 = 0
            var s0: UInt32 = 0, s1: UInt32 = 0
            var s2: UInt32 = 0, s3: UInt32 = 0

            let (sig0, e0, p0) = sampleInfoFromTuple(baseX,     baseY)
            if sig0 { rho |= 1; eQ0 = e0; s0 = p0; if e0 > eQMax { eQMax = e0 } }

            let (sig1, e1, p1) = sampleInfoFromTuple(baseX,     baseY + 1)
            if sig1 { rho |= 2; eQ1 = e1; s1 = p1; if e1 > eQMax { eQMax = e1 } }

            let (sig2, e2, p2) = sampleInfoFromTuple(baseX + 1, baseY)
            if sig2 { rho |= 4; eQ2 = e2; s2 = p2; if e2 > eQMax { eQMax = e2 } }

            let (sig3, e3, p3) = sampleInfoFromTuple(baseX + 1, baseY + 1)
            if sig3 { rho |= 8; eQ3 = e3; s3 = p3; if e3 > eQMax { eQMax = e3 } }

            return (rho, eQMax, eQ0, eQ1, eQ2, eQ3, s0, s1, s2, s3)
        }

        @inline(__always)
        func processQuad(baseX: Int, baseY: Int)
            -> (rho: Int, eQMax: Int,
                eQ0: Int, eQ1: Int, eQ2: Int, eQ3: Int,
                s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32)
        {
            J2KHTEntropyEncoderProfile.bumpProcessQuad()
            // v6-alpha6 phase 1.1: GPU-pre-classified tuple stream.
            // Loop-invariant — optimiser hoists this branch.
            if preClassifiedTuples != nil {
                return processQuadFromTuples(baseX: baseX, baseY: baseY)
            }
            // v5.39 M1: dispatch to SIMD path if the caller opted in.
            // The branch is loop-invariant (same value for the entire
            // encode call), so the optimiser hoists it; per-quad cost
            // is zero.
            if useSIMDClassification {
                return processQuadSIMD(baseX: baseX, baseY: baseY)
            }
            var rho = 0
            var eQMax = 0
            var eQ0 = 0, eQ1 = 0, eQ2 = 0, eQ3 = 0
            var s0: UInt32 = 0, s1: UInt32 = 0
            var s2: UInt32 = 0, s3: UInt32 = 0

            let t0 = fetch(baseX,     baseY)
            let (sig0, e0, p0) = sampleInfo(t0)
            if sig0 { rho |= 1; eQ0 = e0; s0 = p0; if e0 > eQMax { eQMax = e0 } }

            let t1 = fetch(baseX,     baseY + 1)
            let (sig1, e1, p1) = sampleInfo(t1)
            if sig1 { rho |= 2; eQ1 = e1; s1 = p1; if e1 > eQMax { eQMax = e1 } }

            let t2 = fetch(baseX + 1, baseY)
            let (sig2, e2, p2) = sampleInfo(t2)
            if sig2 { rho |= 4; eQ2 = e2; s2 = p2; if e2 > eQMax { eQMax = e2 } }

            let t3 = fetch(baseX + 1, baseY + 1)
            let (sig3, e3, p3) = sampleInfo(t3)
            if sig3 { rho |= 8; eQ3 = e3; s3 = p3; if e3 > eQMax { eQMax = e3 } }

            return (rho, eQMax, eQ0, eQ1, eQ2, eQ3, s0, s1, s2, s3)
        }

        /// v9.3 Path B Phase 3 — batched 4-sample magsgn emit.
        ///
        /// Packs the up-to-4 significant-sample emissions of a quad into
        /// a single UInt64 codeword + total-bit-count, then makes ONE
        /// `encode64` call instead of up to 4 separate `encode` calls.
        /// On a DX encode this reduces 1.5M magsgn-encode calls down to
        /// ~490K (one per quad), amortizing per-call fixed overhead
        /// (function preamble, counter bump, fast-path probe).
        ///
        /// Bit-exact equivalent of the legacy 4-call sequence: the
        /// LSB-first packing in `combined` matches the order in which
        /// the legacy code emitted bits. Verified by HTSIMDIntegrationTests,
        /// V91Phase2cArrayVsRawParityTests, HTCrossCodecConformantTests.
        ///
        /// Fallback path: if total emitted bits exceed 64 (i.e. Uq > 16
        /// with 4 significant samples, which is rare on real fixtures),
        /// dispatch to the legacy 4-call sequence below.
        @inline(__always)
        func emitQuadMagSgn(
            rho: Int, tuple: Int, Uq: Int,
            s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32
        ) {
            // v9.3 — fast skip for non-significant quads. rho == 0
            // means all 4 samples are zero; the legacy path called no
            // emit functions, so we must also call nothing here. Without
            // this check the encode64(0,0) early-return still costs a
            // function-call cycle per non-significant quad (~50% of
            // quads on sparse blocks).
            if rho == 0 { return }
            // Common case: Uq ≤ 16 (typical for medical fixtures).
            // 4 × 16 = 64 bits fits in UInt64 — single batched emit.
            if Uq <= 16 {
                var combined: UInt64 = 0
                var totalBits: Int = 0
                if (rho & 1) != 0 {
                    let m = Uq - (tuple & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s0 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 2) != 0 {
                    let m = Uq - ((tuple >> 1) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s1 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 4) != 0 {
                    let m = Uq - ((tuple >> 2) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s2 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 8) != 0 {
                    let m = Uq - ((tuple >> 3) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s3 & mask) << totalBits
                    totalBits &+= m
                }
                magsgnEnc.encode64(codeword: combined, count: totalBits)
                return
            }
            // Fallback for high-magnitude quads (Uq > 16): legacy
            // per-sample emit. Identical to the pre-Phase-3 path.
            @inline(__always) func emit(sample: UInt32, eBit: Int) {
                let m = Uq - eBit
                let mask: UInt32 = (m >= 32) ? ~UInt32(0)
                                            : ((UInt32(1) << m) - 1)
                magsgnEnc.encode(codeword: sample & mask, count: m)
            }
            if (rho & 1) != 0 { emit(sample: s0, eBit: tuple & 1) }
            if (rho & 2) != 0 { emit(sample: s1, eBit: (tuple >> 1) & 1) }
            if (rho & 4) != 0 { emit(sample: s2, eBit: (tuple >> 2) & 1) }
            if (rho & 8) != 0 { emit(sample: s3, eBit: (tuple >> 3) & 1) }
        }

        // --- Initial row of quads (y = 0, 1) ---

        let _v91ClassifyStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var c_q0 = 0
        var y = 0

        var lep = 0      // index into eVal
        var lcxp = 0     // index into cxVal
        eValPtr[lep] = 0
        cxValPtr[lcxp] = 0

        if height > 0 {
            var spX = 0
            while spX < width {
                let q0 = processQuad(baseX: spX, baseY: 0)
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let Uq0 = max(eQMax0, 1)
                let u_q0 = Uq0 - 1

                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }

                // lep / lcxp bookkeeping: the max e_q from the quad's
                // bottom row carries forward; rho's bottom bits feed
                // the next row's context.
                eValPtr[lep] = max(eValPtr[lep], UInt8(q0.eQ1)); lep += 1
                eValPtr[lep] = UInt8(q0.eQ3)
                cxValPtr[lcxp] = cxValPtr[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                cxValPtr[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable0Conformant[
                    (c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)

                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }

                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3)

                // Second quad of the pair (might be out of bounds).
                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = processQuad(baseX: spX + 2, baseY: 0)
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let c_q1 = (rho0 >> 1) | (rho0 & 1)
                    let Uq1 = max(eQMax1, 1)
                    u_q1 = Uq1 - 1
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eValPtr[lep] = max(eValPtr[lep], UInt8(q1.eQ1)); lep += 1
                    eValPtr[lep] = UInt8(q1.eQ3)
                    cxValPtr[lcxp] = cxValPtr[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    cxValPtr[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable0Conformant[
                        (c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)

                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }

                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3)
                }

                // u-value encoding for this quad pair.
                if u_q0 > 0 && u_q1 > 0 {
                    melEnc.encode(eventIsOne: min(u_q0, u_q1) > 2)
                }
                if u_q0 > 2 && u_q1 > 2 {
                    let e0 = uvlcTableConformant[u_q0 - 2]
                    let e1 = uvlcTableConformant[u_q1 - 2]
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                } else if u_q0 > 2 && u_q1 > 0 {
                    let e0 = uvlcTableConformant[u_q0]
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: u_q1 - 1, count: 1)
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                } else {
                    let e0 = uvlcTableConformant[u_q0]
                    let e1 = uvlcTableConformant[u_q1]
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                }

                c_q0 = (rho1 >> 1) | (rho1 & 1)
                spX += 4
            }
        }
        // Mark the end-of-row sentinel in eValPtr.
        if lep + 1 < guardedWidth { eValPtr[lep + 1] = 0 }

        // --- Subsequent quad rows (y = 2, 4, ...) ---

        y = 2
        while y < height {
            lep = 0
            var maxE = max(Int(eValPtr[0]), Int(eValPtr[1])) - 1
            eValPtr[0] = 0
            lcxp = 0
            c_q0 = Int(cxValPtr[0]) + (Int(cxValPtr[1]) << 2)
            cxValPtr[0] = 0

            var spX = 0
            while spX < width {
                let q0 = processQuad(baseX: spX, baseY: y)
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let kappaA = ((rho0 & (rho0 - 1)) != 0) ? max(1, maxE) : 1
                let Uq0 = max(eQMax0, kappaA)
                let u_q0 = Uq0 - kappaA
                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }
                eValPtr[lep] = max(eValPtr[lep], UInt8(q0.eQ1)); lep += 1
                maxE = max(Int(eValPtr[lep]), Int(eValPtr[lep + 1])) - 1
                eValPtr[lep] = UInt8(q0.eQ3)
                cxValPtr[lcxp] = cxValPtr[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                var c_q1 = Int(cxValPtr[lcxp]) + (Int(cxValPtr[lcxp + 1]) << 2)
                cxValPtr[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable1Conformant[
                    (c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)
                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }
                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3)

                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = processQuad(baseX: spX + 2, baseY: y)
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let kappaB = ((rho1 & (rho1 - 1)) != 0) ? max(1, maxE) : 1
                    c_q1 |= ((rho0 & 4) >> 1) | ((rho0 & 8) >> 2)
                    let Uq1 = max(eQMax1, kappaB)
                    u_q1 = Uq1 - kappaB
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eValPtr[lep] = max(eValPtr[lep], UInt8(q1.eQ1)); lep += 1
                    maxE = max(Int(eValPtr[lep]), Int(eValPtr[lep + 1])) - 1
                    eValPtr[lep] = UInt8(q1.eQ3)
                    cxValPtr[lcxp] = cxValPtr[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    c_q0 = Int(cxValPtr[lcxp]) + (Int(cxValPtr[lcxp + 1]) << 2)
                    cxValPtr[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable1Conformant[
                        (c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)
                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }
                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3)
                }

                // Subsequent rows use unconditional UVLC per quad.
                let e0 = uvlcTableConformant[u_q0]
                let e1 = uvlcTableConformant[u_q1]
                J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                J2KHTEntropyEncoderProfile.bumpVlcUVLCEncode()
                vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))

                c_q0 |= ((rho1 & 4) >> 1) | ((rho1 & 8) >> 2)
                spX += 4
            }
            y += 2
        }

        let _v91ClassifyEndNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        J2KHTEntropyEncoderProfile.recordBlockClassifyNs(
            _v91ClassifyEndNs &- _v91ClassifyStartNs)
        // Close the two `withUnsafeTemporaryAllocation` scopes opened
        // near the top of the function (cxVal inner, eVal outer).
        } /* end cxValPtr withUnsafeTemporaryAllocation */
        } /* end eValPtr withUnsafeTemporaryAllocation */
    }

    /// v9.1 Path B Phase 2c — public encode wrapper for Array-backed
    /// engines (HTMagSgnEncoderConformant et al.).
    ///
    /// Bit-identical to the prior monolithic implementation; the loop
    /// body now lives in `encodeLoopGeneric`. Existing callers (the
    /// 3-overload chain forwarding to this signature, plus
    /// J2KEncoderPipeline.encodeCodeBlockConformant) work unchanged.

    public static func encode(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int,
        height: Int,
        missingMSBs: Int,
        magsgnEnc: inout HTMagSgnEncoderConformant,
        melEnc: inout HTMELEncoderConformant,
        vlcEnc: inout HTReverseBitEmitterConformant,
        useSIMDClassification: Bool,
        preClassifiedTuples: UnsafeBufferPointer<UInt64>?
    ) -> (magsgn: [UInt8], mel: [UInt8], vlc: [UInt8]) {
        precondition(coefficients.count == width * height,
                     "coefficient count mismatch")
        precondition(missingMSBs < 30, "missingMSBs must leave room for data")
        if let tuples = preClassifiedTuples {
            precondition(tuples.count == width * height,
                         "preClassifiedTuples count mismatch")
        }

        let blockStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        // v9.4-research — NEON hot path dispatch. When the env-var gate
        // is set and the block fits the C envelope, bypass the entire
        // Swift encodeLoopGeneric + 3 engine finishes and route through
        // the dcmj2knhe_encode_block_ht32 C entry point. Bit-exact
        // equivalent verified by V94NEONHotPathParityTests.
        if useNEONHotPath
            && width >= 1 && width <= 64
            && height >= 1 && height <= 64
            && missingMSBs < 30
            && preClassifiedTuples == nil
            && !useSIMDClassification
        {
            let result = encodeViaNEONHotPath(
                coefficients: coefficients,
                width: width, height: height,
                missingMSBs: missingMSBs)
            let blockEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            J2KHTEntropyEncoderProfile.recordBlockClassifyNs(blockEnd &- blockStart)
            J2KHTEntropyEncoderProfile.recordBlockTotalNs(blockEnd &- blockStart)
            return result
        }

        encodeLoopGeneric(
            coefficients: coefficients,
            width: width, height: height, missingMSBs: missingMSBs,
            magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc,
            useSIMDClassification: useSIMDClassification,
            preClassifiedTuples: preClassifiedTuples)
        let finishStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let magsgnBytes = magsgnEnc.finish()
        let melBytes = melEnc.finish()
        let vlcBytes = vlcEnc.finish()
        let blockEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        J2KHTEntropyEncoderProfile.recordBlockFinishNs(blockEnd &- finishStart)
        J2KHTEntropyEncoderProfile.recordBlockTotalNs(blockEnd &- blockStart)
        return (magsgnBytes, melBytes, vlcBytes)
    }

    /// v9.1 Path B Phase 2c — public encode wrapper for raw-pointer
    /// engines (HTMagSgnEncoderRawConformant et al.).
    ///
    /// Same loop body as the Array overload (via `encodeLoopGeneric`),
    /// but the engines write to caller-owned
    /// `UnsafeMutableBufferPointer<UInt8>` buffers and return byte
    /// counts rather than allocating `[UInt8]` arrays. Used by the
    /// per-worker pool in J2KEncoderPipeline to eliminate per-byte
    /// `Array.append` ARC + capacity-grow contention measured at 5×
    /// concurrent inflation on M2 (see V9_1_PHASE_2_BREAKTHROUGH.md).
    ///
    /// Caller is responsible for:
    ///   1. Allocating each engine's underlying buffer (16 KB is safe
    ///      for any 64×64 HT block at 30-bit precision).
    ///   2. After this call returns, copying `buf[0..<count]` into the
    ///      caller's downstream pipeline. The VLC count is in
    ///      `emittedReversed` order — call `.reversed()` to get the
    ///      forward on-wire byte order matching `HTReverseBitEmitter-
    ///      Conformant.finish()`.

    public static func encode(
        coefficients: UnsafeBufferPointer<UInt32>,
        width: Int,
        height: Int,
        missingMSBs: Int,
        magsgnEnc: inout HTMagSgnEncoderRawConformant,
        melEnc: inout HTMELEncoderRawConformant,
        vlcEnc: inout HTReverseBitEmitterRawConformant,
        useSIMDClassification: Bool = false,
        preClassifiedTuples: UnsafeBufferPointer<UInt64>? = nil
    ) -> (magsgnCount: Int, melCount: Int, vlcCount: Int) {
        precondition(coefficients.count == width * height,
                     "coefficient count mismatch")
        precondition(missingMSBs < 30, "missingMSBs must leave room for data")
        if let tuples = preClassifiedTuples {
            precondition(tuples.count == width * height,
                         "preClassifiedTuples count mismatch")
        }

        let blockStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        encodeLoopGeneric(
            coefficients: coefficients,
            width: width, height: height, missingMSBs: missingMSBs,
            magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc,
            useSIMDClassification: useSIMDClassification,
            preClassifiedTuples: preClassifiedTuples)
        let finishStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let magsgnCount = magsgnEnc.finishCount()
        let melCount = melEnc.finishCount()
        let vlcCount = vlcEnc.finishCount()
        let blockEnd = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        J2KHTEntropyEncoderProfile.recordBlockFinishNs(blockEnd &- finishStart)
        J2KHTEntropyEncoderProfile.recordBlockTotalNs(blockEnd &- blockStart)
        return (magsgnCount, melCount, vlcCount)
    }
}
