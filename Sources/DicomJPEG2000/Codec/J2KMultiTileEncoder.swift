// J2KMultiTileEncoder.swift
// v5.39 M4 / v6-alpha1 — multi-tile HT lossless prototype.
// v6-alpha3 step 5 — switched from wrap-and-stitch to the native
// multi-tile codestream assembler in `EncoderPipeline`. The
// dispatcher now produces ONE legal codestream with a single main
// header and N tile-parts, instead of N standalone codestreams
// stitched at byte level. Each tile is still encoded with the
// parity-aware DWT at its real image-coordinate origin
// (v6-alpha3 step 1+2+3).
//
// Production code path is unchanged: the v6-alpha2 planner still
// constrains layouts to 32-aligned tile origins (because the
// J2KSwift decoder's inverse 5/3 DWT is not yet parity-aware —
// step 6's scope), and the public entry `J2KEncoder.encode(_:)`
// only invokes this module when `J2K_HT_TILE_MODE` requests
// multi-tile and the planner accepts the layout.
//
// Determinism: native assembly is deterministic — same input +
// same layout produces byte-identical output across runs. The
// per-tile-encode parallelism that wrap-and-stitch used via
// `withTaskGroup` is not yet ported to the native path; that's a
// perf concern for a separate step once the structural
// correctness is established.

import Foundation

/// Per-tile observation captured by the work scheduler — used by
/// the M4 benchmark to print the load-balance table and is part
/// of the diagnostic surface, not the production return.
///
/// v6-alpha3 step 3 added `originX` / `originY` so tests can probe
/// that the multi-tile dispatcher actually threaded the per-tile
/// image-coordinate origin into the encoder pipeline (rather than
/// silently encoding every tile at (0, 0) as the wrap-and-stitch
/// prototype did).
public struct J2KTileWorkObservation: Sendable {
    public let tileIndex: Int
    public let pixels: Int
    public let tileBytes: Int
    public let encodeMs: Double
    public let originX: Int
    public let originY: Int
}

/// Aggregated result of a multi-tile encode — both the assembled
/// codestream and the per-tile observations used for diagnostics.
public struct J2KMultiTileEncodeResult: Sendable {
    public let codestream: Data
    public let layout: J2KTileLayout
    public let observations: [J2KTileWorkObservation]
}

enum J2KMultiTileEncoder {

    /// Run `N` per-tile encodes in parallel via `withTaskGroup`. Each
    /// task slices its tile from the parent image, builds a fresh
    /// `J2KEncoder` with the same configuration, and runs the
    /// existing `encode(_:)` pipeline. The encoder's planner is NOT
    /// re-consulted inside the per-tile encode (we route directly to
    /// the single-tile pipeline via a config flag).
    static func encode(
        image: J2KImage,
        layout: J2KTileLayout,
        configuration: J2KEncodingConfiguration
    ) async throws -> J2KMultiTileEncodeResult {

        let n = layout.tileCount
        precondition(n >= 1, "tile count must be ≥ 1")

        // v6-alpha3 step 5: the step-4 parity-alignment guard
        // (which refused non-32-aligned origins to prevent the
        // wrap-and-stitch path from producing trap-prone bytes)
        // is REMOVED in step 5. The wrap-and-stitch path itself
        // is gone — replaced by `EncoderPipeline.encodeNativeMultiTile`,
        // which produces ONE legal codestream with a single main
        // header and N tile-parts, encoding each tile with its
        // real image-coordinate origin via the parity-aware DWT.
        // The native assembler structurally handles any origin.
        //
        // Production behaviour is unchanged: the v6-alpha2 planner
        // still enforces 32-alignment up front (because the
        // J2KSwift decoder's inverse 5/3 DWT is not yet parity-
        // aware — that's v6-alpha3 step 6's scope). Non-aligned
        // layouts only reach this dispatcher when test code
        // bypasses the planner, and step 5 wants those probes
        // to *succeed* (producing a structurally valid codestream
        // that external parity-aware decoders may or may not
        // reconstruct correctly), not throw a guard error.

        // v6-alpha3 step 5: native multi-tile codestream assembler.
        // Replaces the wrap-and-stitch path that produced N
        // standalone per-tile codestreams and concatenated them
        // (the SIZ-vs-content inconsistency that step 4 traced).
        // The native assembler emits ONE legal codestream with a
        // single main header and N tile-parts; each tile is
        // encoded with its real image-coordinate origin via the
        // parity-aware DWT path landed in steps 1+2+3.
        let pipeline = EncoderPipeline(config: configuration)
        let (codestream, partials) =
            try await pipeline.encodeNativeMultiTile(image, layout: layout)

        let observations = partials.map { partial -> J2KTileWorkObservation in
            // We don't have a per-tile output-byte count from the
            // native assembler (the encoded tile data lives inside
            // the unified codestream), so we report the size of the
            // tile-data payload (excluding SOT/SOD overhead).
            return J2KTileWorkObservation(
                tileIndex: 0,  // filled below
                pixels: partial.pixels,
                tileBytes: partial.tileData.count,
                encodeMs: partial.encodeMs,
                originX: partial.originX,
                originY: partial.originY)
        }
        // Re-index the observations to carry their actual tile index
        // (the partials are already in row-major tile-index order).
        let indexedObservations = observations.enumerated().map { (k, obs) in
            J2KTileWorkObservation(
                tileIndex: k,
                pixels: obs.pixels,
                tileBytes: obs.tileBytes,
                encodeMs: obs.encodeMs,
                originX: obs.originX,
                originY: obs.originY)
        }

        return J2KMultiTileEncodeResult(
            codestream: codestream,
            layout: layout,
            observations: indexedObservations)
    }
}
