//
//  JPEGExtendedDecoder.swift
//  DicomCore
//
//  Native sequential-DCT Huffman JPEG decoder for DICOM JPEG Extended
//  (Process 2 and 4, SOF1) grayscale frames (issue #1228). Exists so 12-bit
//  JPEG Extended payloads decode without the 8-bit precision loss the
//  ImageIO fallback would introduce. Also accepts 8-bit SOF0/SOF1 streams,
//  but the backend resolver keeps <=8-bit frames on ImageIO; this decoder
//  is selected only when precision preservation requires it.
//
//  Scope: single-component (grayscale) sequential Huffman scans with
//  optional restart intervals. Progressive (SOF2), hierarchical, arithmetic
//  coding, lossless processes, and multi-component scans are rejected with
//  typed errors — they are either out of Process 2/4 scope or owned by
//  other backends (JPEGLosslessDecoder, ImageIO).
//

import Foundation

public enum JPEGExtendedDecoder {
    public struct DecodedFrame: Equatable, Sendable {
        /// Level-shifted samples clamped to `0...(2^precision - 1)`,
        /// row-major, one sample per pixel.
        public let pixels: [UInt16]
        public let width: Int
        public let height: Int
        /// Sample precision declared by the SOF segment (8...12).
        public let precision: Int
    }

    public enum DecodeError: Error, Equatable, LocalizedError, Sendable {
        case notAJPEGStream
        case progressiveModeUnsupported
        case hierarchicalModeUnsupported
        case arithmeticCodingUnsupported
        case losslessProcessNotSequential
        case multiComponentUnsupported(components: Int)
        case precisionUnsupported(bits: Int)
        case missingQuantizationTable(id: Int)
        case missingHuffmanTable(tableClass: Int, id: Int)
        case missingStartOfFrame
        case missingStartOfScan
        case truncatedStream
        case invalidHuffmanCode
        case restartMarkerMismatch(expected: Int, found: Int)
        case invalidDimensions(width: Int, height: Int)

        public var errorDescription: String? {
            switch self {
            case .notAJPEGStream:
                return "The payload does not start with a JPEG SOI marker."
            case .progressiveModeUnsupported:
                return "Progressive JPEG (SOF2) is not part of JPEG Extended Process 2/4."
            case .hierarchicalModeUnsupported:
                return "Hierarchical JPEG processes are not supported."
            case .arithmeticCodingUnsupported:
                return "Arithmetic-coded JPEG processes are not supported; Process 2/4 decoding covers Huffman scans."
            case .losslessProcessNotSequential:
                return "Lossless JPEG (SOF3) is decoded by JPEGLosslessDecoder, not the sequential-DCT path."
            case .multiComponentUnsupported(let components):
                return "JPEG Extended native decoding supports single-component grayscale; the stream declares \(components) components."
            case .precisionUnsupported(let bits):
                return "JPEG Extended sample precision must be 2...12 bits; the stream declares \(bits)."
            case .missingQuantizationTable(let id):
                return "The scan references undefined quantization table \(id)."
            case .missingHuffmanTable(let tableClass, let id):
                return "The scan references undefined Huffman table class \(tableClass), id \(id)."
            case .missingStartOfFrame:
                return "No SOF segment was found before the scan."
            case .missingStartOfScan:
                return "No SOS segment was found."
            case .truncatedStream:
                return "The entropy-coded data ended before the frame was complete."
            case .invalidHuffmanCode:
                return "The entropy-coded data contains an invalid Huffman code."
            case .restartMarkerMismatch(let expected, let found):
                return "Expected restart marker RST\(expected) but found RST\(found)."
            case .invalidDimensions(let width, let height):
                return "The SOF segment declares invalid dimensions \(width)x\(height)."
            }
        }
    }

    // MARK: - Public entry point

