// dcmj2knhe_tables.h — JPEG 2000 Part-15 (HT) lookup tables.
//
// The values are defined by ITU-T T.814 (the HT codestream
// specification). They are mathematical constants, not creative
// authorship. The corresponding Swift arrays in
// Sources/J2KCodec/J2KHTConformantTables.swift are our existing
// source-of-truth; we transcribe the same constants into C arrays
// here so the C+NEON encoder doesn't need to call back into Swift
// for table lookups. A startup-time sanity test
// (V94NEONHotPathParityTests.testTablesMatchSwiftSourceOfTruth)
// verifies bit-identity between the two.

#ifndef J2KNHE_TABLES_H
#define J2KNHE_TABLES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// VLC table 0 — used for the first row of quads and after rho==0
/// quads. Indexed as `(c_q << 8) | (rho << 4) | eps`, range
/// [0, 2048). Returns a packed uint16_t encoding the tuple
/// (codeword, codeword_length, eps_bits) — see Swift
/// vlcTable0Conformant for layout.
extern const uint16_t dcmj2knhe_vlc_table0[2048];

/// VLC table 1 — used for subsequent rows of quads. Same layout +
/// indexing convention as table 0.
extern const uint16_t dcmj2knhe_vlc_table1[2048];

/// UVLC table — used for U-value (Uq - kappa) emit. The table has
/// 75 entries indexed by `u_value` in [0, 74]; each entry packs
/// (prefix, prefix_len, suffix, suffix_len) into a uint32_t.
/// See Swift uvlcTableConformant for the layout: bits 0..7 = pre,
/// 8..15 = preLen, 16..23 = suf, 24..31 = sufLen.
extern const uint32_t dcmj2knhe_uvlc_table[75];

#ifdef __cplusplus
}
#endif

#endif // J2KNHE_TABLES_H
