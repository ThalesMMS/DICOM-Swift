// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Huffman table, encoding, and decoding for JPEG entropy coding.

// MARK: - Huffman Table

/// A compiled Huffman table for encoding or decoding.
struct HuffmanTable {
    /// Number of codes at each bit length (1–16).
    let bits: [UInt8]
    /// The code and bit length for each symbol (for encoding).
    /// Index is the symbol value; value is (code, bitLength).
    let encodingTable: [(code: UInt16, length: UInt8)]

    /// For decoding: maximum code value at each bit length (1–16).
    let maxCode: [Int32]
    /// For decoding: minimum code value at each bit length.
    let minCode: [Int32]
    /// For decoding: index into values array for each bit length.
    let valPtr: [Int]
    /// Ordered symbol values.
    let values: [UInt8]

    /// Lookahead decode tables, indexed by the next 8 bits of the stream.
    /// `lookaheadLength[i]` is the bit length (1–8) of the code whose canonical
    /// prefix matches the top bits of `i`, or 0 when the code is longer than 8
    /// bits (no ≤8-bit code is a prefix of `i`). `lookaheadSymbol[i]` is the
    /// decoded symbol when the length is non-zero. This is the standard
    /// table-driven fast path (libjpeg's `HUFF_LOOKAHEAD = 8`): one buffered
    /// byte resolves the common short codes in O(1), and the prefix-free
    /// property guarantees the result is identical to walking the code
    /// bit-by-bit. Codes >8 bits and any byte near a marker fall back to the
    /// bit-by-bit reader, so error/restart handling is unchanged.
    let lookaheadLength: [UInt8]
    let lookaheadSymbol: [UInt8]

    /// Builds a Huffman table from JPEG-standard bits and values arrays.
    ///
    /// - Parameters:
    ///   - bits: 16-element array, where `bits[i]` is the number of codes of length `i+1`.
    ///   - values: Symbol values in order of increasing code length.
    init(bits: [UInt8], values: [UInt8]) {
        self.bits = bits
        self.values = values
        var encoding = [(code: UInt16, length: UInt8)](repeating: (0, 0), count: 256)

        var maxC = [Int32](repeating: -1, count: 17)
        var minC = [Int32](repeating: -1, count: 17)
        var vPtr = [Int](repeating: 0, count: 17)
        var laLen = [UInt8](repeating: 0, count: 256)
        var laSym = [UInt8](repeating: 0, count: 256)

        // Wider than the 16-bit codes it produces so canonical-code generation
        // can't overflow on a malformed BITS array — a complete length-16 code
        // walks `code` up to 2^16, one past UInt16's range. Stored codes still
        // fit in 16 bits for any well-formed table.
        var code: UInt32 = 0
        var valueIndex = 0

        for bitLength in 1...16 {
            let count = Int(bits[bitLength - 1])
            if count > 0 {
                vPtr[bitLength] = valueIndex
                minC[bitLength] = Int32(code)
                for _ in 0..<count where valueIndex < values.count {
                    let symbol = values[valueIndex]
                    encoding[Int(symbol)] = (UInt16(truncatingIfNeeded: code), UInt8(bitLength))
                    // Fill every 8-bit lookahead slot whose top `bitLength` bits
                    // equal this code. A canonical code of length ≤8 is < 256,
                    // so `code << (8 - bitLength)` and its run stay in 0...255.
                    if bitLength <= 8 {
                        let shift = 8 - bitLength
                        let start = Int(code << shift)
                        for k in start..<(start + (1 << shift)) {
                            laLen[k] = UInt8(bitLength)
                            laSym[k] = symbol
                        }
                    }
                    valueIndex += 1
                    code += 1
                }
                maxC[bitLength] = Int32(code - 1)
            }
            code <<= 1
        }

        self.encodingTable = encoding
        self.maxCode = maxC
        self.minCode = minC
        self.valPtr = vPtr
        self.lookaheadLength = laLen
        self.lookaheadSymbol = laSym
    }
}

// MARK: - Standard JPEG Huffman Tables (ITU-T T.81 Annex K)

/// Standard Huffman table definitions from the JPEG specification.
enum StandardHuffmanTables {
    /// DC luminance table (Table K.3).
    static let dcLuminance = HuffmanTable(
        bits: [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0],
        values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    )