    public static func decode(_ data: Data) throws -> DecodedFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw DecodeError.notAJPEGStream
        }

        var quantizationTables = [Int: [Int]]()
        var dcTables = [Int: HuffmanTable]()
        var acTables = [Int: HuffmanTable]()
        var frame: FrameHeader?
        var restartInterval = 0
        var scan: ScanHeader?
        var entropyStart = 0

        var index = 2
        markerLoop: while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else {
                throw DecodeError.truncatedStream
            }
            var marker = bytes[index + 1]
            index += 2
            while marker == 0xFF, index < bytes.count {
                marker = bytes[index]
                index += 1
            }

            switch marker {
            case 0xD8: // unexpected second SOI; tolerate
                continue
            case 0xD9: // EOI before any scan
                break markerLoop
            case 0x01, 0xD0...0xD7: // standalone markers
                continue
            default:
                break
            }

            guard index + 1 < bytes.count else {
                throw DecodeError.truncatedStream
            }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else {
                throw DecodeError.truncatedStream
            }
            let segment = Array(bytes[(index + 2)..<(index + length)])
            index += length

            switch marker {
            case 0xC0, 0xC1: // SOF0 baseline / SOF1 extended sequential
                frame = try parseFrameHeader(segment)
            case 0xC2:
                throw DecodeError.progressiveModeUnsupported
            case 0xC3:
                throw DecodeError.losslessProcessNotSequential
            case 0xC5, 0xC6, 0xC7, 0xCD, 0xCE, 0xCF:
                throw DecodeError.hierarchicalModeUnsupported
            case 0xC9, 0xCA, 0xCB:
                throw DecodeError.arithmeticCodingUnsupported
            case 0xC4: // DHT
                try parseHuffmanTables(segment, dcTables: &dcTables, acTables: &acTables)
            case 0xDB: // DQT
                try parseQuantizationTables(segment, into: &quantizationTables)
            case 0xDD: // DRI
                guard segment.count >= 2 else { throw DecodeError.truncatedStream }
                restartInterval = Int(segment[0]) << 8 | Int(segment[1])
            case 0xDA: // SOS
                scan = try parseScanHeader(segment)
                entropyStart = index
                break markerLoop
            default: // APPn, COM, and other length-bearing segments
                continue
            }
        }

        guard let frame else { throw DecodeError.missingStartOfFrame }
        guard let scan else { throw DecodeError.missingStartOfScan }
        guard let quantization = quantizationTables[frame.quantizationTableID] else {
            throw DecodeError.missingQuantizationTable(id: frame.quantizationTableID)
        }
        guard let dcTable = dcTables[scan.dcTableID] else {
            throw DecodeError.missingHuffmanTable(tableClass: 0, id: scan.dcTableID)
        }
        guard let acTable = acTables[scan.acTableID] else {
            throw DecodeError.missingHuffmanTable(tableClass: 1, id: scan.acTableID)
        }

        return try decodeScan(
            bytes: bytes,
            entropyStart: entropyStart,
            frame: frame,
            quantization: quantization,
            dcTable: dcTable,
            acTable: acTable,
            restartInterval: restartInterval
        )
    }

    // MARK: - Header parsing

    private struct FrameHeader {
        let precision: Int
        let width: Int
        let height: Int
        let quantizationTableID: Int
    }

    private struct ScanHeader {
        let dcTableID: Int
        let acTableID: Int
    }

    private static func parseFrameHeader(_ segment: [UInt8]) throws -> FrameHeader {
        guard segment.count >= 6 else { throw DecodeError.truncatedStream }
        let precision = Int(segment[0])
        let height = Int(segment[1]) << 8 | Int(segment[2])
        let width = Int(segment[3]) << 8 | Int(segment[4])
        let componentCount = Int(segment[5])
        guard precision >= 2, precision <= 12 else {
            throw DecodeError.precisionUnsupported(bits: precision)
        }
        guard componentCount == 1 else {
            throw DecodeError.multiComponentUnsupported(components: componentCount)
        }
        guard width > 0, height > 0 else {
            throw DecodeError.invalidDimensions(width: width, height: height)
        }
        guard segment.count >= 6 + 3 else { throw DecodeError.truncatedStream }
        // Component: id, sampling factors (irrelevant for one component), Tq.
        let quantizationTableID = Int(segment[8])
        return FrameHeader(
            precision: precision,
            width: width,
            height: height,
            quantizationTableID: quantizationTableID
        )
    }

    private static func parseScanHeader(_ segment: [UInt8]) throws -> ScanHeader {
        guard segment.count >= 1 else { throw DecodeError.truncatedStream }
        let componentCount = Int(segment[0])
        guard componentCount == 1 else {
            throw DecodeError.multiComponentUnsupported(components: componentCount)
        }
        guard segment.count >= 1 + 2 else { throw DecodeError.truncatedStream }
        let tableSelector = segment[2]
        return ScanHeader(
            dcTableID: Int(tableSelector >> 4),
            acTableID: Int(tableSelector & 0x0F)
        )
    }

    private static func parseQuantizationTables(
        _ segment: [UInt8],
        into tables: inout [Int: [Int]]
    ) throws {
        var offset = 0
        while offset < segment.count {
            let precisionAndID = segment[offset]
            let entryIs16Bit = (precisionAndID >> 4) != 0
            let tableID = Int(precisionAndID & 0x0F)
            offset += 1
            let entryCount = 64
            let byteCount = entryIs16Bit ? entryCount * 2 : entryCount
            guard offset + byteCount <= segment.count else {
                throw DecodeError.truncatedStream
            }
            var table = [Int](repeating: 0, count: entryCount)
            for entry in 0..<entryCount {
                if entryIs16Bit {
                    table[entry] = Int(segment[offset + entry * 2]) << 8
                        | Int(segment[offset + entry * 2 + 1])
                } else {
                    table[entry] = Int(segment[offset + entry])
                }
            }
            tables[tableID] = table
            offset += byteCount
        }
    }

    // MARK: - Huffman tables (canonical, JPEG Annex C)

    private struct HuffmanTable {
        let minCode: [Int]
        let maxCode: [Int]
        let valuePointer: [Int]
        let symbols: [UInt8]
    }

    private static func parseHuffmanTables(
        _ segment: [UInt8],
        dcTables: inout [Int: HuffmanTable],
        acTables: inout [Int: HuffmanTable]
    ) throws {
        var offset = 0
        while offset < segment.count {
            guard offset + 17 <= segment.count else { throw DecodeError.truncatedStream }
            let classAndID = segment[offset]
            let tableClass = Int(classAndID >> 4)
            let tableID = Int(classAndID & 0x0F)
            let counts = Array(segment[(offset + 1)..<(offset + 17)]).map(Int.init)
            let symbolCount = counts.reduce(0, +)
            guard offset + 17 + symbolCount <= segment.count else {
                throw DecodeError.truncatedStream
            }
            let symbols = Array(segment[(offset + 17)..<(offset + 17 + symbolCount)])
            offset += 17 + symbolCount

            var minCode = [Int](repeating: -1, count: 17)
            var maxCode = [Int](repeating: -1, count: 17)
            var valuePointer = [Int](repeating: 0, count: 17)
            var code = 0
            var symbolIndex = 0
            for length in 1...16 {
                let count = counts[length - 1]
                if count > 0 {
                    valuePointer[length] = symbolIndex
                    minCode[length] = code
                    code += count
                    symbolIndex += count
                    maxCode[length] = code - 1
                }
                code <<= 1
            }
            let table = HuffmanTable(
                minCode: minCode,
                maxCode: maxCode,
                valuePointer: valuePointer,
                symbols: symbols
            )
            if tableClass == 0 {
                dcTables[tableID] = table
            } else {
                acTables[tableID] = table
            }
        }
    }

    // MARK: - Entropy-coded scan

    private final class BitReader {
        private let bytes: [UInt8]
        private(set) var index: Int
        private var currentByte: UInt8 = 0
        private var bitsRemaining = 0
        private(set) var pendingRestartMarker: Int?
        private(set) var reachedEndOfScan = false

        init(bytes: [UInt8], start: Int) {
            self.bytes = bytes
            self.index = start
        }

        func nextBit() throws -> Int {
            if bitsRemaining == 0 {
                try loadByte()
            }
            bitsRemaining -= 1
            return Int((currentByte >> UInt8(bitsRemaining)) & 1)
        }

        func receive(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | (try nextBit())
            }
            return value
        }

        /// Byte-aligns and consumes the next restart marker.
        func consumeRestartMarker() throws -> Int {
            bitsRemaining = 0
            pendingRestartMarker = nil
            while index + 1 < bytes.count {
                if bytes[index] == 0xFF {
                    let marker = bytes[index + 1]
                    if marker >= 0xD0, marker <= 0xD7 {
                        index += 2
                        return Int(marker - 0xD0)
                    }
                    if marker == 0xFF { // fill byte
                        index += 1
                        continue
                    }
                    throw DecodeError.truncatedStream
                }
                index += 1
            }
            throw DecodeError.truncatedStream
        }

        private func loadByte() throws {
            // A pending restart marker where data was expected means the
            // entropy data is shorter than the frame needs.
            guard pendingRestartMarker == nil else {
                throw DecodeError.truncatedStream
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte != 0xFF {
                    currentByte = byte
                    bitsRemaining = 8
                    index += 1
                    return
                }
                guard index + 1 < bytes.count else {
                    throw DecodeError.truncatedStream
                }
                let next = bytes[index + 1]
                if next == 0x00 { // byte-stuffed 0xFF data byte
                    currentByte = 0xFF
                    bitsRemaining = 8
                    index += 2
                    return
                }
                if next >= 0xD0, next <= 0xD7 {
                    pendingRestartMarker = Int(next - 0xD0)
                    throw DecodeError.truncatedStream
                }
                if next == 0xFF { // fill byte
                    index += 1
                    continue
                }
                // Any other marker (typically EOI) ends the scan.
                reachedEndOfScan = true
                throw DecodeError.truncatedStream
            }
            throw DecodeError.truncatedStream
        }
    }

    private static func decodeHuffmanSymbol(_ reader: BitReader, table: HuffmanTable) throws -> Int {
        var code = 0
        for length in 1...16 {
            code = (code << 1) | (try reader.nextBit())
            let maxCode = table.maxCode[length]
            if maxCode >= 0, code <= maxCode {
                let symbolIndex = table.valuePointer[length] + code - table.minCode[length]
                guard symbolIndex < table.symbols.count else {
                    throw DecodeError.invalidHuffmanCode
                }
                return Int(table.symbols[symbolIndex])
            }
        }
        throw DecodeError.invalidHuffmanCode
    }

    /// JPEG EXTEND (Annex F.2.2.1): converts a received magnitude-category
    /// value into the signed difference/coefficient.
    private static func extend(_ value: Int, bitCount: Int) -> Int {
        guard bitCount > 0 else { return 0 }
        if value < (1 << (bitCount - 1)) {
            return value - (1 << bitCount) + 1
        }
        return value
    }

    private static let zigzagToNatural: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
    ]

    /// `idctBasis[position][frequency] = C(frequency) * cos((2*position+1) * frequency * pi / 16)`
    private static let idctBasis: [[Double]] = {
        (0..<8).map { position in
            (0..<8).map { frequency in
                let scale = frequency == 0 ? (1.0 / 2.0.squareRoot()) : 1.0
                let angle = Double(2 * position + 1) * Double(frequency) * Double.pi / 16.0
                return scale * Foundation.cos(angle)
            }
        }
    }()

    private static func decodeScan(
        bytes: [UInt8],
        entropyStart: Int,
        frame: FrameHeader,
        quantization: [Int],
        dcTable: HuffmanTable,
        acTable: HuffmanTable,
        restartInterval: Int
    ) throws -> DecodedFrame {
        let blocksWide = (frame.width + 7) / 8
        let blocksHigh = (frame.height + 7) / 8
        let levelShift = 1 << (frame.precision - 1)
        let maxSample = (1 << frame.precision) - 1
        var pixels = [UInt16](repeating: 0, count: frame.width * frame.height)

        let reader = BitReader(bytes: bytes, start: entropyStart)
        var dcPredictor = 0
        var restartCount = 0
        var coefficients = [Double](repeating: 0, count: 64)

        for blockIndex in 0..<(blocksWide * blocksHigh) {
            if restartInterval > 0, blockIndex > 0, blockIndex % restartInterval == 0 {
                let found = try reader.consumeRestartMarker()
                let expected = restartCount % 8
                guard found == expected else {
                    throw DecodeError.restartMarkerMismatch(expected: expected, found: found)
                }
                restartCount += 1
                dcPredictor = 0
            }

            for entry in 0..<64 {
                coefficients[entry] = 0
            }

            // DC coefficient.
            let dcCategory = try decodeHuffmanSymbol(reader, table: dcTable)
            guard dcCategory <= 15 else { throw DecodeError.invalidHuffmanCode }
            let difference = dcCategory == 0
                ? 0
                : extend(try reader.receive(dcCategory), bitCount: dcCategory)
            dcPredictor += difference
            coefficients[0] = Double(dcPredictor * quantization[0])

            // AC coefficients.
            var coefficientIndex = 1
            while coefficientIndex < 64 {
                let runAndSize = try decodeHuffmanSymbol(reader, table: acTable)
                if runAndSize == 0x00 { // EOB
                    break
                }
                if runAndSize == 0xF0 { // ZRL: sixteen zero coefficients
                    coefficientIndex += 16
                    guard coefficientIndex <= 64 else { throw DecodeError.invalidHuffmanCode }
                    continue
                }
                let zeroRun = runAndSize >> 4
                let magnitudeBits = runAndSize & 0x0F
                guard magnitudeBits > 0 else { throw DecodeError.invalidHuffmanCode }
                coefficientIndex += zeroRun
                guard coefficientIndex < 64 else { throw DecodeError.invalidHuffmanCode }
                let value = extend(try reader.receive(magnitudeBits), bitCount: magnitudeBits)
                coefficients[zigzagToNatural[coefficientIndex]] =
                    Double(value * quantization[coefficientIndex])
                coefficientIndex += 1
            }

            // Inverse DCT and level shift into the output raster.
            let blockX = (blockIndex % blocksWide) * 8
            let blockY = (blockIndex / blocksWide) * 8
            for y in 0..<8 {
                let pixelY = blockY + y
                guard pixelY < frame.height else { break }
                for x in 0..<8 {
                    let pixelX = blockX + x
                    guard pixelX < frame.width else { continue }
                    var sum = 0.0
                    for v in 0..<8 {
                        let basisY = idctBasis[y][v]
                        for u in 0..<8 {
                            let coefficient = coefficients[v * 8 + u]
                            if coefficient != 0 {
                                sum += coefficient * idctBasis[x][u] * basisY
                            }
                        }
                    }
                    let sample = Int((sum / 4.0).rounded()) + levelShift
                    pixels[pixelY * frame.width + pixelX] =
                        UInt16(min(max(sample, 0), maxSample))
                }
            }
        }

        return DecodedFrame(
            pixels: pixels,
            width: frame.width,
            height: frame.height,
            precision: frame.precision
        )
    }
}
