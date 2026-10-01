// J2KHTBlockDecoderConformant.swift
// ISO/IEC 15444-15 cleanup-pass codeblock decoder (scalar, 32-bit).
//
// Reference implementation that mirrors the encoder (M5b) step-for-
// step. Rather than porting OpenJPH's fast 1024-entry decoder
// lookup, this decoder walks the cleanup-pass tuple by tuple and
// matches the next VLC bits against the source codebook (table0.h /
// table1.h) by linear search — O(n) per quad but simple to verify
// against the encoder. OpenJPH's fast tables are a further
// optimization that can replace this once cross-codec validation
// passes (M7).

import Foundation
import DicomJPEG2000NEON

/// v10.2-research Phase D1.5-D — gate for the integrated C+NEON HT
/// block decoder (`dcmj2knhd_decode_block_ht32`). **Default ON since
/// Phase D1.5-D (2026-05-15)**: the warm cross-codec A/B cleared the
/// v7.4 ≥3 ms DX A/B threshold (DX mid −5.34 ms, DX large −6.98 ms;
/// PX mid −3.04 ms, PX large −3.05 ms across two ON runs). MG variance
/// was too large to confirm signal in 2 runs but trend was favourable
/// (5/6 ON-vs-OFF deltas across two ON runs were ≤0 ms).
///
/// **Opt-out:** set `J2K_NEON_HT_DECODE=0` to fall back to the Swift
/// reference path. This is the escape hatch if a fixture regression
/// is reported.
///
/// The C path uses the 4-byte SWAR MagSgn refill (matches Swift v7.4
/// `refillBatched`) and otherwise mirrors `HTBlockDecoderConformant.decode`
/// bit-exactly per `V10_2_DecodeBlockParityTests` (8 tests, ~100+ block
/// configurations, 0 failures).
public enum HTBlockDecoderConformantNEON {
    nonisolated(unsafe) public static var routingEnabled: Bool = {
        // Default ON unless explicit opt-out via env var.
        ProcessInfo.processInfo.environment["J2K_NEON_HT_DECODE"] != "0"
    }()
}

public enum HTBlockDecoderConformant {

    /// **v7.4 NEON reconstruction gate.** Default `false` —
    /// rigorous A/B benchmarking (`V740NeonDXWallBenchmark`,
    /// `V740NeonReconstructionMicrobench`) measured the SIMD-vs-
    /// scalar wall-time delta on DX 2800×2288 in-process decode at
    /// only **0.90 ms (1.5 %)** at the v7.3.0 codebase state, well
    /// below v7.4's 3 ms threshold for "default ON" enablement.
    ///
    /// The SIMD path is bit-exact-equivalent to the scalar reference
    /// per `V740NeonReconstructionParityTests` (5/5 sweeps pass:
    /// bit-depths, densities, block sizes, 32 random seeds, full
    /// medical corpus end-to-end). Both paths are fully maintained;
    /// callers (and tests) can flip this flag to A/B compare.
    ///
    /// Why scalar is the new default: at v7.3.0, after Phase 3c
    /// (bottom-row recoverEQ) and Phase 3d (rho=0 fast path) had
    /// landed, the readQuadSamples reconstruction body became a
    /// smaller share of block-decode wall — leaving SIMD with too
    /// little work per call to amortise its setup cost. The SIMD
    /// path wins ~3 % on sparse blocks (where its flat per-call
    /// cost beats scalar's per-iteration overhead) but loses ~3 %
    /// on dense blocks. Aggregate on DX in-process at v7.4 time: +0.9 ms.
    ///
    /// **v8 Phase 4 (2026-05-09) re-evaluation flips default to true.**
    /// Re-running the same DX A/B benchmark on v8 main (post Phase 3
    /// SIMD IDWT) shows the NEON reconstruction win is now consistently
    /// 2.5-4.5 ms with median 2.96 ms across 10 samples — right at
    /// the v7.4 3 ms gate. Under the v8 product narrowing to Apple-
    /// Silicon-only (memory `feedback_apple_only_v8`), measurable
    /// consistent Apple Silicon wins are accepted default-on even
    /// when borderline against the v7.4 cross-platform gate. The
    /// flag is preserved (now a default-ON opt-out) so non-Apple
    /// or future curve-shifted platforms can disable it.
    nonisolated(unsafe) public static var neonReconstructionEnabled: Bool = true

    /// Decode a Part-15 codeblock produced by
    /// `HTBlockEncoderConformant.encode` + `HTBlockLayoutConformant.assemble`.
    /// Returns the reconstructed `width * height` coefficient array
    /// in OpenJPH sign-magnitude convention (bit 31 = sign, magnitude
    /// in bits below `p = 30 - missingMSBs`).
    ///
    /// v10.2 Phase D1.5-C: routes to the integrated C+NEON hot path
    /// (`dcmj2knhd_decode_block_ht32`) when `HTBlockDecoderConformantNEON.routingEnabled`
    /// is true (set by `J2K_NEON_HT_DECODE=1` env var). The C path is
    /// bit-exact with the Swift reference per `V10_2_DecodeBlockParityTests`;
    /// router fallback throws `malformedBlock` on any C-side error code.
    public static func decode(
        block: [UInt8],
        width: Int,
        height: Int,
        missingMSBs: Int
    ) throws -> [UInt32] {
        if HTBlockDecoderConformantNEON.routingEnabled {
            return try decodeViaNEONHotPath(
                block: block, width: width, height: height, missingMSBs: missingMSBs)
        }
        guard let parsed = HTBlockLayoutConformant.parse(block: block) else {
            throw HTBlockDecoderConformantError.malformedBlock
        }
        // Pass slices directly into the inner readers — they hold an
        // ArraySlice<UInt8> so this avoids two `Array(parsed.*)` copies
        // on the per-codeblock hot path. With 1024×1024 inputs the saved
        // allocations were ~30 MB across thousands of codeblocks.
        var state = DecodeState(
            melVlcBytes: parsed.melVlc, scup: parsed.scup,
            magsgnBytes: parsed.magsgn,
            width: width, height: height,
            p: UInt32(30 - missingMSBs))

        // Initial quad row (y = 0, 1) uses table0 with implicit kappa = 1.
        state.decodeInitialRow()

        // Subsequent quad rows (y = 2, 4, ...) use table1. max_e and
        // c_q0 flow from eVal/cxVal buffers populated by the previous row.
        var y = 2
        while y < height {
            state.decodeSubsequentRow(y: y)
            y += 2
        }

        return state.coefs
    }

