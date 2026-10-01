// J2KEncoderGeometryTrace.swift
// v6-alpha3 step 6A — band/code-block/packet geometry trace
// infrastructure used by HTNativeMultiTileBandGeometryTests to
// verify that the parity-aware DWT band dimensions propagate
// consistently into PendingCodeBlock creation, packet-header
// tag-tree dimensions, and packet body block ordering.
//
// SCOPE: trace only. Production code paths default
// `geometryCollector: nil` and pay zero cost (one nil-check per
// per-band/per-packet record). The collector exists solely so
// tests can inspect intermediate encoder state without parsing
// the codestream wire format.
//
// Threading model: `encodeNativeMultiTile` loops tiles
// sequentially; within a tile, the band loop in
// `applyEntropyCodingHTJ2KFused` is sequential (parallelism happens
// at block-level AFTER the band loop), and `writePacket` is called
// from the sequential LRCP loop in `generateTileData`. So the
// collector is written to from a single thread per tile, multiple
// tiles in sequence — `NSLock` is sufficient + cheap.

import Foundation

/// One PendingCodeBlock or DeferredCodeBlock as captured by the
/// trace.
///
/// - `(x, y)`: tag-tree cell position. For the canvas-anchored
///   partition (ISO/IEC 15444-1 B.7) this is `(bi * cbW, bj * cbH)`
///   where `(bi, bj)` is the block's index within the tile's
///   precinct/band. Matches what `writePacket` reads via
///   `block.x / cbW`.
/// - `(originX, originY)`: tile-band-relative extraction coordinates
///   for the block's coefficients (where the encoder reads samples
///   from `info.coefficients`). For canvas-aligned tile origins,
///   `originX == x`; for misaligned origins they differ on the
///   first/last block of each row/column when the canvas-anchored
///   partition's first cell straddles the tile band's leading edge.
/// - `(width, height)`: clipped block content size (may be
///   `< (cbW, cbH)` for first/last partial blocks).
struct GeometryPendingBlock: Sendable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let originX: Int
    let originY: Int
}

/// Per (tile, component, band) snapshot captured during entropy
/// coding. `pendingBlocks` mirrors the order the encoder appended
/// them into the deferred list (row-major, raster).
struct GeometryBand: Sendable {
    let tileIndex: Int
    let componentIndex: Int
    let dwtLevel: Int            // info.level: 0 = baseband (LL of coarsest); 1..N for HL/LH/HH
    let subband: J2KSubband
    let resolutionLevel: Int     // resolution level used in LRCP (0..N)
    /// DWT-actual band dimensions taken from `SubbandInfo.width/height`.
    let bandWidth: Int
    let bandHeight: Int
    let codeBlockWidth: Int
    let codeBlockHeight: Int
    /// Code-block grid dims as the encoder computes them
    /// (`ceil(bandWidth / cbW)` etc.). Test 7+ verifies this
    /// matches the packet's tag-tree dims.
    let blocksX: Int
    let blocksY: Int
    let pendingBlocks: [GeometryPendingBlock]
}

/// One block as recorded inside a packet's per-band tag-tree
/// iteration in `writePacket`. `included == true` ↔ block had
/// non-empty data + `passeCount > 0` and was appended to the
/// packet body.
struct GeometryPacketBlockEntry: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let included: Bool
    /// Position in the packet body's append order. `nil` when
    /// `!included` (the block contributes header inclusion bits
    /// but no body bytes).
    let bodyOrderIndex: Int?
}

/// Per-band component of a packet record.
struct GeometryPacketBand: Sendable {
    let subband: J2KSubband
    /// Tag-tree dims as `writePacket` computes them — currently
    /// `band.map { $0.x / cbW }.max()! + 1`. The audit tests
    /// verify this equals `GeometryBand.blocksX/blocksY` for the
    /// matching band entry.
    let tagTreeWidth: Int
    let tagTreeHeight: Int
    /// Every block the tag-tree iterated over, in iteration order.
    /// `bodyBlockCount` is `entries.filter(\.included).count`.
    let entries: [GeometryPacketBlockEntry]
}

struct GeometryPacket: Sendable {
    let tileIndex: Int
    let resolutionLevel: Int
    let componentIndex: Int
    let bands: [GeometryPacketBand]
}

/// Collects band + packet geometry across one or more tile encodes.
/// Threaded through the encoder pipeline as an optional parameter;
/// when `nil` (the default in production) the encoder skips all
/// recording.
final class GeometryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _bands: [GeometryBand] = []
    private var _packets: [GeometryPacket] = []

    init() {}

    var bands: [GeometryBand] {
        lock.lock(); defer { lock.unlock() }
        return _bands
    }

    var packets: [GeometryPacket] {
        lock.lock(); defer { lock.unlock() }
        return _packets
    }

    func addBand(_ entry: GeometryBand) {
        lock.lock(); defer { lock.unlock() }
        _bands.append(entry)
    }

    func addPacket(_ entry: GeometryPacket) {
        lock.lock(); defer { lock.unlock() }
        _packets.append(entry)
    }

    /// Lookup helper: all bands for a given (tile, component).
    func bands(forTile tileIndex: Int, component: Int) -> [GeometryBand] {
        bands.filter { $0.tileIndex == tileIndex && $0.componentIndex == component }
    }

    /// Lookup helper: the unique band record for (tile, component,
    /// resolutionLevel, subband). Tests use this to pair a packet
    /// band with its entropy-stage band.
    func band(
        tileIndex: Int, componentIndex: Int,
        resolutionLevel: Int, subband: J2KSubband
    ) -> GeometryBand? {
        bands.first(where: {
            $0.tileIndex == tileIndex
                && $0.componentIndex == componentIndex
                && $0.resolutionLevel == resolutionLevel
                && $0.subband == subband
        })
    }

    /// Lookup helper: all packets for a given tile.
    func packets(forTile tileIndex: Int) -> [GeometryPacket] {
        packets.filter { $0.tileIndex == tileIndex }
    }
}
