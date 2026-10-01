// JPEGReconstruction.swift — issue #2334
//
// Own JPEG reader/writer pair for JPEG XL JPEG recompression (`.111`),
// written against the reference semantics of libjxl 0.11
// (`jpeg/enc_jpeg_data_reader.cc`, `jpeg/dec_jpeg_data_writer.cc`,
// `jpeg/jpeg_data.cc`; BSD-3-Clause, materials preserved). The reader
// turns a JPEG interchange stream into the `JPEGData` model that the
// `jbrd` box carries (`JBRDBox`) plus the quantised coefficients of every
// component; the writer serialises that model back into the identical
// byte sequence. Everything the entropy-coded segments contain beyond the
// coefficients — restart markers, padding bits that are not all ones,
// end-of-band runs that reset early, extra zero runs before an end of
// block, data between markers, bytes after EOI — is recorded so that the
// reconstruction is exact, or refused with a typed error.

import Foundation

package enum JPEGReconstructionError: Error, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    package var description: String {
        switch self {
        case .malformed(let s): return "malformed JPEG: \(s)"
        case .unsupported(let s): return "unsupported JPEG: \(s)"
        }
    }
}

/// The reconstruction model of one JPEG: the `jbrd` bundle and the
/// quantised coefficients per component (block-major, natural order
/// inside each 64-coefficient block, libjxl `JPEGComponent::coeffs`).
package struct JPEGReconstructionImage: Sendable {
    package var jbrd: JBRDBox
    package var coefficients: [[Int16]]
    package var isProgressive: Bool
}

/// libjxl `kJPEGNaturalOrder`: zig-zag index → natural (row-major) index.
let jpegNaturalOrder: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    // libjxl pads the table to 80 entries so that runs may index past 63.
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
]

// MARK: - Reader

