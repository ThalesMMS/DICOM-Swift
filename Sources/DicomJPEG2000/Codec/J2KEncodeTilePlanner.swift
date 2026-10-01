// J2KEncodeTilePlanner.swift
// v5.39 M4 / v6-alpha1 — multi-tile HT lossless architecture prototype.
// v6-alpha3 step 7 — planner constraint relaxed. Multi-tile is now
// correctness-clean on every corpus fixture × every mode (cross-decode
// + self-roundtrip), so the v6-alpha2 32-alignment rule is removed.
// Only the DWT-depth floor remains; tile dim must be ≥ 2^N for the
// per-tile DWT to run.
//
// The single-tile encoder hits a structural ceiling on large fixtures
// (M3 diagnosis: DX 81 ms vs Kakadu 19 ms). The most-likely-to-clear-
// gate intervention identified in M3 was multi-tile encoding (each
// tile gets its own DWT + entropy + codestream segment, running in
// parallel). This module is the planner: it decides how many tiles
// to use based on image dimensions and the user-set environment flag.
//
// Production default is `single` — same code path as v5.38. Multi-
// tile modes are opt-in via `J2K_HT_TILE_MODE` env var:
//   - `single`   — 1×1, the current behaviour (default).
//   - `2x2`      — 2 columns × 2 rows = 4 tiles.
//   - `4x4`      — 4×4 = 16 tiles.
//   - `strips4`  — 1 column × 4 rows = 4 horizontal strips.
//   - `auto`     — pick 2x2 if pixels >= 3 M, else `single`.
//
// The planner refuses multi-tile when the resulting tile would be
// smaller than `2 ** decompositionLevels` in either dimension —
// without that floor the per-tile DWT can't run with the encoder's
// configured decomposition depth.
//
// Setting `J2K_HT_TILE_DEBUG_LAYOUT=1` prints the planner's
// requested-mode → resolved-layout decision once per encode call.
// Off by default; production logs are unaffected.

import Foundation

/// Selector for the multi-tile encode path. Read once at process
/// startup from `J2K_HT_TILE_MODE`; production default is `.auto`
/// after v7.0.0 (was `.single` through v6.x). Set
/// `J2K_HT_TILE_MODE=single` to restore v6.x single-tile bytes.
public enum J2KHTTileMode: Sendable, CustomStringConvertible {
    case single
    case tiles2x2
    case tiles4x4
    case strips4
    case auto

    public var description: String {
        switch self {
        case .single:    return "single"
        case .tiles2x2:  return "2x2"
        case .tiles4x4:  return "4x4"
        case .strips4:   return "strips4"
        case .auto:      return "auto"
        }
    }

    public static func from(envValue: String?) -> J2KHTTileMode {
        // v7.0.0 default flip — production default changed from
        // `.single` to `.auto` per docs/V6_4_0_G1_2_INVESTIGATION.md
        // SemVer Path 2 decision. The empirical encode-wall wins
        // measured at +30-50 % on MR/XA/PX (HT-conformant lossless
        // 5/3) reach default-config consumers without env-var twiddling.
        // Codestream bytes change vs v6.x for users with no
        // J2K_HT_TILE_MODE set; pixels remain bit-exact (HTTileParity-
        // MatrixTests 48/48 self-RT + cross-decode through OpenJPH /
        // Grok / Kakadu). See CROSS_VERSION_DELTA_REPORT.md.
        //
        // Opt-out path: set `J2K_HT_TILE_MODE=single` to restore v6.x
        // bytes-equality for backward-compatible byte-stream consumers.
        guard let v = envValue?.lowercased() else { return .auto }
        switch v {
        case "single", "1x1":          return .single
        case "2x2", "tiles2x2":        return .tiles2x2
        case "4x4", "tiles4x4":        return .tiles4x4
        case "strips4", "1x4":         return .strips4
        case "auto":                   return .auto
        default:                       return .auto    // v7.0.0: unrecognised → auto (was .single)
        }
    }
}

/// Concrete tile grid produced by the planner — `cols × rows` tiles
/// each of fixed `tileWidth × tileHeight` (the trailing column / row
/// may be smaller if image dims aren't multiples). All tiles share
/// the same encoder configuration (same COD / QCD / decomp levels).
public struct J2KTileLayout: Sendable, CustomStringConvertible {
    public let cols: Int
    public let rows: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int

