// dcmj2knhd_magsgn.c — scalar + 4-byte SWAR C ports of HTMagSgnDecoderConformant.
// v10.2-research Phase D1.5-A.
//
// Two refill implementations, bit-exact equivalent by construction:
//   * dcmj2knhd_magsgn_refill_scalar — byte-at-a-time reference (v10.1).
//   * dcmj2knhd_magsgn_refill_swar4  — 4-byte unaligned uint32 load with SWAR
//                                   FF-detect (mirrors Swift v7.4
//                                   `refillBatched`).
//
// Selected at init time per `swar` flag (false = scalar, true = SWAR-4).
// Mirrors Swift's `useV74Batched` cached-selector pattern so the per-call
// branch is predictable and the static flag is read once per decoder.

#include <string.h>

#include "j2knhd.h"

void dcmj2knhd_magsgn_init(dcmj2knhd_magsgn_t *dec,
                        const uint8_t *bytes,
                        size_t bytes_len) {
    dec->bytes = bytes;
    dec->bytes_len = bytes_len;
    dec->read_index = 0;
    dec->tmp = 0;
    dec->bits = 0;
    dec->unstuff = false;
    dec->use_swar4 = false;
}

void dcmj2knhd_magsgn_init_swar(dcmj2knhd_magsgn_t *dec,
                             const uint8_t *bytes,
                             size_t bytes_len) {
    dcmj2knhd_magsgn_init(dec, bytes, bytes_len);
    dec->use_swar4 = true;
}

// Scalar refill (v10.1 path). Bit-exact mirror of Swift refillScalar.
static inline void dcmj2knhd_magsgn_refill_scalar(dcmj2knhd_magsgn_t *dec) {
    while (dec->bits <= 32 && dec->read_index < dec->bytes_len) {
        uint8_t byte = dec->bytes[dec->read_index];
        dec->read_index += 1;
        int d_bits = 8 - (dec->unstuff ? 1 : 0);
        uint8_t mask = (uint8_t)0xFF >> (dec->unstuff ? 1 : 0);
        dec->tmp |= ((uint64_t)(byte & mask)) << dec->bits;
        dec->bits += d_bits;
        dec->unstuff = (byte == 0xFF);
    }
    while (dec->bits <= 32) {
        uint8_t byte = 0xFF;
        int d_bits = 8 - (dec->unstuff ? 1 : 0);
        uint8_t mask = (uint8_t)0xFF >> (dec->unstuff ? 1 : 0);
        dec->tmp |= ((uint64_t)(byte & mask)) << dec->bits;
        dec->bits += d_bits;
        dec->unstuff = (byte == 0xFF);
    }
}

// 4-byte SWAR refill. Bit-exact mirror of Swift refillBatched (v7.4).
// SWAR FF-detect:
//   inv     = p32 ^ 0xFFFFFFFF       — each 0xFF lane → 0x00
//   hasZero = (inv − 0x01010101) & ~inv & 0x80808080
//   anyFF   = hasZero != 0
// Fast-path fires when no 0xFF in the 4-byte batch AND no carried
// unstuff; reduces the batch to one unaligned load + one OR-into-tmp.
// Slow-path is the scalar byte loop on those 4 bytes — same arithmetic
// as refill_scalar, so bit-exactness is guaranteed by construction.
static inline void dcmj2knhd_magsgn_refill_swar4(dcmj2knhd_magsgn_t *dec) {
    // Fast/slow batched loop (4 bytes per iteration).
    while (dec->bits <= 32 &&
           dec->read_index + 4 <= dec->bytes_len) {
        uint32_t p32;
        // Unaligned 32-bit load. memcpy is the portable idiom; clang
        // emits a single ldur on ARM64 in release builds.
        memcpy(&p32, dec->bytes + dec->read_index, 4);
        uint32_t inv = p32 ^ 0xFFFFFFFFu;
        uint32_t has_zero = (inv - 0x01010101u) & ~inv & 0x80808080u;
        bool any_ff = has_zero != 0;

        if (!any_ff && !dec->unstuff) {
            // Fast path: all 4 bytes contribute 8 bits each, no unstuff.
            dec->tmp |= ((uint64_t)p32) << dec->bits;
            dec->bits += 32;
            dec->read_index += 4;
            // unstuff stays false (no byte was 0xFF in this batch).
        } else {
            // Slow path: byte-by-byte through the 4 bytes (same body as
            // refill_scalar). Exit early if bits saturates inside the batch.
            int k = 0;
            while (k < 4) {
                uint8_t byte = dec->bytes[dec->read_index];
                dec->read_index += 1;
                int d_bits = 8 - (dec->unstuff ? 1 : 0);
                uint8_t mask = (uint8_t)0xFF >> (dec->unstuff ? 1 : 0);
                dec->tmp |= ((uint64_t)(byte & mask)) << dec->bits;
                dec->bits += d_bits;
                dec->unstuff = (byte == 0xFF);
                k += 1;
                if (dec->bits > 32) break;
            }
        }
    }

    // Tail: byte-at-a-time for the last 0..3 stream bytes.
    while (dec->bits <= 32 && dec->read_index < dec->bytes_len) {
        uint8_t byte = dec->bytes[dec->read_index];
        dec->read_index += 1;
        int d_bits = 8 - (dec->unstuff ? 1 : 0);
        uint8_t mask = (uint8_t)0xFF >> (dec->unstuff ? 1 : 0);
        dec->tmp |= ((uint64_t)(byte & mask)) << dec->bits;
        dec->bits += d_bits;
        dec->unstuff = (byte == 0xFF);
    }

    // End-of-stream 0xFF padding.
    while (dec->bits <= 32) {
        uint8_t byte = 0xFF;
        int d_bits = 8 - (dec->unstuff ? 1 : 0);
        uint8_t mask = (uint8_t)0xFF >> (dec->unstuff ? 1 : 0);
        dec->tmp |= ((uint64_t)(byte & mask)) << dec->bits;
        dec->bits += d_bits;
        dec->unstuff = (byte == 0xFF);
    }
}

uint32_t dcmj2knhd_magsgn_read(dcmj2knhd_magsgn_t *dec, int count) {
    if (dec->bits < count) {
        if (dec->use_swar4) {
            dcmj2knhd_magsgn_refill_swar4(dec);
        } else {
            dcmj2knhd_magsgn_refill_scalar(dec);
        }
    }
    uint64_t mask = (count >= 64) ? ~(uint64_t)0 : (((uint64_t)1 << count) - 1);
    uint32_t v = (uint32_t)(dec->tmp & mask);
    dec->tmp >>= count;
    dec->bits -= count;
    return v;
}
