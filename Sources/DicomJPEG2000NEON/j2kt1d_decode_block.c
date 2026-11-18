// j2kt1d_decode_block.c — EBCOT code-block decoder (issue #3078).
//
// Bit-exact port of `BitPlaneDecoder.decode` with ISO run-length position coding
// (Sources/DicomJPEG2000/Codec/J2KBitPlaneCoder.swift), its `MQDecoder` and `RawBypassDecoder`
// (J2KMQCoder.swift) and the context rules of `ContextModeler` (J2KContextModeling.swift).
//
// Layout: one 16-bit flag word per coefficient on a grid padded by one sample on every side, so the neighbours of
// a border coefficient need no test. Low byte: significance of the eight neighbours; bits 8-11: their cardinal
// signs; bits 12-15: the coefficient's own state. A coefficient that becomes significant sets its bits in its
// neighbours' words, so a significance context is one table lookup. The four rows of a stripe column are adjacent,
// so one 64-bit load decides whether a column has anything to code. The bit-plane of each coefficient's last
// significance or refinement is kept beside it, and the midpoint ("half bit") is rebuilt from it at the end.

#include "j2kt1d.h"

#include <string.h>

// --- Tables -------------------------------------------------------------------------------------------------------

// MQ states by context byte (state << 1 | MPS): qe | next context after an MPS << 16 | after an LPS << 24, the
// MPS switch of ISO/IEC 15444-1 Table C.2 folded into the LPS successor.
static const uint32_t j2kt1d_mq_states[94] = {
    0x03025601, 0x02035601, 0x0C043401, 0x0D053401, 0x12061801, 0x13071801,
    0x18080AC1, 0x19090AC1, 0x3A0A0521, 0x3B0B0521, 0x424C0221, 0x434D0221,
    0x0D0E5601, 0x0C0F5601, 0x1C105401, 0x1D115401, 0x1C124801, 0x1D134801,
    0x1C143801, 0x1D153801, 0x22163001, 0x23173001, 0x24182401, 0x25192401,
    0x281A1C01, 0x291B1C01, 0x2A3A1601, 0x2B3B1601, 0x1D1E5601, 0x1C1F5601,
    0x1C205401, 0x1D215401, 0x1E225101, 0x1F235101, 0x20244801, 0x21254801,
    0x22263801, 0x23273801, 0x24283401, 0x25293401, 0x262A3001, 0x272B3001,
    0x262C2801, 0x272D2801, 0x282E2401, 0x292F2401, 0x2A302201, 0x2B312201,
    0x2C321C01, 0x2D331C01, 0x2E341801, 0x2F351801, 0x30361601, 0x31371601,
    0x32381401, 0x33391401, 0x343A1201, 0x353B1201, 0x363C1101, 0x373D1101,
    0x383E0AC1, 0x393F0AC1, 0x3A4009C1, 0x3B4109C1, 0x3C4208A1, 0x3D4308A1,
    0x3E440521, 0x3F450521, 0x40460441, 0x41470441, 0x424802A1, 0x434902A1,
    0x444A0221, 0x454B0221, 0x464C0141, 0x474D0141, 0x484E0111, 0x494F0111,
    0x4A500085, 0x4B510085, 0x4C520049, 0x4D530049, 0x4E540025, 0x4F550025,
    0x50560015, 0x51570015, 0x52580009, 0x53590009, 0x545A0005, 0x555B0005,
    0x565A0001, 0x575B0001, 0x5C5C5601, 0x5D5D5601,
};