    /// DC chrominance table (Table K.4).
    static let dcChrominance = HuffmanTable(
        bits: [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    )

    /// AC luminance table (Table K.5).
    static let acLuminance = HuffmanTable(
        bits: [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D],
        values: [
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
            0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
            0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
            0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
            0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
            0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
            0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
            0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
            0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
            0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
            0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
            0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
            0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
            0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
            0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
            0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
            0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA
        ]
    )

    /// AC chrominance table (Table K.6).
    static let acChrominance = HuffmanTable(
        bits: [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77],
        values: [
            0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
            0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
            0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
            0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
            0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
            0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
            0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
            0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
            0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
            0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
            0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
            0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
            0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
            0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
            0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
            0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
            0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
            0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
            0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
            0xF9, 0xFA
        ]
    )
}

// MARK: - Optimal Huffman Table Generation

/// Builds image-optimal Huffman tables from symbol frequencies, per the
/// procedure in ITU-T T.81 Annex K.2 (the same algorithm libjpeg uses for
/// `-optimize`). Replacing the fixed Annex K tables with per-image tables
/// typically shrinks entropy-coded output 10–50% at identical quality, since
/// the fixed tables are tuned for a generic photo and waste bits on symbol
/// distributions that don't match the actual image.
enum HuffmanTableBuilder {

    /// Generates an optimal Huffman table from `frequencies` (indexed by symbol,
    /// at least 256 entries). Returns `fallback` unchanged when no symbols were
    /// counted — an empty table can't encode anything and some decoders reject
    /// empty DHT segments, so the standard table is a safe no-op there.
    static func build(frequencies: [Int], fallback: HuffmanTable) -> HuffmanTable {
        if frequencies.reduce(0, +) == 0 { return fallback }

        // freq[256] is a reserved code point that guarantees no real symbol gets
        // the all-ones code (forbidden by JPEG). Work on a 257-entry copy.
        var freq = [Int](repeating: 0, count: 257)
        for i in 0..<min(256, frequencies.count) { freq[i] = frequencies[i] }
        freq[256] = 1

        var codesize = [Int](repeating: 0, count: 257)
        var others = [Int](repeating: -1, count: 257)

        // Repeatedly merge the two least-frequent live nodes (Huffman tree build),
        // tracking each merged chain's growing code length in `codesize`.
        while true {
            var c1 = -1, v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v { v = freq[i]; c1 = i }
            var c2 = -1; v = Int.max
            for i in 0...256 where freq[i] > 0 && freq[i] <= v && i != c1 { v = freq[i]; c2 = i }
            if c2 < 0 { break }

            freq[c1] += freq[c2]
            freq[c2] = 0
            codesize[c1] += 1
            while others[c1] >= 0 { c1 = others[c1]; codesize[c1] += 1 }
            others[c1] = c2
            codesize[c2] += 1
            while others[c2] >= 0 { c2 = others[c2]; codesize[c2] += 1 }
        }

        // Count codes of each length (1–32 before limiting).
        var bits = [Int](repeating: 0, count: 33)
        for i in 0...256 where codesize[i] > 0 { bits[codesize[i]] += 1 }

        // Limit code lengths to 16 bits (Annex K.2, figure K.3). Each over-long
        // code is shortened by reshaping the prefix tree, keeping it a valid
        // prefix code.
        var i = 32
        while i > 16 {
            while bits[i] > 0 {
                var j = i - 2
                while bits[j] == 0 { j -= 1 }
                bits[i] -= 2
                bits[i - 1] += 1
                bits[j + 1] += 2
                bits[j] -= 1
            }
            i -= 1
        }
        // Drop the reserved code point: decrement the longest non-empty length.
        i = 16
        while i > 0 && bits[i] == 0 { i -= 1 }
        if i > 0 { bits[i] -= 1 }

        var bits16 = [UInt8](repeating: 0, count: 16)
        for len in 1...16 { bits16[len - 1] = UInt8(bits[len]) }

        // HUFFVAL: real symbols (0–255) ordered by increasing original code length.
        // Symbol 256 (reserved) is naturally excluded by the 0...255 range.
        var values = [UInt8]()
        for len in 1...32 {
            for sym in 0...255 where codesize[sym] == len { values.append(UInt8(sym)) }
        }

        return HuffmanTable(bits: bits16, values: values)
    }
}

// MARK: - Huffman Encoding

/// Huffman entropy encoder for JPEG data.
enum HuffmanEncoder {

