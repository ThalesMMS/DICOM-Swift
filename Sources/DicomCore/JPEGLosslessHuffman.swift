import Foundation

extension JPEGLosslessDecoder {
    // MARK: - Huffman Table Construction

    /// Builds Huffman decoding tables from symbol counts and values
    /// Implements the algorithm from JPEG specification Annex F.2.2.3
    /// Builds canonical Huffman decoding tables from the provided table's symbol counts.
    /// 
    /// Populates `table.minCode`, `table.maxCode`, and `table.valPtr` for bit lengths 1–16 using the counts in `table.symbolCounts`, following the canonical JPEG Huffman table construction (Annex F). Each `minCode[length]` and `maxCode[length]` define the inclusive code range for that bit length and `valPtr[length]` is the starting index into the symbol list for that length.
    /// - Parameter table: Mutable Huffman table whose `symbolCounts` are used as input. On return, `minCode`, `maxCode`, and `valPtr` are set.
    func buildHuffmanDecodingTables(table: inout HuffmanTable) {
        // Initialize decoding tables (length 17: index 0 unused, 1-16 for bit lengths)
        var minCode = [Int](repeating: -1, count: 17)
        var maxCode = [Int](repeating: -1, count: 17)
        var valPtr = [Int](repeating: 0, count: 17)

        // Generate code sizes array (JPEG spec Figure F.15)
        var huffsize: [Int] = []
        for length in 1...16 {
            let count = table.symbolCounts[length - 1]
            for _ in 0..<count {
                huffsize.append(length)
            }
        }

        // Generate Huffman codes array (JPEG spec Figure F.16)
        var huffcode: [Int] = []
        if !huffsize.isEmpty {
            var code = 0
            var currentSize = huffsize[0]

            for size in huffsize {
                // If code length increases, shift code left
                if size > currentSize {
                    code <<= (size - currentSize)
                    currentSize = size
                }
                huffcode.append(code)
                code += 1
            }
        }

        // Build decoding tables (JPEG spec Figure F.17)
        // For each bit length, store minimum code, maximum code, and symbol value index
        var symbolIndex = 0
        for length in 1...16 {
            let symbolCount = Int(table.symbolCounts[length - 1])
            if symbolCount > 0 {
                valPtr[length] = symbolIndex
                minCode[length] = huffcode[symbolIndex]
                symbolIndex += symbolCount
                maxCode[length] = huffcode[symbolIndex - 1]
            }
        }

        // Store decoding tables in mutable copy
        table.minCode = minCode
        table.maxCode = maxCode
        table.valPtr = valPtr
        table.lookup = Self.buildLookup(huffsize: huffsize, huffcode: huffcode, symbolValues: table.symbolValues)
    }

    /// Fills a `1 << lookupBits` table so that most symbols resolve with one peek instead of a bit-serial search.
    private static func buildLookup(huffsize: [Int], huffcode: [Int], symbolValues: [UInt8]) -> [UInt16] {
        let bits = HuffmanTable.lookupBits
        var lookup = [UInt16](repeating: 0, count: 1 << bits)
        for (index, size) in huffsize.enumerated() where size <= bits && index < symbolValues.count {
            let base = huffcode[index] << (bits - size)
            let entry = UInt16(size << 8) | UInt16(symbolValues[index])
            for slot in base..<(base + (1 << (bits - size))) where slot < lookup.count {
                lookup[slot] = entry
            }
        }
        return lookup
    }
}

/// Canonical code assignment shared by the decoder and the own encoder (T.81 Annex C, Figures C.1–C.3).
enum JPEGLosslessHuffmanCodes {
    struct Code: Equatable {
        let value: Int
        let length: Int
    }

    /// Codes in the order of `symbolValues` (BITS then HUFFVAL, as carried by a DHT segment).
    static func canonical(symbolCounts: [UInt8]) -> [Code] {
        var codes: [Code] = []
        var code = 0
        for length in 1...16 {
            let count = length - 1 < symbolCounts.count ? Int(symbolCounts[length - 1]) : 0
            for _ in 0..<count {
                codes.append(Code(value: code, length: length))
                code += 1
            }
            code <<= 1
        }
        return codes
    }
}