// Significance contexts by neighbour byte (bit 0 NW, 1 N, 2 NE, 3 W, 4 E, 5 SW, 6 S, 7 SE), from the h/v/d rules of
// `ContextModeler.significanceContext{LH,HL,HH}Value`.
static const uint8_t j2kt1d_sig_lh[256] = {
     0,  1,  3,  3,  1,  2,  3,  3,  5,  6,  7,  7,  6,  6,  7,  7,
     5,  6,  7,  7,  6,  6,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     1,  2,  3,  3,  2,  2,  3,  3,  6,  6,  7,  7,  6,  6,  7,  7,
     6,  6,  7,  7,  6,  6,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     3,  3,  4,  4,  3,  3,  4,  4,  7,  7,  7,  7,  7,  7,  7,  7,
     7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     3,  3,  4,  4,  3,  3,  4,  4,  7,  7,  7,  7,  7,  7,  7,  7,
     7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     1,  2,  3,  3,  2,  2,  3,  3,  6,  6,  7,  7,  6,  6,  7,  7,
     6,  6,  7,  7,  6,  6,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     2,  2,  3,  3,  2,  2,  3,  3,  6,  6,  7,  7,  6,  6,  7,  7,
     6,  6,  7,  7,  6,  6,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     3,  3,  4,  4,  3,  3,  4,  4,  7,  7,  7,  7,  7,  7,  7,  7,
     7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
     3,  3,  4,  4,  3,  3,  4,  4,  7,  7,  7,  7,  7,  7,  7,  7,
     7,  7,  7,  7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,
};
static const uint8_t j2kt1d_sig_hl[256] = {
     0,  1,  5,  6,  1,  2,  6,  6,  3,  3,  7,  7,  3,  3,  7,  7,
     3,  3,  7,  7,  3,  3,  7,  7,  4,  4,  7,  7,  4,  4,  7,  7,
     1,  2,  6,  6,  2,  2,  6,  6,  3,  3,  7,  7,  3,  3,  7,  7,
     3,  3,  7,  7,  3,  3,  7,  7,  4,  4,  7,  7,  4,  4,  7,  7,
     5,  6,  8,  8,  6,  6,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     6,  6,  8,  8,  6,  6,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     1,  2,  6,  6,  2,  2,  6,  6,  3,  3,  7,  7,  3,  3,  7,  7,
     3,  3,  7,  7,  3,  3,  7,  7,  4,  4,  7,  7,  4,  4,  7,  7,
     2,  2,  6,  6,  2,  2,  6,  6,  3,  3,  7,  7,  3,  3,  7,  7,
     3,  3,  7,  7,  3,  3,  7,  7,  4,  4,  7,  7,  4,  4,  7,  7,
     6,  6,  8,  8,  6,  6,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     6,  6,  8,  8,  6,  6,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
     7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,  7,  7,  8,  8,
};
static const uint8_t j2kt1d_sig_hh[256] = {
     0,  3,  1,  4,  3,  6,  4,  7,  1,  4,  2,  5,  4,  7,  5,  7,
     1,  4,  2,  5,  4,  7,  5,  7,  2,  5,  2,  5,  5,  7,  5,  7,
     3,  6,  4,  7,  6,  8,  7,  8,  4,  7,  5,  7,  7,  8,  7,  8,
     4,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     1,  4,  2,  5,  4,  7,  5,  7,  2,  5,  2,  5,  5,  7,  5,  7,
     2,  5,  2,  5,  5,  7,  5,  7,  2,  5,  2,  5,  5,  7,  5,  7,
     4,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     5,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     3,  6,  4,  7,  6,  8,  7,  8,  4,  7,  5,  7,  7,  8,  7,  8,
     4,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     6,  8,  7,  8,  8,  8,  8,  8,  7,  8,  7,  8,  8,  8,  8,  8,
     7,  8,  7,  8,  8,  8,  8,  8,  7,  8,  7,  8,  8,  8,  8,  8,
     4,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     5,  7,  5,  7,  7,  8,  7,  8,  5,  7,  5,  7,  7,  8,  7,  8,
     7,  8,  7,  8,  8,  8,  8,  8,  7,  8,  7,  8,  8,  8,  8,  8,
     7,  8,  7,  8,  8,  8,  8,  8,  7,  8,  7,  8,  8,  8,  8,  8,
};
// Sign contexts (`ContextModeler.signContextLUT`: context << 1 | xor bit) by sign index: bit 0 N, 1 W, 2 E, 3 S
// significant; bit 4 N, 5 W, 6 E, 7 S negative.
static const uint8_t j2kt1d_sign[256] = {
    18, 20, 24, 26, 24, 26, 24, 26, 20, 20, 26, 26, 26, 26, 26, 26,
    18, 21, 24, 22, 24, 22, 24, 22, 20, 18, 26, 24, 26, 24, 26, 24,
    18, 20, 25, 23, 24, 26, 18, 20, 20, 20, 23, 23, 26, 26, 20, 20,
    18, 21, 25, 27, 24, 22, 18, 21, 20, 18, 23, 25, 26, 24, 20, 18,
    18, 20, 24, 26, 25, 23, 18, 20, 20, 20, 26, 26, 23, 23, 20, 20,
    18, 21, 24, 22, 25, 27, 18, 21, 20, 18, 26, 24, 23, 25, 20, 18,
    18, 20, 25, 23, 25, 23, 25, 23, 20, 20, 23, 23, 23, 23, 23, 23,
    18, 21, 25, 27, 25, 27, 25, 27, 20, 18, 23, 25, 23, 25, 23, 25,
    18, 20, 24, 26, 24, 26, 24, 26, 21, 18, 22, 24, 22, 24, 22, 24,
    18, 21, 24, 22, 24, 22, 24, 22, 21, 21, 22, 22, 22, 22, 22, 22,
    18, 20, 25, 23, 24, 26, 18, 20, 21, 18, 27, 25, 22, 24, 21, 18,
    18, 21, 25, 27, 24, 22, 18, 21, 21, 21, 27, 27, 22, 22, 21, 21,
    18, 20, 24, 26, 25, 23, 18, 20, 21, 18, 22, 24, 27, 25, 21, 18,
    18, 21, 24, 22, 25, 27, 18, 21, 21, 21, 22, 22, 27, 27, 21, 21,
    18, 20, 25, 23, 25, 23, 25, 23, 21, 18, 27, 25, 27, 25, 27, 25,
    18, 21, 25, 27, 25, 27, 25, 27, 21, 21, 27, 27, 27, 27, 27, 27,
};

