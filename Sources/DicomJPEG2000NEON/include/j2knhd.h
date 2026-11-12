// dcmj2knhd.h — J2K NEON HT Decoder (J2K NHD)
// v10.1-research — symmetric counterpart to dcmj2knhe (HT encoder).
// Phase D1 Phase 0 scope: scalar-only C ports of the per-block decode
// state machines, evaluated against the Swift reference for the
// ≥10% per-block speedup gate before any NEON retrofit.
//
// This first commit ports the MEL state machine only:
//   - Swift reference: `HTMELDecoderConformant` in
//     Sources/J2KCodec/J2KHTConformantMELCoder.swift
//   - Parity oracle: V10_1_MELParityTests (random byte streams +
//     dictionary edge cases)
//
// Bit-exact contract: given any byte sequence, the C decoder must
// emit the same packed run values in the same order as the Swift
// decoder, up to and including the post-EOF 0xFF pad behaviour
// (OpenJPH convention).
//
// Memory model: caller-owned input buffer. The decoder holds no
// heap-allocated state; callers stack-allocate `dcmj2knhd_mel_t` and
// pass it into the entry points.

#ifndef J2KNHD_H
#define J2KNHD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// MEL decoder state. Caller-owned. Lifetime is bounded by the input
/// byte buffer pointed to by `bytes`.
typedef struct dcmj2knhd_mel {
    const uint8_t *bytes;   ///< caller-owned input buffer
    size_t bytes_len;       ///< length of `bytes` in bytes
    size_t read_index;      ///< absolute byte position in `bytes`
    uint64_t tmp;           ///< 64-bit bit buffer, MSB-first consumption
    int bits;               ///< valid bits currently in `tmp` (top-aligned)
    bool unstuff;           ///< if true, next byte's high bit is reserved
    int state;              ///< MEL state machine index, [0, 12]
} dcmj2knhd_mel_t;

/// Initialise a MEL decoder over `bytes[0..bytes_len)`.
/// Pre: `dec != NULL`, `bytes != NULL || bytes_len == 0`.
/// Bit-exact equivalent of `HTMELDecoderConformant(bytes:)`.
void dcmj2knhd_mel_init(dcmj2knhd_mel_t *dec,
                     const uint8_t *bytes,
                     size_t bytes_len);

/// Returns the next packed run value. Format matches OpenJPH:
///   - low bit 0 → `run >> 1` zero events, no terminator
///   - low bit 1 → `run >> 1` zero events followed by a `1` event
/// Bit-exact equivalent of `HTMELDecoderConformant.nextRun()`.
int64_t dcmj2knhd_mel_next_run(dcmj2knhd_mel_t *dec);

// ---------------------------------------------------------------------------
// MagSgn forward bit reader.
//
// LSB-first consumption; every byte that follows a 0xFF byte contributes
// only 7 bits (its high bit is a reserved stuff bit). When the byte stream
// is exhausted, 0xFF is fed (matches OpenJPH `frwd_read<X=0xFF>`).
//
// Swift reference: `HTMagSgnDecoderConformant` scalar path in
// Sources/J2KCodec/J2KHTConformantMagSgnCoder.swift lines 191-385.
// (The v7.4 4-byte SWAR + v8.1 8-byte SWAR refill paths are Swift-side
// micro-optimisations that the scalar reference is the canonical truth
// for; the C port ports the scalar path only.)

typedef struct dcmj2knhd_magsgn {
    const uint8_t *bytes;
    size_t bytes_len;
    size_t read_index;
    uint64_t tmp;           ///< 64-bit bit buffer, LSB-first consumption
    int bits;               ///< valid bits in `tmp` (low-aligned)
    bool unstuff;           ///< if true, next byte's high bit is reserved
    bool use_swar4;         ///< v10.2: select between scalar (false) and 4-byte SWAR (true) refill paths; set at init only
} dcmj2knhd_magsgn_t;

/// Initialise a MagSgn decoder over `bytes[0..bytes_len)`. Uses the
/// scalar byte-at-a-time refill path (v10.1 reference).
void dcmj2knhd_magsgn_init(dcmj2knhd_magsgn_t *dec,
                        const uint8_t *bytes,
                        size_t bytes_len);

/// v10.2: initialise a MagSgn decoder routed through the 4-byte SWAR
/// refill path (mirrors Swift v7.4 `refillBatched`). Bit-exact
/// equivalent of the scalar path by construction.
void dcmj2knhd_magsgn_init_swar(dcmj2knhd_magsgn_t *dec,
                             const uint8_t *bytes,
                             size_t bytes_len);

/// Read `count` LSB-first bits from the stream. `count` MUST be in
/// [0, 32]. Bit-exact equivalent of `HTMagSgnDecoderConformant.read(count:)`.
uint32_t dcmj2knhd_magsgn_read(dcmj2knhd_magsgn_t *dec, int count);

