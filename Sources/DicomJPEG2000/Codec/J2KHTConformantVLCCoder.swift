// J2KHTVLCCoderConformant.swift
// ISO/IEC 15444-15 cleanup-pass VLC helpers (codebook lookup + UVLC).
//
// The cleanup pass emits one codeword per 4-sample quad into a
// reverse-ordered byte stream stored at the end of the block. Each
// codeword comes from the `vlc_tbl0` / `vlc_tbl1` lookup indexed by
// `(c_q << 8) | (rho << 4) | emb`; the 16-bit entry packs
// `(cwd << 8) | (cwd_len << 4) | e_k`.
//
// In addition to the quad codeword, the u-value (magnitude-range
// offset for the quad) is encoded with the 75-entry UVLC codebook:
// a short unary prefix, a 5-bit suffix, and an optional 4-bit
// extension for the largest values.
//
// This file provides the low-level codebook primitives used by the
// block-level cleanup-pass orchestrator (wired in M5).

import Foundation

/// Cleanup-pass VLC primitives over the reverse bit emitter. Two
/// table flavours: `initialLine == true` picks `vlcTable0Conformant` for
/// the first row of quads in a codeblock; subsequent rows use
/// `vlcTable1Conformant`.
public enum HTVLCCoderConformant {

    /// Looks up the cleanup-pass codeword for one quad. Returns
    /// `(cwd, cwdLen, e_k)` where `cwd` holds the `cwdLen` bits to
    /// emit, LSB-first, into the reverse VLC stream. `e_k` gives the
    /// epsilon mask that the caller XORs against its known epsilon
    /// bits to derive magnitude refinement positions (used later in
    /// the MagSgn pass).
    ///
    /// The `emb` argument is the embedded-epsilon nibble; when
    /// `u_off == 0` it MUST be `0`, otherwise the low 4 bits of the
    /// epsilon mask for the quad.
    public static func lookupQuad(
        initialLine: Bool,
        c_q: Int,
        rho: Int,
        emb: Int
    ) -> (cwd: Int, cwdLen: Int, e_k: Int) {
        precondition((0..<8).contains(c_q), "c_q out of range")
        precondition((0..<16).contains(rho), "rho out of range")
        precondition((0..<16).contains(emb), "emb out of range")
        let tbl = initialLine ? vlcTable0Conformant : vlcTable1Conformant
        let entry = Int(tbl[(c_q << 8) | (rho << 4) | emb])
        return (cwd: entry >> 8, cwdLen: (entry >> 4) & 0x7, e_k: entry & 0xF)
    }

    /// Emit the cleanup-pass codeword for one quad into the reverse
    /// bit emitter.
    public static func encodeQuad(
        initialLine: Bool,
        c_q: Int,
        rho: Int,
        emb: Int,
        into emitter: inout HTReverseBitEmitterConformant
    ) {
        let (cwd, cwdLen, _) = lookupQuad(
            initialLine: initialLine, c_q: c_q, rho: rho, emb: emb)
        emitter.encode(codeword: cwd, count: cwdLen)
    }

    /// Emit one u-value (magnitude-range offset) for a quad into the
    /// reverse bit emitter, using the 75-entry UVLC codebook.
    ///
    /// U values encode as:
    /// - `u == 0`: nothing emitted (pre_len == 0).
    /// - `u in 1...4`: 1–3 bit unary prefix, up to 1 suffix bit.
    /// - `u in 5...32`: 3-bit prefix `000` + 5-bit suffix.
    /// - `u in 33...74`: same as above + 4-bit extension.
    public static func encodeUVLC(
        u: Int,
        into emitter: inout HTReverseBitEmitterConformant
    ) {
        precondition((0..<75).contains(u), "u out of range for UVLC")
        let entry = uvlcTableConformant[u]
        if entry.preLen > 0 {
            emitter.encode(codeword: Int(entry.pre), count: Int(entry.preLen))
        }
        if entry.sufLen > 0 {
            emitter.encode(codeword: Int(entry.suf), count: Int(entry.sufLen))
        }
        if entry.extLen > 0 {
            emitter.encode(codeword: Int(entry.ext), count: Int(entry.extLen))
        }
    }
}