// --- Flag word ----------------------------------------------------------------------------------------------------

#define F_SIG_NW 0x0001u
#define F_SIG_N 0x0002u
#define F_SIG_NE 0x0004u
#define F_SIG_W 0x0008u
#define F_SIG_E 0x0010u
#define F_SIG_SW 0x0020u
#define F_SIG_S 0x0040u
#define F_SIG_SE 0x0080u
#define F_NEG_N 0x0100u
#define F_NEG_W 0x0200u
#define F_NEG_E 0x0400u
#define F_NEG_S 0x0800u
#define F_SIG 0x1000u     // significant
#define F_VISIT 0x2000u   // coded in this bit-plane's significance-propagation pass
#define F_REFINED 0x4000u // refined at least once
#define F_NEG 0x8000u     // negative
#define F_NEIGHBOURS 0x00FFu
#define F_SOUTH (F_SIG_SW | F_SIG_S | F_SIG_SE | F_NEG_S)

// The four rows of a stripe column are four consecutive flag words, so one 64-bit load tests them together.
#define LANES(f) (0x0001000100010001ull * (uint64_t)(f))

#define J2KT1D_INLINE static inline __attribute__((always_inline))

// --- MQ and raw decoders ------------------------------------------------------------------------------------------

/// An MQ context: its state index << 1 | its MPS.
typedef uint8_t j2kt1d_cx_t;

typedef struct {
    const uint8_t *p;
    int64_t count;
    int64_t pos;
    int64_t over_read;
    uint32_t a;
    uint32_t c;
    int32_t ct;
    uint8_t buffer;
} j2kt1d_mq_t;

typedef struct {
    const uint8_t *p;
    int64_t count;
    int64_t pos;
    uint32_t c;
    int32_t ct;
} j2kt1d_raw_t;

J2KT1D_INLINE uint8_t mq_read(j2kt1d_mq_t *m) {
    if (m->pos < m->count) {
        return m->p[m->pos++];
    }
    m->over_read++;
    return 0xFF;
}

// `MQDecoder.fillC`: a byte after 0xFF above 0x8F is a marker; it is not consumed and ones are fed instead.
J2KT1D_INLINE void mq_fill(j2kt1d_mq_t *m) {
    if (m->buffer == 0xFF) {
        int64_t prev = m->pos;
        uint8_t next = mq_read(m);
        if (next > 0x8F) {
            if (m->pos > prev) {
                m->pos -= 1;
            }
            m->c += 0xFF00u;
            m->ct = 8;
        } else {
            m->c += (uint32_t)next << 9;
            m->buffer = next;
            m->ct = 7;
        }
    } else {
        m->buffer = mq_read(m);
        m->c += (uint32_t)m->buffer << 8;
        m->ct = 8;
    }
}

static void mq_init(j2kt1d_mq_t *m, const uint8_t *p, int64_t count) {
    m->p = p;
    m->count = count;
    m->pos = 0;
    m->over_read = 0;
    m->a = 0x8000u;
    m->c = 0;
    m->ct = 0;
    m->buffer = mq_read(m);
    m->c = (uint32_t)m->buffer << 16;
    mq_fill(m);
    m->c <<= 7;
    m->ct -= 7;
    m->a = 0x8000u;
}

J2KT1D_INLINE void mq_renormalize(j2kt1d_mq_t *m) {
    if (m->a >= 0x8000u) {
        return;
    }
    int32_t shifts = __builtin_clz(m->a) - 16;
    if (shifts > 0 && m->ct >= shifts) {
        m->a <<= shifts;
        m->c <<= shifts;
        m->ct -= shifts;
    } else {
        do {
            if (m->ct == 0) {
                mq_fill(m);
            }
            m->a <<= 1;
            m->c <<= 1;
            m->ct -= 1;
        } while (m->a < 0x8000u);
    }
}