    /// v10.2 Phase D1.5-C: route a single HT block through the
    /// integrated C decoder (`dcmj2knhd_decode_block_ht32`).
    /// SWAR-4 MagSgn refill is enabled (matches Swift production
    /// default `HTMagSgnDecoderConformant.neonRefillEnabled = true`).
    private static func decodeViaNEONHotPath(
        block: [UInt8],
        width: Int, height: Int, missingMSBs: Int
    ) throws -> [UInt32] {
        var coefs = [UInt32](repeating: 0, count: width * height)
        let rc: Int32 = block.withUnsafeBufferPointer { bp -> Int32 in
            return vlcDecoderTable0Conformant.withUnsafeBufferPointer { t0 in
                return vlcDecoderTable1Conformant.withUnsafeBufferPointer { t1 in
                    return coefs.withUnsafeMutableBufferPointer { co in
                        return dcmj2knhd_decode_block_ht32(
                            bp.baseAddress, bp.count,
                            UInt32(width), UInt32(height), UInt32(missingMSBs),
                            t0.baseAddress, t1.baseAddress,
                            true,
                            co.baseAddress)
                    }
                }
            }
        }
        if rc != 0 {
            throw HTBlockDecoderConformantError.malformedBlock
        }
        return coefs
    }
}

// MARK: - Decode state machine

