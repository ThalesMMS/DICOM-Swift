import Foundation

extension DicomJPIPServer {
    struct DeliveryBin: Sendable {
        let id: DicomJPIPDatabinID
        let data: Data
        let ranges: [Range<Int>]
        let packetEnds: [Int]
        let tile: Int
        let component: Int
        let resolution: Int
        let precinct: Int
        let limit: Int
        var count: Int { ranges.reduce(0) { $0 + $1.count } }
        func bytes(_ range: Range<Int>) -> Data {
            var result = Data(), offset = 0
            for source in ranges {
                let start = max(range.lowerBound, offset), end = min(range.upperBound, offset + source.count)
                if start < end { result.append(data[source.lowerBound + start - offset..<source.lowerBound + end - offset]) }
                offset += source.count
                if offset >= range.upperBound { break }
            }
            return result
        }
    }
    static func select(_ index: DicomJPIPCodestreamIndex, stream: Int, window: DicomJPIPWindow) throws
        -> (bins: [DeliveryBin], headers: [String: String], full: Bool) {
        let jpt = window.type == .jptStream
        guard jpt || index.supportsJPP else { throw DicomJPIPServerError.unsupportedMediaType }
        guard window.comps.allSatisfy({ $0.upperBound < index.components }) else { throw DicomJPIPServerError.malformedRequest }
        let requested = window.fsiz ?? .init(index.width, index.height)
        let sizes = (0...index.decompositions).map { r -> DicomJPIPWindow.Size in
            let scale = 1 << (index.decompositions - r)
            return .init((index.width + scale - 1) / scale, (index.height + scale - 1) / scale)
        }
        var level = sizes.firstIndex { $0.width >= requested.width && $0.height >= requested.height } ?? index.decompositions
        if window.rounding == .roundDown {
            level = sizes.lastIndex { $0.width <= requested.width && $0.height <= requested.height } ?? 0
        } else if window.rounding == .closest {
            level = sizes.indices.min { a, b in
                abs(Double(sizes[a].width) - Double(requested.width)) + abs(Double(sizes[a].height) - Double(requested.height))
                    < abs(Double(sizes[b].width) - Double(requested.width)) + abs(Double(sizes[b].height) - Double(requested.height))
            } ?? level
        }
        // JPT delivers complete tile-parts; acknowledge the full tile coding quality and resolution.
        if jpt { level = index.decompositions }
        let size = sizes[level], offset = window.roff ?? .init(0, 0)
        let region = window.rsiz ?? .init(requested.width - offset.width, requested.height - offset.height)
        let x0 = Int(Double(offset.width) * Double(index.width) / Double(requested.width))
        let y0 = Int(Double(offset.height) * Double(index.height) / Double(requested.height))
        let x1 = Int(ceil(Double(offset.width + region.width) * Double(index.width) / Double(requested.width)))
        let y1 = Int(ceil(Double(offset.height + region.height) * Double(index.height) / Double(requested.height)))
        let layers = jpt ? index.layers : min(window.layers ?? index.layers, index.layers)
        let components = jpt || window.comps.isEmpty ? [0...(index.components - 1)] : window.comps
        // Include wavelet support around the ROI at each scale, retaining all lower-resolution support.
        let chosen = index.precincts.filter { p in
            let margin = 4 * (1 << (index.decompositions - p.resolution))
            return p.resolution <= level && components.contains { $0.contains(p.component) }
                && p.x < x1 + margin && p.endX > x0 - margin && p.y < y1 + margin && p.endY > y0 - margin
        }
        var tiles = Set(chosen.map(\.tile))
        if jpt && index.precincts.isEmpty { tiles = Set(index.tileParts.map(\.tile)) }
        var bins = [DeliveryBin(id: .init(codestream: stream, classID: 6, binID: 0), data: index.data,
            ranges: [index.mainHeader], packetEnds: [], tile: -1, component: -1, resolution: -1, precinct: -1,
            limit: index.mainHeader.count)]
        for tile in tiles.sorted() {
            let parts = index.tileParts.filter { $0.tile == tile }
            if jpt {
                let ranges = parts.map(\.bytes)
                bins.append(.init(id: .init(codestream: stream, classID: 4, binID: tile), data: index.data,
                    ranges: ranges, packetEnds: [], tile: tile, component: -1, resolution: -1, precinct: -1,
                    limit: ranges.reduce(0) { $0 + $1.count }))
            } else {
                guard let part = parts.first else { throw DicomJPIPServerError.malformedCodestream }
                // T.808 tile-header bins omit the SOT marker code itself, as OpenJPIP emits.
                let header: Data
                if parts.count == 1 && index.usesPLT { header = Data(index.data[part.header]) }
                else { header = try Self.tileHeader(index, tile: tile) }
                let range = 2..<header.count
                bins.append(.init(id: .init(codestream: stream, classID: 2, binID: tile), data: header,
                    ranges: [range], packetEnds: [], tile: tile, component: -1, resolution: -1, precinct: -1, limit: range.count))
                for p in chosen.filter({ $0.tile == tile }).sorted(by: { ($0.resolution, $0.binID) < ($1.resolution, $1.binID) }) {
                    bins.append(.init(id: .init(codestream: stream, classID: 0, binID: p.binID), data: index.data,
                        ranges: p.packets, packetEnds: p.packetEnds, tile: tile, component: p.component,
                        resolution: p.resolution, precinct: p.sequence, limit: p.packetEnds[layers - 1]))
                }
            }
        }
        let servedOffset = DicomJPIPWindow.Size(Int(Double(x0) * Double(size.width) / Double(index.width)),
                                               Int(Double(y0) * Double(size.height) / Double(index.height)))
        let servedSize = DicomJPIPWindow.Size(min(size.width - servedOffset.width, Int(ceil(Double(x1 - x0) * Double(size.width) / Double(index.width)))),
                                             min(size.height - servedOffset.height, Int(ceil(Double(y1 - y0) * Double(size.height) / Double(index.height)))))
        return (bins, ["JPIP-fsiz": "\(size.width),\(size.height)", "JPIP-roff": "\(servedOffset.width),\(servedOffset.height)",
            "JPIP-rsiz": "\(servedSize.width),\(servedSize.height)", "JPIP-layers": String(layers),
            "JPIP-comps": components.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")],
            level == index.decompositions && layers == index.layers && x0 == 0 && y0 == 0 && x1 == index.width && y1 == index.height
                && components == [0...(index.components - 1)])
    }

    /// Consolidates tile-parts and supplies measured packet lengths to independent clients.
    /// Inline packet bytes remain unchanged; the resulting tile-header databin has one PLT sequence.
    static func tileHeader(_ index: DicomJPIPCodestreamIndex, tile: Int) throws -> Data {
        guard let part = index.tileParts.first(where: { $0.tile == tile }) else { throw DicomJPIPServerError.malformedCodestream }
        let data = index.data
        var header = Data(data[part.header.lowerBound..<part.header.lowerBound + 12])
        header[10] = 0; header[11] = 1
        var at = part.header.lowerBound + 12
        while at < part.header.upperBound - 2 {
            let length = Int(data[at + 2]) * 256 + Int(data[at + 3]) + 2
            if data[at + 1] != 0x58 { header.append(data[at..<at + length]) }
            at += length
        }
        let packets = index.precincts.filter { $0.tile == tile }.flatMap(\.packets).sorted { $0.lowerBound < $1.lowerBound }
        var payload = Data(), sequence = 0
        func appendPLT() throws {
            guard sequence <= 255 else { throw DicomJPIPServerError.limitExceeded }
            let length = payload.count + 3
            header.append(contentsOf: [255, 88, UInt8(length >> 8), UInt8(length & 255), UInt8(sequence)])
            header.append(payload); payload.removeAll(keepingCapacity: true); sequence += 1
        }
        for packet in packets {
            let length = DicomJPIPMessageWriter.vbas(packet.count)
            if payload.count + length.count > 65_532 { try appendPLT() }
            payload.append(length)
        }
        if !payload.isEmpty { try appendPLT() }
        header.append(contentsOf: [255, 147])
        let length = header.count + packets.reduce(0) { $0 + $1.count }
        guard length <= Int(UInt32.max) else { throw DicomJPIPServerError.limitExceeded }
        for n in 0..<4 { header[6 + n] = UInt8((length >> (24 - 8 * n)) & 255) }
        return header
    }

    actor Delivery {
        let bins: [DeliveryBin]
        let sessions: DicomJPIPServerSessions
        let lease: DicomJPIPServerSessions.Lease?
        let writer = DicomJPIPMessageWriter()
        let full: Bool
        let limitReason: UInt8
        let align: Bool
        var remaining: Int
        var offsets: [Int]
        var limits: [Int]
        var excluded: [[Range<Int>]]
        var appliedModel = false
        var done = false
        init(bins: [DeliveryBin], request: DicomJPIPServerRequest, configuration: DicomJPIPServerConfiguration,
             sessions: DicomJPIPServerSessions, lease: DicomJPIPServerSessions.Lease?, full: Bool) throws {
            self.bins = bins; self.sessions = sessions; self.lease = lease; self.full = full; align = request.align
            let budgets: [(Int, UInt8)] = [(configuration.maximumResponseBytes, 7),
                (request.window.len ?? Int.max, 4), (lease?.remaining ?? Int.max, 6)]
            let budget = budgets.min { $0.0 < $1.0 }!
            remaining = max(3, budget.0); limitReason = budget.1
            offsets = bins.map { lease?.sent[$0.id] ?? 0 }
            limits = bins.map(\.limit)
            excluded = Array(repeating: [], count: bins.count)
            func matches(_ d: DicomJPIPCacheModel.Descriptor, _ bin: DeliveryBin) -> Bool {
                guard d.codestreams.contains(where: { $0.contains(bin.id.codestream) }),
                      d.classID == nil || d.classID == bin.id.classID,
                      d.binID == nil || d.binID == bin.id.binID else { return false }
                if d.classID == nil && bin.id.classID != 0 { return false }
                let values = ["t": bin.tile, "c": bin.component, "r": bin.resolution, "p": bin.precinct]
                return d.selectors.allSatisfy { $0.value.contains(values[$0.key] ?? -1) }
            }
            func extent(_ d: DicomJPIPCacheModel.Descriptor, _ bin: DeliveryBin) -> Int {
                switch d.extent {
                case .complete: return d.subtractive ? 0 : bin.count
                case .bytes(let n): return min(n, bin.count)
                case .layers(let n): return n == 0 ? 0 : (bin.packetEnds.isEmpty ? 0 : bin.packetEnds[min(n, bin.packetEnds.count) - 1])
                }
            }
            if request.cacheModel.need != nil {
                let descriptors = try request.cacheModel.needDescriptors
                for i in bins.indices {
                    let matching = descriptors.filter { matches($0, bins[i]) }
                    limits[i] = min(bins[i].limit, matching.map { extent($0, bins[i]) }.max() ?? 0)
                    offsets[i] = 0
                }
            } else {
                for d in try request.cacheModel.modelDescriptors {
                    for i in bins.indices where matches(d, bins[i]) {
                        let value = extent(d, bins[i])
                        offsets[i] = d.subtractive ? min(offsets[i], value) : max(offsets[i], value)
                    }
                }
            }
            for descriptor in request.tilePartModel {
                for i in bins.indices where bins[i].id.classID == 4 {
                    let bin = bins[i]
                    guard descriptor.streams.contains(where: { $0.contains(bin.id.codestream) }),
                          descriptor.firstTile <= bin.tile, bin.tile <= descriptor.lastTile else { continue }
                    let first = bin.tile == descriptor.firstTile ? min(descriptor.firstPart, bin.ranges.count) : 0
                    let last = bin.tile == descriptor.lastTile ? min(descriptor.lastPart, bin.ranges.count - 1) + 1 : bin.ranges.count
                    let start = bin.ranges.prefix(first).reduce(0) { $0 + $1.count }
                    let end = bin.ranges.prefix(last).reduce(0) { $0 + $1.count }
                    if descriptor.subtractive { offsets[i] = min(offsets[i], start) }
                    else if start < end { excluded[i].append(start..<end) }
                }
            }
        }
        func cancel() { done = true }
        func finish(_ reason: UInt8) async throws -> Data {
            done = true
            let data = try writer.endOfResponse(reason: reason)
            if let lease { _ = await sessions.record(lease, bytes: data.count, bin: nil, end: 0) }
            return data
        }
        func next() async throws -> Data? {
            guard !done else { return nil }
            try Task.checkCancellation()
            if let lease, !(await sessions.active(lease)) { return try await finish(3) }
            // Headers precede precincts; each precinct advances one layer before its peers advance again.
            for i in bins.indices {
                for range in excluded[i].sorted(by: { $0.lowerBound < $1.lowerBound }) where range.contains(offsets[i]) {
                    offsets[i] = range.upperBound
                }
            }
            if !appliedModel, let lease {
                await sessions.applyModel(lease, known: Dictionary(uniqueKeysWithValues: bins.indices.map { (bins[$0].id, offsets[$0]) }))
                appliedModel = true
            }
            let currentOffsets = offsets
            let candidates = bins.indices.filter { offsets[$0] < limits[$0] }
            guard let i = candidates.min(by: { a, b in
                func key(_ i: Int) -> [Int] {
                    let bin = bins[i]
                    let packet = bin.packetEnds.firstIndex { $0 > currentOffsets[i] } ?? 0
                    return [bin.id.codestream, bin.tile, bin.id.classID == 0 ? 1 : 0, bin.resolution, packet, bin.id.binID]
                }
                return key(a).lexicographicallyPrecedes(key(b))
            }) else { return try await finish(full ? 1 : 2) }
            let bin = bins[i], start = offsets[i]
            let nextExcluded = excluded[i].filter { $0.lowerBound > start }.map(\.lowerBound).min() ?? limits[i]
            let boundary = min(bin.packetEnds.first(where: { $0 > start }) ?? limits[i], nextExcluded)
            var end = min(boundary, limits[i], align && bin.id.classID == 0 ? boundary : start + 16_384)
            if remaining <= 16 { return try await finish(limitReason) }
            end = min(end, start + remaining - 16)
            if align && bin.id.classID == 0 && end < boundary { return try await finish(limitReason) }
            let message = DicomJPIPMessage(classID: bin.id.classID,
                codestream: bin.id.codestream, binID: bin.id.binID, offset: start, isComplete: end == bin.count,
                body: bin.bytes(start..<end))
            let encoded = try writer.encode(message)
            guard encoded.count <= remaining - 3 else { return try await finish(limitReason) }
            if let lease, !(await sessions.record(lease, bytes: encoded.count, bin: bin.id, end: end)) { return try await finish(6) }
            offsets[i] = end; remaining -= encoded.count
            return encoded
        }
    }
}