    public var tileCount: Int { cols * rows }
    public var isMultiTile: Bool { tileCount > 1 }

    /// Pixel-rect for tile k in row-major order (k = row * cols + col).
    /// Trailing tiles may have smaller width / height when image dims
    /// aren't exact multiples of `tileWidth` / `tileHeight`.
    public func rect(forTile k: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        precondition(k >= 0 && k < tileCount, "tile index out of range")
        let col = k % cols
        let row = k / cols
        let x = col * tileWidth
        let y = row * tileHeight
        let w = min(tileWidth, imageWidth - x)
        let h = min(tileHeight, imageHeight - y)
        return (x, y, w, h)
    }

    public var description: String {
        "\(cols)x\(rows) (\(tileWidth)×\(tileHeight))"
    }
}

/// Planner: picks the tile layout for a given image and environment-
/// requested mode. Refuses multi-tile when the resulting tile is too
/// small to support the encoder's decomposition depth.
public enum J2KEncodeTilePlanner {

    /// Cached env-var read at process startup. Only consulted when
    /// the encoder explicitly opts into the planner-driven path; the
    /// production default flow ignores it entirely.
    public static let envMode: J2KHTTileMode = {
        J2KHTTileMode.from(envValue: ProcessInfo.processInfo.environment["J2K_HT_TILE_MODE"])
    }()