/// All mutable state for a codeblock decode session. Holds the three
/// stream readers, scratch buffers for inter-row context, and the
/// output coefficient array.
fileprivate struct DecodeState {
    var melDec: HTMELDecoderConformant
    var vlcReader: VLCReverseReader
    var magsgnDec: HTMagSgnDecoderConformant
    let width: Int
    let height: Int
    let p: UInt32

    /// Per-row scratch: max e_q from the bottom row of each quad in
    /// the previous row (consumed when computing max_e for subsequent
    /// rows). Sized with +2 guard slots.
    var eVal: [UInt8]
    /// Per-row scratch: rho's bottom-row bits from the previous row
    /// (feeds c_q context for subsequent rows).
    var cxVal: [UInt8]

    var coefs: [UInt32]

    /// MEL run-state: OpenJPH's packed "2*count | terminator" value.
    var melRun: Int

    init(
        melVlcBytes: ArraySlice<UInt8>, scup: Int,
        magsgnBytes: ArraySlice<UInt8>,
        width: Int, height: Int, p: UInt32
    ) {
        self.melDec = HTMELDecoderConformant(bytes: melVlcBytes)
        self.vlcReader = VLCReverseReader(
            melVlcBytes: melVlcBytes, scup: scup)
        self.magsgnDec = HTMagSgnDecoderConformant(bytes: magsgnBytes)
        self.width = width
        self.height = height
        self.p = p
        let guarded = ((width + 3) / 4) * 2 + 2
        self.eVal = [UInt8](repeating: 0, count: guarded)
        self.cxVal = [UInt8](repeating: 0, count: guarded)
        self.coefs = [UInt32](repeating: 0, count: width * height)
        self.melRun = self.melDec.nextRun()
    }

    mutating func nextMELEvent() -> Bool {
        melRun -= 2
        let isOne = (melRun == -1)
        if melRun < 0 {
            melRun = melDec.nextRun()
        }
        return isOne
    }

    /// Fast VLC lookup via OpenJPH's 1024-entry reverse-table
    /// (indexed by `(c_q << 7) | bits7`, packed as
    /// `e_k|e_1|rho|u_off|cwd_len`). Constant-time per codeword.
    @inline(__always)
    func lookupVLC(
        c_q: Int, bits: Int, initialLine: Bool
    ) -> (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) {
        let tbl = initialLine
            ? vlcDecoderTable0Conformant
            : vlcDecoderTable1Conformant
        let idx = (c_q << 7) | (bits & 0x7F)
        let entry = Int(tbl[idx])
        let cwd_len = entry & 0x7
        let u_off   = (entry >> 3) & 0x1
        let rho     = (entry >> 4) & 0xF
        let e_1     = (entry >> 8) & 0xF
        let e_k     = (entry >> 12) & 0xF
        return (rho: rho, u_off: u_off, cwd_len: cwd_len, e_k: e_k, e_1: e_1)
    }

    /// Unary prefix reader for UVLC: 1→1, 01→2, 001→3, 000→4.
    mutating func readPrefix() -> Int {
        let b0 = Int(vlcReader.read(count: 1))
        if b0 == 1 { return 1 }
        let b1 = Int(vlcReader.read(count: 1))
        if b1 == 1 { return 2 }
        let b2 = Int(vlcReader.read(count: 1))
        if b2 == 1 { return 3 }
        return 4
    }

    /// Map a prefix length to the base u value, reading any
    /// additional suffix/extension bits as required.
    mutating func decodeFromPrefix(_ len: Int) -> Int {
        if len == 3 {
            let suf = Int(vlcReader.read(count: 1))
            return 3 + suf
        }
        if len == 4 {
            let suf = Int(vlcReader.read(count: 5))
            if suf < 28 { return 5 + suf }
            let ext = Int(vlcReader.read(count: 4))
            return 33 + (suf - 28) + 4 * ext
        }
        return len
    }

    /// Decode a u-value pair per OpenJPH's branch structure for the
    /// initial row (with MEL arbitration when both u_off are set).
    ///
    /// Encoder wire layout (matches every branch in
    /// `HTBlockEncoderConformant.encode` initial-row UVLC):
    /// - No-u-values branch: nothing emitted.
    /// - Both u_off=1 + MEL=1 (both u > 2 after +2 shift): `pre0, pre1,
    ///   suf0, suf1` — prefixes first, then suffixes.
    /// - Both u_off=1 + MEL=0 + u_q0 > 2: `pre0, 1-bit-for-u_q1, suf0`.
    /// - Both u_off=1 + MEL=0 + u_q0 ≤ 2: `pre0, pre1, (suf0=∅), suf1`
    ///   — u_q0 has no suffix so only u_q1's suffix is read.
    /// - One u_off: `pre, suf` for the active quad.
    mutating func decodeUVLCPairInitial(
        u_off0: Int, u_off1: Int
    ) -> (Int, Int) {
        if u_off0 == 0 && u_off1 == 0 { return (0, 0) }
        if u_off0 == 1 && u_off1 == 1 {
            let melEvent = nextMELEvent()
            if melEvent {
                let p0 = readPrefix()
                let p1 = readPrefix()
                let s0 = decodeFromPrefix(p0)
                let s1 = decodeFromPrefix(p1)
                return (s0 + 2, s1 + 2)
            }
            let p0 = readPrefix()
            // Encoder emits u_q1's 1-bit marker BEFORE suf0 when
            // u_q0 > 2 (i.e. prefix length 3 or 4). Read that bit
            // first, then let decodeFromPrefix(p0) consume suf0.
            if p0 >= 3 {
                let bit = Int(vlcReader.read(count: 1))
                let u0 = decodeFromPrefix(p0)
                return (u0, bit + 1)
            }
            // u_q0 ≤ 2 path: encoder writes `pre0, pre1, (no suf0), suf1`.
            let p1 = readPrefix()
            let u0 = decodeFromPrefix(p0)
            let u1 = decodeFromPrefix(p1)
            return (u0, u1)
        }
        // Exactly one u_off is set: encoder wrote `pre, suf` for that
        // quad; decoder reads the same in sequence.
        let u0 = (u_off0 != 0) ? decodeFromPrefix(readPrefix()) : 0
        let u1 = (u_off1 != 0) ? decodeFromPrefix(readPrefix()) : 0
        return (u0, u1)
    }

    /// Subsequent-row UVLC: encoder writes `pre0, pre1, suf0, suf1` in
    /// that order unconditionally (with the suffix slots being empty
    /// when the prefix length is 1 or 2). The decoder must read both
    /// prefixes first and only then consume the suffixes — reading
    /// prefix+suffix interleaved per quad desyncs the stream whenever
    /// the first quad has a non-empty suffix.
    mutating func decodeUVLCPairSubsequent(
        u_off0: Int, u_off1: Int
    ) -> (Int, Int) {
        let len0 = (u_off0 != 0) ? readPrefix() : 0
        let len1 = (u_off1 != 0) ? readPrefix() : 0
        let u0 = (u_off0 != 0) ? decodeFromPrefix(len0) : 0
        let u1 = (u_off1 != 0) ? decodeFromPrefix(len1) : 0
        return (u0, u1)
    }

    // MARK: - Row decoding

    mutating func decodeInitialRow() {
        var lep = 0
        var lcxp = 0
        var c_q0 = 0
        var x = 0
        while x < width {
            // When c_q=0 the encoder reads a MEL event first and
            // only emits a VLC codeword if rho is non-zero. Mirror
            // that sequence or we eat into the next token's bits.
            var rho0 = 0
            var look0: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int)
                = (0, 0, 0, 0, 0)
            if c_q0 == 0 {
                if nextMELEvent() {
                    let head = Int(vlcReader.peek(maxBits: 7))
                    look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: true)
                    vlcReader.consume(count: look0.cwd_len)
                    rho0 = look0.rho
                }
            } else {
                let head = Int(vlcReader.peek(maxBits: 7))
                look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: true)
                vlcReader.consume(count: look0.cwd_len)
                rho0 = look0.rho
            }

            var rho1 = 0
            var look1: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int)
                = (0, 0, 0, 0, 0)
            if x + 2 < width {
                let c_q1 = (rho0 >> 1) | (rho0 & 1)
                if c_q1 == 0 {
                    if nextMELEvent() {
                        let head1 = Int(vlcReader.peek(maxBits: 7))
                        look1 = lookupVLC(c_q: c_q1, bits: head1,
                                          initialLine: true)
                        vlcReader.consume(count: look1.cwd_len)
                        rho1 = look1.rho
                    }
                } else {
                    let head1 = Int(vlcReader.peek(maxBits: 7))
                    look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: true)
                    vlcReader.consume(count: look1.cwd_len)
                    rho1 = look1.rho
                }
            }

            let (u_q0, u_q1) = decodeUVLCPairInitial(
                u_off0: rho0 != 0 ? look0.u_off : 0,
                u_off1: rho1 != 0 ? look1.u_off : 0)
            let Uq0 = u_q0 + 1  // kappa = 1 for initial row
            let Uq1 = u_q1 + 1

            readQuadSamples(
                baseX: x, baseY: 0,
                rho: rho0, Uq: Uq0,
                e_k: look0.e_k, e_1: look0.e_1)
            if x + 2 < width {
                readQuadSamples(
                    baseX: x + 2, baseY: 0,
                    rho: rho1, Uq: Uq1,
                    e_k: look1.e_k, e_1: look1.e_1)
            }

            // Mirror encoder's e_q/rho recovery for bookkeeping.
            // For the decoder we can recover eQ[1] and eQ[3] from
            // whether the samples were significant and their
            // reconstructed magnitude bit widths. We use them only to
            // populate eVal/cxVal for the next row.
            let eQ0 = recoverEQBottomRow(rho: rho0, baseX: x, baseY: 0)
            eVal[lep] = max(eVal[lep], UInt8(eQ0.0)); lep += 1
            eVal[lep] = UInt8(eQ0.1)
            cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
            cxVal[lcxp] = UInt8((rho0 & 8) >> 3)
            if x + 2 < width {
                let eQ1 = recoverEQBottomRow(rho: rho1, baseX: x + 2, baseY: 0)
                eVal[lep] = max(eVal[lep], UInt8(eQ1.0)); lep += 1
                eVal[lep] = UInt8(eQ1.1)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                cxVal[lcxp] = UInt8((rho1 & 8) >> 3)
            }

            c_q0 = (rho1 >> 1) | (rho1 & 1)
            x += 4
        }
        if lep + 1 < eVal.count { eVal[lep + 1] = 0 }
    }

    mutating func decodeSubsequentRow(y: Int) {
        var lep = 0
        var lcxp = 0
        var maxE = max(Int(eVal[0]), Int(eVal[1])) - 1
        eVal[0] = 0
        var c_q0 = Int(cxVal[0]) + (Int(cxVal[1]) << 2)
        cxVal[0] = 0

        var x = 0
        while x < width {
            // Step 1: decode VLC (+MEL gate) for both quads of the
            // pair. c_q1 is read from cxVal AFTER the first quad's
            // lcxp update — mirrors encoder's read-then-overwrite
            // ordering.
            var rho0 = 0
            var look0: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int)
                = (0, 0, 0, 0, 0)
            if c_q0 == 0 {
                if nextMELEvent() {
                    let head = Int(vlcReader.peek(maxBits: 7))
                    look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: false)
                    vlcReader.consume(count: look0.cwd_len)
                    rho0 = look0.rho
                }
            } else {
                let head = Int(vlcReader.peek(maxBits: 7))
                look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: false)
                vlcReader.consume(count: look0.cwd_len)
                rho0 = look0.rho
            }
            let kappaA = ((rho0 & (rho0 - 1)) != 0) ? max(1, maxE) : 1

            // Advance lcxp partially to discover c_q1's source slot
            // (the encoder reads c_q1 BEFORE writing its own lcxp).
            cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
            var c_q1 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
            cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

            var rho1 = 0
            var look1: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int)
                = (0, 0, 0, 0, 0)
            if x + 2 < width {
                c_q1 |= ((rho0 & 4) >> 1) | ((rho0 & 8) >> 2)
                if c_q1 == 0 {
                    if nextMELEvent() {
                        let head1 = Int(vlcReader.peek(maxBits: 7))
                        look1 = lookupVLC(c_q: c_q1, bits: head1,
                                          initialLine: false)
                        vlcReader.consume(count: look1.cwd_len)
                        rho1 = look1.rho
                    }
                } else {
                    let head1 = Int(vlcReader.peek(maxBits: 7))
                    look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: false)
                    vlcReader.consume(count: look1.cwd_len)
                    rho1 = look1.rho
                }
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                c_q0 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                cxVal[lcxp] = UInt8((rho1 & 8) >> 3)
            }

            // Step 2: UVLC for the pair (encoder emits both quads'
            // u values after both VLC codewords).
            let (u_q0, u_q1) = decodeUVLCPairSubsequent(
                u_off0: rho0 != 0 ? look0.u_off : 0,
                u_off1: rho1 != 0 ? look1.u_off : 0)

            // Step 3: decode MagSgn for quad 0. Must happen before we
            // can derive eQ0 for the eVal/max_e bookkeeping that
            // feeds kappaB.
            let Uq0 = u_q0 + kappaA
            readQuadSamples(
                baseX: x, baseY: y,
                rho: rho0, Uq: Uq0,
                e_k: look0.e_k, e_1: look0.e_1)

            // Step 4: update eVal using quad 0's reconstructed e_q.
            // The encoder's equivalent sequence is:
            //   lep[0] = max(lep[0], e_q[1]); lep++;
            //   max_e = max(lep[0], lep[1]) - 1;
            //   lep[0] = e_q[3];
            let eQ0pair = recoverEQBottomRow(rho: rho0, baseX: x, baseY: y)
            eVal[lep] = max(eVal[lep], UInt8(eQ0pair.0)); lep += 1
            let maxEAfterQ0 = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
            eVal[lep] = UInt8(eQ0pair.1)

            // Step 5: kappaB and MagSgn for quad 1.
            var kappaB = 1
            if x + 2 < width {
                kappaB = ((rho1 & (rho1 - 1)) != 0) ? max(1, maxEAfterQ0) : 1
                let Uq1 = u_q1 + kappaB
                readQuadSamples(
                    baseX: x + 2, baseY: y,
                    rho: rho1, Uq: Uq1,
                    e_k: look1.e_k, e_1: look1.e_1)

                let eQ1pair = recoverEQBottomRow(rho: rho1, baseX: x + 2, baseY: y)
                eVal[lep] = max(eVal[lep], UInt8(eQ1pair.0)); lep += 1
                maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                eVal[lep] = UInt8(eQ1pair.1)
            } else {
                maxE = maxEAfterQ0
            }

            c_q0 |= ((rho1 & 4) >> 1) | ((rho1 & 8) >> 2)
            x += 4
        }
    }

    // MARK: - Sample reconstruction

    /// Read MagSgn bits for each significant sample of the quad and
    /// place reconstructed (bin-center) coefficients into `coefs`.
    ///
    /// **v7.3.0 Phase 3b — SIMD reconstruction.** The four samples
    /// of a quad are independent in their reconstruction: each
    /// computes `coef = ((payload & mask) | (e1Bit << m) | 1 + 2)
    /// << (p - 1)` plus an OR-with-sign-bit. The MagSgn read is
    /// serial (the bit-stream cursor advances as bits are consumed),
    /// but everything downstream of the four reads can run lane-
    /// parallel via `SIMD4<UInt32>`. Bit-identical to the scalar
    /// reference implementation by construction (same arithmetic,
    /// just executed lane-parallel).
    /// Dispatcher. Routes to the SIMD or scalar implementation based
    /// on the `_neonReconstructionEnabled` static flag. Both paths
    /// share the rho=0 fast-path; only the per-lane reconstruction
    /// arithmetic differs. Tests can flip the flag to A/B compare.
    @inline(__always)
    mutating func readQuadSamples(
        baseX: Int, baseY: Int,
        rho: Int, Uq: Int,
        e_k: Int, e_1: Int
    ) {
        if rho == 0 { return }
        if DecodeState._neonReconstructionEnabled {
            readQuadSamplesSIMD(
                baseX: baseX, baseY: baseY,
                rho: rho, Uq: Uq, e_k: e_k, e_1: e_1)
        } else {
            readQuadSamplesScalar(
                baseX: baseX, baseY: baseY,
                rho: rho, Uq: Uq, e_k: e_k, e_1: e_1)
        }
    }

    /// **v7.4 NEON reconstruction prototype gate.**
    ///
    /// Reads from `HTBlockDecoderConformant.neonReconstructionEnabled`
    /// — exposed publicly so tests can A/B compare. Default `true`
    /// (Phase 3b's SIMD reconstruction has been the production path
    /// since v7.3.0).
    @inline(__always)
    static var _neonReconstructionEnabled: Bool {
        HTBlockDecoderConformant.neonReconstructionEnabled
    }

    /// **Scalar reference path.** The pre-Phase-3b implementation,
    /// kept as the truth oracle for the SIMD path's bit-exactness
    /// proof and as the fallback when the NEON gate is off.
    /// Identical to the original `readQuadSamples` from before v7.3
    /// other than minor bookkeeping (the `bumpQuadSamples` /
    /// `bumpMagsgnReadBits` probe calls were removed in #367 along
    /// with their SIMD-path counterparts).
    @inline(__always)
    mutating func readQuadSamplesScalar(
        baseX: Int, baseY: Int,
        rho: Int, Uq: Int,
        e_k: Int, e_1: Int
    ) {
        let offsets = [(0, 0), (0, 1), (1, 0), (1, 1)]
        for i in 0..<4 {
            let bit = (rho >> i) & 1
            if bit == 0 { continue }
            let eBit = (e_k >> i) & 1
            let e1Bit = (e_1 >> i) & 1
            let m = Uq - eBit
            let payload = magsgnDec.read(count: m)
            let sign = UInt32(payload & 1)
            let mask: UInt32 = (m >= 32) ? ~UInt32(0)
                                         : ((UInt32(1) << m) - 1)
            var v_n: UInt32 = payload & mask
            v_n |= UInt32(e1Bit) << m
            v_n |= 1
            let (dx, dy) = offsets[i]
            let xi = baseX + dx
            let yi = baseY + dy
            if xi >= width || yi >= height { continue }
            var coef: UInt32 = (v_n &+ 2) << (p &- 1)
            if sign != 0 { coef |= 0x8000_0000 }
            coefs[yi * width + xi] = coef
        }
    }

    /// **NEON SIMD reconstruction path** (Phase 3b shape, kept as
    /// `readQuadSamplesSIMD` so the dispatcher above can A/B against
    /// `readQuadSamplesScalar`).
    ///
    /// Lane-parallel `SIMD4<UInt32>` reconstruction. The four samples
    /// of a quad are independent in their reconstruction (mask + v_n
    /// + coef + sign); only the MagSgn read itself is serial. SIMD4
    /// on Apple Silicon maps to NEON 128-bit Q-register ops; each
    /// shift/and/or below compiles to one instruction.
    @inline(__always)
    mutating func readQuadSamplesSIMD(
        baseX: Int, baseY: Int,
        rho: Int, Uq: Int,
        e_k: Int, e_1: Int
    ) {
        let r0 = (rho     ) & 1
        let r1 = (rho >> 1) & 1
        let r2 = (rho >> 2) & 1
        let r3 = (rho >> 3) & 1
        let m0 = Uq - ((e_k     ) & 1)
        let m1 = Uq - ((e_k >> 1) & 1)
        let m2 = Uq - ((e_k >> 2) & 1)
        let m3 = Uq - ((e_k >> 3) & 1)
        var p0: UInt32 = 0; if r0 != 0 { p0 = magsgnDec.read(count: m0) }
        var p1: UInt32 = 0; if r1 != 0 { p1 = magsgnDec.read(count: m1) }
        var p2: UInt32 = 0; if r2 != 0 { p2 = magsgnDec.read(count: m2) }
        var p3: UInt32 = 0; if r3 != 0 { p3 = magsgnDec.read(count: m3) }

        let payloads = SIMD4<UInt32>(p0, p1, p2, p3)
        let ms = SIMD4<UInt32>(UInt32(m0), UInt32(m1), UInt32(m2), UInt32(m3))
        let one = SIMD4<UInt32>(repeating: 1)
        // mask = (1 << m) - 1. For m == 32, `1 &<< 32` is 0 in Swift,
        // and `0 &- 1` wraps to ~0 — same result as the scalar
        // branch's `(m >= 32) ? ~0 : (1 << m) - 1`.
        let mask = (one &<< ms) &- one
        let e1 = SIMD4<UInt32>(
            UInt32((e_1     ) & 1),
            UInt32((e_1 >> 1) & 1),
            UInt32((e_1 >> 2) & 1),
            UInt32((e_1 >> 3) & 1))
        let signs = payloads & one
        let v_n = (payloads & mask) | (e1 &<< ms) | one
        let pShift = SIMD4<UInt32>(repeating: UInt32(p &- 1))
        var coefs4 = (v_n &+ SIMD4<UInt32>(repeating: 2)) &<< pShift
        // signs is 0 or 1; `signs &<< 31` produces 0 or 0x8000_0000
        // branchlessly. Inactive lanes produce harmless garbage that
        // the rho-gated stores below skip.
        coefs4 = coefs4 | (signs &<< SIMD4<UInt32>(repeating: 31))

        if r0 != 0 {
            let yi = baseY
            if baseX < width && yi < height {
                coefs[yi * width + baseX] = coefs4[0]
            }
        }
        if r1 != 0 {
            let yi = baseY + 1
            if baseX < width && yi < height {
                coefs[yi * width + baseX] = coefs4[1]
            }
        }
        if r2 != 0 {
            let xi = baseX + 1
            let yi = baseY
            if xi < width && yi < height {
                coefs[yi * width + xi] = coefs4[2]
            }
        }
        if r3 != 0 {
            let xi = baseX + 1
            let yi = baseY + 1
            if xi < width && yi < height {
                coefs[yi * width + xi] = coefs4[3]
            }
        }
    }

    /// **v7.3.0 Phase 3c — bottom-row-only `recoverEQ`.**
    ///
    /// Derive e_q for the bottom-row samples of a quad (in-quad
    /// indices 1 and 3) from the reconstructed coefficients placed
    /// in `coefs`. Returns `(eQ_pos1, eQ_pos3)`.
    ///
    /// Replaces the previous `recoverEQ -> (Int, Int, Int, Int)`
    /// helper that computed all four positions but whose callers
    /// only ever read indices 1 and 3 (the bottom-row eQ values
    /// feed the `eVal` bookkeeping for the next decoding row;
    /// indices 0 and 2 — top-row — were computed and immediately
    /// discarded).
    ///
    /// On DX 4x4 the per-decode call count is ~1.2 M; the per-call
    /// savings come from skipping two of the four iterations
    /// (the bit-test + offset-derivation + bounds-check + work for
    /// indices 0 and 2). Bit-identical to the previous helper at
    /// the consumed-output level (callers read only `.1`/`.3`).
    @inline(__always)
    func recoverEQBottomRow(rho: Int, baseX: Int, baseY: Int)
        -> (Int, Int)
    {
        // v7.3.0 Phase 3d — rho=0 fast path. Both bottom-row positions
        // (1 and 3) check rho bits 1 and 3; if rho == 0 both are
        // unset and the function returns (0, 0). Skip both bit-tests
        // and bounds-checks in this case.
        if rho == 0 { return (0, 0) }
        // Position 1: in-quad (col=0, row=1) → (baseX, baseY+1)
        var eQ1: Int = 0
        if (rho >> 1) & 1 != 0 {
            let yi = baseY + 1
            if baseX < width && yi < height {
                let mag = coefs[yi * width + baseX] & 0x7FFF_FFFF
                // Invert (v_n + 2) << (p - 1). Ignoring sign:
                //   v_n + 2 = mag >> (p - 1)
                //   v_n = (mag >> (p-1)) - 2
                // Then eQ = 32 - leadingZeroBits(v_n | 1), matching
                // the encoder's `2μ_p - 1` convention.
                let v_n = (mag >> (p &- 1)) &- 2
                let twoMuMinusOne = v_n | 1
                eQ1 = 32 - twoMuMinusOne.leadingZeroBitCount
            }
        }
        // Position 3: in-quad (col=1, row=1) → (baseX+1, baseY+1)
        var eQ3: Int = 0
        if (rho >> 3) & 1 != 0 {
            let xi = baseX + 1
            let yi = baseY + 1
            if xi < width && yi < height {
                let mag = coefs[yi * width + xi] & 0x7FFF_FFFF
                let v_n = (mag >> (p &- 1)) &- 2
                let twoMuMinusOne = v_n | 1
                eQ3 = 32 - twoMuMinusOne.leadingZeroBitCount
            }
        }
        return (eQ1, eQ3)
    }
}

