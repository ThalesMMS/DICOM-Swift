//
//  JPEGLosslessEntropyReader.swift
//  DicomCore
//
//  Entropy-coded segment reader for the own JPEG lossless (SOF3) decoder: a 64-bit accumulator over the raw
//  bytes, marker-aware refill (0xFF00 unstuffing, stop at any other marker), lookup-table Huffman decode with
//  the canonical search as the long-code fallback, and restart-marker consumption with the T.81 padding rule.
//

import Foundation

struct JPEGLosslessEntropyReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var position: Int
    private let end: Int
    private var accumulator: UInt64 = 0
    private var bitCount: Int = 0

    init(bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) {
        self.bytes = bytes
        position = start
        self.end = end
    }

    /// Loads whole bytes until the accumulator holds more than 56 bits or a marker/end of data is reached.
    @inline(__always)
    private mutating func fill() {
        while bitCount <= 56, position < end {
            let byte = bytes[position]
            if byte == JPEGMarker.prefix {
                guard position + 1 < end, bytes[position + 1] == JPEGMarker.stuffingByte else { return }
                position += 2
            } else {
                position += 1
            }
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8
        }
    }

    /// The next `count` bits without consuming them; missing bits (end of data) read as zero.
    @inline(__always)
    private mutating func peek(_ count: Int) -> Int {
        if bitCount < count { fill() }
        let mask = (1 << count) - 1
        if bitCount >= count {
            return Int(truncatingIfNeeded: accumulator >> UInt64(bitCount - count)) & mask
        }
        return (Int(truncatingIfNeeded: accumulator) << (count - bitCount)) & mask
    }

    @inline(__always)
    private mutating func consume(_ count: Int) throws {
        guard count <= bitCount else {
            throw DICOMError.invalidDICOMFormat(reason: "Unexpected end of JPEG bitstream")
        }
        bitCount -= count
    }

    /// Reads `count` (0...16) raw bits, most significant first.
    @inline(__always)
    mutating func readBits(_ count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        let value = peek(count)
        try consume(count)
        return value
    }

    /// Decodes one Huffman symbol (T.81 F.2.2.3) — one table lookup for codes up to `HuffmanTable.lookupBits`.
    @inline(__always)
    mutating func decodeSymbol(_ table: JPEGLosslessDecodingTable) throws -> Int {
        let entry = table.lookup[peek(HuffmanTable.lookupBits)]
        if entry != 0 {
            try consume(Int(entry >> 8))
            return Int(entry & 0xFF)
        }
        for length in (HuffmanTable.lookupBits + 1)...16 {
            let code = peek(length)
            if table.minCode[length] >= 0, code <= table.maxCode[length] {
                let symbolIndex = table.valPtr[length] + (code - table.minCode[length])
                guard symbolIndex >= 0, symbolIndex < table.symbolCount else {
                    throw DICOMError.invalidDICOMFormat(reason: "Huffman symbol index out of range: \(symbolIndex)")
                }
                try consume(length)
                return Int(table.symbols[symbolIndex])
            }
        }
        throw DICOMError.invalidDICOMFormat(reason: "Invalid Huffman code encountered")
    }

    /// The signed difference for category `ssss` (T.81 H.1.2.2 / Table H.2); SSSS 16 carries no extra bits.
    @inline(__always)
    mutating func readDifference(category ssss: Int) throws -> Int {
        if ssss == 0 { return 0 }
        if ssss == 16 { return 32768 }
        let bits = try readBits(ssss)
        return bits < (1 << (ssss - 1)) ? bits - (1 << ssss) + 1 : bits
    }

    /// Byte-aligns over the all-ones padding and consumes the next RSTn marker, returning `n`.
    mutating func consumeRestartMarker() throws -> Int {
        fill()
        guard bitCount <= 7 else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) at the restart boundary but found additional entropy data"
            )
        }
        if bitCount > 0 {
            let paddingMask = UInt64((1 << bitCount) - 1)
            guard accumulator & paddingMask == paddingMask else {
                throw DICOMError.invalidDICOMFormat(reason: "Expected JPEG restart marker (RSTn) after all-ones entropy padding")
            }
        }
        accumulator = 0
        bitCount = 0
        guard position + 1 < end else {
            throw DICOMError.invalidDICOMFormat(reason: "Entropy-coded data ended while expecting a JPEG restart marker (RSTn)")
        }
        guard bytes[position] == JPEGMarker.prefix else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) at the restart boundary but found entropy byte "
                    + "0x\(String(bytes[position], radix: 16, uppercase: true))"
            )
        }
        while position + 1 < end, bytes[position + 1] == JPEGMarker.prefix {
            position += 1
        }
        guard position + 1 < end else {
            throw DICOMError.invalidDICOMFormat(reason: "Entropy-coded data ended while expecting a JPEG restart marker (RSTn)")
        }
        let marker = bytes[position + 1]
        guard JPEGMarker.isRestart(marker) else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) in entropy-coded data but found marker "
                    + "0xFF\(String(marker, radix: 16, uppercase: true))"
            )
        }
        position += 2
        return Int(marker - 0xD0)
    }
}

/// Pointer view of a built `HuffmanTable` for the hot loop (no array retain/release per sample). Owned by the
/// decoder for the duration of one scan; `deallocate()` releases it.
struct JPEGLosslessDecodingTable {
    let lookup: UnsafeMutablePointer<UInt16>
    let minCode: UnsafeMutablePointer<Int>
    let maxCode: UnsafeMutablePointer<Int>
    let valPtr: UnsafeMutablePointer<Int>
    let symbols: UnsafeMutablePointer<UInt8>
    let symbolCount: Int

    init(_ table: HuffmanTable) {
        lookup = UnsafeMutablePointer<UInt16>.allocate(capacity: 1 << HuffmanTable.lookupBits)
        lookup.initialize(repeating: 0, count: 1 << HuffmanTable.lookupBits)
        for (index, value) in table.lookup.prefix(1 << HuffmanTable.lookupBits).enumerated() { lookup[index] = value }
        minCode = UnsafeMutablePointer<Int>.allocate(capacity: 17)
        maxCode = UnsafeMutablePointer<Int>.allocate(capacity: 17)
        valPtr = UnsafeMutablePointer<Int>.allocate(capacity: 17)
        for index in 0..<17 {
            minCode[index] = index < table.minCode.count ? table.minCode[index] : -1
            maxCode[index] = index < table.maxCode.count ? table.maxCode[index] : -1
            valPtr[index] = index < table.valPtr.count ? table.valPtr[index] : 0
        }
        symbolCount = table.symbolValues.count
        symbols = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, symbolCount))
        for (index, value) in table.symbolValues.enumerated() { symbols[index] = value }
    }

    func deallocate() {
        lookup.deallocate()
        minCode.deallocate()
        maxCode.deallocate()
        valPtr.deallocate()
        symbols.deallocate()
    }
}