    /// Returns the category (number of bits) needed to represent a value.
    ///
    /// Category 0 = value 0, category 1 = -1..1, category 2 = -3..-2, 2..3, etc.
    /// One CLZ instruction: `bits(|v|) = 32 − clz(|v|)` (and `clz(0) = 32` makes
    /// the zero case fall out naturally). Identical to counting shifts — this
    /// runs twice per sample in lossless encode, so it must be branch-free.
    @inline(__always)
    static func category(for value: Int32) -> Int {
        Int(32 - value.magnitude.leadingZeroBitCount)
    }

    /// Returns the additional bits to encode after the Huffman category code.
    ///
    /// For positive values: the value itself. For negative: `value + (1 << category) - 1`.
    static func additionalBits(for value: Int32, category cat: Int) -> UInt32 {
        if cat == 0 { return 0 }
        if value >= 0 {
            return UInt32(value)
        } else {
            return UInt32(Int(value) + (1 << cat) - 1)
        }
    }

    /// Counts the Huffman symbol a DC difference would emit, without writing bits.
    /// Mirrors ``encodeDC(_:table:writer:)`` exactly so a counting pass and an
    /// emit pass agree on which symbols appear. `freq` is indexed by symbol (0–255).
    static func countDC(_ diff: Int32, freq: inout [Int]) {
        freq[category(for: diff)] += 1
    }

    /// Counts the Huffman symbols the 63 AC coefficients would emit. Mirrors
    /// ``encodeAC(_:table:writer:)``.
    static func countAC(_ zigzag: [Int32], freq: inout [Int]) {
        var zeroRun = 0
        for i in 1..<64 {
            let value = zigzag[i]
            if value == 0 {
                zeroRun += 1
            } else {
                while zeroRun > 15 {
                    freq[0xF0] += 1  // ZRL
                    zeroRun -= 16
                }
                freq[(zeroRun << 4) | category(for: value)] += 1
                zeroRun = 0
            }
        }
        if zeroRun > 0 { freq[0x00] += 1 }  // EOB
    }

    /// Encodes a DC coefficient difference using the given Huffman table.
    ///
    /// The Huffman code and its appended magnitude bits are emitted in a single
    /// `writeBits` call: appending `n` bits then `m` bits MSB-first produces the
    /// same bit sequence as appending the `n+m`-bit concatenation, and stuffing/
    /// padding are pure functions of the bit sequence — so the stream is
    /// byte-identical while halving the mutating-writer calls. Max combined
    /// width is 16 (code) + 15 (DCT magnitude) = 31 bits, within `writeBits`'
    /// 32-bit value.
    static func encodeDC(_ diff: Int32, table: HuffmanTable, writer: inout BitWriter) {
        let cat = category(for: diff)
        let entry = table.encodingTable[cat]
        if cat > 0 {
            let fused = (UInt32(entry.code) << cat) | additionalBits(for: diff, category: cat)
            writer.writeBits(fused, count: Int(entry.length) + cat)
        } else {
            writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        }
    }

    /// Encodes the 63 AC coefficients of a block (in zigzag order, starting from index 1).
    static func encodeAC(_ zigzag: [Int32], table: HuffmanTable, writer: inout BitWriter) {
        var zeroRun = 0

        for i in 1..<64 {
            let value = zigzag[i]
            if value == 0 {
                zeroRun += 1
            } else {
                // Emit ZRL (zero run length) symbols for runs > 15
                while zeroRun > 15 {
                    let entry = table.encodingTable[0xF0]  // ZRL symbol
                    writer.writeBits(UInt32(entry.code), count: Int(entry.length))
                    zeroRun -= 16
                }
                let cat = category(for: value)
                let symbol = (zeroRun << 4) | cat
                let entry = table.encodingTable[symbol]
                // Code + magnitude bits in one call (see encodeDC) — identical
                // bitstream, half the writer calls. AC cat ≤ 14 → ≤ 30 bits.
                let fused = (UInt32(entry.code) << cat) | additionalBits(for: value, category: cat)
                writer.writeBits(fused, count: Int(entry.length) + cat)
                zeroRun = 0
            }
        }

        // EOB (End of Block) if the last coefficient(s) were zero
        if zeroRun > 0 {
            let entry = table.encodingTable[0x00]  // EOB symbol
            writer.writeBits(UInt32(entry.code), count: Int(entry.length))
        }
    }
}

// MARK: - Huffman Decoding

/// Huffman entropy decoder for JPEG data.
enum HuffmanDecoder {