public enum HTBlockDecoderConformantError: Error {
    case malformedBlock
}

/// **v7.4 VLC refill gate.** Default initially `false` — the
/// scalar reference is the v7.3 production path; tests can flip
/// to `true` to enable the SWAR-batched alternate path. Default
/// flips to `true` only when DX in-process A/B measures ≥ 3 ms
/// improvement (per v7.4 acceptance criterion) — see
/// `V740NeonVlcRefillDXWallBenchmark` and
/// `V7_4_0_PHASE_3_FINDING.md`.
public enum VLCReverseReaderTesting {
    nonisolated(unsafe) public static var batchedRefillEnabled: Bool = false

    /// v10.1-research Phase D1 parity hook. Drives the (fileprivate)
    /// `VLCReverseReader` with the scalar refill path against a fixed
    /// read plan and returns the produced 64-bit values. Used by
    /// `V10_1_VLCParityTests` to compare against the C scalar port
    /// in `Sources/J2KCodecNEON/dcmj2knhd_vlc.c`.
    public static func runScalarReadPlan(
        bytes: [UInt8], scup: Int, widths: [Int]
    ) -> [UInt64] {
        let prev = batchedRefillEnabled
        batchedRefillEnabled = false
        defer { batchedRefillEnabled = prev }
        var reader = VLCReverseReader(melVlcBytes: bytes, scup: scup)
        var out: [UInt64] = []
        out.reserveCapacity(widths.count)
        for w in widths {
            out.append(reader.read(count: w))
        }
        return out
    }

