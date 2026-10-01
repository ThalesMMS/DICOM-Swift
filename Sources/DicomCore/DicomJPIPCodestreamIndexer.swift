import Foundation

public struct DicomJPIPCodestreamIndex: Sendable {
    public struct Precinct: Sendable {
        public let binID: Int
        public let tile: Int
        public let component: Int
        public let resolution: Int
        public let sequence: Int
        public let x: Int
        public let y: Int
        public let endX: Int
        public let endY: Int
        public var packets: [Range<Int>]
        public var packetEnds: [Int] {
            var offset = 0
            return packets.map { offset += $0.count; return offset }
        }
    }
    public struct TilePart: Sendable {
        public let tile: Int
        public let part: Int
        public let header: Range<Int>
        public let bytes: Range<Int>
    }
    public let data: Data
    public let mainHeader: Range<Int>
    public let width: Int
    public let height: Int
    public let components: Int
    public let layers: Int
    public let decompositions: Int
    public let progression: String
    public let isHTJ2K: Bool
    public let supportsJPP: Bool
    public let usesPLT: Bool
    public let tileParts: [TilePart]
    public let precincts: [Precinct]
    public var estimatedBytes: Int { data.count + precincts.reduce(0) { $0 + 128 + $1.packets.count * 16 } + tileParts.count * 64 }
}

/// Pure codestream indexing. PLT lengths take precedence; absent PLT, Tier-2 measures inline headers.
public struct DicomJPIPCodestreamIndexer: Sendable {
    public let maximumIndexBytes: Int
    public let maximumPackets: Int
    public init(maximumIndexBytes: Int = 128 * 1_024 * 1_024, maximumPackets: Int = 1_000_000) {
        self.maximumIndexBytes = max(0, maximumIndexBytes); self.maximumPackets = max(0, maximumPackets)
    }
    private struct Coding {
        var levels = 0, layers = 0, progression = 0, flags = 0, cbx = 6, cby = 6, style = 0
        var precincts: [(Int, Int)] = []
    }
    private struct Component { let x: Int; let y: Int }
    private struct Change {
        let resolution: Range<Int>
        let component: Range<Int>
        let layers: Int
        let progression: Int
    }
    private struct Packet { let precinct: Int; let layer: Int }
    private static func ceil(_ n: Int, _ d: Int) -> Int { -((-n).dividedDown(by: d)) }

