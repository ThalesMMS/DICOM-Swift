import Foundation

/// Incremental JPEG 2000 Part 1 framing (`.90/.91`), not a decoder (issue #3040). It follows the codestream
/// structure of T.800 Annex A: SOC, SIZ first, length-delimited main and tile-part header segments, SOT/Psot
/// tile-parts and EOC. Psot-delimited tile data and segment payloads other than SIZ/SOT are skipped without being
/// read, so bytes inside them are never taken for delimiters. A last tile-part with Psot 0 is scanned to EOC: the
/// T.800 bit stuffing keeps 0xFF in packet data below 0xFF90, and SOP/EPH are the only markers it may carry.
struct DicomJ2KFrameBoundaryScanner {
    private enum Phase {
        case startPrefix, startCode, markerPrefix, markerCode
        case lengthHigh, lengthLow(Int)
        /// Skipped segment payload; `toStream` returns to Psot 0 tile data (SOP) instead of the next marker.
        case segment(Int, toStream: Bool)
        /// SIZ/SOT payload, kept in `payload`.
        case captured(Int)
        case tileData(Int)
        case stream, streamPrefix
        case finished(padding: Int)
    }

    private enum Context { case mainHeader, tileHeader, betweenTileParts }

    /// Bytes read at SOC, usually the whole main header and the first SOT; a skip that follows within them is
    /// consumed instead of jumped. Later header reads take one marker and its length at a time.
    private static let mainHeaderReadAhead = 256

    private var phase: Phase = .startPrefix
    private var context: Context = .mainHeader
    private var marker: UInt8 = 0
    private var sawSIZ = false
    private var payload: [UInt8] = []
    /// Logical offset in this frame's codestream, across fragments.
    private var position = 0
    private var tilePartStart = 0
    private var tilePartLength = 0

    private var finished: Bool { if case .finished = phase { true } else { false } }

    /// Upcoming bytes the framing does not need to see.
    private var skippableBytes: Int {
        switch phase {
        case .segment(let remaining, _), .tileData(let remaining): remaining
        default: 0
        }
    }

    /// Bytes worth reading next.
    private var wantedBytes: Int {
        switch phase {
        case .captured(let remaining): remaining
        case .stream, .streamPrefix: Int.max
        case .finished: 2
        case .startPrefix: Self.mainHeaderReadAhead
        default: 4
        }
    }

    /// Frame → fragment indexes for an empty table. Reads only header bytes of Psot-delimited tile-parts; every byte
    /// read counts against `maximumScanBytes`. Frames end with EOC at a fragment end, followed by at most the one
    /// pad byte an odd codestream needs to fill its even fragment.
    static func map(source: DicomByteSource, fragments: [DicomEncapsulatedPixelDataFragment],
                    numberOfFrames: Int, maximumScanBytes: Int) async throws -> [[Int]] {
        var scanner = Self()
        var budget = max(0, maximumScanBytes)
        var frames: [[Int]] = []
        var firstFragment = 0
        let chunkSize = min(65536, source.limits.maximumReadBytes)
        guard chunkSize > 0 else { throw DicomByteSource.Failure.readLimit }
        for fragment in fragments {
            var offset = fragment.valueRange.lowerBound
            let end = fragment.valueRange.upperBound
            while offset < end {
                try Task.checkCancellation()
                let skip = min(scanner.skippableBytes, end - offset)
                if skip > 0 {
                    scanner.skip(skip)
                    offset += skip
                    continue
                }
                let count = min(chunkSize, scanner.wantedBytes, end - offset)
                guard count <= budget else { throw DicomSourceFrameIndex.Failure.boundaryScanLimit }
                budget -= count
                let lease = try await source.read(offset..<(offset + count))
                try lease.withUnsafeBytes { bytes in
                    for byte in bytes { try scanner.consume(byte) }
                }
                offset += count
            }
            if scanner.finished {
                guard frames.count < numberOfFrames else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
                frames.append(Array(firstFragment...fragment.index))
                firstFragment = fragment.index + 1
                scanner = Self()
            }
        }
        guard frames.count == numberOfFrames, firstFragment == fragments.count else {
            throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
        }
        return frames
    }