package enum JPEGReconstructionReader {
    private static let maxComponents = 4
    private static let maxHuffmanTables = 4
    private static let maxDimension = 65535
    private static let maxDHTMarkers = 512
    private static let dcAlphabetSize = 12
    private static let huffmanAlphabetSize = 256

    /// libjxl `kIsValidMarker` (indexed by marker − 0xC0).
    private static let validMarker: [Bool] = [
        true, true, true, false, true, false, false, false, false, false, false, false, false, false, false, false,
        true, true, true, true, true, true, true, true, false, true, true, true, false, true, false, false,
        true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true,
        false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false,
    ]

    private struct Component {
        var id: Int
        var h: Int
        var v: Int
        var quantIdx: Int
        var quantTableIndex: Int? = nil
        var widthInBlocks: Int
        var heightInBlocks: Int
    }

    /// Canonical Huffman decoding table (`maxcode`/`valptr` form).
    private struct HuffmanDecoder {
        var maxCode = [Int](repeating: -1, count: 18)
        var valPtr = [Int](repeating: 0, count: 17)
        var minCode = [Int](repeating: 0, count: 17)
        var values: [Int] = []
        var defined = false

        init() {}

        init(counts: [Int], values: [Int]) {
            self.values = values
            var code = 0
            var k = 0
            for l in 1...16 {
                let n = counts[l]
                valPtr[l] = k
                minCode[l] = code
                code += n
                k += n
                maxCode[l] = n > 0 ? code - 1 : -1
                code <<= 1
            }
            maxCode[17] = Int.max
            defined = true
        }
    }

    private struct BitReaderState {
        let data: [UInt8]
        var pos: Int
        var val: UInt64 = 0
        var bitsLeft = 0
        var nextMarkerPos: Int

        init(data: [UInt8], pos: Int) {
            self.data = data
            self.pos = pos
            nextMarkerPos = data.count - 2
            reset(pos)
        }

        mutating func reset(_ p: Int) {
            pos = p
            val = 0
            bitsLeft = 0
            nextMarkerPos = data.count - 2
            fillBitWindow()
        }

        mutating func nextByte() -> UInt8 {
            if pos >= nextMarkerPos {
                pos += 1
                return 0
            }
            let c = data[pos]
            pos += 1
            if c == 0xFF {
                let escape = data[pos]
                if escape == 0 {
                    pos += 1
                } else {
                    nextMarkerPos = pos - 1
                }
            }
            return c
        }

        mutating func fillBitWindow() {
            if bitsLeft <= 16 {
                while bitsLeft <= 56 {
                    val <<= 8
                    val |= UInt64(nextByte())
                    bitsLeft += 8
                }
            }
        }

        mutating func readBits(_ n: Int) -> Int {
            fillBitWindow()
            let v = (val >> UInt64(bitsLeft - n)) & ((UInt64(1) << UInt64(n)) - 1)
            bitsLeft -= n
            return Int(v)
        }

        /// `FinishStream`: records the padding bits of this entropy segment
        /// and rewinds the bytes the window read past the marker.
        mutating func finishStream(box: inout JBRDBox) throws -> Int {
            let npadbits = bitsLeft & 7
            if npadbits > 0 {
                let padmask: UInt64 = (UInt64(1) << UInt64(npadbits)) - 1
                let padbits = (val >> UInt64(bitsLeft - npadbits)) & padmask
                if padbits != padmask { box.hasZeroPaddingBit = true }
                for i in stride(from: npadbits - 1, through: 0, by: -1) {
                    box.paddingBits.append(UInt8((padbits >> UInt64(i)) & 1))
                }
            }
            var unusedBytesLeft = bitsLeft >> 3
            while unusedBytesLeft > 0 {
                unusedBytesLeft -= 1
                pos -= 1
                if pos < nextMarkerPos, pos >= 1, data[pos] == 0, data[pos - 1] == 0xFF {
                    pos -= 1
                }
            }
            guard pos <= nextMarkerPos else { throw JPEGReconstructionError.malformed("unexpected end of scan") }
            return pos
        }

        mutating func readSymbol(_ table: HuffmanDecoder) throws -> Int {
            guard table.defined else { throw JPEGReconstructionError.malformed("Huffman table used before it is defined") }
            var code = 0
            for l in 1...16 {
                code = (code << 1) | readBits(1)
                if code <= table.maxCode[l] {
                    let index = table.valPtr[l] + code - table.minCode[l]
                    guard index < table.values.count else { break }
                    return table.values[index]
                }
            }
            throw JPEGReconstructionError.malformed("invalid Huffman code")
        }
    }

    @inline(__always)
    private static func huffExtend(_ x: Int, _ s: Int) -> Int {
        let half = 1 << (s - 1)
        return x >= half ? x : x - (1 << s) + 1
    }

    package static func read(_ input: Data) throws -> JPEGReconstructionImage {
        let data = [UInt8](input)
        let len = data.count
        guard len >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw JPEGReconstructionError.malformed("missing SOI marker")
        }
        var box = JBRDBox()
        var components: [Component] = []
        var coefficients: [[Int16]] = []
        var dcTables = [HuffmanDecoder](repeating: HuffmanDecoder(), count: maxHuffmanTables)
        var acTables = [HuffmanDecoder](repeating: HuffmanDecoder(), count: maxHuffmanTables)
        var scanProgression = [[UInt16]](repeating: [UInt16](repeating: 0, count: 64), count: maxComponents)
        var foundSOF = false
        var foundDRI = false
        var isProgressive = false
        var pos = 2
        var marker = 0xD8

        func readU16(_ p: inout Int) -> Int {
            let v = (Int(data[p]) << 8) | Int(data[p + 1])
            p += 2
            return v
        }
        func verifyLen(_ p: Int, _ n: Int) throws {
            guard p + n <= len else { throw JPEGReconstructionError.malformed("unexpected end of input") }
        }

        repeat {
            // `FindNextMarker`: bytes before the next valid marker are inter-marker data.
            var skipped = 0
            while pos + 1 < len, data[pos] != 0xFF || data[pos + 1] < 0xC0 || !validMarker[Int(data[pos + 1]) - 0xC0] {
                // A frame marker of a process the bridge does not carry is a
                // typed refusal, not inter-marker data (libjxl skips it and
                // fails on the following scan).
                if !foundSOF, data[pos] == 0xFF, [0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].contains(data[pos + 1]) {
                    throw JPEGReconstructionError.unsupported(
                        "SOF\(Int(data[pos + 1]) - 0xC0) (lossless, hierarchical or arithmetic-coded process); "
                        + "only SOF0, SOF1 and SOF2 with Huffman coding are recompressed")
                }
                pos += 1
                skipped += 1
            }
            if skipped > 0 {
                box.markerOrder.append(0xFF)
                box.interMarkerData.append(Data(data[(pos - skipped)..<pos]))
            }
            guard pos + 2 <= len, data[pos] == 0xFF else {
                throw JPEGReconstructionError.malformed("marker byte expected at \(pos)")
            }
            marker = Int(data[pos + 1])
            pos += 2
            switch marker {
            case 0xC0, 0xC1, 0xC2:
                isProgressive = marker == 0xC2
                guard !foundSOF else { throw JPEGReconstructionError.malformed("duplicate SOF marker") }
                let start = pos
                try verifyLen(pos, 8)
                let markerLen = readU16(&pos)
                let precision = Int(data[pos]); pos += 1
                let height = readU16(&pos)
                let width = readU16(&pos)
                let n = Int(data[pos]); pos += 1
                guard precision == 8 else { throw JPEGReconstructionError.unsupported("\(precision)-bit precision (8-bit only)") }
                guard (1...maxDimension).contains(height), (1...maxDimension).contains(width) else {
                    throw JPEGReconstructionError.malformed("invalid dimensions \(width)x\(height)")
                }
                guard (1...maxComponents).contains(n) else { throw JPEGReconstructionError.malformed("invalid component count \(n)") }
                try verifyLen(pos, 3 * n)
                box.width = width
                box.height = height
                var seen = [Bool](repeating: false, count: 256)
                var maxH = 1, maxV = 1
                for _ in 0..<n {
                    let id = Int(data[pos]); pos += 1
                    guard !seen[id] else { throw JPEGReconstructionError.malformed("duplicate component id \(id) in SOF") }
                    seen[id] = true
                    let factor = Int(data[pos]); pos += 1
                    let h = factor >> 4, v = factor & 0xF
                    guard (1...15).contains(h), (1...15).contains(v) else {
                        throw JPEGReconstructionError.malformed("invalid sampling factor \(h)x\(v)")
                    }
                    let q = Int(data[pos]); pos += 1
                    components.append(Component(id: id, h: h, v: v, quantIdx: q, widthInBlocks: 0, heightInBlocks: 0))
                    maxH = max(maxH, h)
                    maxV = max(maxV, v)
                }
                let mcuRows = (height + maxV * 8 - 1) / (maxV * 8)
                let mcuCols = (width + maxH * 8 - 1) / (maxH * 8)
                for i in 0..<components.count {
                    guard maxH % components[i].h == 0, maxV % components[i].v == 0 else {
                        throw JPEGReconstructionError.malformed("non-integral subsampling ratios")
                    }
                    components[i].widthInBlocks = mcuCols * components[i].h
                    components[i].heightInBlocks = mcuRows * components[i].v
                    coefficients.append([Int16](repeating: 0, count: components[i].widthInBlocks * components[i].heightInBlocks * 64))
                }
                guard start + markerLen == pos else { throw JPEGReconstructionError.malformed("invalid SOF length") }
                foundSOF = true
            case 0xC4:
                let start = pos
                try verifyLen(pos, 2)
                let markerLen = readU16(&pos)
                guard markerLen > 2 else { throw JPEGReconstructionError.malformed("DHT without tables") }
                while pos < start + markerLen {
                    try verifyLen(pos, 17)
                    let slot = Int(data[pos]); pos += 1
                    let isAC = slot & 0x10 != 0
                    let index = slot & 0x0F
                    guard slot & 0xE0 == 0, index <= 3 else { throw JPEGReconstructionError.malformed("invalid Huffman table slot \(slot)") }
                    var counts = [Int](repeating: 0, count: 17)
                    var total = 0
                    var space = 1 << 16
                    var maxDepth = 1
                    for l in 1...16 {
                        let c = Int(data[pos]); pos += 1
                        if c != 0 { maxDepth = l }
                        counts[l] = c
                        total += c
                        space -= c * (1 << (16 - l))
                    }
                    guard total <= (isAC ? huffmanAlphabetSize : dcAlphabetSize) else {
                        throw JPEGReconstructionError.malformed("too many Huffman codes")
                    }
                    try verifyLen(pos, total)
                    var valuesSeen = [Bool](repeating: false, count: 256)
                    var values: [Int] = []
                    for _ in 0..<total {
                        let v = Int(data[pos]); pos += 1
                        if !isAC { guard v < dcAlphabetSize else { throw JPEGReconstructionError.malformed("invalid DC Huffman value \(v)") } }
                        guard !valuesSeen[v] else { throw JPEGReconstructionError.malformed("duplicate Huffman code value \(v)") }
                        valuesSeen[v] = true
                        values.append(v)
                    }
                    space -= 1 << (16 - maxDepth)
                    guard space >= 0 else { throw JPEGReconstructionError.malformed("invalid Huffman code lengths") }
                    let decoder = HuffmanDecoder(counts: counts, values: values)
                    if isAC { acTables[index] = decoder } else { dcTables[index] = decoder }
                    // The bundle form: the sentinel symbol at the deepest length.
                    var boxCounts = counts.map { UInt32($0) }
                    boxCounts[maxDepth] += 1
                    var boxValues = values.map { UInt32($0) }
                    boxValues.append(UInt32(huffmanAlphabetSize))
                    box.huffmanCode.append(JBRDHuffmanCode(
                        counts: boxCounts, values: boxValues, slotId: slot, isLast: pos == start + markerLen))
                }
                guard start + markerLen == pos else { throw JPEGReconstructionError.malformed("invalid DHT length") }
            case 0xD0...0xD7, 0xD9:
                break
            case 0xDA:
                guard foundSOF else { throw JPEGReconstructionError.malformed("SOS before SOF") }
                try processScan(data, &pos, &box, &components, &coefficients, dcTables, acTables, &scanProgression, isProgressive)
            case 0xDB:
                let start = pos
                try verifyLen(pos, 2)
                let markerLen = readU16(&pos)
                guard markerLen > 2 else { throw JPEGReconstructionError.malformed("DQT without tables") }
                while pos < start + markerLen, box.quant.count < 4 {
                    try verifyLen(pos, 1)
                    let pq = Int(data[pos]) >> 4, tq = Int(data[pos]) & 0xF
                    pos += 1
                    guard pq <= 1, tq <= 3 else { throw JPEGReconstructionError.malformed("invalid DQT header") }
                    try verifyLen(pos, (pq + 1) * 64)
                    var zigzag = [Int32](repeating: 0, count: 64)
                    for i in 0..<64 {
                        let v = pq == 1 ? readU16(&pos) : { let b = Int(data[pos]); pos += 1; return b }()
                        guard v >= 1 else { throw JPEGReconstructionError.malformed("zero quantisation value") }
                        zigzag[i] = Int32(v)
                    }
                    box.quant.append(JBRDQuantTable(precision: UInt32(pq), index: UInt32(tq), isLast: pos == start + markerLen, values: zigzag))
                }
                guard start + markerLen == pos else { throw JPEGReconstructionError.malformed("invalid DQT length") }
            case 0xDD:
                guard !foundDRI else { throw JPEGReconstructionError.malformed("duplicate DRI marker") }
                foundDRI = true
                let start = pos
                try verifyLen(pos, 4)
                let markerLen = readU16(&pos)
                box.restartInterval = UInt32(readU16(&pos))
                guard start + markerLen == pos else { throw JPEGReconstructionError.malformed("invalid DRI length") }
            case 0xE0...0xEF, 0xFE:
                try verifyLen(pos, 2)
                let markerLen = readU16(&pos)
                guard markerLen >= 2 else { throw JPEGReconstructionError.malformed("invalid marker length") }
                try verifyLen(pos, markerLen - 2)
                // libjxl keeps the marker byte, the length and the payload.
                let segment = Data(data[(pos - 3)..<(pos - 2 + markerLen)])
                pos += markerLen - 2
                if marker == 0xFE {
                    box.comData.append(segment)
                } else {
                    box.appData.append(segment)
                    box.appMarkerType.append(.unknown)
                }
            default:
                throw JPEGReconstructionError.unsupported(
                    "marker 0x\(String(marker, radix: 16, uppercase: true)) (arithmetic, hierarchical, lossless or extension processes)")
            }
            box.markerOrder.append(UInt8(marker))
        } while marker != 0xD9

        guard foundSOF else { throw JPEGReconstructionError.malformed("missing SOF marker") }
        if pos < len { box.tailData = Data(data[pos..<len]) }
        // `FixupIndexes`: component quant indices become positions in the table list.
        var boxComponents: [JBRDComponent] = []
        for c in components {
            guard let q = c.quantTableIndex else {
                throw JPEGReconstructionError.malformed("quantisation table \(c.quantIdx) not found")
            }
            boxComponents.append(JBRDComponent(
                id: UInt32(c.id), hSampFactor: c.h, vSampFactor: c.v, quantIdx: UInt32(q),
                widthInBlocks: UInt32(c.widthInBlocks), heightInBlocks: UInt32(c.heightInBlocks)))
        }
        box.components = boxComponents
        guard !box.huffmanCode.isEmpty else { throw JPEGReconstructionError.malformed("no Huffman table") }
        guard box.huffmanCode.count < maxDHTMarkers else { throw JPEGReconstructionError.malformed("too many Huffman tables") }
        return JPEGReconstructionImage(jbrd: box, coefficients: coefficients, isProgressive: isProgressive)
    }

    // swiftlint:disable:next function_parameter_count
    private static func processScan(
        _ data: [UInt8], _ pos: inout Int, _ box: inout JBRDBox, _ components: inout [Component],
        _ coefficients: inout [[Int16]], _ dcTables: [HuffmanDecoder], _ acTables: [HuffmanDecoder],
        _ scanProgression: inout [[UInt16]], _ isProgressive: Bool
    ) throws {
        let len = data.count
        // `ProcessSOS`.
        let start = pos
        guard pos + 3 <= len else { throw JPEGReconstructionError.malformed("truncated SOS") }
        let markerLen = (Int(data[pos]) << 8) | Int(data[pos + 1])
        pos += 2
        let n = Int(data[pos]); pos += 1
        guard (1...components.count).contains(n) else { throw JPEGReconstructionError.malformed("invalid component count \(n) in SOS") }
        guard pos + 2 * n + 3 <= len else { throw JPEGReconstructionError.malformed("truncated SOS") }
        var scan = JBRDScanInfo(numComponents: UInt32(n), components: [])
        var seen = [Bool](repeating: false, count: 256)
        for _ in 0..<n {
            let id = Int(data[pos]); pos += 1
            guard !seen[id] else { throw JPEGReconstructionError.malformed("duplicate component id \(id) in SOS") }
            seen[id] = true
            guard let compIdx = components.firstIndex(where: { $0.id == id }) else {
                throw JPEGReconstructionError.malformed("SOS names an unknown component \(id)")
            }
            if components[compIdx].quantTableIndex == nil {
                let selector = components[compIdx].quantIdx
                guard let index = box.quant.lastIndex(where: { Int($0.index) == selector }) else {
                    throw JPEGReconstructionError.malformed("quantisation table \(selector) not found")
                }
                components[compIdx].quantTableIndex = index
            }
            let t = Int(data[pos]); pos += 1
            let dc = t >> 4, ac = t & 0xF
            guard dc <= 3, ac <= 3 else { throw JPEGReconstructionError.malformed("invalid Huffman table index in SOS") }
            scan.components.append(JBRDScanComponent(compIdx: UInt32(compIdx), dcTblIdx: UInt32(dc), acTblIdx: UInt32(ac)))
        }
        let ssRaw = Int(data[pos]); pos += 1
        let seRaw = Int(data[pos]); pos += 1
        guard ssRaw <= 63, seRaw >= ssRaw, seRaw <= 63 else { throw JPEGReconstructionError.malformed("invalid spectral selection") }
        let c = Int(data[pos]); pos += 1
        scan.ss = UInt32(ssRaw)
        scan.se = UInt32(seRaw)
        scan.ah = UInt32(c >> 4)
        scan.al = UInt32(c & 0xF)
        for sc in scan.components {
            let hasDC = box.huffmanCode.contains { $0.slotId == Int(sc.dcTblIdx) }
            let hasAC = box.huffmanCode.contains { $0.slotId == Int(sc.acTblIdx) + 16 }
            if ssRaw == 0, !hasDC { throw JPEGReconstructionError.malformed("DC Huffman table \(sc.dcTblIdx) missing") }
            if seRaw > 0, !hasAC { throw JPEGReconstructionError.malformed("AC Huffman table \(sc.acTblIdx) missing") }
        }
        guard start + markerLen == pos else { throw JPEGReconstructionError.malformed("invalid SOS length") }

        // `ProcessScan`.
        let interleaved = n > 1
        var maxH = 1, maxV = 1
        for comp in components {
            maxH = max(maxH, comp.h)
            maxV = max(maxV, comp.v)
        }
        var mcuRows = (box.height + maxV * 8 - 1) / (maxV * 8)
        var mcusPerRow = (box.width + maxH * 8 - 1) / (maxH * 8)
        if !interleaved {
            let comp = components[Int(scan.components[0].compIdx)]
            mcusPerRow = (box.width * comp.h + 8 * maxH - 1) / (8 * maxH)
            mcuRows = (box.height * comp.v + 8 * maxV - 1) / (8 * maxV)
        }
        var lastDC = [Int](repeating: 0, count: maxComponents)
        var br = BitReaderState(data: data, pos: pos)
        var restartsToGo = Int(box.restartInterval)
        var nextRestartMarker = 0
        var eobrun = -1
        var blockScanIndex = 0
        let al = isProgressive ? Int(scan.al) : 0
        let ah = isProgressive ? Int(scan.ah) : 0
        let ss = isProgressive ? Int(scan.ss) : 0
        let se = isProgressive ? Int(scan.se) : 63
        let scanBitmask: UInt16 = ah == 0 ? UInt16(truncatingIfNeeded: 0xFFFF << al) : UInt16(1 << al)
        let refinementBitmask: UInt16 = UInt16((1 << al) - 1)
        for sc in scan.components {
            let compIdx = Int(sc.compIdx)
            for k in ss...se {
                guard scanProgression[compIdx][k] & scanBitmask == 0 else {
                    throw JPEGReconstructionError.malformed("overlapping scans for component \(compIdx)")
                }
                guard scanProgression[compIdx][k] & refinementBitmask == 0 else {
                    throw JPEGReconstructionError.malformed("invalid scan order for component \(compIdx)")
                }
                scanProgression[compIdx][k] |= scanBitmask
            }
        }
        guard al <= 10 else { throw JPEGReconstructionError.unsupported("scan parameter Al=\(al)") }
        let am = 1 << al

        for mcuY in 0..<mcuRows {
            for mcuX in 0..<mcusPerRow {
                if box.restartInterval > 0 {
                    if restartsToGo == 0 {
                        // `ProcessRestart`.
                        let p = try br.finishStream(box: &box)
                        guard p + 2 <= len, data[p] == 0xFF, Int(data[p + 1]) == 0xD0 + nextRestartMarker else {
                            throw JPEGReconstructionError.malformed("expected restart marker \(nextRestartMarker)")
                        }
                        br.reset(p + 2)
                        nextRestartMarker = (nextRestartMarker + 1) & 7
                        restartsToGo = Int(box.restartInterval)
                        for i in 0..<lastDC.count { lastDC[i] = 0 }
                        guard eobrun <= 0 else { throw JPEGReconstructionError.malformed("end-of-block run too long") }
                        eobrun = -1
                    }
                    restartsToGo -= 1
                }
                for sc in scan.components {
                    let compIdx = Int(sc.compIdx)
                    let comp = components[compIdx]
                    let dcTable = dcTables[Int(sc.dcTblIdx)]
                    let acTable = acTables[Int(sc.acTblIdx)]
                    let nby = interleaved ? comp.v : 1
                    let nbx = interleaved ? comp.h : 1
                    for iy in 0..<nby {
                        for ix in 0..<nbx {
                            let blockY = mcuY * nby + iy
                            let blockX = mcuX * nbx + ix
                            let blockIdx = blockY * comp.widthInBlocks + blockX
                            guard blockIdx < comp.widthInBlocks * comp.heightInBlocks else {
                                throw JPEGReconstructionError.malformed("block index out of range")
                            }
                            var resetState = false
                            var numZeroRuns = 0
                            let base = blockIdx * 64
                            if ah == 0 {
                                try decodeBlock(&br, dcTable, acTable, ss, se, al, am, &eobrun, &resetState, &numZeroRuns,
                                                &lastDC[compIdx], &coefficients[compIdx], base)
                            } else {
                                try refineBlock(&br, acTable, ss, se, al, am, &eobrun, &resetState, &coefficients[compIdx], base)
                            }
                            if resetState { scan.resetPoints.append(UInt32(blockScanIndex)) }
                            if numZeroRuns > 0 {
                                scan.extraZeroRuns.append(JBRDExtraZeroRun(blockIdx: UInt32(blockScanIndex), numExtraZeroRuns: UInt32(numZeroRuns)))
                            }
                            blockScanIndex += 1
                        }
                    }
                }
            }
        }
        guard eobrun <= 0 else { throw JPEGReconstructionError.malformed("end-of-block run too long") }
        pos = try br.finishStream(box: &box)
        guard pos <= len else { throw JPEGReconstructionError.malformed("unexpected end of file during scan") }
        box.scanInfo.append(scan)
    }

    // swiftlint:disable:next function_parameter_count
    private static func decodeBlock(
        _ br: inout BitReaderState, _ dc: HuffmanDecoder, _ ac: HuffmanDecoder, _ ssIn: Int, _ se: Int, _ al: Int, _ am: Int,
        _ eobrun: inout Int, _ resetState: inout Bool, _ numZeroRuns: inout Int, _ lastDC: inout Int,
        _ coeffs: inout [Int16], _ base: Int
    ) throws {
        var ss = ssIn
        let eobrunAllowed = ss > 0
        if ss == 0 {
            let s = try br.readSymbol(dc)
            guard s < dcAlphabetSize else { throw JPEGReconstructionError.malformed("invalid DC Huffman symbol \(s)") }
            var diff = 0
            if s > 0 { diff = huffExtend(br.readBits(s), s) }
            let coeff = diff + lastDC
            let dcCoeff = coeff * am
            guard let stored = Int16(exactly: dcCoeff) else { throw JPEGReconstructionError.malformed("invalid DC coefficient \(dcCoeff)") }
            coeffs[base] = stored
            lastDC = coeff
            ss += 1
        }
        if ss > se { return }
        if eobrun > 0 {
            eobrun -= 1
            return
        }
        numZeroRuns = 0
        var k = ss
        while k <= se {
            let sr = try br.readSymbol(ac)
            guard sr < huffmanAlphabetSize else { throw JPEGReconstructionError.malformed("invalid AC Huffman symbol \(sr)") }
            let r = sr >> 4
            let s = sr & 15
            if s > 0 {
                k += r
                guard k <= se else { throw JPEGReconstructionError.malformed("out-of-band coefficient \(k)") }
                guard s + al < dcAlphabetSize else { throw JPEGReconstructionError.malformed("out-of-range AC coefficient") }
                let coeff = huffExtend(br.readBits(s), s)
                coeffs[base + jpegNaturalOrder[k]] = Int16(truncatingIfNeeded: coeff * am)
                numZeroRuns = 0
            } else if r == 15 {
                k += 15
                numZeroRuns += 1
            } else {
                if eobrunAllowed, k == ss, eobrun == 0 { resetState = true }
                eobrun = 1 << r
                if r > 0 {
                    guard eobrunAllowed else { throw JPEGReconstructionError.malformed("end-of-block run crossing DC coefficient") }
                    eobrun += br.readBits(r)
                }
                break
            }
            k += 1
        }
        eobrun -= 1
    }

    // swiftlint:disable:next function_parameter_count
    private static func refineBlock(
        _ br: inout BitReaderState, _ ac: HuffmanDecoder, _ ssIn: Int, _ se: Int, _ al: Int, _ am: Int,
        _ eobrun: inout Int, _ resetState: inout Bool, _ coeffs: inout [Int16], _ base: Int
    ) throws {
        var ss = ssIn
        let eobrunAllowed = ss > 0
        if ss == 0 {
            let s = br.readBits(1)
            coeffs[base] |= Int16(truncatingIfNeeded: s * am)
            ss += 1
        }
        if ss > se { return }
        let p1 = am
        let m1 = -am
        var k = ss
        var inZeroRun = false
        if eobrun <= 0 {
            while k <= se {
                var s = try br.readSymbol(ac)
                guard s < huffmanAlphabetSize else { throw JPEGReconstructionError.malformed("invalid AC Huffman symbol \(s)") }
                var r = s >> 4
                s &= 15
                if s != 0 {
                    guard s == 1 else { throw JPEGReconstructionError.malformed("invalid refinement symbol") }
                    s = br.readBits(1) != 0 ? p1 : m1
                    inZeroRun = false
                } else {
                    if r != 15 {
                        if eobrunAllowed, k == ss, eobrun == 0 { resetState = true }
                        eobrun = 1 << r
                        if r > 0 {
                            guard eobrunAllowed else { throw JPEGReconstructionError.malformed("end-of-block run crossing DC coefficient") }
                            eobrun += br.readBits(r)
                        }
                        break
                    }
                    inZeroRun = true
                }
                repeat {
                    let idx = base + jpegNaturalOrder[k]
                    var thiscoef = Int(coeffs[idx])
                    if thiscoef != 0 {
                        if br.readBits(1) != 0, thiscoef & p1 == 0 {
                            thiscoef += thiscoef >= 0 ? p1 : m1
                        }
                        coeffs[idx] = Int16(truncatingIfNeeded: thiscoef)
                    } else {
                        r -= 1
                        if r < 0 { break }
                    }
                    k += 1
                } while k <= se
                if s != 0 {
                    guard k <= se else { throw JPEGReconstructionError.malformed("out-of-band coefficient \(k)") }
                    coeffs[base + jpegNaturalOrder[k]] = Int16(truncatingIfNeeded: s)
                }
                k += 1
            }
        }
        guard !inZeroRun else { throw JPEGReconstructionError.malformed("extra zero run before end of block") }
        if eobrun > 0 {
            while k <= se {
                let idx = base + jpegNaturalOrder[k]
                var thiscoef = Int(coeffs[idx])
                if thiscoef != 0 {
                    if br.readBits(1) != 0, thiscoef & p1 == 0 {
                        thiscoef += thiscoef >= 0 ? p1 : m1
                    }
                    coeffs[idx] = Int16(truncatingIfNeeded: thiscoef)
                }
                k += 1
            }
        }
        eobrun -= 1
    }
}