// ---------------------------------------------------------------------------
// VLC reverse-byte reader.
//
// LSB-first bit accumulator over a byte buffer consumed in REVERSE.
// The first byte read is `bytes[scup - 2]`, of which only the high
// nibble (with possible top-bit unstuff) is consumed. Subsequent bytes
// are `bytes[scup - 3]`, `bytes[scup - 4]`, etc. Once byte_idx drops
// below 0 the stream is exhausted; further bits are 0 (unlike MEL /
// MagSgn which pad with 0xFF).
//
// FF-stuff rule (different from MagSgn!): drop bit 7 only when the
// PRIOR byte was > 0x8F AND the current byte's low 7 bits are all 1
// (i.e. value is 0x7F or 0xFF). After consumption, `unstuff` is set
// from `byte > 0x8F`.
//
// Swift reference: `VLCReverseReader` (fileprivate struct) in
// Sources/J2KCodec/J2KHTConformantBlockDecoder.swift lines 692-899.
// The C port mirrors `refillScalar` (lines 738-760), the production
// path (the v7.4 SWAR `refillBatched` is bit-exact equivalent and
// gated behind the `VLCReverseReaderTesting.batchedRefillEnabled`
// opt-in flag, default false).

typedef struct dcmj2knhd_vlc {
    const uint8_t *bytes;
    size_t bytes_len;
    int32_t scup;
    int32_t byte_idx;       ///< signed; may go negative when stream exhausted
    uint64_t tmp;           ///< 64-bit bit buffer, LSB-first consumption
    int bits;               ///< valid bits in `tmp` (low-aligned)
    bool unstuff;           ///< if true, prior byte was > 0x8F (FF-stuff carry)
} dcmj2knhd_vlc_t;

/// Initialise a VLC reverse-reader. Consumes the high nibble of
/// `bytes[scup - 2]` immediately (mirrors Swift `init(melVlcBytes:scup:)`).
/// Bit-exact equivalent of `VLCReverseReader.init`.
void dcmj2knhd_vlc_init(dcmj2knhd_vlc_t *dec,
                     const uint8_t *bytes,
                     size_t bytes_len,
                     int32_t scup);

/// Returns the low `max_bits` bits of the accumulator without
/// consuming them. `max_bits` MUST be in [0, 64].
/// Bit-exact equivalent of `VLCReverseReader.peek(maxBits:)`.
uint64_t dcmj2knhd_vlc_peek(dcmj2knhd_vlc_t *dec, int max_bits);

/// Consume `count` bits already inspected via a prior peek. Discards
/// the value. Bit-exact equivalent of `VLCReverseReader.consume(count:)`.
void dcmj2knhd_vlc_consume(dcmj2knhd_vlc_t *dec, int count);

/// Read + return `count` low bits (combined peek + consume).
/// Bit-exact equivalent of `VLCReverseReader.read(count:)`.
uint64_t dcmj2knhd_vlc_read(dcmj2knhd_vlc_t *dec, int count);

// ---------------------------------------------------------------------------
// Per-block HT decoder entry point.
//
// Integrated mirror of `HTBlockDecoderConformant.decode` in
// Sources/J2KCodec/J2KHTConformantBlockDecoder.swift. Wires the three
// state machines (MEL, VLC reverse-reader, MagSgn) into the row-dispatch
// state machine and writes reconstructed sign-magnitude coefficients
// into a caller-owned buffer.
//
// Tables are passed in (1024 entries each, UInt16). Swift caller wires
// `vlcDecoderTable0Conformant` / `vlcDecoderTable1Conformant` from
// J2KHTConformantTables.swift via `withUnsafeBufferPointer`.

#define J2KNHD_OK             0
#define J2KNHD_E_MALFORMED   -1   ///< block too small or Scup out of range
#define J2KNHD_E_DIMENSIONS  -2   ///< width / height / missing_msbs out of range

/// Decode an HT-conformant Part-15 codeblock.
///
/// - block / block_len: encoded block bytes (output of HTBlockLayoutConformant.assemble)
/// - width / height: block sample dimensions, each in [1, 64]
/// - missing_msbs: in [0, 29] per T.814 conformance
/// - vlc_table0 / vlc_table1: 1024-entry decoder lookup tables (UInt16 each)
/// - magsgn_use_swar4: when true, MagSgn refill uses v7.4 SWAR; else scalar
/// - coefs_out: caller-owned buffer of width*height uint32 entries, written
///              in row-major order, sign-magnitude (bit 31 = sign, magnitude
///              in bits below p = 30 - missing_msbs)
///
/// Returns J2KNHD_OK or a J2KNHD_E_* negative error code.
int dcmj2knhd_decode_block_ht32(
    const uint8_t *block, size_t block_len,
    uint32_t width, uint32_t height, uint32_t missing_msbs,
    const uint16_t *vlc_table0,
    const uint16_t *vlc_table1,
    bool magsgn_use_swar4,
    uint32_t *coefs_out);

#ifdef __cplusplus
}
#endif

#endif // J2KNHD_H