    private mutating func skip(_ count: Int) {
        position += count
        switch phase {
        case .segment(let remaining, let toStream):
            phase = remaining == count ? (toStream ? .stream : .markerPrefix) : .segment(remaining - count, toStream: toStream)
        case .tileData(let remaining):
            if remaining == count { endTilePart() } else { phase = .tileData(remaining - count) }
        default: break
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        position += 1
        switch phase {
        case .startPrefix:
            guard byte == 0xFF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .startCode
        case .startCode:
            guard byte == 0x4F else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .markerPrefix
        case .markerPrefix:
            guard byte == 0xFF else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            phase = .markerCode
        case .markerCode:
            try startMarker(byte)
        case .lengthHigh:
            phase = .lengthLow(Int(byte) << 8)
        case .lengthLow(let high):
            let length = high | Int(byte)
            switch marker {
            case 0x51:
                // Lsiz = 38 + 3 × Csiz, Csiz ≥ 1.
                guard length >= 41 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
                payload = []
                phase = .captured(length - 2)
            case 0x90:
                guard length == 10 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
                payload = []
                phase = .captured(8)
            default:
                guard length >= 2 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
                phase = length == 2 ? .markerPrefix : .segment(length - 2, toStream: false)
            }
        case .segment(let remaining, let toStream):
            phase = remaining == 1 ? (toStream ? .stream : .markerPrefix) : .segment(remaining - 1, toStream: toStream)
        case .captured(let remaining):
            payload.append(byte)
            if remaining == 1 { try finishCapturedSegment() } else { phase = .captured(remaining - 1) }
        case .tileData(let remaining):
            if remaining == 1 { endTilePart() } else { phase = .tileData(remaining - 1) }
        case .stream:
            if byte == 0xFF { phase = .streamPrefix }
        case .streamPrefix:
            switch byte {
            case 0x00..<0x90, 0x92: phase = .stream // Packet data after a stuffed 0xFF, or EPH.
            case 0x91: phase = .segment(4, toStream: true) // SOP: Lsop = 4 and Nsop.
            case 0xD9: phase = .finished(padding: 0)
            default: throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
        case .finished(let padding):
            // PS3.5 A.4: one byte pads an odd codestream to its even fragment. OpenJPEG and the own decoder accept
            // any value there (#2487, #2858).
            guard padding == 0 else { throw DicomSourceFrameIndex.Failure.invalidPadding }
            phase = .finished(padding: 1)
        }
    }

    private mutating func startMarker(_ byte: UInt8) throws {
        // 0xFF30–0xFF3F carry no parameters (T.800 A.1.4).
        let delimiters: Set<UInt8> = [0x4F, 0x51, 0x90, 0x91, 0x92, 0x93, 0xD9, 0xFF]
        switch context {
        case .mainHeader:
            if !sawSIZ {
                guard byte == 0x51 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
            } else if byte == 0x90 {
                return startTilePart()
            } else if (0x30...0x3F).contains(byte) {
                phase = .markerPrefix
                return
            } else if byte < 0x30 || delimiters.contains(byte) {
                throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
        case .tileHeader:
            if byte == 0x93 { return try startTileData() }
            if (0x30...0x3F).contains(byte) {
                phase = .markerPrefix
                return
            }
            guard byte >= 0x30, !delimiters.contains(byte) else {
                throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
        case .betweenTileParts:
            switch byte {
            case 0x90: return startTilePart()
            case 0xD9:
                phase = .finished(padding: 0)
                return
            default: throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
        }
        marker = byte
        phase = .lengthHigh
    }

    private mutating func startTilePart() {
        context = .tileHeader
        tilePartStart = position - 2
        marker = 0x90
        phase = .lengthHigh
    }

    private mutating func startTileData() throws {
        guard tilePartLength != 0 else {
            phase = .stream
            return
        }
        // Psot counts from the first byte of SOT to the end of the tile-part data.
        let remaining = tilePartStart + tilePartLength - position
        guard remaining >= 0 else { throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries }
        if remaining == 0 { endTilePart() } else { phase = .tileData(remaining) }
    }

    private mutating func endTilePart() {
        context = .betweenTileParts
        phase = .markerPrefix
    }

    private mutating func finishCapturedSegment() throws {
        if marker == 0x51 {
            let components = Int(payload[34]) << 8 | Int(payload[35])
            guard components >= 1, payload.count == 36 + 3 * components else {
                throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
            sawSIZ = true
        } else {
            // Psot 0 extends the last tile-part to EOC; otherwise it covers at least SOT and SOD.
            tilePartLength = payload[2...5].reduce(0) { $0 << 8 | Int($1) }
            guard tilePartLength == 0 || tilePartLength >= 14 else {
                throw DicomSourceFrameIndex.Failure.ambiguousFrameBoundaries
            }
        }
        payload = []
        phase = .markerPrefix
    }
}
