// dcmj2knhe.h — J2K NEON HT Encoder (J2K NHE)
// v9.4-research — custom C+NEON tier-1 entropy block encoder for
// JPEG 2000 Part-15 (HT). NOT a port of OpenJPH; designed by us
// applying the v9.3 architectural lessons (caller-owned buffers, no
// global statics, no allocator hits in the hot path). Apple Silicon
// (ARM64 NEON) is the primary target; the scalar fallback also works
// on any C99-supporting toolchain.
//
// Bit-exact equivalent of HTBlockEncoderConformant.encodeLoopGeneric
// in the J2KSwift Swift codebase. Validated against the 500-trial
// random sweep + 6-corpus fixture set in
// Tests/J2KCodecTests/V94NEONHotPathParityTests.swift.

#ifndef J2KNHE_H
#define J2KNHE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bit-exact encoder entry point for the HT cleanup-pass block coder.
/// Sample input convention matches the Swift path:
///   - one `uint32_t` per coefficient in row-major order
///   - bit 31 = sign (1 = negative); bits 0..(30 - missing_msbs) =
///     magnitude
///   - A value of 0 means "zero coefficient, not significant"
///
/// The three Part-15 sub-streams are written into caller-owned buffers
/// via the magsgn_buf, mel_buf, vlc_buf arguments. Each *_len out-
/// param receives the number of bytes written:
///   - magsgn_len: forward MagSgn byte stream length
///   - mel_len:    forward MEL byte stream length
///   - vlc_len:    forward-on-wire VLC byte stream length (matches
///                 HTReverseBitEmitterConformant.finish() output —
///                 the reverse-bit stream produced internally is
///                 already byte-reversed before this return)
///
/// `width` and `height` must be in [1, 64] for v9.4-research. The
/// Swift caller is responsible for routing larger blocks to the
/// existing Swift path.
///
/// `missing_msbs` must be in [0, 29] per T.814 conformance.
///
/// Returns:
///    0 on success
///   -1 if any output buffer overflows its capacity (encoded length
///      exceeds the supplied `*_cap`) — partial output may have been
///      written; caller should treat the result as undefined
///   -2 on invalid input (width/height/missing_msbs out of range)
int dcmj2knhe_encode_block_ht32(
    const uint32_t *coefficients,
    uint32_t width,
    uint32_t height,
    uint32_t missing_msbs,
    uint8_t *magsgn_buf, size_t magsgn_cap, size_t *magsgn_len,
    uint8_t *mel_buf,    size_t mel_cap,    size_t *mel_len,
    uint8_t *vlc_buf,    size_t vlc_cap,    size_t *vlc_len);

/// Returns a static version string identifying the build (e.g.
/// "dcmj2knhe-v9.4-research-scalar" or "dcmj2knhe-v9.4-research-neon").
/// Used by the parity tests + research finding doc for traceability.
const char *dcmj2knhe_version(void);

#ifdef __cplusplus
}
#endif

#endif // J2KNHE_H