// MARK: - Writer

package enum JPEGReconstructionWriter {
    private struct CodeTable {
        var depth = [Int](repeating: 127, count: 256)
        var code = [Int](repeating: 0, count: 256)
        var initialized = false
    }

    /// `JpegBitWriter`: 64-bit accumulator, 0xFF stuffing, padding pattern.
    private struct BitWriter {
        var out: [UInt8]
        var putBuffer: UInt64 = 0
        var putBits = 64
        var healthy = true

        init(reserving: Int) {
            out = []
            out.reserveCapacity(reserving)
        }

        @inline(__always) mutating func emitByte(_ b: UInt8) {
            out.append(b)
            if b == 0xFF { out.append(0) }
        }

        mutating func writeBits(_ nbits: Int, _ bits: UInt64) {
            putBits -= nbits
            if putBits < 0 {
                if nbits > 64 {
                    putBits += nbits
                    healthy = false
                    return
                }
                putBuffer |= bits >> UInt64(-putBits)
                for shift in stride(from: 56, through: 0, by: -8) {
                    emitByte(UInt8((putBuffer >> UInt64(shift)) & 0xFF))
                }
                putBits += 64
                putBuffer = bits << UInt64(putBits)
            } else {
                putBuffer |= bits << UInt64(putBits)
            }
        }

        mutating func emitMarker(_ marker: UInt8) {
            out.append(0xFF)
            out.append(marker)
        }

        /// `JumpToByteBoundary`: pads with ones or with the recorded bits.
        mutating func jumpToByteBoundary(padBits: [UInt8]?, padPos: inout Int) throws {
            var nBits = putBits & 7
            var dangling: UInt8 = 0
            var padPattern: UInt8
            if let padBits {
                padPattern = 0
                while nBits > 0 {
                    nBits -= 1
                    padPattern <<= 1
                    guard padPos < padBits.count else { throw JPEGReconstructionError.malformed("padding bits exhausted") }
                    let bit = padBits[padPos]
                    padPos += 1
                    dangling |= bit
                    padPattern |= bit
                }
            } else {
                padPattern = UInt8((1 << nBits) - 1)
            }
            guard dangling & ~1 == 0 else { throw JPEGReconstructionError.malformed("invalid padding bit") }
            while putBits <= 56 {
                emitByte(UInt8((putBuffer >> 56) & 0xFF))
                putBuffer <<= 8
                putBits += 8
            }
            if putBits < 64 {
                let padMask = 0xFF >> (64 - putBits)
                let c = (Int((putBuffer >> 56) & 0xFF) & ~padMask) | Int(padPattern)
                emitByte(UInt8(c))
            }
            putBuffer = 0
            putBits = 64
        }
    }

    /// `DCTCodingState`: buffered end-of-band run and refinement bits.
    private struct CodingState {
        var eobRun = 0
        var acTable = CodeTable()
        var refinementBits: [UInt16] = []
        var refinementBitsCount = 0

        mutating func flush(_ bw: inout BitWriter) {
            if eobRun > 0 {
                let nbits = floorLog2(eobRun)
                let symbol = nbits << 4
                writeSymbol(symbol, acTable, &bw)
                if nbits > 0 { bw.writeBits(nbits, UInt64(eobRun & ((1 << nbits) - 1))) }
                eobRun = 0
            }
            let numWords = refinementBitsCount >> 4
            for i in 0..<numWords { bw.writeBits(16, UInt64(refinementBits[i])) }
            let tail = refinementBitsCount & 0xF
            if tail != 0, let last = refinementBits.last { bw.writeBits(tail, UInt64(last)) }
            refinementBits.removeAll(keepingCapacity: true)
            refinementBitsCount = 0
        }

        mutating func bufferEndOfBand(_ ac: CodeTable, _ newBits: [Int], _ bw: inout BitWriter) {
            if eobRun == 0 { acTable = ac }
            eobRun += 1
            var count = newBits.count
            if count > 0 {
                var bits: UInt64 = 0
                for b in newBits { bits = (bits << 1) | UInt64(b) }
                let tail = refinementBitsCount & 0xF
                if tail != 0 {
                    let stuff = min(16 - tail, count)
                    var stuffBits = UInt16(truncatingIfNeeded: bits >> UInt64(count - stuff))
                    stuffBits &= UInt16((1 << stuff) - 1)
                    refinementBits[refinementBits.count - 1] = (refinementBits[refinementBits.count - 1] << UInt16(stuff)) | stuffBits
                    count -= stuff
                    refinementBitsCount += stuff
                }
                while count >= 16 {
                    refinementBits.append(UInt16(truncatingIfNeeded: bits >> UInt64(count - 16)))
                    count -= 16
                    refinementBitsCount += 16
                }
                if count > 0 {
                    refinementBits.append(UInt16(truncatingIfNeeded: bits & ((UInt64(1) << UInt64(count)) - 1)))
                    refinementBitsCount += count
                }
            }
            if eobRun == 0x7FFF { flush(&bw) }
        }
    }

    @inline(__always)
    private static func floorLog2(_ v: Int) -> Int {
        Int.bitWidth - 1 - v.leadingZeroBitCount
    }

    @inline(__always)
    private static func writeSymbol(_ symbol: Int, _ table: CodeTable, _ bw: inout BitWriter) {
        bw.writeBits(table.depth[symbol], UInt64(table.code[symbol]))
    }

    /// A stream-derived value that must fit one byte; anything else is a
    /// typed failure rather than a trap.
    private static func byte<T: BinaryInteger>(_ value: T, _ what: String) throws -> UInt8 {
        guard let b = UInt8(exactly: value) else { throw JPEGReconstructionError.malformed("\(what) \(value) does not fit a byte") }
        return b
    }

    private static func buildCodeTable(_ huff: JBRDHuffmanCode) throws -> CodeTable {
        guard huff.counts.count == 17 else { throw JPEGReconstructionError.malformed("Huffman count vector malformed") }
        var table = CodeTable()
        var huffSize = [Int](repeating: 0, count: 257)
        var huffCode = [Int](repeating: 0, count: 256)
        var p = 0
        for l in 1...16 {
            var i = Int(huff.counts[l])
            guard p + i <= 257 else { throw JPEGReconstructionError.malformed("Huffman code count overflow") }
            while i > 0 {
                huffSize[p] = l
                p += 1
                i -= 1
            }
        }
        if p == 0 { return table }
        let lastP = p - 1
        huffSize[lastP] = 0
        var code = 0
        var si = huffSize[0]
        p = 0
        while huffSize[p] != 0 {
            while huffSize[p] == si {
                huffCode[p] = code
                p += 1
                code += 1
            }
            code <<= 1
            si += 1
        }
        for q in 0..<lastP {
            guard q < huff.values.count, huff.values[q] < 256 else { throw JPEGReconstructionError.malformed("Huffman value out of range") }
            let v = Int(huff.values[q])
            table.depth[v] = huffSize[q]
            table.code[v] = huffCode[q]
        }
        table.initialized = true
        return table
    }

    /// Serialises the JPEG described by `jbrd` with the coefficients of
    /// every component (block-major, natural order, libjxl `coeffs`).
    package static func write(jbrd: JBRDBox, coefficients: [[Int16]]) throws -> Data {
        guard !jbrd.markerOrder.isEmpty else { throw JPEGReconstructionError.malformed("empty marker order") }
        guard coefficients.count == jbrd.components.count else {
            throw JPEGReconstructionError.malformed("\(coefficients.count) coefficient planes for \(jbrd.components.count) components")
        }
        for (i, c) in jbrd.components.enumerated() {
            guard coefficients[i].count == Int(c.widthInBlocks) * Int(c.heightInBlocks) * 64 else {
                throw JPEGReconstructionError.malformed("component \(i) coefficient count does not match its block grid")
            }
        }
        var bw = BitWriter(reserving: coefficients.reduce(0) { $0 + $1.count / 2 } + 4096)
        bw.out.append(contentsOf: [0xFF, 0xD8])
        var dcTables = [CodeTable](repeating: CodeTable(), count: 4)
        var acTables = [CodeTable](repeating: CodeTable(), count: 4)
        let padBits: [UInt8]? = jbrd.hasZeroPaddingBit ? jbrd.paddingBits : nil
        var padPos = 0
        var dhtIndex = 0
        var dqtIndex = 0
        var appIndex = 0
        var comIndex = 0
        var dataIndex = 0
        var scanIndex = 0
        var seenDRI = false
        var isProgressive = false

        for marker in jbrd.markerOrder {
            switch marker {
            case 0xC0, 0xC1, 0xC2:
                isProgressive = marker == 0xC2
                let n = jbrd.components.count
                let markerLen = 8 + 3 * n
                guard (1...65_535).contains(jbrd.height), (1...65_535).contains(jbrd.width) else {
                    throw JPEGReconstructionError.malformed("image size \(jbrd.width)x\(jbrd.height) is outside the JPEG range")
                }
                bw.out.append(contentsOf: [0xFF, marker, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF), 8,
                                           UInt8(jbrd.height >> 8), UInt8(jbrd.height & 0xFF),
                                           UInt8(jbrd.width >> 8), UInt8(jbrd.width & 0xFF), try byte(n, "component count")])
                for c in jbrd.components {
                    guard Int(c.quantIdx) < jbrd.quant.count else { throw JPEGReconstructionError.malformed("component quant index out of range") }
                    guard (1...4).contains(c.hSampFactor), (1...4).contains(c.vSampFactor) else {
                        throw JPEGReconstructionError.malformed("sampling factor \(c.hSampFactor)x\(c.vSampFactor) is outside the JPEG range")
                    }
                    bw.out.append(contentsOf: [try byte(c.id, "component id"), UInt8((c.hSampFactor << 4) | c.vSampFactor),
                                               try byte(jbrd.quant[Int(c.quantIdx)].index, "quant table index")])
                }
            case 0xC4:
                var markerLen = 2
                var i = dhtIndex
                while i < jbrd.huffmanCode.count {
                    let huff = jbrd.huffmanCode[i]
                    markerLen += 16 + Int(huff.counts.reduce(0, +))
                    if huff.isLast { break }
                    i += 1
                }
                guard markerLen <= 65_535 else { throw JPEGReconstructionError.malformed("DHT segment too long") }
                bw.out.append(contentsOf: [0xFF, 0xC4, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
                while true {
                    guard dhtIndex < jbrd.huffmanCode.count else { throw JPEGReconstructionError.malformed("DHT marker without a table") }
                    let huff = jbrd.huffmanCode[dhtIndex]
                    dhtIndex += 1
                    var index = huff.slotId
                    let table = try buildCodeTable(huff)
                    if index & 0x10 != 0 {
                        index -= 0x10
                        guard index < 4 else { throw JPEGReconstructionError.malformed("Huffman slot out of range") }
                        acTables[index] = table
                    } else {
                        guard index < 4 else { throw JPEGReconstructionError.malformed("Huffman slot out of range") }
                        dcTables[index] = table
                    }
                    var totalCount = 0
                    var maxLength = 0
                    for l in 0..<huff.counts.count where huff.counts[l] != 0 {
                        maxLength = l
                    }
                    for l in 0..<huff.counts.count { totalCount += Int(huff.counts[l]) }
                    totalCount -= 1
                    guard totalCount >= 0 else { throw JPEGReconstructionError.malformed("Huffman sentinel missing") }
                    bw.out.append(try byte(huff.slotId, "Huffman slot"))
                    guard huff.counts.count == 17 else { throw JPEGReconstructionError.malformed("Huffman count vector malformed") }
                    for l in 1...16 {
                        // The sentinel symbol is dropped from the longest code length;
                        // `counts[maxLength]` is at least one there.
                        let count = l == maxLength ? Int(huff.counts[l]) - 1 : Int(huff.counts[l])
                        bw.out.append(try byte(count, "Huffman code count"))
                    }
                    guard totalCount <= huff.values.count else { throw JPEGReconstructionError.malformed("Huffman values missing") }
                    for v in 0..<totalCount { bw.out.append(UInt8(truncatingIfNeeded: huff.values[v])) }
                    if huff.isLast { break }
                }
            case 0xDB:
                var markerLen = 2
                var i = dqtIndex
                while i < jbrd.quant.count {
                    markerLen += 1 + (jbrd.quant[i].precision != 0 ? 2 : 1) * 64
                    if jbrd.quant[i].isLast { break }
                    i += 1
                }
                guard markerLen <= 65_535 else { throw JPEGReconstructionError.malformed("DQT segment too long") }
                bw.out.append(contentsOf: [0xFF, 0xDB, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF)])
                while true {
                    guard dqtIndex < jbrd.quant.count else { throw JPEGReconstructionError.malformed("DQT marker without a table") }
                    let table = jbrd.quant[dqtIndex]
                    dqtIndex += 1
                    guard table.values.count == 64 else { throw JPEGReconstructionError.malformed("quantisation table without values") }
                    guard table.precision <= 1, table.index <= 3 else { throw JPEGReconstructionError.malformed("quant table header out of range") }
                    bw.out.append(UInt8((table.precision << 4) + table.index))
                    for i in 0..<64 {
                        let val = Int(table.values[i])
                        guard val >= 1, val <= (table.precision != 0 ? 65_535 : 255) else {
                            throw JPEGReconstructionError.malformed("quant table value \(val) out of range")
                        }
                        if table.precision != 0 { bw.out.append(UInt8((val >> 8) & 0xFF)) }
                        bw.out.append(UInt8(val & 0xFF))
                    }
                    if table.isLast { break }
                }
            case 0xDD:
                seenDRI = true
                guard jbrd.restartInterval <= 65_535 else { throw JPEGReconstructionError.malformed("restart interval out of range") }
                bw.out.append(contentsOf: [0xFF, 0xDD, 0, 4, UInt8(jbrd.restartInterval >> 8), UInt8(jbrd.restartInterval & 0xFF)])
            case 0xD0...0xD7:
                bw.out.append(contentsOf: [0xFF, marker])
            case 0xD9:
                bw.out.append(contentsOf: [0xFF, 0xD9])
                bw.out.append(contentsOf: jbrd.tailData)
            case 0xE0...0xEF:
                guard appIndex < jbrd.appData.count else { throw JPEGReconstructionError.malformed("APP marker without data") }
                bw.out.append(0xFF)
                bw.out.append(contentsOf: jbrd.appData[appIndex])
                appIndex += 1
            case 0xFE:
                guard comIndex < jbrd.comData.count else { throw JPEGReconstructionError.malformed("COM marker without data") }
                bw.out.append(0xFF)
                bw.out.append(contentsOf: jbrd.comData[comIndex])
                comIndex += 1
            case 0xFF:
                guard dataIndex < jbrd.interMarkerData.count else { throw JPEGReconstructionError.malformed("inter-marker data missing") }
                bw.out.append(contentsOf: jbrd.interMarkerData[dataIndex])
                dataIndex += 1
            case 0xDA:
                guard scanIndex < jbrd.scanInfo.count else { throw JPEGReconstructionError.malformed("SOS without scan info") }
                try encodeScan(jbrd: jbrd, scan: jbrd.scanInfo[scanIndex], coefficients: coefficients,
                               dcTables: dcTables, acTables: acTables, isProgressive: isProgressive,
                               restartInterval: seenDRI ? Int(jbrd.restartInterval) : 0,
                               padBits: padBits, padPos: &padPos, bw: &bw)
                scanIndex += 1
            default:
                throw JPEGReconstructionError.malformed("marker 0x\(String(marker, radix: 16)) in the marker order")
            }
            guard bw.healthy else { throw JPEGReconstructionError.malformed("bit writer overflow") }
        }
        if let padBits, padPos != padBits.count {
            throw JPEGReconstructionError.malformed("invalid number of padding bits")
        }
        return Data(bw.out)
    }

    // swiftlint:disable:next function_parameter_count
    private static func encodeScan(
        jbrd: JBRDBox, scan: JBRDScanInfo, coefficients: [[Int16]],
        dcTables: [CodeTable], acTables: [CodeTable], isProgressive: Bool, restartInterval: Int,
        padBits: [UInt8]?, padPos: inout Int, bw: inout BitWriter
    ) throws {
        // `EncodeSOS`.
        let n = Int(scan.numComponents)
        guard n > 0, scan.components.count == n else { throw JPEGReconstructionError.malformed("scan component list mismatch") }
        let markerLen = 6 + 2 * n
        bw.out.append(contentsOf: [0xFF, 0xDA, UInt8(markerLen >> 8), UInt8(markerLen & 0xFF), try byte(n, "scan component count")])
        for sc in scan.components {
            guard Int(sc.compIdx) < jbrd.components.count else { throw JPEGReconstructionError.malformed("scan component out of range") }
            guard sc.dcTblIdx <= 3, sc.acTblIdx <= 3 else { throw JPEGReconstructionError.malformed("scan Huffman selector out of range") }
            bw.out.append(try byte(jbrd.components[Int(sc.compIdx)].id, "component id"))
            bw.out.append(UInt8((sc.dcTblIdx << 4) + sc.acTblIdx))
        }
        guard scan.ss <= 63, scan.se <= 63, scan.ah <= 15, scan.al <= 15 else {
            throw JPEGReconstructionError.malformed("scan progression parameters out of range")
        }
        bw.out.append(contentsOf: [UInt8(scan.ss), UInt8(scan.se), UInt8((scan.ah << 4) | scan.al)])

        // `DoEncodeScan`.
        let al = isProgressive ? Int(scan.al) : 0
        let ah = isProgressive ? Int(scan.ah) : 0
        let ss = isProgressive ? Int(scan.ss) : 0
        let se = isProgressive ? Int(scan.se) : 63
        let needSequential = !isProgressive || (ah == 0 && al == 0 && ss == 0 && se == 63)
        let mode = needSequential ? 0 : (ah == 0 ? 1 : 2)
        let interleaved = n > 1
        let base = jbrd.components[Int(scan.components[0].compIdx)]
        let hGroup = interleaved ? 1 : base.hSampFactor
        let vGroup = interleaved ? 1 : base.vSampFactor
        var maxH = 1, maxV = 1
        for c in jbrd.components {
            maxH = max(maxH, c.hSampFactor)
            maxV = max(maxV, c.vSampFactor)
        }
        let mcusPerRow = (jbrd.width * hGroup + 8 * maxH - 1) / (8 * maxH)
        let mcuRows = (jbrd.height * vGroup + 8 * maxV - 1) / (8 * maxV)
        let wantAC = ss != 0 || se != 0
        let wantDC = ss == 0
        var state = CodingState()
        var restartsToGo = restartInterval
        var nextRestartMarker = 0
        var blockScanIndex = 0
        var extraZeroRunsPos = 0
        var nextResetPointPos = 0
        var nextResetPoint = scan.resetPoints.first.map(Int.init) ?? -1
        if !scan.resetPoints.isEmpty { nextResetPointPos = 1 }
        var nextExtraZeroRunIndex = scan.extraZeroRuns.first.map { Int($0.blockIdx) } ?? -1
        var lastDC = [Int](repeating: 0, count: 4)
        var block = [Int16](repeating: 0, count: 64)

        for mcuY in 0..<mcuRows {
            for mcuX in 0..<mcusPerRow {
                if restartInterval > 0, restartsToGo == 0 {
                    state.flush(&bw)
                    try bw.jumpToByteBoundary(padBits: padBits, padPos: &padPos)
                    bw.emitMarker(UInt8(0xD0 + nextRestartMarker))
                    nextRestartMarker = (nextRestartMarker + 1) & 7
                    restartsToGo = restartInterval
                    for i in 0..<lastDC.count { lastDC[i] = 0 }
                }
                for sc in scan.components {
                    let compIdx = Int(sc.compIdx)
                    let c = jbrd.components[compIdx]
                    guard Int(sc.dcTblIdx) < 4, Int(sc.acTblIdx) < 4 else { throw JPEGReconstructionError.malformed("Huffman index out of range") }
                    let dcHuff = dcTables[Int(sc.dcTblIdx)]
                    let acHuff = acTables[Int(sc.acTblIdx)]
                    if wantDC, !dcHuff.initialized { throw JPEGReconstructionError.malformed("DC Huffman table used before defined") }
                    if wantAC, !acHuff.initialized { throw JPEGReconstructionError.malformed("AC Huffman table used before defined") }
                    let nby = interleaved ? c.vSampFactor : 1
                    let nbx = interleaved ? c.hSampFactor : 1
                    for iy in 0..<nby {
                        for ix in 0..<nbx {
                            let blockY = mcuY * nby + iy
                            let blockX = mcuX * nbx + ix
                            let blockIdx = blockY * Int(c.widthInBlocks) + blockX
                            guard blockIdx < Int(c.widthInBlocks) * Int(c.heightInBlocks) else {
                                throw JPEGReconstructionError.malformed("block index out of range")
                            }
                            if blockScanIndex == nextResetPoint {
                                state.flush(&bw)
                                if nextResetPointPos < scan.resetPoints.count {
                                    nextResetPoint = Int(scan.resetPoints[nextResetPointPos])
                                    nextResetPointPos += 1
                                } else {
                                    nextResetPoint = -1
                                }
                            }
                            var numZeroRuns = 0
                            if blockScanIndex == nextExtraZeroRunIndex {
                                numZeroRuns = Int(scan.extraZeroRuns[extraZeroRunsPos].numExtraZeroRuns)
                                extraZeroRunsPos += 1
                                nextExtraZeroRunIndex = extraZeroRunsPos < scan.extraZeroRuns.count
                                    ? Int(scan.extraZeroRuns[extraZeroRunsPos].blockIdx) : -1
                            }
                            let offset = blockIdx * 64
                            for k in 0..<64 { block[k] = coefficients[compIdx][offset + k] }
                            switch mode {
                            case 0:
                                try encodeSequential(block, dcHuff, acHuff, numZeroRuns, &lastDC[compIdx], &bw)
                            case 1:
                                try encodeProgressive(block, dcHuff, acHuff, ss, se, al, numZeroRuns, &state, &lastDC[compIdx], &bw)
                            default:
                                encodeRefinement(block, acHuff, ss, se, al, &state, &bw)
                            }
                            blockScanIndex += 1
                        }
                    }
                }
                restartsToGo -= 1
            }
        }
        state.flush(&bw)
        try bw.jumpToByteBoundary(padBits: padBits, padPos: &padPos)
    }

    // swiftlint:disable:next function_parameter_count
    private static func encodeSequential(
        _ coeffs: [Int16], _ dc: CodeTable, _ ac: CodeTable, _ numZeroRuns: Int, _ lastDC: inout Int, _ bw: inout BitWriter
    ) throws {
        var temp2 = Int(coeffs[0])
        var temp = temp2 - lastDC
        lastDC = temp2
        temp2 = temp >> 15
        temp += temp2
        temp2 ^= temp
        let dcNbits = temp2 == 0 ? 0 : floorLog2(temp2) + 1
        writeSymbol(dcNbits, dc, &bw)
        if dcNbits > 0 { bw.writeBits(dcNbits, UInt64(temp & ((1 << dcNbits) - 1))) }
        var r = 0
        var litmus = 0
        for i in 1..<64 {
            temp = Int(coeffs[jpegNaturalOrder[i]])
            if temp == 0 {
                r += 1
                continue
            }
            temp2 = temp >> 15
            temp += temp2
            temp2 ^= temp
            if r > 15 {
                writeSymbol(0xF0, ac, &bw)
                r -= 16
                if r > 15 {
                    writeSymbol(0xF0, ac, &bw)
                    r -= 16
                }
                if r > 15 {
                    writeSymbol(0xF0, ac, &bw)
                    r -= 16
                }
            }
            litmus |= temp2
            let acNbits = floorLog2(temp2 & 0xFFFF) + 1
            let symbol = (r << 4) + acNbits
            bw.writeBits(acNbits + ac.depth[symbol], UInt64(temp & ((1 << acNbits) - 1)) | (UInt64(ac.code[symbol]) << UInt64(acNbits)))
            r = 0
        }
        for _ in 0..<numZeroRuns {
            writeSymbol(0xF0, ac, &bw)
            r -= 16
        }
        if r > 0 { writeSymbol(0, ac, &bw) }
        guard litmus >= 0 else { throw JPEGReconstructionError.malformed("coefficient out of range") }
    }

    // swiftlint:disable:next function_parameter_count
    private static func encodeProgressive(
        _ coeffs: [Int16], _ dc: CodeTable, _ ac: CodeTable, _ ssIn: Int, _ se: Int, _ al: Int, _ numZeroRuns: Int,
        _ state: inout CodingState, _ lastDC: inout Int, _ bw: inout BitWriter
    ) throws {
        var ss = ssIn
        let eobRunAllowed = ss > 0
        if ss == 0 {
            var temp2 = Int(coeffs[0]) >> al
            var temp = temp2 - lastDC
            lastDC = temp2
            temp2 = temp
            if temp < 0 {
                temp = -temp
                temp2 -= 1
            }
            let nbits = temp == 0 ? 0 : floorLog2(temp) + 1
            writeSymbol(nbits, dc, &bw)
            if nbits > 0 { bw.writeBits(nbits, UInt64(temp2 & ((1 << nbits) - 1))) }
            ss += 1
        }
        if ss > se { return }
        var r = 0
        for k in ss...se {
            var temp = Int(coeffs[jpegNaturalOrder[k]])
            var temp2: Int
            if temp == 0 {
                r += 1
                continue
            }
            if temp < 0 {
                temp = -temp
                temp >>= al
                temp2 = ~temp
            } else {
                temp >>= al
                temp2 = temp
            }
            if temp == 0 {
                r += 1
                continue
            }
            state.flush(&bw)
            while r > 15 {
                writeSymbol(0xF0, ac, &bw)
                r -= 16
            }
            let nbits = floorLog2(temp) + 1
            let symbol = (r << 4) + nbits
            writeSymbol(symbol, ac, &bw)
            bw.writeBits(nbits, UInt64(temp2 & ((1 << nbits) - 1)))
            r = 0
        }
        if numZeroRuns > 0 {
            state.flush(&bw)
            for _ in 0..<numZeroRuns {
                writeSymbol(0xF0, ac, &bw)
                r -= 16
            }
        }
        if r > 0 {
            state.bufferEndOfBand(ac, [], &bw)
            if !eobRunAllowed { state.flush(&bw) }
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func encodeRefinement(
        _ coeffs: [Int16], _ ac: CodeTable, _ ssIn: Int, _ se: Int, _ al: Int, _ state: inout CodingState, _ bw: inout BitWriter
    ) {
        var ss = ssIn
        let eobRunAllowed = ss > 0
        if ss == 0 {
            bw.writeBits(1, UInt64((Int(coeffs[0]) >> al) & 1))
            ss += 1
        }
        if ss > se { return }
        var absValues = [Int](repeating: 0, count: 64)
        var eob = 0
        for k in ss...se {
            absValues[k] = abs(Int(coeffs[jpegNaturalOrder[k]])) >> al
            if absValues[k] == 1 { eob = k }
        }
        var r = 0
        var refinementBits: [Int] = []
        for k in ss...se {
            if absValues[k] == 0 {
                r += 1
                continue
            }
            while r > 15, k <= eob {
                state.flush(&bw)
                writeSymbol(0xF0, ac, &bw)
                r -= 16
                for b in refinementBits { bw.writeBits(1, UInt64(b)) }
                refinementBits.removeAll(keepingCapacity: true)
            }
            if absValues[k] > 1 {
                refinementBits.append(absValues[k] & 1)
                continue
            }
            state.flush(&bw)
            let symbol = (r << 4) + 1
            let newNonZeroBit = coeffs[jpegNaturalOrder[k]] < 0 ? 0 : 1
            writeSymbol(symbol, ac, &bw)
            bw.writeBits(1, UInt64(newNonZeroBit))
            for b in refinementBits { bw.writeBits(1, UInt64(b)) }
            refinementBits.removeAll(keepingCapacity: true)
            r = 0
        }
        if r > 0 || !refinementBits.isEmpty {
            state.bufferEndOfBand(ac, refinementBits, &bw)
            if !eobRunAllowed { state.flush(&bw) }
        }
    }
}
