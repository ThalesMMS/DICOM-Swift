// dcmj2knhd_vlc.c — scalar C port of VLCReverseReader (Swift fileprivate
// struct in Sources/J2KCodec/J2KHTConformantBlockDecoder.swift
// lines 692-899). Mirrors `refillScalar` (lines 738-760), the
// production path on v9.5.2.
//
// Forward bit reader over the REVERSE VLC stream:
//   - first read = high nibble of bytes[scup - 2] (with possible
//     unstuff of the top bit if (b >> 4) > 0x8)
//   - subsequent bytes consumed in decreasing index order
//   - when byte_idx drops below 0, stream is exhausted and zero bytes
//     are fed (unlike MagSgn/MEL which pad with 0xFF)
//
// FF-stuff rule:
//   prior byte > 0x8F AND current byte's low 7 bits all 1
//   (i.e. value == 0x7F or 0xFF) → drop bit 7 of current byte

#include "j2knhd.h"

void dcmj2knhd_vlc_init(dcmj2knhd_vlc_t *dec,
                     const uint8_t *bytes,
                     size_t bytes_len,
                     int32_t scup) {
    dec->bytes = bytes;
    dec->bytes_len = bytes_len;
    dec->scup = scup;
    dec->tmp = 0;
    dec->bits = 0;
    dec->unstuff = false;
    dec->byte_idx = scup - 2;
    if (dec->byte_idx >= 0 && (size_t)dec->byte_idx < bytes_len) {
        uint8_t b = bytes[dec->byte_idx];
        uint64_t high_nibble = (uint64_t)(b >> 4);
        // t = 1 if the top 3 bits of the nibble are 111 (i.e. nibble
        // value 7 — same shape as Swift's
        // ((highNibble & 0x7) == 0x7) ? 1 : 0).
        int t = ((high_nibble & 0x7) == 0x7) ? 1 : 0;
        uint64_t val = high_nibble & ((uint64_t)0xF >> t);
        dec->tmp = val;
        dec->bits = 4 - t;
        dec->unstuff = (val > 0x8);
        dec->byte_idx -= 1;
    }
}

static inline void dcmj2knhd_vlc_refill(dcmj2knhd_vlc_t *dec) {
    while (dec->bits <= 32) {
        uint8_t byte;
        if (dec->byte_idx >= 0 && (size_t)dec->byte_idx < dec->bytes_len) {
            byte = dec->bytes[dec->byte_idx];
            dec->byte_idx -= 1;
        } else {
            // Stream exhausted: pad with zero bytes (matches Swift
            // refillScalar lines 745-747 — `byte = 0` not 0xFF).
            byte = 0;
        }
        // FF-stuff rule: drop bit 7 only when prior byte was > 0x8F
        // AND this byte's low 7 bits are all ones (val is 0x7F or
        // 0xFF). Mirrors Swift refillScalar lines 752-755.
        int t = (dec->unstuff && ((int)byte & 0x7F) == 0x7F) ? 1 : 0;
        int d_bits = 8 - t;
        uint8_t mask = (t == 1) ? 0x7F : 0xFF;
        uint64_t value = (uint64_t)(byte & mask);
        dec->tmp |= value << dec->bits;
        dec->bits += d_bits;
        dec->unstuff = (byte > 0x8F);
    }
}

uint64_t dcmj2knhd_vlc_peek(dcmj2knhd_vlc_t *dec, int max_bits) {
    if (dec->bits < max_bits) {
        dcmj2knhd_vlc_refill(dec);
    }
    uint64_t mask = (max_bits >= 64)
        ? ~(uint64_t)0
        : (((uint64_t)1 << max_bits) - 1);
    return dec->tmp & mask;
}

void dcmj2knhd_vlc_consume(dcmj2knhd_vlc_t *dec, int count) {
    dec->tmp >>= count;
    dec->bits -= count;
}

uint64_t dcmj2knhd_vlc_read(dcmj2knhd_vlc_t *dec, int count) {
    if (dec->bits < count) {
        dcmj2knhd_vlc_refill(dec);
    }
    uint64_t mask = (count >= 64)
        ? ~(uint64_t)0
        : (((uint64_t)1 << count) - 1);
    uint64_t v = dec->tmp & mask;
    dec->tmp >>= count;
    dec->bits -= count;
    return v;
}