// `MQDecoder.decode(context:)` (ISO/IEC 15444-1 C.3.2).
J2KT1D_INLINE uint32_t mq_decode(j2kt1d_mq_t *m, j2kt1d_cx_t *cx) {
    const uint32_t entry = j2kt1d_mq_states[*cx];
    const uint32_t qe = entry & 0xFFFFu;
    const uint32_t mps = *cx & 1u;
    const uint8_t next_mps = (uint8_t)(entry >> 16);
    const uint8_t next_lps = (uint8_t)(entry >> 24);
    uint32_t symbol;
    m->a -= qe;
    if ((m->c >> 16) < qe) {
        if (m->a < qe) {
            symbol = mps;
            *cx = next_mps;
        } else {
            symbol = mps ^ 1u;
            *cx = next_lps;
        }
        m->a = qe;
        mq_renormalize(m);
    } else {
        m->c -= qe << 16;
        if ((m->a & 0x8000u) == 0) {
            if (m->a < qe) {
                symbol = mps ^ 1u;
                *cx = next_lps;
            } else {
                symbol = mps;
                *cx = next_mps;
            }
            mq_renormalize(m);
        } else {
            symbol = mps;
        }
    }
    return symbol;
}

static void raw_init(j2kt1d_raw_t *r, const uint8_t *p, int64_t count) {
    r->p = p;
    r->count = count;
    r->pos = 0;
    r->c = 0;
    r->ct = 0;
}

// `RawBypassDecoder.decode`: MSB first; after 0xFF the stuffed bit is skipped; past the end, ones.
J2KT1D_INLINE uint32_t raw_decode(j2kt1d_raw_t *r) {
    if (r->ct == 0) {
        if (r->pos < r->count) {
            uint32_t prev = r->c;
            r->c = r->p[r->pos++];
            r->ct = prev == 0xFF ? 7 : 8;
        } else {
            r->c = 0xFF;
            r->ct = 8;
        }
    }
    r->ct -= 1;
    return (r->c >> r->ct) & 1u;
}

// --- Block state --------------------------------------------------------------------------------------------------

// Grid: one stripe row of padding above and below, one column of padding left and right; inside a stripe the four
// rows of a column are consecutive. (x, y) is at ((y >> 2) + 1) * stripe_stride + (x + 1) * 4 + (y & 3).
typedef struct {
    uint16_t *flags;
    uint32_t *mag;     // first magnitude bits; valid for significant coefficients only
    uint8_t *plane;    // bit-plane of the last significance or refinement, for the midpoint
    const uint8_t *sig_lut;
    int32_t width;
    int32_t height;
    ptrdiff_t stripe_stride;
    uint16_t vsc_mask; // flag mask of a stripe's last row (vertically causal: no south neighbours)
} j2kt1d_block_t;

#define CX_RUN_LENGTH 17
#define CX_UNIFORM 18

static const j2kt1d_cx_t j2kt1d_initial_contexts[19] = {
    4 << 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 << 1, 46 << 1,
};

J2KT1D_INLINE uint32_t sign_index(uint32_t f) {
    return ((f >> 1) & 1u) | ((f >> 2) & 2u) | ((f >> 2) & 4u) | ((f >> 3) & 8u) | ((f >> 4) & 0xF0u);
}

J2KT1D_INLINE uint32_t shl32(uint32_t value, int32_t shift) {
    return shift >= 32 ? 0u : value << shift;
}

J2KT1D_INLINE uint64_t load_column(const uint16_t *col) {
    uint64_t v;
    memcpy(&v, col, sizeof v);
    return v;
}

J2KT1D_INLINE void store_column(uint16_t *col, uint64_t v) {
    memcpy(col, &v, sizeof v);
}

// Marks the coefficient at `fp` (row `r` of its stripe) significant and publishes it to its eight neighbours.
J2KT1D_INLINE void set_significant(uint16_t *fp, int32_t r, ptrdiff_t stripe_stride, uint32_t negative,
                                   uint16_t own) {
    const ptrdiff_t up = r > 0 ? -1 : -stripe_stride + 3;
    const ptrdiff_t down = r < 3 ? 1 : stripe_stride - 3;
    fp[up - 4] |= F_SIG_SE;
    fp[up] |= (uint16_t)(F_SIG_S | (negative ? F_NEG_S : 0u));
    fp[up + 4] |= F_SIG_SW;
    fp[-4] |= (uint16_t)(F_SIG_E | (negative ? F_NEG_E : 0u));
    fp[4] |= (uint16_t)(F_SIG_W | (negative ? F_NEG_W : 0u));
    fp[down - 4] |= F_SIG_NE;
    fp[down] |= (uint16_t)(F_SIG_N | (negative ? F_NEG_N : 0u));
    fp[down + 4] |= F_SIG_NW;
    fp[0] |= (uint16_t)(F_SIG | (negative ? F_NEG : 0u) | own);
}

// Decodes the sign of a coefficient that just became significant and records its first magnitude bit.
J2KT1D_INLINE void decode_new_significant(j2kt1d_block_t *b, j2kt1d_mq_t *m, j2kt1d_cx_t *cx, uint16_t *fp,
                                          int32_t r, uint32_t f, uint32_t bit_mask, uint8_t plane, uint16_t own) {
    const uint8_t entry = j2kt1d_sign[sign_index(f)];
    const uint32_t negative = mq_decode(m, &cx[entry >> 1]) ^ (entry & 1u);
    const ptrdiff_t index = fp - b->flags;
    b->mag[index] = bit_mask;
    b->plane[index] = plane;
    set_significant(fp, r, b->stripe_stride, negative, own);
}