    /// Compute a tile layout for the given image.
    ///
    /// **Single correctness constraint (post-v6-alpha3 step 7)** —
    /// the per-tile DWT depth floor:
    ///
    ///   - **Decomposition floor**: each tile must be ≥
    ///     `2^decompositionLevels` along each axis or the per-tile
    ///     DWT cannot run with that depth. Below this size the
    ///     planner falls back to single-tile.
    ///
    /// **History — v6-alpha2 32-alignment constraint REMOVED:**
    ///
    /// v6-alpha2 added a second constraint requiring tile width and
    /// height to each be multiples of `2^decompositionLevels`. That
    /// constraint existed because the v6-alpha1 wrap-and-stitch
    /// encoder treated each tile as a standalone image (origin
    /// (0, 0)) so DWT lifting started at even parity at every level;
    /// a multi-tile decoder applies the inverse DWT using image-
    /// coordinate parity at each level (`origin / 2^level`), so
    /// non-32-aligned origins produced wrong pixels (M4 root cause:
    /// 7/8 large-fixture/mode cells failed external cross-decode;
    /// only XA 1024² — origin always 32-aligned — passed).
    ///
    /// v6-alpha3 step 1+2+3 made the encoder DWT origin-aware;
    /// step 5 replaced wrap-and-stitch with a native multi-tile
    /// codestream assembler; step 6A canvas-anchored the encoder
    /// code-block partition; step 6B mirrored everything on the
    /// decode side. After step 6B, every (fixture, mode) cell
    /// cross-decodes bit-exact through OpenJPH/Grok/Kakadu AND
    /// J2KSwift self-roundtrips bit-exact. The 32-alignment
    /// constraint is therefore obsolete and removed in step 7.
    ///
    /// The decomposition floor (constraint 1) stays — it's a
    /// per-tile DWT depth precondition, not a multi-tile parity
    /// concern.
    public static func plan(
        imageWidth: Int,
        imageHeight: Int,
        decompositionLevels: Int,
        mode: J2KHTTileMode
    ) -> J2KTileLayout {
        let pixels = imageWidth * imageHeight
        let chosen: J2KHTTileMode
        switch mode {
        case .auto:
            // v6-alpha4 step 10 — auto mode picks the tile grid that
            // empirically minimises encode wall time at each fixture
            // size, per the step-9 release-build median-of-5
            // measurement (see MEDICAL_BENCHMARK_V6.md "step 9"
            // section):
            //
            //   pixels ≥ 3 M  → 4x4
            //     PX 2459×1316 (3.24 M): 4x4 23.2 ms vs 2x2 27.0 ms
            //                            (single 37.2 ms — 1.66× win)
            //     DX 2800×2288 (6.41 M): 4x4 53.5 ms vs 2x2 56.0 ms
            //                            (single 74.5 ms — 1.39× win)
            //
            //   500 K ≤ pixels < 3 M  → 2x2
            //     XA 1024×1024 (1.05 M): 2x2 7.7 ms (single 11.5 ms
            //                            — 1.49× win); 4x4 8.1 ms
            //                            (4x4 not better at this size)
            //     MR  886× 886 (0.78 M): 2x2 2.6 ms (single 5.3 ms —
            //                            2.04× win); 4x4 3.4 ms
            //
            //   pixels < 500 K  → single
            //     MR-small / CT etc.: per-tile encode time is below
            //     the task-group dispatch + scheduler floor, so
            //     multi-tile would be net slower.
            //
            // The per-tile DWT depth floor (constraint 1 below) is
            // a separate hard limit; if the chosen multi-tile grid
            // would produce a tile smaller than `2^decompositionLevels`,
            // the planner falls back to single regardless.
            // v9.6 mammography override (2026-05-15) — the v8.7 corpus
            // A/B (V8_7_ENCODER_REDESIGN_FINDING.md table at line 57-64)
            // measured 4x4 regressing MG 3517×4784 by **-13.32 ms / -8.0%**
            // (166.89 ms 2x2 vs 180.21 ms 4x4) on M2 cold-shot CLI walls.
            // The 2x2 win on MG is data-supported and independent of the
            // 4x4 wins on PX (+3.80 ms) and XA (+2.78 ms). Gate it on
            // (pixels ≥ 12 MP AND min(w,h) ≥ 2400) so it catches MG
            // (16.8 MP, min 3520) without touching XA (7.86 MP, min 2560)
            // or DX (≤7.78 MP, min 2544) which both stay on the
            // 4x4-wins-or-noise side of the v8.7 data.
            let minDimension = min(imageWidth, imageHeight)
            if pixels >= 12_000_000 && minDimension >= 2400 {
                chosen = .tiles2x2
            } else if pixels >= 3_000_000 {
                chosen = .tiles4x4
            } else if pixels >= 500_000 {
                chosen = .tiles2x2
            } else {
                chosen = .single
            }
        default:
            chosen = mode
        }

        let (cols, rows): (Int, Int)
        switch chosen {
        case .single:    (cols, rows) = (1, 1)
        case .tiles2x2:  (cols, rows) = (2, 2)
        case .tiles4x4:  (cols, rows) = (4, 4)
        case .strips4:   (cols, rows) = (1, 4)
        case .auto:      (cols, rows) = (1, 1)  // resolved above
        }

        let tileW = (imageWidth  + cols - 1) / cols
        let tileH = (imageHeight + rows - 1) / rows
        let single = J2KTileLayout(
            cols: 1, rows: 1,
            tileWidth: imageWidth, tileHeight: imageHeight,
            imageWidth: imageWidth, imageHeight: imageHeight)

        // Constraint 1: per-tile DWT depth floor. Below `2^N` the
        // per-tile DWT cannot run with the encoder's configured
        // decomposition depth.
        let minDim = 1 << decompositionLevels
        if tileW < minDim || tileH < minDim {
            debugLogLayout(requested: mode, resolved: chosen,
                           outcome: "fallback (tile dim < 2^\(decompositionLevels))",
                           layout: single, image: (imageWidth, imageHeight))
            return single
        }

        let layout = J2KTileLayout(
            cols: (imageWidth + tileW - 1) / tileW, rows: (imageHeight + tileH - 1) / tileH,
            tileWidth: tileW, tileHeight: tileH,
            imageWidth: imageWidth, imageHeight: imageHeight)
        debugLogLayout(requested: mode, resolved: chosen,
                       outcome: layout.isMultiTile ? "multi-tile" : "single",
                       layout: layout, image: (imageWidth, imageHeight))
        return layout
    }

    /// Cached env-var read at process startup. When set to `"1"`
    /// (or `"true"` / `"yes"`), the planner prints its decision
    /// once per `plan(...)` call. Off by default; production
    /// behaviour unchanged.
    private static let debugLayoutEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["J2K_HT_TILE_DEBUG_LAYOUT"]?.lowercased() {
        case "1", "true", "yes", "on": return true
        default:                       return false
        }
    }()

    private static func debugLogLayout(
        requested: J2KHTTileMode,
        resolved: J2KHTTileMode,
        outcome: String,
        layout: J2KTileLayout,
        image: (w: Int, h: Int)
    ) {
        guard debugLayoutEnabled else { return }
        print("[J2K planner] image=\(image.w)×\(image.h) " +
              "requested=\(requested) resolved=\(resolved) " +
              "→ \(outcome) | layout=\(layout) " +
              "tiles=\(layout.tileCount)")
    }
}