    /// Decodes a single Huffman symbol from the bit stream.
    static func decodeSymbol(from reader: inout BitReader, table: HuffmanTable) throws -> UInt8 {
        // Fast path: resolve short (≤8-bit) codes from an 8-bit lookahead table.
        // Falls through to the bit-by-bit walk for long codes and any byte near
        // a marker / end of data, so all error and restart handling is unchanged.
        if let symbol = reader.fastDecodeSymbol(table) { return symbol }
        return try decodeSymbolBitByBit(from: &reader, table: table)
    }

    /// Bit-by-bit Huffman symbol decode: reads one bit at a time, comparing the
    /// accumulated code against `maxCode` at each length (ITU-T T.81 F.2.2.3).
    /// This is the reference/fallback path — it owns all long-code (>8-bit),
    /// marker, EOF, and malformed-table handling. ``decodeSymbol(from:table:)``
    /// only short-circuits to the lookahead table when it can prove the result
    /// is identical to this walk.
    static func decodeSymbolBitByBit(
        from reader: inout BitReader, table: HuffmanTable
    ) throws -> UInt8 {
        var code: Int32 = 0

        for bitLength in 1...16 {
            let bit = try reader.readBit()
            code = (code << 1) | Int32(bit)

            if table.maxCode[bitLength] >= 0 && code <= table.maxCode[bitLength] {
                let index = table.valPtr[bitLength] + Int(code - table.minCode[bitLength])
                // A malformed DHT (e.g. a corrupted code-count byte) can yield a
                // valPtr/minCode that points past the value list; bounds-check
                // rather than trap on untrusted input.
                guard index >= 0, index < table.values.count else {
                    throw JLIError.decodingFailed("Huffman code index out of range")
                }
                return table.values[index]
            }
        }

        throw JLIError.decodingFailed("Invalid Huffman code")
    }

    /// Decodes a signed value from additional bits after a Huffman category.
    static func decodeValue(from reader: inout BitReader, category cat: Int) throws -> Int32 {
        guard cat > 0 else { return 0 }

        let bits = try reader.readBits(cat)
        // If MSB is 0, the value is negative
        if bits < (1 << (cat - 1)) {
            return Int32(bits) - Int32((1 << cat) - 1)
        } else {
            return Int32(bits)
        }
    }

    /// Decodes a DC coefficient from the bit stream.
    static func decodeDC(from reader: inout BitReader, table: HuffmanTable) throws -> Int32 {
        let cat = Int(try decodeSymbol(from: &reader, table: table))
        return try decodeValue(from: &reader, category: cat)
    }

    /// Decodes the 63 AC coefficients of a block from the bit stream.
    ///
    /// Returns 64 coefficients in zigzag order (index 0 is left empty for DC).
    static func decodeAC(from reader: inout BitReader, table: HuffmanTable) throws -> [Int32] {
        var coefficients = [Int32](repeating: 0, count: 64)
        try decodeAC(from: &reader, table: table, into: &coefficients)
        return coefficients
    }

    /// In-place variant: decodes 64 zigzag-order AC coefficients into `out`.
    /// Caller's buffer is zeroed before decoding. Saves an `[Int32](repeating:)`
    /// allocation per block in the decoder hot loop.
    static func decodeAC(
        from reader: inout BitReader, table: HuffmanTable, into out: inout [Int32]
    ) throws {
        precondition(out.count == 64)
        for i in 0..<64 { out[i] = 0 }

        var index = 1
        while index < 64 {
            let symbol = try decodeSymbol(from: &reader, table: table)

            if symbol == 0x00 {
                break  // EOB — remaining coefficients are zero
            }
            if symbol == 0xF0 {
                index += 16  // ZRL — skip 16 zeros
                continue
            }

            let zeroRun = Int(symbol >> 4)
            let cat = Int(symbol & 0x0F)
            index += zeroRun
            guard index < 64 else { break }

            out[index] = try decodeValue(from: &reader, category: cat)
            index += 1
        }
    }
}
