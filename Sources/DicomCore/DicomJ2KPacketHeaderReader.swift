import Foundation

/// Stateful Tier-2 length reader. Code-block state belongs to one precinct, across quality layers.
/// Entropy-coded contributions are skipped, never decoded or copied.
public struct DicomJ2KPacketHeaderReader: Sendable {
    public struct Band: Sendable {
        public let columns: Int
        public let rows: Int
        public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
    }
    private struct Block: Sendable {
        var included = false
        var lblock = 3
        var segmentPasses = 0
        var segmentCapacity = 0
    }
    private struct Tree: Sendable {
        var widths: [Int] = []
        var offsets: [Int] = []
        var low: [Int] = []
        var value: [Int] = []
        init(_ width: Int, _ height: Int) {
            var w = width, h = height
            while w > 0 && h > 0 {
                widths.append(w); offsets.append(low.count)
                low += Array(repeating: 0, count: w * h)
                value += Array(repeating: Int.max, count: w * h)
                if w == 1 && h == 1 { break }
                w = (w + 1) / 2; h = (h + 1) / 2
            }
        }
        mutating func decode(_ leaf: Int, threshold: Int, bits: inout Bits) throws -> Bool {
            var x = leaf % widths[0], y = leaf / widths[0], path: [Int] = []
            for level in widths.indices {
                path.append(offsets[level] + y * widths[level] + x); x /= 2; y /= 2
            }
            var inherited = 0
            for node in path.reversed() {
                low[node] = max(low[node], inherited)
                while low[node] < threshold && low[node] < value[node] {
                    if try bits.read(1) == 1 { value[node] = low[node] }
                    else { low[node] += 1 }
                }
                inherited = low[node]
            }
            return value[path[0]] < threshold
        }
    }
    private struct State: Sendable {
        var inclusion: Tree
        var zeroPlanes: Tree
        var blocks: [Block]
    }
    private struct Bits {
        let data: Data
        let end: Int
        var cursor: Int
        var remaining = 0
        var byte: UInt8 = 0
        mutating func read(_ count: Int) throws -> Int {
            guard (0...32).contains(count) else { throw DicomJPIPServerError.malformedCodestream }
            var result = 0
            for _ in 0..<count {
                if remaining == 0 {
                    guard cursor < end else { throw DicomJPIPServerError.malformedCodestream }
                    remaining = byte == 255 ? 7 : 8
                    byte = data[cursor]; cursor += 1
                    if remaining == 7 && byte & 128 != 0 { throw DicomJPIPServerError.malformedCodestream }
                }
                remaining -= 1
                result = (result << 1) | Int((byte >> remaining) & 1)
            }
            return result
        }
        mutating func align() throws {
            if byte == 255 {
                remaining = 0
                _ = try read(1)
            }
            remaining = 0
        }
    }
    private var states: [State]
    private let style: Int
    private let sop: Bool
    private let eph: Bool

    public init(bands: [Band], codeBlockStyle: Int = 0, sop: Bool = false, eph: Bool = false,
                maximumCodeBlocks: Int = 65_536) throws {
        guard bands.count <= 3, codeBlockStyle & ~63 == 0 else { throw DicomJPIPServerError.unsupportedCodestream }
        var remaining = max(0, maximumCodeBlocks)
        for band in bands {
            guard band.columns >= 0, band.rows >= 0,
                  band.rows == 0 || band.columns <= remaining / band.rows else {
                throw DicomJPIPServerError.limitExceeded
            }
            remaining -= band.columns * band.rows
        }
        states = bands.map { .init(inclusion: Tree($0.columns, $0.rows), zeroPlanes: Tree($0.columns, $0.rows),
                                  blocks: Array(repeating: Block(), count: $0.columns * $0.rows)) }
        style = codeBlockStyle; self.sop = sop; self.eph = eph
    }

    public mutating func packetLength(in data: Data, range: Range<Int>, layer: Int) throws -> Int {
        guard range.lowerBound >= data.startIndex, range.upperBound <= data.endIndex,
              !range.isEmpty, (0..<65_535).contains(layer) else { throw DicomJPIPServerError.malformedCodestream }
        var cursor = range.lowerBound
        if sop && range.count >= 2 && data[cursor] == 255 && data[cursor + 1] == 145 {
            guard range.count >= 6, data[cursor + 2] == 0, data[cursor + 3] == 4 else {
                throw DicomJPIPServerError.malformedCodestream
            }
            cursor += 6
        }
        var bits = Bits(data: data, end: range.upperBound, cursor: cursor)
        var bodyLength = 0
        if try bits.read(1) != 0 {
            for band in states.indices {
                for block in states[band].blocks.indices {
                    var state = states[band].blocks[block]
                    let included = try state.included ? bits.read(1) != 0
                        : states[band].inclusion.decode(block, threshold: layer + 1, bits: &bits)
                    if !included { continue }
                    if !state.included {
                        var threshold = 1
                        while try !states[band].zeroPlanes.decode(block, threshold: threshold, bits: &bits) {
                            threshold += 1
                            guard threshold <= 256 else { throw DicomJPIPServerError.malformedCodestream }
                        }
                        state.included = true
                    }
                    var passes = 1
                    if try bits.read(1) != 0 {
                        passes = 2
                        if try bits.read(1) != 0 {
                            passes = 3 + (try bits.read(2))
                            if passes == 6 {
                                passes = 6 + (try bits.read(5))
                                if passes == 37 { passes = 37 + (try bits.read(7)) }
                            }
                        }
                    }
                    while try bits.read(1) != 0 {
                        state.lblock += 1
                        guard state.lblock <= 32 else { throw DicomJPIPServerError.malformedCodestream }
                    }
                    while passes > 0 {
                        if state.segmentPasses == state.segmentCapacity {
                            if style & 4 != 0 { state.segmentCapacity = 1 }
                            else if style & 1 != 0 {
                                state.segmentCapacity = state.segmentCapacity == 0 ? 10
                                    : (state.segmentCapacity == 10 || state.segmentCapacity == 1 ? 2 : 1)
                            } else { state.segmentCapacity = 109 }
                            state.segmentPasses = 0
                        }
                        let contribution = min(passes, state.segmentCapacity - state.segmentPasses)
                        let log = Int.bitWidth - 1 - contribution.leadingZeroBitCount
                        let length = try bits.read(state.lblock + log)
                        guard length <= range.count - bodyLength else { throw DicomJPIPServerError.malformedCodestream }
                        bodyLength += length; passes -= contribution; state.segmentPasses += contribution
                    }
                    states[band].blocks[block] = state
                }
            }
        }
        try bits.align()
        cursor = bits.cursor
        if eph {
            guard cursor <= range.upperBound - 2, data[cursor] == 255, data[cursor + 1] == 146 else {
                throw DicomJPIPServerError.malformedCodestream
            }
            cursor += 2
        }
        guard bodyLength <= range.upperBound - cursor else { throw DicomJPIPServerError.malformedCodestream }
        return cursor - range.lowerBound + bodyLength
    }
}