// --- Passes -------------------------------------------------------------------------------------------------------

J2KT1D_INLINE void spp_one(j2kt1d_block_t *b, j2kt1d_mq_t *m, j2kt1d_cx_t *cx, uint16_t *col, int32_t r,
                           uint32_t bit_mask, uint8_t plane) {
    uint16_t *fp = col + r;
    uint32_t f = *fp;
    if (r == 3) {
        f &= b->vsc_mask;
    }
    if ((f & (F_SIG | F_VISIT)) != 0 || (f & F_NEIGHBOURS) == 0) {
        return;
    }
    if (mq_decode(m, &cx[b->sig_lut[f & F_NEIGHBOURS]])) {
        decode_new_significant(b, m, cx, fp, r, f, bit_mask, plane, F_VISIT);
    } else {
        *fp |= F_VISIT;
    }
}

static void pass_significance(j2kt1d_block_t *b, j2kt1d_mq_t *mqp, j2kt1d_cx_t *cx, uint32_t bit_mask,
                              uint8_t plane) {
    j2kt1d_mq_t m = *mqp;
    const int32_t w = b->width, h = b->height;
    for (int32_t y0 = 0; y0 < h; y0 += 4) {
        const int32_t rows = h - y0 < 4 ? h - y0 : 4;
        uint16_t *col = b->flags + ((y0 >> 2) + 1) * b->stripe_stride + 4;
        if (rows == 4) {
            for (int32_t x = 0; x < w; x++, col += 4) {
                const uint64_t c = load_column(col);
                if ((c & LANES(F_NEIGHBOURS)) == 0) {
                    continue;
                }
                const uint64_t done = c & LANES(F_SIG | F_VISIT);
                if (((done | (done >> 1)) & LANES(F_SIG)) == LANES(F_SIG)) {
                    continue;
                }
                spp_one(b, &m, cx, col, 0, bit_mask, plane);
                spp_one(b, &m, cx, col, 1, bit_mask, plane);
                spp_one(b, &m, cx, col, 2, bit_mask, plane);
                spp_one(b, &m, cx, col, 3, bit_mask, plane);
            }
        } else {
            for (int32_t x = 0; x < w; x++, col += 4) {
                for (int32_t r = 0; r < rows; r++) {
                    spp_one(b, &m, cx, col, r, bit_mask, plane);
                }
            }
        }
    }
    *mqp = m;
}

static void pass_significance_raw(j2kt1d_block_t *b, j2kt1d_raw_t *rp, uint32_t bit_mask, uint8_t plane) {
    j2kt1d_raw_t raw = *rp;
    const int32_t w = b->width, h = b->height;
    for (int32_t y0 = 0; y0 < h; y0 += 4) {
        const int32_t rows = h - y0 < 4 ? h - y0 : 4;
        uint16_t *col = b->flags + ((y0 >> 2) + 1) * b->stripe_stride + 4;
        for (int32_t x = 0; x < w; x++, col += 4) {
            for (int32_t r = 0; r < rows; r++) {
                uint16_t *fp = col + r;
                uint32_t f = *fp;
                if (r == 3) {
                    f &= b->vsc_mask;
                }
                if ((f & (F_SIG | F_VISIT)) != 0 || (f & F_NEIGHBOURS) == 0) {
                    continue;
                }
                if (raw_decode(&raw)) {
                    const uint32_t negative = raw_decode(&raw);
                    const ptrdiff_t index = fp - b->flags;
                    b->mag[index] = bit_mask;
                    b->plane[index] = plane;
                    set_significant(fp, r, b->stripe_stride, negative, F_VISIT);
                } else {
                    *fp |= F_VISIT;
                }
            }
        }
    }
    *rp = raw;
}

J2KT1D_INLINE void mrp_one(j2kt1d_block_t *b, j2kt1d_mq_t *m, j2kt1d_cx_t *cx, uint16_t *col, int32_t r,
                           uint32_t bit_mask, uint8_t plane) {
    uint16_t *fp = col + r;
    uint32_t f = *fp;
    if ((f & (F_SIG | F_VISIT)) != F_SIG) {
        return;
    }
    if (r == 3) {
        f &= b->vsc_mask;
    }
    const uint32_t context = (f & F_REFINED) ? 16u : ((f & F_NEIGHBOURS) ? 15u : 14u);
    const ptrdiff_t index = fp - b->flags;
    if (mq_decode(m, &cx[context])) {
        b->mag[index] |= bit_mask;
    }
    b->plane[index] = plane;
    *fp |= F_REFINED;
}