    /// As `runScalarReadPlan` but also wires in `peek` and `consume`
    /// in the alternating pattern the real decoder uses:
    ///   peek(maxBits) → use the result to derive `cwd_len` →
    ///   consume(cwd_len).
    /// Caller supplies the (maxBits, consumeBits) pair sequence.
    public static func runScalarPeekConsumePlan(
        bytes: [UInt8], scup: Int, pairs: [(Int, Int)]
    ) -> [UInt64] {
        let prev = batchedRefillEnabled
        batchedRefillEnabled = false
        defer { batchedRefillEnabled = prev }
        var reader = VLCReverseReader(melVlcBytes: bytes, scup: scup)
        var out: [UInt64] = []
        out.reserveCapacity(pairs.count)
        for (peekBits, consumeBits) in pairs {
            out.append(reader.peek(maxBits: peekBits))
            reader.consume(count: consumeBits)
        }
        return out
    }
}

/// Forward bit reader over the reverse VLC stream. Reads LSB-first
/// from `melVlcBytes[scup - 2]`'s high nibble, then through earlier
/// bytes. Skips the last byte (which holds Scup's high 8 bits).
fileprivate struct VLCReverseReader {
    private let melVlcBytes: ArraySlice<UInt8>
    private let bytesStart: Int
    private let scup: Int
    private var byteIdx: Int   // position relative to bytesStart, may be -1 once exhausted
    private var tmp: UInt64 = 0
    private var bits: Int = 0
    private var unstuff: Bool = false

    init(melVlcBytes: ArraySlice<UInt8>, scup: Int) {
        self.melVlcBytes = melVlcBytes
        self.bytesStart = melVlcBytes.startIndex
        self.scup = scup
        self.byteIdx = scup - 2
        if byteIdx >= 0 {
            let b = melVlcBytes[bytesStart + byteIdx]
            let highNibble = UInt64(b >> 4)
            let t = ((highNibble & 0x7) == 0x7) ? UInt64(1) : UInt64(0)
            let val = highNibble & (0xF >> t)
            tmp = val
            bits = Int(4 - t)
            unstuff = val > 0x8
            byteIdx -= 1
        }
    }

    init(melVlcBytes: [UInt8], scup: Int) {
        self.init(melVlcBytes: melVlcBytes[...], scup: scup)
    }

    /// Refill dispatcher. Routes to `refillBatched` (v7.4 SWAR
    /// prototype) or `refillScalar` (v7.3 production) per the
    /// `VLCReverseReaderTesting.batchedRefillEnabled` flag.
    @inline(__always)
    mutating func refill() {
        if VLCReverseReaderTesting.batchedRefillEnabled {
            refillBatched()
        } else {
            refillScalar()
        }
    }

    /// **Scalar reference path** — v7.3.0 production VLC refill.
    /// Reverse-byte-iteration with per-byte unstuff handling
    /// (FF-stuff rule: drop bit 7 only when prior byte was > 0x8F
    /// AND this byte's low 7 bits are all ones).
    @inline(__always)
    mutating func refillScalar() {
        while bits <= 32 {
            let byte: UInt8
            if byteIdx >= 0 {
                byte = melVlcBytes[bytesStart + byteIdx]
                byteIdx -= 1
            } else {
                byte = 0
            }
            // FF-stuff rule: drop bit 7 only when prior byte was
            // > 0x8F AND this byte's low 7 bits are all ones
            // (i.e. val is 0x7F or 0xFF). Mirrors OpenJPH's
            // `rev_read8` precisely — see ojph_block_decoder64.cpp:322.
            let t: Int = (unstuff && (Int(byte) & 0x7F) == 0x7F) ? 1 : 0
            let dBits = 8 - t
            let mask: UInt8 = (t == 1) ? 0x7F : 0xFF
            let value = UInt64(byte & mask)
            tmp |= value << bits
            bits += dBits
            unstuff = (byte > 0x8F)
        }
    }

    /// **v7.4 SWAR-batched VLC refill prototype.** Reverse-byte
    /// iteration in 4-byte batches. Mirrors Phase 2's MagSgn shape
    /// but with VLC-specific stuff semantics:
    ///
    ///   - **MagSgn**: stuff fires when previous byte == 0xFF;
    ///     fast-path test is "no byte == 0xFF in batch + no carried
    ///     unstuff" (~99% of batches at corpus 0xFF density of 0.4%).
    ///   - **VLC**: stuff fires when previous byte > 0x8F AND
    ///     current byte's low 7 bits are all 1s (0x7F or 0xFF).
    ///     Fast-path test is "no byte > 0x8F in batch + no carried
    ///     unstuff" — bytes > 0x8F are 7/16 of the value space, so
    ///     fast-path hit-rate on uniform random data is
    ///     ~(9/16)^4 ≈ 10%. Real VLC bytes may hit higher or lower
    ///     depending on the entropy-stream distribution; the DX A/B
    ///     measures end-to-end reality.
    ///
    /// Bit-exact equivalent of `refillScalar` — the slow-fallback
    /// branch IS the scalar code on those 4 bytes; the fast branch
    /// only fires when the SWAR test guarantees no unstuff applies.
    @inline(__always)
    mutating func refillBatched() {
        // Reverse direction means we need 4 bytes at byteIdx-3 ..
        // byteIdx (decreasing as we consume). Load address = byteIdx-3.
        // After load, the LSB of the UInt32 is memory[byteIdx-3] and
        // the MSB is memory[byteIdx]. Byte-swap so byte 0 = the byte
        // we'd consume FIRST in the scalar reverse iteration
        // (memory[byteIdx]).
        melVlcBytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            // `withUnsafeBufferPointer` on an ArraySlice yields a
            // pointer at the slice's start (slice-element 0), not at
            // the underlying array's index 0. So `byteIdx` is the
            // correct offset into `base` directly — do NOT add
            // `bytesStart` again here (that would double-offset).
            // 4-byte batched fast path. byteIdx is slice-relative;
            // we need byteIdx >= 3 to load 4 bytes at positions
            // byteIdx-3 .. byteIdx.
            while bits <= 32 && byteIdx >= 3 {
                let raw = UnsafeRawPointer(base.advanced(by: byteIdx - 3))
                    .loadUnaligned(as: UInt32.self)
                // Byte-swap so the first-to-consume byte
                // (memory[byteIdx]) is at lane 0 of `p32`.
                let p32 = raw.byteSwapped
                // SWAR detect: any byte > 0x8F. For each byte b,
                // `(b + 0x70)` carries into the next byte iff b ≥
                // 0x90, which would corrupt adjacent SWAR lanes.
                // Per-lane test: use NEON SIMD compare. Swift's
                // SIMD4<UInt8> .> is a single NEON instruction.
                let bytes = SIMD4<UInt8>(
                    UInt8(p32 & 0xFF),
                    UInt8((p32 >> 8) & 0xFF),
                    UInt8((p32 >> 16) & 0xFF),
                    UInt8((p32 >> 24) & 0xFF))
                let gt = bytes .> SIMD4<UInt8>(repeating: 0x8F)
                let anyOver8F = any(gt)

                if !anyOver8F && !unstuff {
                    // Fast path — none of the 4 bytes are > 0x8F
                    // and no unstuff carried in. Each byte
                    // contributes its full 8 bits with no masking.
                    tmp |= UInt64(p32) << bits
                    bits += 32
                    byteIdx -= 4
                    // unstuff = (last consumed byte > 0x8F) =
                    // (byte at byteIdx-3 in original index, which
                    // is bytes[3]) > 0x8F. Since we tested all 4
                    // bytes ≤ 0x8F, the new unstuff = false.
                    // (left as-is — `unstuff` is already false on
                    // entry to this branch)
                } else {
                    // Slow fallback — at least one byte > 0x8F or
                    // carried unstuff. Process byte-by-byte (same
                    // as scalar). Process exactly 4 bytes from
                    // this batch, then re-check loop condition.
                    var k = 0
                    while k < 4 {
                        let byte = base[byteIdx]
                        byteIdx -= 1
                        let t: Int = (unstuff && (Int(byte) & 0x7F) == 0x7F) ? 1 : 0
                        let dBits = 8 - t
                        let mask: UInt8 = (t == 1) ? 0x7F : 0xFF
                        tmp |= UInt64(byte & mask) << bits
                        bits += dBits
                        unstuff = (byte > 0x8F)
                        k += 1
                        if bits > 32 { break }
                    }
                }
            }
        }
        // Tail: byte-by-byte (incl. byteIdx < 3 stream-end + the
        // 0-padding loop). Identical to scalar.
        while bits <= 32 {
            let byte: UInt8
            if byteIdx >= 0 {
                byte = melVlcBytes[bytesStart + byteIdx]
                byteIdx -= 1
            } else {
                byte = 0
            }
            let t: Int = (unstuff && (Int(byte) & 0x7F) == 0x7F) ? 1 : 0
            let dBits = 8 - t
            let mask: UInt8 = (t == 1) ? 0x7F : 0xFF
            let value = UInt64(byte & mask)
            tmp |= value << bits
            bits += dBits
            unstuff = (byte > 0x8F)
        }
    }

    @inline(__always)
    mutating func peek(maxBits: Int) -> UInt64 {
        if bits < maxBits { refill() }
        let m: UInt64 = (maxBits >= 64) ? ~UInt64(0) : ((UInt64(1) << maxBits) - 1)
        return tmp & m
    }

    @inline(__always)
    mutating func read(count: Int) -> UInt64 {
        if bits < count { refill() }
        let m: UInt64 = (count >= 64) ? ~UInt64(0) : ((UInt64(1) << count) - 1)
        let v = tmp & m
        tmp >>= count
        bits -= count
        return v
    }

    /// **v7.3.0 Phase 3e — consume-only.** Advance past `count` bits
    /// that the caller has already inspected via a prior `peek`. No
    /// bounds-check on `bits >= count` because peek already brought
    /// us up to ≥ maxBits, and `count` (= cwd_len from the VLC
    /// lookup) is always ≤ peek's `maxBits`. Discards the value.
    @inline(__always)
    mutating func consume(count: Int) {
        tmp >>= count
        bits -= count
    }
}