    public func index(_ input: Data) throws -> DicomJPIPCodestreamIndex {
        guard input.count <= maximumIndexBytes else { throw DicomJPIPServerError.limitExceeded }
        let data = Data(input)
        func u16(_ p: Int) -> Int { Int(data[p]) * 256 + Int(data[p + 1]) }
        func u32(_ p: Int) -> Int { u16(p) * 65_536 + u16(p + 2) }
        guard data.count >= 4, u16(0) == 0xff4f else { throw DicomJPIPServerError.malformedCodestream }
        var width = 0, height = 0, ox = 0, oy = 0, tw = 0, th = 0, tx0 = 0, ty0 = 0
        var components: [Component] = [], coding: Coding?, overrides: [Int: Coding] = [:]
        var changes: [Change] = [], ht = false, cursor = 2
        func parseCoding(_ start: Int, _ end: Int, _ flags: Int, _ base: Coding) throws -> Coding {
            guard end - start >= 5 else { throw DicomJPIPServerError.malformedCodestream }
            var c = base
            c.flags = flags; c.levels = Int(data[start]); c.cbx = Int(data[start + 1]) + 2
            c.cby = Int(data[start + 2]) + 2; c.style = Int(data[start + 3])
            guard c.levels <= 30, c.cbx <= 10, c.cby <= 10, c.cbx + c.cby <= 12,
                  data[start + 4] <= 1 else { throw DicomJPIPServerError.unsupportedCodestream }
            guard flags & 1 == 0 || end - start == 6 + c.levels else { throw DicomJPIPServerError.malformedCodestream }
            c.precincts = (0...c.levels).map { r in
                let v = flags & 1 == 0 ? 255 : Int(data[start + 5 + r])
                return (v & 15, v >> 4)
            }
            return c
        }
        func parseMarker(_ marker: Int, _ at: Int, _ end: Int, _ tile: Bool) throws {
            switch marker {
            case 0xff51:
                guard !tile, components.isEmpty, end - at >= 43 else { throw DicomJPIPServerError.malformedCodestream }
                width = u32(at + 6); height = u32(at + 10); ox = u32(at + 14); oy = u32(at + 18)
                tw = u32(at + 22); th = u32(at + 26); tx0 = u32(at + 30); ty0 = u32(at + 34)
                let count = u16(at + 38)
                guard count > 0, count <= 16_384, end - at == 40 + count * 3,
                      width > ox, height > oy, tw > 0, th > 0, tx0 <= ox, ty0 <= oy,
                      tx0 + tw > ox, ty0 + th > oy else { throw DicomJPIPServerError.malformedCodestream }
                for c in 0..<count {
                    let x = Int(data[at + 41 + c * 3]), y = Int(data[at + 42 + c * 3])
                    guard x > 0, y > 0 else { throw DicomJPIPServerError.malformedCodestream }
                    components.append(.init(x: x, y: y))
                }
            case 0xff52:
                guard end - at >= 14 else { throw DicomJPIPServerError.malformedCodestream }
                var c = Coding()
                c.layers = u16(at + 6); c.progression = Int(data[at + 5])
                guard c.layers > 0, c.progression < 5 else { throw DicomJPIPServerError.malformedCodestream }
                coding = try parseCoding(at + 9, end, Int(data[at + 4]), c)
            case 0xff53:
                let size = components.count < 257 ? 1 : 2
                guard let base = coding, end - at >= 10 + size else { throw DicomJPIPServerError.malformedCodestream }
                let component = size == 1 ? Int(data[at + 4]) : u16(at + 4)
                guard component < components.count else { throw DicomJPIPServerError.malformedCodestream }
                overrides[component] = try parseCoding(at + 5 + size, end, Int(data[at + 4 + size]), base)
            case 0xff5f:
                let size = components.count < 257 ? 1 : 2, entry = components.count < 257 ? 7 : 9
                guard (end - at - 4) % entry == 0 else { throw DicomJPIPServerError.malformedCodestream }
                for p in stride(from: at + 4, to: end, by: entry) {
                    let rs = Int(data[p]), cs = size == 1 ? Int(data[p + 1]) : u16(p + 1)
                    let layers = u16(p + 1 + size), re = Int(data[p + 3 + size])
                    let ce = size == 1 ? (data[p + 4 + size] == 0 ? 256 : Int(data[p + 4 + size])) : u16(p + 4 + size)
                    let order = Int(data[p + entry - 1])
                    guard rs < re, cs < ce, ce <= components.count, layers > 0, order < 5 else {
                        throw DicomJPIPServerError.malformedCodestream
                    }
                    changes.append(.init(resolution: rs..<re, component: cs..<ce, layers: layers, progression: order))
                }
            case 0xff50:
                guard end - at >= 8 else { throw DicomJPIPServerError.malformedCodestream }
                ht = u32(at + 4) & 0x00020000 != 0
            case 0xff60, 0xff61: throw DicomJPIPServerError.unsupportedCodestream
            case 0xff5c, 0xff5d:
                let size = marker == 0xff5d ? (components.count < 257 ? 1 : 2) : 0
                guard end - at >= 5 + size else { throw DicomJPIPServerError.malformedCodestream }
                if size > 0 {
                    let c = size == 1 ? Int(data[at + 4]) : u16(at + 4)
                    guard c < components.count else { throw DicomJPIPServerError.malformedCodestream }
                }
                let style = Int(data[at + 4 + size] & 31), payload = end - at - 5 - size
                guard style <= 2, payload > 0, style == 0 || payload % 2 == 0,
                      style != 1 || payload == 2 else { throw DicomJPIPServerError.malformedCodestream }
            case 0xff5e:
                let size = components.count < 257 ? 1 : 2
                guard end - at == 6 + size else { throw DicomJPIPServerError.malformedCodestream }
                let c = size == 1 ? Int(data[at + 4]) : u16(at + 4)
                guard c < components.count, data[at + 4 + size] == 0 else { throw DicomJPIPServerError.unsupportedCodestream }
            case 0xff55:
                guard end - at >= 6 else { throw DicomJPIPServerError.malformedCodestream }
                let style = Int(data[at + 5]), tileBytes = (style >> 4) & 3
                let partBytes = style & 64 == 0 ? 2 : 4
                guard tileBytes <= 2, style & 143 == 0, (end - at - 6) % (tileBytes + partBytes) == 0 else {
                    throw DicomJPIPServerError.malformedCodestream
                }
            case 0xff57:
                guard end - at >= 5 else { throw DicomJPIPServerError.malformedCodestream }
                var p = at + 5
                while p < end {
                    guard end - p >= 4 else { throw DicomJPIPServerError.malformedCodestream }
                    let count = u32(p); p += 4
                    guard count <= end - p else { throw DicomJPIPServerError.malformedCodestream }
                    p += count
                }
            case 0xff58, 0xff64, 0xff59: break
            default: throw DicomJPIPServerError.unsupportedCodestream
            }
        }
        while cursor + 2 <= data.count && u16(cursor) != 0xff90 {
            guard cursor + 4 <= data.count else { throw DicomJPIPServerError.malformedCodestream }
            let length = u16(cursor + 2)
            guard length >= 2, length <= data.count - cursor - 2 else { throw DicomJPIPServerError.malformedCodestream }
            try parseMarker(u16(cursor), cursor, cursor + length + 2, false)
            cursor += length + 2
        }
        guard let mainCoding = coding, !components.isEmpty else { throw DicomJPIPServerError.malformedCodestream }
        let mainEnd = cursor, nx = Self.ceil(width - tx0, tw), ny = Self.ceil(height - ty0, th)
        guard nx <= 65_535 / ny else { throw DicomJPIPServerError.limitExceeded }
        let tileCount = nx * ny, mainOverrides = overrides, mainChanges = changes
        var precincts: [DicomJPIPCodestreamIndex.Precinct] = [], readers: [Int: DicomJ2KPacketHeaderReader] = [:]
        var parts: [DicomJPIPCodestreamIndex.TilePart] = [], orders: [Int: [Packet]] = [:], consumed: [Int: Int] = [:]
        var allPLT = true, jpp = true, allocated = data.count, packetCount = 0
        func reserve(_ bytes: Int) throws {
            guard bytes <= maximumIndexBytes - allocated else { throw DicomJPIPServerError.limitExceeded }
            allocated += bytes
        }
        while cursor + 2 <= data.count && u16(cursor) == 0xff90 {
            let start = cursor
            guard data.count - cursor >= 14, u16(cursor + 2) == 10 else { throw DicomJPIPServerError.malformedCodestream }
            let tile = u16(cursor + 4), declared = u32(cursor + 6), part = Int(data[cursor + 10])
            let end = declared == 0 ? data.count - 2 : cursor + declared
            guard tile < tileCount, end <= data.count - 2, end - cursor >= 14,
                  part == parts.filter({ $0.tile == tile }).count else { throw DicomJPIPServerError.malformedCodestream }
            coding = mainCoding; overrides = mainOverrides; changes = mainChanges
            cursor += 12
            var lengths: [Int] = [], plt = Data(), z = 0
            while cursor + 2 <= end && u16(cursor) != 0xff93 {
                guard cursor + 4 <= end else { throw DicomJPIPServerError.malformedCodestream }
                let length = u16(cursor + 2), marker = u16(cursor)
                guard length >= 2, length <= end - cursor - 2 else { throw DicomJPIPServerError.malformedCodestream }
                if marker == 0xff58 {
                    guard length >= 3, Int(data[cursor + 4]) == z else { throw DicomJPIPServerError.malformedCodestream }
                    z += 1; plt.append(data[(cursor + 5)..<(cursor + length + 2)])
                } else {
                    guard part == 0 || ![0xff52, 0xff53, 0xff5f].contains(marker) else {
                        throw DicomJPIPServerError.unsupportedCodestream
                    }
                    try parseMarker(marker, cursor, cursor + length + 2, true)
                }
                cursor += length + 2
            }
            guard cursor + 2 <= end, u16(cursor) == 0xff93 else { throw DicomJPIPServerError.malformedCodestream }
            cursor += 2
            try reserve(64)
            parts.append(.init(tile: tile, part: part, header: start..<cursor, bytes: start..<end))
            var value = 0
            for byte in plt {
                guard value <= (Int.max - 127) / 128 else { throw DicomJPIPServerError.malformedCodestream }
                value = value * 128 + Int(byte & 127)
                if byte & 128 == 0 {
                    guard value > 0, lengths.count < maximumPackets else { throw DicomJPIPServerError.limitExceeded }
                    lengths.append(value); value = 0
                }
            }
            guard plt.last.map({ $0 & 128 == 0 }) ?? true else { throw DicomJPIPServerError.malformedCodestream }
            allPLT = allPLT && z > 0
            if ht && z == 0 { jpp = false; cursor = end; continue }
            guard let code = coding else { throw DicomJPIPServerError.malformedCodestream }
            if part == 0 {
                var indices: [Int] = []
                let tileX = tile % nx, tileY = tile / nx
                for (component, sampling) in components.enumerated() {
                    let c = overrides[component] ?? code
                    var sequence = 0
                    let cx0 = Self.ceil(max(ox, tx0 + tileX * tw), sampling.x)
                    let cy0 = Self.ceil(max(oy, ty0 + tileY * th), sampling.y)
                    let cx1 = Self.ceil(min(width, tx0 + (tileX + 1) * tw), sampling.x)
                    let cy1 = Self.ceil(min(height, ty0 + (tileY + 1) * th), sampling.y)
                    for r in 0...c.levels {
                        let scale = 1 << (c.levels - r), pw = 1 << c.precincts[r].0, ph = 1 << c.precincts[r].1
                        let x0 = Self.ceil(cx0, scale), y0 = Self.ceil(cy0, scale)
                        let x1 = Self.ceil(cx1, scale), y1 = Self.ceil(cy1, scale)
                        if x0 == x1 || y0 == y1 { continue }
                        let cols = Self.ceil(x1, pw) - x0 / pw, rows = Self.ceil(y1, ph) - y0 / ph
                        guard rows > 0, cols <= maximumPackets / rows,
                              cols * rows <= (maximumPackets - packetCount) / code.layers else {
                            throw DicomJPIPServerError.limitExceeded
                        }
                        for y in (y0 / ph)..<Self.ceil(y1, ph) {
                            for x in (x0 / pw)..<Self.ceil(x1, pw) {
                                try reserve(128 + code.layers * 16)
                                packetCount += code.layers
                                let index = precincts.count
                                indices.append(index)
                                precincts.append(.init(binID: tile + (component + sequence * components.count) * tileCount,
                                    tile: tile, component: component, resolution: r, sequence: sequence,
                                    x: max(x0, x * pw) * scale * sampling.x, y: max(y0, y * ph) * scale * sampling.y,
                                    endX: min(x1, (x + 1) * pw) * scale * sampling.x,
                                    endY: min(y1, (y + 1) * ph) * scale * sampling.y, packets: []))
                                sequence += 1
                                if z == 0 {
                                    var bands: [DicomJ2KPacketHeaderReader.Band] = []
                                    for band in (r == 0 ? 0...0 : 1...3) {
                                        let shift = r == 0 ? 0 : 1
                                        let bx0 = Self.ceil(cx0 - (band & 1) * scale, scale << shift)
                                        let by0 = Self.ceil(cy0 - (band >> 1) * scale, scale << shift)
                                        let bx1 = Self.ceil(cx1 - (band & 1) * scale, scale << shift)
                                        let by1 = Self.ceil(cy1 - (band >> 1) * scale, scale << shift)
                                        let bw = max(1, pw >> shift), bh = max(1, ph >> shift)
                                        let a = max(bx0, x * bw), b = min(bx1, (x + 1) * bw)
                                        let d = max(by0, y * bh), e = min(by1, (y + 1) * bh)
                                        let cbw = min(1 << c.cbx, bw), cbh = min(1 << c.cby, bh)
                                        bands.append(.init(columns: max(0, Self.ceil(b, cbw) - a.dividedDown(by: cbw)),
                                                           rows: max(0, Self.ceil(e, cbh) - d.dividedDown(by: cbh))))
                                    }
                                    let blocks = bands.reduce(0) { $0 + $1.columns * $1.rows }
                                    try reserve(blocks * 128)
                                    readers[index] = try .init(bands: bands, codeBlockStyle: c.style,
                                                              sop: code.flags & 2 != 0, eph: code.flags & 4 != 0)
                                }
                            }
                        }
                    }
                }
                func sorted(_ packets: [Packet], _ order: Int) -> [Packet] {
                    func key(_ p: Packet) -> [Int] {
                        let a = precincts[p.precinct]
                        switch order {
                        case 0: return [p.layer, a.resolution, a.component, a.y, a.x]
                        case 1: return [a.resolution, p.layer, a.component, a.y, a.x]
                        case 2: return [a.resolution, a.y, a.x, a.component, p.layer]
                        case 3: return [a.y, a.x, a.component, a.resolution, p.layer]
                        default: return [a.component, a.y, a.x, a.resolution, p.layer]
                        }
                    }
                    return packets.sorted { key($0).lexicographicallyPrecedes(key($1)) }
                }
                let packets = indices.flatMap { p in (0..<code.layers).map { Packet(precinct: p, layer: $0) } }
                if changes.isEmpty { orders[tile] = sorted(packets, code.progression) }
                else {
                    var used: Set<Int> = [], result: [Packet] = []
                    for change in changes {
                        let chosen = packets.filter {
                            let p = precincts[$0.precinct]
                            return change.resolution.contains(p.resolution) && change.component.contains(p.component)
                                && $0.layer < change.layers && !used.contains($0.precinct * code.layers + $0.layer)
                        }
                        result += sorted(chosen, change.progression)
                        for packet in chosen { used.insert(packet.precinct * code.layers + packet.layer) }
                    }
                    guard result.count == packets.count else { throw DicomJPIPServerError.unsupportedCodestream }
                    orders[tile] = result
                }
            }
            guard let order = orders[tile] else { throw DicomJPIPServerError.malformedCodestream }
            var position = consumed[tile] ?? 0, lengthIndex = 0
            while cursor < end {
                guard position < order.count else { throw DicomJPIPServerError.malformedCodestream }
                let packet = order[position]
                let length: Int
                if z > 0 {
                    guard lengthIndex < lengths.count else { throw DicomJPIPServerError.malformedCodestream }
                    length = lengths[lengthIndex]; lengthIndex += 1
                } else {
                    guard var reader = readers[packet.precinct] else { throw DicomJPIPServerError.unsupportedCodestream }
                    length = try reader.packetLength(in: data, range: cursor..<end, layer: packet.layer)
                    readers[packet.precinct] = reader
                }
                guard length <= end - cursor, precincts[packet.precinct].packets.count == packet.layer else {
                    throw DicomJPIPServerError.malformedCodestream
                }
                precincts[packet.precinct].packets.append(cursor..<cursor + length)
                cursor += length; position += 1
            }
            guard lengthIndex == lengths.count else { throw DicomJPIPServerError.malformedCodestream }
            consumed[tile] = position
        }
        guard cursor == data.count - 2, u16(cursor) == 0xffd9,
              Set(parts.map(\.tile)).count == tileCount,
              orders.allSatisfy({ consumed[$0.key] == $0.value.count }),
              precincts.allSatisfy({ $0.packets.count >= mainCoding.layers }) else {
            throw DicomJPIPServerError.malformedCodestream
        }
        return .init(data: data, mainHeader: 0..<mainEnd, width: width, height: height, components: components.count,
                     layers: mainCoding.layers, decompositions: mainCoding.levels,
                     progression: ["LRCP", "RLCP", "RPCL", "PCRL", "CPRL"][mainCoding.progression],
                     isHTJ2K: ht, supportsJPP: jpp, usesPLT: allPLT, tileParts: parts, precincts: precincts)
    }
}

private extension Int {
    func dividedDown(by divisor: Int) -> Int { self >= 0 ? self / divisor : -((-self + divisor - 1) / divisor) }
}
