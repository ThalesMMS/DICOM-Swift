// dcmj2knhd_mel.c — scalar C port of HTMELDecoderConformant.
// v10.1-research Phase D1 Phase 0.
//
// Bit-exact mirror of Sources/J2KCodec/J2KHTConformantMELCoder.swift
// lines 99-186. Variable names track the Swift identifiers so a side-
// by-side diff is straightforward.

#include "j2knhd.h"

// Shared MEL exponent table. MUST match `melExpConformant` in Swift
// (J2KHTConformantMELCoder.swift line 27).
static const int kJ2knhdMelExp[13] = {
    0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5
};

void dcmj2knhd_mel_init(dcmj2knhd_mel_t *dec,
                     const uint8_t *bytes,
                     size_t bytes_len) {
    dec->bytes = bytes;
    dec->bytes_len = bytes_len;
    dec->read_index = 0;
    dec->tmp = 0;
    dec->bits = 0;
    dec->unstuff = false;
    dec->state = 0;
}

// Feed MEL bytes into the bit buffer with FF-unstuffing until at
// least 32 bits are available. Mirrors Swift `refill()` lines 169-185.
static inline void dcmj2knhd_mel_refill(dcmj2knhd_mel_t *dec) {
    while (dec->bits <= 32) {
        uint8_t byte;
        if (dec->read_index < dec->bytes_len) {
            byte = dec->bytes[dec->read_index];
            dec->read_index += 1;
        } else {
            // Post-EOF pad per OpenJPH convention; matches Swift.
            byte = 0xFF;
        }
        int d_bits = 8 - (dec->unstuff ? 1 : 0);
        uint64_t mask = ((uint64_t)1 << d_bits) - 1;
        uint64_t value = (uint64_t)byte & mask;
        dec->tmp |= value << (64 - dec->bits - d_bits);
        dec->bits += d_bits;
        dec->unstuff = (byte == 0xFF);
    }
}

int64_t dcmj2knhd_mel_next_run(dcmj2knhd_mel_t *dec) {
    if (dec->bits < 6) {
        dcmj2knhd_mel_refill(dec);
    }
    int eval = kJ2knhdMelExp[dec->state];
    int64_t run;
    if ((dec->tmp & ((uint64_t)1 << 63)) != 0) {
        // 1-bit: threshold consecutive zero events, no terminator.
        run = ((int64_t)1 << eval) - 1;
        if (dec->state + 1 < 12) {
            dec->state = dec->state + 1;
        } else {
            dec->state = 12;
        }
        dec->tmp <<= 1;
        dec->bits -= 1;
        run <<= 1;                  // low bit 0 → "no terminator"
    } else {
        // 0-bit: next `eval` bits give the zero-count; then a `1`.
        if (eval > 0) {
            run = (int64_t)((dec->tmp >> (63 - eval))
                            & (uint64_t)((1 << eval) - 1));
        } else {
            run = 0;
        }
        if (dec->state - 1 > 0) {
            dec->state = dec->state - 1;
        } else {
            dec->state = 0;
        }
        dec->tmp <<= (eval + 1);
        dec->bits -= (eval + 1);
        run = (run << 1) + 1;       // low bit 1 → "terminator"
    }
    return run;
}
