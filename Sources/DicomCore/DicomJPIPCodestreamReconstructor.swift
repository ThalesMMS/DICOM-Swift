import Foundation

public struct DicomJPIPReconstructionInfo: Sendable, Equatable {
    public enum Completeness: String, Sendable { case full, partial }
    public let layersUsed: Int
    public let resolutionLevelsAvailable: Int
    public let completeness: Completeness
    public let missingBinsCount: Int
    public let fractionComplete: Double
}

public enum DicomJPIPReconstructionError: Error, Sendable, Equatable {
    case missingMainHeader
    case malformedCodestream
    case unsupportedPacketOrdering
    case outputLimitExceeded
}

/// Reassembles cached bytes without decoding or rewriting CAP/CPF coding capabilities.
public struct DicomJPIPCodestreamReconstructor: Sendable {
    public let maximumOutputBytes: Int
    public init(maximumOutputBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    public func reconstruct(_ cache: DicomJPIPDatabinCache, codestream: Int = 0, window: DicomJPIPWindow? = nil) throws
        -> (data: Data, info: DicomJPIPReconstructionInfo) {
        guard let main = cache.bin(codestream: codestream, classID: 6, binID: 0), main.isComplete else {
            throw DicomJPIPReconstructionError.missingMainHeader
        }
        let header = main.contiguousData
        let layout = try Layout(header)
        let requiredBins = try Self.windowBins(header: header, codestream: codestream, window: window)
        var requiredResolution = layout.decompositions
        var availableResolution = layout.decompositions
        if cache.isJPP(codestream: codestream) != false {
            availableResolution = -1
            for tile in 0..<layout.tileCount {
                for precinct in try layout.precincts(tile: tile) {
                    if cache.bin(codestream: codestream, classID: 0, binID: precinct.id)?.contiguousData.isEmpty == false {
                        availableResolution = max(availableResolution, precinct.resolution)
                    }
                }
            }
            availableResolution = max(0, availableResolution)
            if let fsiz = window?.fsiz {
                var requested = layout.decompositions
                while requested > 0 {
                    let scale = 1 << (layout.decompositions - requested + 1)
                    if (layout.width + scale - 1) / scale < fsiz.width || (layout.height + scale - 1) / scale < fsiz.height { break }
                    requested -= 1
                }
                requiredResolution = requested
                availableResolution = min(availableResolution, requested)
            }
        }
        var output = try layout.reducedHeader(header, resolution: availableResolution)
        var missing = 0
        var expected = 1
        var complete = 1
        var covered = main.byteCount
        var knownLength = main.byteCount
        var layersUsed = layout.layers
        var maxResolution = -1
        func account(_ bin: DicomJPIPDatabin?) {
            expected += 1
            if let bin {
                if bin.isComplete { complete += 1 } else { missing += 1 }
                covered += bin.byteCount
                knownLength += max(bin.finalLength ?? (bin.byteCount + 1), bin.byteCount)
            } else {
                missing += 1
                knownLength += 1
            }
        }
        for tile in 0..<layout.tileCount {
            if cache.isJPP(codestream: codestream) == false {
                let bin = cache.bin(codestream: codestream, classID: 4, binID: tile)
                if requiredBins.contains(.init(codestream: codestream, classID: 4, binID: tile)) { account(bin) }
                let bytes = bin?.contiguousData ?? Data()
                // Only complete tile-parts are decodable; leave a trailing interrupted part cached.
                var cursor = 0
                while cursor + 12 <= bytes.count {
                    guard bytes[cursor] == 255, bytes[cursor + 1] == 144 else {
                        throw DicomJPIPReconstructionError.malformedCodestream
                    }
                    let length = Layout.u32(bytes, cursor + 6)
                    guard length >= 14 else { throw DicomJPIPReconstructionError.malformedCodestream }
                    if length > bytes.count - cursor { break }
                    try append(bytes.subdata(in: cursor..<cursor + length), to: &output)
                    cursor += length
                }
                if cursor == 0 { try append(Self.tileHeader(tile, length: 14), to: &output) }
                if bin?.isComplete != true { layersUsed = 0 }
                maxResolution = layout.decompositions
                continue
            }
            let tileBin = cache.bin(codestream: codestream, classID: 2, binID: tile)
            if requiredBins.contains(.init(codestream: codestream, classID: 2, binID: tile)) { account(tileBin) }
            var tileHeader = tileBin?.contiguousData ?? Data()
            if tileHeader.count >= 2, tileHeader.prefix(2) != Data([255, 144]) {
                tileHeader = Data([255, 144]) + tileHeader
            }
            if tileHeader.isEmpty { tileHeader = Self.tileHeader(tile, length: 14) }
            guard tileHeader.count >= 14, tileHeader.prefix(2) == Data([255, 144]),
                  tileHeader.suffix(2) == Data([255, 147]) else {
                throw DicomJPIPReconstructionError.malformedCodestream
            }
            let precincts = try layout.precincts(tile: tile)
            let packetLengths = try Self.packetLengths(tileHeader)
            tileHeader = try Self.withoutPacketLengths(tileHeader)
            var tileData = Data()
            let visible = precincts.filter { $0.resolution <= availableResolution }
            var packetsByBin: [Int: [Int]] = [:]
            if !packetLengths.isEmpty {
                let order = try layout.packetOrder(precincts, maximumPackets: maximumOutputBytes)
                guard packetLengths.count == order.count else { throw DicomJPIPReconstructionError.malformedCodestream }
                for (packet, length) in zip(order, packetLengths) { packetsByBin[packet.precinct.id, default: []].append(length) }
            }
            for precinct in precincts where precinct.resolution <= requiredResolution {
                let bin = cache.bin(codestream: codestream, classID: 0, binID: precinct.id)
                let isRequired = requiredBins.contains(.init(codestream: codestream, classID: 0, binID: precinct.id))
                if isRequired { account(bin) }
                guard precinct.resolution <= availableResolution else {
                    if isRequired { layersUsed = 0 }
                    continue
                }
                if let bin, !bin.contiguousData.isEmpty {
                    maxResolution = max(maxResolution, precinct.resolution)
                    var packets = bin.isComplete ? layout.layers : bin.completePackets
                    if let lengths = packetsByBin[precinct.id] {
                        var offset = 0
                        packets = 0
                        for length in lengths {
                            guard length <= bin.contiguousData.count - offset else { break }
                            offset += length
                            packets += 1
                        }
                    }
                    if isRequired { layersUsed = min(layersUsed, packets) }
                    // RPCL/PCRL/CPRL keep every precinct's layers adjacent. For a class-0 bin
                    // without packet lengths, preserve its contiguous bytes for decoder truncation.
                    if layout.progression <= 1 { continue }
                    if let lengths = packetsByBin[precinct.id] {
                        var offset = 0
                        var count = 0
                        for length in lengths {
                            guard length <= bin.contiguousData.count - offset else { break }
                            offset += length
                            count += 1
                        }
                        try append(Data(bin.contiguousData.prefix(offset)), to: &tileData)
                        try append(Data(repeating: 0, count: layout.layers - count), to: &tileData)
                        if isRequired { layersUsed = min(layersUsed, count) }
                        continue
                    }
                    if !bin.isComplete, let end = bin.packetEnds[packets], packets > 0 {
                        try append(Data(bin.contiguousData.prefix(end)), to: &tileData)
                    } else {
                        try append(bin.contiguousData, to: &tileData)
                    }
                    if packets > 0 && packets < layout.layers {
                        try append(Data(repeating: 0, count: layout.layers - packets), to: &tileData)
                    }
                } else {
                    if isRequired { layersUsed = 0 }
                    if layout.progression > 1 { try append(Data(repeating: 0, count: layout.layers), to: &tileData) }
                }
            }
            if layout.progression <= 1 {
                for packet in try layout.packetOrder(visible, maximumPackets: maximumOutputBytes) {
                    let bin = cache.bin(codestream: codestream, classID: 0, binID: packet.precinct.id)
                    let bytes = bin?.contiguousData ?? Data()
                    var start: Int?
                    var end: Int?
                    if let lengths = packetsByBin[packet.precinct.id] {
                        start = lengths.prefix(packet.layer).reduce(0, +)
                        end = start.map { $0 + lengths[packet.layer] }
                    } else if layout.layers == 1 {
                        start = 0
                        end = bytes.count
                    } else {
                        start = packet.layer == 0 ? 0 : bin?.packetEnds[packet.layer]
                        end = bin?.packetEnds[packet.layer + 1]
                    }
                    if let start, let end, end > start, end <= bytes.count {
                        try append(bytes.subdata(in: start..<end), to: &tileData)
                    } else if packetsByBin[packet.precinct.id] != nil || bytes.isEmpty || start.map({ $0 >= bytes.count }) == true {
                        try append(Data([0]), to: &tileData)
                    } else {
                        throw DicomJPIPReconstructionError.unsupportedPacketOrdering
                    }
                }
            }
            let length = tileHeader.count + tileData.count
            guard length <= Int(UInt32.max) else { throw DicomJPIPReconstructionError.outputLimitExceeded }
            for index in 0..<4 { tileHeader[6 + index] = UInt8((length >> (24 - 8 * index)) & 255) }
            tileHeader[10] = 0
            tileHeader[11] = 1
            try append(tileHeader, to: &output)
            try append(tileData, to: &output)
        }
        try append(Data([255, 217]), to: &output)
        let full = complete == expected
        return (output, DicomJPIPReconstructionInfo(layersUsed: layersUsed,
            resolutionLevelsAvailable: maxResolution + 1, completeness: full ? .full : .partial,
            missingBinsCount: missing,
            fractionComplete: full ? 1 : min(0.999999, Double(covered) / Double(max(1, knownLength)))))
    }

    /// Includes every precinct whose reference-grid rectangle overlaps the requested window.
    /// No packet is clipped at an ROI edge; reconstruction still emits the full served canvas.
    static func windowBins(header: Data, codestream: Int, window: DicomJPIPWindow?) throws -> Set<DicomJPIPDatabinID> {
        let layout = try Layout(header)
        let fsiz = window?.fsiz ?? .init(layout.width, layout.height)
        let offset = window?.roff ?? .init(0, 0)
        let size = window?.rsiz ?? .init(fsiz.width - offset.width, fsiz.height - offset.height)
        let x0 = Double(offset.width) * Double(layout.width) / Double(fsiz.width)
        let y0 = Double(offset.height) * Double(layout.height) / Double(fsiz.height)
        let x1 = Double(offset.width + size.width) * Double(layout.width) / Double(fsiz.width)
        let y1 = Double(offset.height + size.height) * Double(layout.height) / Double(fsiz.height)
        var resolution = layout.decompositions
        while resolution > 0 {
            let scale = 1 << (layout.decompositions - resolution + 1)
            if (layout.width + scale - 1) / scale < fsiz.width || (layout.height + scale - 1) / scale < fsiz.height { break }
            resolution -= 1
        }
        var result: Set<DicomJPIPDatabinID> = [.init(codestream: codestream, classID: 6, binID: 0)]
        for tile in 0..<layout.tileCount {
            for precinct in try layout.precincts(tile: tile) where precinct.resolution <= resolution {
                guard window?.comps.isEmpty != false || window!.comps.contains(where: { $0.contains(precinct.component) }),
                      Double(precinct.x) < x1, Double(precinct.endX) > x0,
                      Double(precinct.y) < y1, Double(precinct.endY) > y0 else { continue }
                result.insert(.init(codestream: codestream, classID: 0, binID: precinct.id))
                result.insert(.init(codestream: codestream, classID: 2, binID: tile))
                result.insert(.init(codestream: codestream, classID: 4, binID: tile))
            }
        }
        return result
    }

    private func append(_ data: Data, to output: inout Data) throws {
        guard output.count <= maximumOutputBytes, data.count <= maximumOutputBytes - output.count else {
            throw DicomJPIPReconstructionError.outputLimitExceeded
        }
        output.append(data)
    }

    private static func packetLengths(_ header: Data) throws -> [Int] {
        var cursor = 12
        var payload = Data()
        var nextIndex = 0
        while cursor + 4 <= header.count {
            let marker = Layout.u16(header, cursor)
            if marker == 0xff93 { break }
            let length = Layout.u16(header, cursor + 2)
            guard length >= 2, length <= header.count - cursor - 2 else {
                throw DicomJPIPReconstructionError.malformedCodestream
            }
            if marker == 0xff58 {
                guard length >= 3, Int(header[cursor + 4]) == nextIndex else {
                    throw DicomJPIPReconstructionError.malformedCodestream
                }
                nextIndex += 1
                payload.append(header.subdata(in: cursor + 5..<cursor + length + 2))
            }
            cursor += length + 2
        }
        var lengths: [Int] = []
        var value = 0
        for byte in payload {
            guard value <= (Int.max - Int(byte & 127)) / 128 else {
                throw DicomJPIPReconstructionError.malformedCodestream
            }
            value = value * 128 + Int(byte & 127)
            if byte & 128 == 0 { lengths.append(value); value = 0 }
        }
        guard payload.last.map({ $0 & 128 == 0 }) ?? true else {
            throw DicomJPIPReconstructionError.malformedCodestream
        }
        return lengths
    }

    private static func withoutPacketLengths(_ header: Data) throws -> Data {
        var result = Data(header.prefix(12))
        var cursor = 12
        while cursor + 4 <= header.count {
            let marker = Layout.u16(header, cursor)
            if marker == 0xff93 { break }
            let length = Layout.u16(header, cursor + 2)
            guard length >= 2, length <= header.count - cursor - 2 else {
                throw DicomJPIPReconstructionError.malformedCodestream
            }
            if [0xff52, 0xff53, 0xff5f].contains(marker) {
                throw DicomJPIPReconstructionError.unsupportedPacketOrdering
            }
            if marker != 0xff58 { result.append(header.subdata(in: cursor..<cursor + length + 2)) }
            cursor += length + 2
        }
        result.append(contentsOf: [255, 147])
        return result
    }

    private static func tileHeader(_ tile: Int, length: Int) -> Data {
        Data([255, 144, 0, 10, UInt8((tile >> 8) & 255), UInt8(tile & 255),
              UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
              UInt8((length >> 8) & 255), UInt8(length & 255), 0, 1, 255, 147])
    }

    private struct Layout {
        var width = 0
        var height = 0
        var xOrigin = 0
        var yOrigin = 0
        var tileWidth = 0
        var tileHeight = 0
        var tileXOrigin = 0
        var tileYOrigin = 0
        var components: [(x: Int, y: Int)] = []
        var decompositions = 0
        var layers = 0
        var progression = 0
        var precinctSizes: [(x: Int, y: Int)] = []
        var tilesX: Int { (width - tileXOrigin + tileWidth - 1) / tileWidth }
        var tilesY: Int { (height - tileYOrigin + tileHeight - 1) / tileHeight }
        var tileCount: Int { tilesX * tilesY }
        static func u16(_ bytes: Data, _ at: Int) -> Int { Int(bytes[at]) * 256 + Int(bytes[at + 1]) }
        static func u32(_ bytes: Data, _ at: Int) -> Int { u16(bytes, at) * 65_536 + u16(bytes, at + 2) }

        init(_ bytes: Data) throws {
            guard bytes.count >= 2, bytes[0] == 255, bytes[1] == 79 else {
                throw DicomJPIPReconstructionError.malformedCodestream
            }
            var cursor = 2
            while cursor + 4 <= bytes.count {
                let marker = Self.u16(bytes, cursor)
                let length = Self.u16(bytes, cursor + 2)
                guard length >= 2, length <= bytes.count - cursor - 2 else {
                    throw DicomJPIPReconstructionError.malformedCodestream
                }
                if marker == 0xff51 {
                    guard length >= 41 else { throw DicomJPIPReconstructionError.malformedCodestream }
                    width = Self.u32(bytes, cursor + 6)
                    height = Self.u32(bytes, cursor + 10)
                    xOrigin = Self.u32(bytes, cursor + 14)
                    yOrigin = Self.u32(bytes, cursor + 18)
                    tileWidth = Self.u32(bytes, cursor + 22)
                    tileHeight = Self.u32(bytes, cursor + 26)
                    tileXOrigin = Self.u32(bytes, cursor + 30)
                    tileYOrigin = Self.u32(bytes, cursor + 34)
                    let count = Self.u16(bytes, cursor + 38)
                    guard count > 0, 38 + count * 3 <= length else {
                        throw DicomJPIPReconstructionError.malformedCodestream
                    }
                    for component in 0..<count {
                        let x = Int(bytes[cursor + 41 + component * 3])
                        let y = Int(bytes[cursor + 42 + component * 3])
                        guard x > 0, y > 0 else { throw DicomJPIPReconstructionError.malformedCodestream }
                        components.append((x, y))
                    }
                } else if marker == 0xff52 {
                    guard length >= 12 else { throw DicomJPIPReconstructionError.malformedCodestream }
                    progression = Int(bytes[cursor + 5])
                    layers = Self.u16(bytes, cursor + 6)
                    decompositions = Int(bytes[cursor + 9])
                    guard decompositions <= 32, layers > 0 else { throw DicomJPIPReconstructionError.malformedCodestream }
                    for resolution in 0...decompositions {
                        var value: UInt8 = 255
                        if bytes[cursor + 4] & 1 != 0 {
                            guard 12 + resolution < length else { throw DicomJPIPReconstructionError.malformedCodestream }
                            value = bytes[cursor + 14 + resolution]
                        }
                        precinctSizes.append((1 << Int(value & 15), 1 << Int(value >> 4)))
                    }
                } else if [0xff53, 0xff5f].contains(marker) {
                    throw DicomJPIPReconstructionError.unsupportedPacketOrdering
                }
                cursor += length + 2
            }
            guard width > xOrigin, height > yOrigin, tileWidth > 0, tileHeight > 0,
                  tileXOrigin <= xOrigin, tileYOrigin <= yOrigin, !components.isEmpty,
                  layers > 0, tilesX <= 65_535, tilesY <= 65_535, tileCount <= 65_535 else { throw DicomJPIPReconstructionError.malformedCodestream }
        }

        func reducedHeader(_ header: Data, resolution: Int) throws -> Data {
            guard resolution < decompositions else { return header }
            var result = Data(header.prefix(2))
            var cursor = 2
            let scale = 1 << (decompositions - resolution)
            while cursor + 4 <= header.count {
                let marker = Self.u16(header, cursor)
                let length = Self.u16(header, cursor + 2)
                var segment = header.subdata(in: cursor..<cursor + length + 2)
                if marker == 0xff51 {
                    for offset in stride(from: 6, through: 34, by: 4) {
                        let value = (Self.u32(segment, offset) + scale - 1) / scale
                        for byte in 0..<4 { segment[offset + byte] = UInt8((value >> (24 - byte * 8)) & 255) }
                    }
                } else if marker == 0xff52 {
                    segment[9] = UInt8(resolution)
                    if segment[4] & 1 != 0 {
                        segment = Data(segment.prefix(15 + resolution))
                        let newLength = segment.count - 2
                        segment[2] = UInt8(newLength >> 8)
                        segment[3] = UInt8(newLength & 255)
                    }
                }
                result.append(segment)
                cursor += length + 2
            }
            return result
        }

        struct Precinct {
            let id: Int
            let component: Int
            let resolution: Int
            let x: Int
            let y: Int
            let endX: Int
            let endY: Int
        }

        struct Packet {
            let precinct: Precinct
            let layer: Int
        }

        func packetOrder(_ precincts: [Precinct], maximumPackets: Int) throws -> [Packet] {
            guard layers <= maximumPackets / max(1, precincts.count) else {
                throw DicomJPIPReconstructionError.outputLimitExceeded
            }
            var packets: [Packet] = []
            for precinct in precincts {
                for layer in 0..<layers { packets.append(Packet(precinct: precinct, layer: layer)) }
            }
            if progression == 0 {
                packets.sort {
                    ($0.layer, $0.precinct.resolution, $0.precinct.component, $0.precinct.y, $0.precinct.x)
                    < ($1.layer, $1.precinct.resolution, $1.precinct.component, $1.precinct.y, $1.precinct.x)
                }
            } else if progression == 1 {
                packets.sort {
                    ($0.precinct.resolution, $0.layer, $0.precinct.component, $0.precinct.y, $0.precinct.x)
                    < ($1.precinct.resolution, $1.layer, $1.precinct.component, $1.precinct.y, $1.precinct.x)
                }
            }
            return packets
        }

        func precincts(tile: Int) throws -> [Precinct] {
            guard (0...4).contains(progression) else { throw DicomJPIPReconstructionError.unsupportedPacketOrdering }
            var result: [Precinct] = []
            let tx = tile % tilesX
            let ty = tile / tilesX
            for (component, sampling) in components.enumerated() {
                var sequence = 0
                for resolution in 0...decompositions {
                    let scale = 1 << (decompositions - resolution)
                    func ceilDiv(_ value: Int, _ divisor: Int) -> Int { (value + divisor - 1) / divisor }
                    let x0 = ceilDiv(max(xOrigin, tileXOrigin + tx * tileWidth), sampling.x * scale)
                    let y0 = ceilDiv(max(yOrigin, tileYOrigin + ty * tileHeight), sampling.y * scale)
                    let x1 = ceilDiv(min(width, tileXOrigin + (tx + 1) * tileWidth), sampling.x * scale)
                    let y1 = ceilDiv(min(height, tileYOrigin + (ty + 1) * tileHeight), sampling.y * scale)
                    let size = precinctSizes[resolution]
                    let px0 = x0 / size.x
                    let py0 = y0 / size.y
                    let px1 = ceilDiv(x1, size.x)
                    let py1 = ceilDiv(y1, size.y)
                    guard px1 >= px0, py1 >= py0,
                          (px1 - px0) * (py1 - py0) <= 1_000_000 - result.count else {
                        throw DicomJPIPReconstructionError.outputLimitExceeded
                    }
                    for y in py0..<py1 {
                        for x in px0..<px1 {
                            let id = tile + (component + sequence * components.count) * tileCount
                            result.append(Precinct(id: id, component: component, resolution: resolution,
                                x: max(x0, x * size.x) * scale * sampling.x,
                                y: max(y0, y * size.y) * scale * sampling.y,
                                endX: min(x1, (x + 1) * size.x) * scale * sampling.x,
                                endY: min(y1, (y + 1) * size.y) * scale * sampling.y))
                            sequence += 1
                        }
                    }
                }
            }
            return result.sorted {
                switch progression {
                case 0, 1: return ($0.resolution, $0.component, $0.y, $0.x) < ($1.resolution, $1.component, $1.y, $1.x)
                case 2: return ($0.resolution, $0.y, $0.x, $0.component) < ($1.resolution, $1.y, $1.x, $1.component)
                case 3: return ($0.y, $0.x, $0.component, $0.resolution) < ($1.y, $1.x, $1.component, $1.resolution)
                default: return ($0.component, $0.y, $0.x, $0.resolution) < ($1.component, $1.y, $1.x, $1.resolution)
                }
            }
        }
    }
}