static void pass_refinement(j2kt1d_block_t *b, j2kt1d_mq_t *mqp, j2kt1d_cx_t *cx, uint32_t bit_mask,
                            uint8_t plane) {
    j2kt1d_mq_t m = *mqp;
    const int32_t w = b->width, h = b->height;
    for (int32_t y0 = 0; y0 < h; y0 += 4) {
        const int32_t rows = h - y0 < 4 ? h - y0 : 4;
        uint16_t *col = b->flags + ((y0 >> 2) + 1) * b->stripe_stride + 4;
        if (rows == 4) {
            for (int32_t x = 0; x < w; x++, col += 4) {
                if ((load_column(col) & LANES(F_SIG)) == 0) {
                    continue;
                }
                mrp_one(b, &m, cx, col, 0, bit_mask, plane);
                mrp_one(b, &m, cx, col, 1, bit_mask, plane);
                mrp_one(b, &m, cx, col, 2, bit_mask, plane);
                mrp_one(b, &m, cx, col, 3, bit_mask, plane);
            }
        } else {
            for (int32_t x = 0; x < w; x++, col += 4) {
                for (int32_t r = 0; r < rows; r++) {
                    mrp_one(b, &m, cx, col, r, bit_mask, plane);
                }
            }
        }
    }
    *mqp = m;
}

static void pass_refinement_raw(j2kt1d_block_t *b, j2kt1d_raw_t *rp, uint32_t bit_mask, uint8_t plane) {
    j2kt1d_raw_t raw = *rp;
    const int32_t w = b->width, h = b->height;
    for (int32_t y0 = 0; y0 < h; y0 += 4) {
        const int32_t rows = h - y0 < 4 ? h - y0 : 4;
        uint16_t *col = b->flags + ((y0 >> 2) + 1) * b->stripe_stride + 4;
        for (int32_t x = 0; x < w; x++, col += 4) {
            for (int32_t r = 0; r < rows; r++) {
                uint16_t *fp = col + r;
                if ((*fp & (F_SIG | F_VISIT)) != F_SIG) {
                    continue;
                }
                const ptrdiff_t index = fp - b->flags;
                if (raw_decode(&raw)) {
                    b->mag[index] |= bit_mask;
                }
                b->plane[index] = plane;
                *fp |= F_REFINED;
            }
        }
    }
    *rp = raw;
}

// One coefficient of the cleanup pass outside a run: skipped (and its coded-this-pass mark cleared) when already
// significant or coded, otherwise decoded with its significance context.
J2KT1D_INLINE void cup_one(j2kt1d_block_t *b, j2kt1d_mq_t *m, j2kt1d_cx_t *cx, uint16_t *col, int32_t r,
                           uint32_t bit_mask, uint8_t plane) {
    uint16_t *fp = col + r;
    uint32_t f = *fp;
    if ((f & (F_SIG | F_VISIT)) != 0) {
        *fp = (uint16_t)(f & ~F_VISIT);
        return;
    }
    if (r == 3) {
        f &= b->vsc_mask;
    }
    if (mq_decode(m, &cx[b->sig_lut[f & F_NEIGHBOURS]])) {
        decode_new_significant(b, m, cx, fp, r, f, bit_mask, plane, 0);
    }
}

// Cleanup pass with ISO run-length position coding. The coded-this-pass marks of the bit-plane are cleared on the
// way, after the column's last reader.
static void pass_cleanup(j2kt1d_block_t *b, j2kt1d_mq_t *mqp, j2kt1d_cx_t *cx, uint32_t bit_mask,
                         uint8_t plane) {
    j2kt1d_mq_t m = *mqp;
    const int32_t w = b->width, h = b->height;
    const uint64_t last_row_mask = 0x0000FFFFFFFFFFFFull | ((uint64_t)b->vsc_mask << 48);
    for (int32_t y0 = 0; y0 < h; y0 += 4) {
        const int32_t rows = h - y0 < 4 ? h - y0 : 4;
        uint16_t *col = b->flags + ((y0 >> 2) + 1) * b->stripe_stride + 4;
        if (rows < 4) {
            for (int32_t x = 0; x < w; x++, col += 4) {
                for (int32_t r = 0; r < rows; r++) {
                    cup_one(b, &m, cx, col, r, bit_mask, plane);
                }
            }
            continue;
        }
        for (int32_t x = 0; x < w; x++, col += 4) {
            const uint64_t c = load_column(col);
            if (((c & last_row_mask) & LANES(F_SIG | F_VISIT | F_NEIGHBOURS)) == 0) {
                // Run-length coding: all four insignificant, uncoded and without significant neighbours.
                if (!mq_decode(&m, &cx[CX_RUN_LENGTH])) {
                    continue;
                }
                int32_t first = (int32_t)(mq_decode(&m, &cx[CX_UNIFORM]) << 1);
                first |= (int32_t)mq_decode(&m, &cx[CX_UNIFORM]);
                uint32_t f = col[first];
                if (first == 3) {
                    f &= b->vsc_mask;
                }
                decode_new_significant(b, &m, cx, col + first, first, f, bit_mask, plane, 0);
                for (int32_t r = first + 1; r < 4; r++) {
                    uint32_t rf = col[r];
                    if (r == 3) {
                        rf &= b->vsc_mask;
                    }
                    if (mq_decode(&m, &cx[b->sig_lut[rf & F_NEIGHBOURS]])) {
                        decode_new_significant(b, &m, cx, col + r, r, rf, bit_mask, plane, 0);
                    }
                }
                continue;
            }
            const uint64_t done = c & LANES(F_SIG | F_VISIT);
            if (((done | (done >> 1)) & LANES(F_SIG)) == LANES(F_SIG)) {
                store_column(col, c & ~LANES(F_VISIT));
                continue;
            }
            cup_one(b, &m, cx, col, 0, bit_mask, plane);
            cup_one(b, &m, cx, col, 1, bit_mask, plane);
            cup_one(b, &m, cx, col, 2, bit_mask, plane);
            cup_one(b, &m, cx, col, 3, bit_mask, plane);
        }
    }
    *mqp = m;
}

