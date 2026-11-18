// j2kt1d.h — EBCOT (JPEG 2000 Part 1) code-block decoder in plain C (issue #3078).
//
// Bit-exact counterpart of `BitPlaneDecoder.decode` (Sources/DicomJPEG2000/Codec/J2KBitPlaneCoder.swift) for the
// ISO run-length position coding the decoder pipeline always uses: same MQ and raw decoders (including their byte
// accounting past the end of a segment), same passes, contexts and midpoint reconstruction. Contexts come from one
// flag word per coefficient that carries the significance and sign of its eight neighbours, so a coefficient's
// context is one table lookup and an empty stripe column is one test.
//
// Memory model: caller-owned input, segment tables, output and scratch; no allocation, no global state.

#ifndef J2KT1D_H
#define J2KT1D_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Subband orientations of the significance context tables.
enum {
    J2KT1D_ORIENT_LL_LH = 0,
    J2KT1D_ORIENT_HL = 1,
    J2KT1D_ORIENT_HH = 2
};

/// Status codes of `j2kt1d_decode_block`.
enum {
    J2KT1D_OK = 0,
    /// A cleanup pass ended with a segmentation symbol other than 0xA (`bad_symbol`, `bad_pass`).
    J2KT1D_BAD_SEGMENTATION_SYMBOL = 1,
    /// The scratch buffer is smaller than `j2kt1d_scratch_words`.
    J2KT1D_SCRATCH_TOO_SMALL = 2
};

typedef struct j2kt1d_params {
    int32_t width;
    int32_t height;
    int32_t orientation;          ///< J2KT1D_ORIENT_*
    int32_t pass_count;
    int32_t active_bit_planes;    ///< bit depth minus zero bit-planes
    int32_t irreversible;         ///< bit masks on the bpno + 1 scale (9/7)
    int32_t bypass;               ///< selective arithmetic bypass (style bit 0)
    int32_t reset_each_pass;      ///< contexts reset at every pass (style bit 1, or predictable termination)
    int32_t vertically_causal;    ///< style bit 3
    int32_t segmentation_symbols; ///< style bit 5
    const uint8_t *data;
    int32_t data_count;
    /// Per-pass codeword segments. `segment_count == 0`: one MQ segment over the whole data.
    const int32_t *segment_offsets;
    const int32_t *segment_lengths;
    int32_t segment_count;
    /// Segment of each pass, `segment_of_pass_count` entries (used only with segments).
    const int32_t *segment_of_pass;
    int32_t segment_of_pass_count;
} j2kt1d_params_t;

typedef struct j2kt1d_result {
    /// Entropy-integrity accounting of the closed segments (#2899). `over_read_count` is the largest over-read of
    /// one segment; for a block with fewer passes than its bit-planes hold, before its last pass began (#3095).
    int64_t declared_bytes;
    int64_t consumed_bytes;
    int64_t over_read_count;
    int32_t bad_symbol;
    int32_t bad_pass;
} j2kt1d_result_t;

/// 32-bit words of scratch `j2kt1d_decode_block` needs for a `width` x `height` block.
size_t j2kt1d_scratch_words(int32_t width, int32_t height);

/// Decodes one code-block into `coefficients` (`width * height` signed values, row-major).
int32_t j2kt1d_decode_block(const j2kt1d_params_t *params,
                            int32_t *coefficients,
                            uint32_t *scratch,
                            size_t scratch_words,
                            j2kt1d_result_t *result);

#ifdef __cplusplus
}
#endif

#endif // J2KT1D_H