// --- Block --------------------------------------------------------------------------------------------------------

enum { LIVE_NONE = 0, LIVE_ARITHMETIC = 1, LIVE_RAW = 2 };

static size_t grid_cells(int32_t width, int32_t height) {
    return (size_t)((height + 3) / 4 + 2) * (size_t)(width + 2) * 4;
}

size_t j2kt1d_scratch_words(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) {
        return 0;
    }
    // Magnitudes (4 bytes), flags (2 bytes) and bit-planes (1 byte) per cell, in 32-bit words.
    return (grid_cells(width, height) * 7 + 3) / 4;
}

int32_t j2kt1d_decode_block(const j2kt1d_params_t *params,
                            int32_t *coefficients,
                            uint32_t *scratch,
                            size_t scratch_words,
                            j2kt1d_result_t *result) {
    memset(result, 0, sizeof *result);
    const int32_t w = params->width, h = params->height;
    if (w <= 0 || h <= 0) {
        return J2KT1D_OK;
    }
    if (params->pass_count <= 0) {
        memset(coefficients, 0, sizeof(int32_t) * (size_t)w * (size_t)h);
        return J2KT1D_OK;
    }
    const size_t cells = grid_cells(w, h);
    if (scratch_words < j2kt1d_scratch_words(w, h)) {
        return J2KT1D_SCRATCH_TOO_SMALL;
    }

    j2kt1d_block_t b;
    b.mag = scratch;
    b.flags = (uint16_t *)(scratch + cells);
    b.plane = (uint8_t *)(b.flags + cells);
    b.width = w;
    b.height = h;
    b.stripe_stride = (ptrdiff_t)(w + 2) * 4;
    b.vsc_mask = params->vertically_causal ? (uint16_t)~F_SOUTH : (uint16_t)0xFFFFu;
    b.sig_lut = params->orientation == J2KT1D_ORIENT_HL ? j2kt1d_sig_hl
        : (params->orientation == J2KT1D_ORIENT_HH ? j2kt1d_sig_hh : j2kt1d_sig_lh);
    memset(b.flags, 0, sizeof(uint16_t) * cells);

    j2kt1d_cx_t cx[19];
    memcpy(cx, j2kt1d_initial_contexts, sizeof cx);

    const int per_pass = params->segment_count > 0;
    j2kt1d_mq_t mq;
    j2kt1d_raw_t raw;
    mq_init(&mq, params->data, per_pass ? 0 : params->data_count);
    raw_init(&raw, params->data, 0);
    int live = per_pass ? LIVE_NONE : LIVE_ARITHMETIC;
    int32_t current_segment = -1;
    // A block that declares fewer passes than its bit-planes hold was cut by rate control, and its encoder may also cut
    // the last pass short: Annex C decodes the rest of it from the 0xFF fill, as OpenJPEG does (#3095). For such a
    // block only the reads past the end before its last pass began count; -1 until then.
    const int cut_short = (int64_t)params->pass_count < 3 * (int64_t)params->active_bit_planes - 2;
    int64_t last_pass_over_read = -1;

#define CLOSE_SEGMENT()                                                                                           \
    do {                                                                                                          \
        if (live == LIVE_ARITHMETIC) {                                                                            \
            result->declared_bytes += mq.count;                                                                   \
            result->consumed_bytes += mq.pos < mq.count ? mq.pos : mq.count;                                      \
            const int64_t over_read = last_pass_over_read >= 0 ? last_pass_over_read : mq.over_read;              \
            if (over_read > result->over_read_count) result->over_read_count = over_read;                         \
        } else if (live == LIVE_RAW) {                                                                            \
            result->declared_bytes += raw.count;                                                                  \
            result->consumed_bytes += raw.pos < raw.count ? raw.pos : raw.count;                                  \
        }                                                                                                         \
    } while (0)

    // `beginPass`: resets the contexts under RESET and opens the pass's codeword segment; 0 when none is left.
#define BEGIN_PASS(is_raw, ok)                                                                                    \
    do {                                                                                                          \
        ok = 1;                                                                                                   \
        if (params->reset_each_pass && passes > 0) memcpy(cx, j2kt1d_initial_contexts, sizeof cx);                \
        if (per_pass) {                                                                                           \
            if (passes >= params->segment_of_pass_count) {                                                        \
                ok = 0;                                                                                           \
            } else {                                                                                              \
                int32_t segment = params->segment_of_pass[passes];                                                \
                if (segment != current_segment) {                                                                 \
                    CLOSE_SEGMENT();                                                                              \
                    const uint8_t *start = params->data + params->segment_offsets[segment];                       \
                    if (is_raw) {                                                                                 \
                        raw_init(&raw, start, params->segment_lengths[segment]);                                  \
                    } else {                                                                                      \
                        mq_init(&mq, start, params->segment_lengths[segment]);                                    \
                    }                                                                                             \
                    live = (is_raw) ? LIVE_RAW : LIVE_ARITHMETIC;                                                 \
                    current_segment = segment;                                                                    \
                }                                                                                                 \
            }                                                                                                     \
        }                                                                                                         \
        if (ok && cut_short && passes == params->pass_count - 1) last_pass_over_read = mq.over_read;              \
    } while (0)

    int32_t status = J2KT1D_OK;
    int32_t passes = 0;
    const int32_t shift = params->irreversible ? 1 : 0;
    for (int32_t plane = params->active_bit_planes - 1; plane >= 0; plane--) {
        const uint32_t bit_mask = shl32(1u, plane + shift);
        // Planes past 255 carry no half bit (their shift is out of range), so 255 stands for all of them.
        const uint8_t plane_tag = (uint8_t)(plane > 255 ? 255 : plane);
        const int first_plane = plane == params->active_bit_planes - 1;
        int ok;
        if (!first_plane && passes < params->pass_count) {
            const int is_raw = params->bypass && passes >= 10;
            BEGIN_PASS(is_raw, ok);
            if (!ok) break;
            if (is_raw) {
                pass_significance_raw(&b, &raw, bit_mask, plane_tag);
            } else {
                pass_significance(&b, &mq, cx, bit_mask, plane_tag);
            }
            passes++;
        }
        if (!first_plane && passes < params->pass_count) {
            const int is_raw = params->bypass && passes >= 10;
            BEGIN_PASS(is_raw, ok);
            if (!ok) break;
            if (is_raw) {
                pass_refinement_raw(&b, &raw, bit_mask, plane_tag);
            } else {
                pass_refinement(&b, &mq, cx, bit_mask, plane_tag);
            }
            passes++;
        }
        if (passes < params->pass_count) {
            BEGIN_PASS(0, ok);
            if (!ok) break;
            pass_cleanup(&b, &mq, cx, bit_mask, plane_tag);
            if (params->segmentation_symbols) {
                int32_t symbol = 0;
                for (int i = 0; i < 4; i++) {
                    symbol = (symbol << 1) | (int32_t)mq_decode(&mq, &cx[CX_UNIFORM]);
                }
                if (symbol != 0xA) {
                    result->bad_symbol = symbol;
                    result->bad_pass = passes;
                    status = J2KT1D_BAD_SEGMENTATION_SYMBOL;
                    break;
                }
            }
            passes++;
        }
        if (passes >= params->pass_count) {
            break;
        }
    }
    CLOSE_SEGMENT();
#undef BEGIN_PASS
#undef CLOSE_SEGMENT
    if (status != J2KT1D_OK) {
        return status;
    }

    // Midpoint reconstruction: the half bit below the last bit-plane that touched each significant coefficient.
    for (int32_t y = 0; y < h; y++) {
        const ptrdiff_t row = ((y >> 2) + 1) * b.stripe_stride + 4 + (y & 3);
        int32_t *out = coefficients + (ptrdiff_t)y * w;
        for (int32_t x = 0; x < w; x++) {
            const ptrdiff_t index = row + (ptrdiff_t)x * 4;
            const uint32_t f = b.flags[index];
            if ((f & F_SIG) == 0) {
                out[x] = 0;
                continue;
            }
            const int32_t plane = b.plane[index];
            const uint32_t half = params->irreversible ? shl32(1u, plane) : (plane > 0 ? shl32(1u, plane - 1) : 0u);
            const uint32_t value = b.mag[index] | half;
            out[x] = (int32_t)((f & F_NEG) ? 0u - value : value);
        }
    }
    return J2KT1D_OK;
}
