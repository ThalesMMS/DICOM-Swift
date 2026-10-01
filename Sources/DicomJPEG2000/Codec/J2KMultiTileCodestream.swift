// J2KMultiTileCodestream.swift
// v5.39 M4 / v6-alpha1 — multi-tile HT prototype: pixel slicer +
// codestream stitcher.
//
// The prototype reuses the existing single-tile encoder unchanged.
// To produce a multi-tile codestream we:
//   1. Slice the input `J2KImage` into N sub-images, one per tile.
//   2. Encode each sub-image as a **standalone** single-tile J2K
//      codestream (existing path, no code changes inside the
//      pipeline).
//   3. Stitch the N standalone codestreams: take tile 0's main
//      header (SOC + SIZ + … + COM), patch SIZ to set the image-
//      level Xsiz / Ysiz / XTsiz / YTsiz, then for each tile
//      append the [SOT, EOC) slice of its standalone codestream
//      after rewriting Isot to k. One EOC at the end.
//
// This preserves the M9 entropy buffer reuse, the M5/M2/M7
// optimisations, and every correctness gate inside the pipeline.
// The only new code paths are the byte-level patching here and a
// small dispatch in `J2KEncoder.encode`.
//
// SCOPE: HT lossless. Single-component-per-image is exercised by
// the medical corpus; multi-component support depends on the
// existing pipeline (each component's data slab is sliced
// independently and reassembled). XRsiz/YRsiz must be 1.

import Foundation

/// Pixel-data slicer. Builds a sub-`J2KImage` covering the rect for
/// tile `k` of `layout`. All components are sliced uniformly (the
/// medical corpus is single-component greyscale; multi-component
/// at full resolution is supported but subsampled components are
/// not — XRsiz/YRsiz must be 1).
enum J2KTileImageSlicer {

    /// Build a sub-image for tile `k` of `layout` from the parent
    /// `image`. Every component's `data` is copied (slice-and-pack
    /// into a contiguous byte buffer for the tile rect).
    static func sliceTile(
        from image: J2KImage,
        layout: J2KTileLayout,
        tileIndex k: Int
    ) throws -> J2KImage {
        let r = layout.rect(forTile: k)

        var sliced: [J2KComponent] = []
        sliced.reserveCapacity(image.components.count)
        for comp in image.components {
            guard comp.subsamplingX == 1, comp.subsamplingY == 1 else {
                throw J2KError.invalidParameter(
                    "multi-tile prototype: subsampled components not supported")
            }
            let bytesPerSample = (comp.bitDepth + 7) / 8
            // Component's logical width/height matches image (no
            // subsampling). For 16-bit medical data, bytesPerSample
            // is 2. We just slice the rect from the per-component
            // raster-scan byte stream.
            let srcRowStride = comp.width * bytesPerSample
            let dstRowStride = r.w * bytesPerSample
            var dst = Data(count: r.h * dstRowStride)
            comp.data.withUnsafeBytes { srcRaw in
                guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                dst.withUnsafeMutableBytes { dstRaw in
                    guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for row in 0..<r.h {
                        let srcOffset = (r.y + row) * srcRowStride + r.x * bytesPerSample
                        let dstOffset = row * dstRowStride
                        memcpy(dstBase + dstOffset, srcBase + srcOffset, dstRowStride)
                    }
                }
            }

            sliced.append(J2KComponent(
                index: comp.index,
                bitDepth: comp.bitDepth,
                signed: comp.signed,
                width: r.w,
                height: r.h,
                subsamplingX: 1,
                subsamplingY: 1,
                data: dst,
                sampleByteOrder: comp.sampleByteOrder))
        }

        return J2KImage(
            width: r.w,
            height: r.h,
            components: sliced,
            offsetX: 0,
            offsetY: 0,
            tileWidth: 0,
            tileHeight: 0,
            tileOffsetX: 0,
            tileOffsetY: 0,
            colorSpace: image.colorSpace)
    }
}

/// Codestream-level assembler: takes the N standalone per-tile
/// codestreams and stitches them into one multi-tile codestream.
/// Patches:
///   - main header SIZ: Xsiz / Ysiz set to image dims (the standalone
///     encodes set them to tile dims because each tile *was* the
///     image to its encode call).
///   - per-tile SOT: Isot set to k (was 0 in the standalone).
///
/// Lsot, Psot, TPsot, TNsot are unchanged: tile-part length is the
/// same byte count whether the tile-part appears alone or stitched.
enum J2KMultiTileAssembler {

    private static let MARK_SOC: UInt16 = 0xFF4F
    private static let MARK_SIZ: UInt16 = 0xFF51
    private static let MARK_SOT: UInt16 = 0xFF90
    private static let MARK_SOD: UInt16 = 0xFF93
    private static let MARK_EOC: UInt16 = 0xFFD9

    /// Find the byte offset of the marker token (2 bytes) in `data`,
    /// scanning from `startAt`. Returns nil if not found.
    private static func findMarker(
        _ marker: UInt16,
        in data: Data,
        startAt: Int = 0
    ) -> Int? {
        let hi = UInt8((marker >> 8) & 0xFF)
        let lo = UInt8(marker & 0xFF)
        guard data.count >= 2 else { return nil }
        var i = startAt
        let end = data.count - 1
        while i < end {
            if data[i] == hi && data[i + 1] == lo {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Patch Xsiz (offset 6 from SIZ marker token) and Ysiz (offset
    /// 10) inside the SIZ segment of `header`. The SIZ segment must
    /// already be present at byte offset `sizMarkerOffset`. Tile
    /// dims (XTsiz / YTsiz at offsets 22 / 26) are left intact —
    /// they're already correct because each tile was encoded as a
    /// standalone image of size tileW × tileH.
    private static func patchSIZ(
        in header: inout Data,
        sizMarkerOffset: Int,
        imageWidth: Int,
        imageHeight: Int
    ) {
        // SIZ layout from offset 0 (marker token):
        //   0..1   marker token (0xFF51)
        //   2..3   Lsiz
        //   4..5   Rsiz
        //   6..9   Xsiz
        //   10..13 Ysiz
        //   14..17 XOsiz
        //   18..21 YOsiz
        //   22..25 XTsiz
        //   26..29 YTsiz
        //   ...
        let xsizOffset = sizMarkerOffset + 6
        let ysizOffset = sizMarkerOffset + 10
        writeUInt32BE(UInt32(imageWidth),  into: &header, at: xsizOffset)
        writeUInt32BE(UInt32(imageHeight), into: &header, at: ysizOffset)
    }

    /// Patch Isot (offset 4 from SOT marker token) to `k`.
    /// SOT layout from offset 0 (marker token):
    ///   0..1   marker token (0xFF90)
    ///   2..3   Lsot (== 10)
    ///   4..5   Isot
    ///   6..9   Psot
    ///   10     TPsot
    ///   11     TNsot
    private static func patchSOTIsot(
        in tilePart: inout Data,
        sotMarkerOffset: Int,
        tileIndex k: Int
    ) {
        precondition(k >= 0 && k <= 0xFFFF, "Isot is UInt16; tile index too large")
        let isotOffset = sotMarkerOffset + 4
        writeUInt16BE(UInt16(k), into: &tilePart, at: isotOffset)
    }

    private static func writeUInt16BE(_ v: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8((v >> 8) & 0xFF)
        data[offset + 1] = UInt8(v & 0xFF)
    }

    private static func writeUInt32BE(_ v: UInt32, into data: inout Data, at offset: Int) {
        data[offset]     = UInt8((v >> 24) & 0xFF)
        data[offset + 1] = UInt8((v >> 16) & 0xFF)
        data[offset + 2] = UInt8((v >>  8) & 0xFF)
        data[offset + 3] = UInt8( v        & 0xFF)
    }

    /// Stitch N standalone per-tile codestreams (each
    /// `SOC + SIZ + … + EOC`) into one multi-tile codestream.
    /// Returns the assembled bytes.
    ///
    /// `perTile` must be in row-major tile order (tile 0 first).
    /// `imageWidth` / `imageHeight` describe the full image; the
    /// stitched SIZ marker is patched to those values.
    static func stitch(
        perTile: [Data],
        imageWidth: Int,
        imageHeight: Int
    ) throws -> Data {
        precondition(!perTile.isEmpty, "stitch: at least one tile required")

        // Take tile 0's main header (everything before its first SOT).
        // Patch SIZ Xsiz / Ysiz to image dims.
        guard let sotInTile0 = findMarker(MARK_SOT, in: perTile[0]) else {
            throw J2KError.encodingError("stitch: no SOT marker in tile 0")
        }
        var mainHeader = perTile[0].prefix(sotInTile0)
        var mainHeaderData = Data(mainHeader)
        guard let sizOffset = findMarker(MARK_SIZ, in: mainHeaderData) else {
            throw J2KError.encodingError("stitch: no SIZ marker in tile 0 main header")
        }
        patchSIZ(in: &mainHeaderData,
                 sizMarkerOffset: sizOffset,
                 imageWidth: imageWidth,
                 imageHeight: imageHeight)
        mainHeader = mainHeaderData

        var assembled = Data()
        assembled.reserveCapacity(perTile.reduce(mainHeaderData.count) { $0 + $1.count })
        assembled.append(mainHeaderData)

        for (k, tile) in perTile.enumerated() {
            guard let sot = findMarker(MARK_SOT, in: tile) else {
                throw J2KError.encodingError("stitch: no SOT in tile \(k)")
            }
            // Find the EOC at the END of the standalone codestream.
            // It's always the last 2 bytes of a well-formed codestream.
            let eocOffset = tile.count - 2
            guard tile[eocOffset]     == 0xFF,
                  tile[eocOffset + 1] == 0xD9
            else {
                throw J2KError.encodingError("stitch: tile \(k) does not end in EOC")
            }
            // Extract [SOT .. EOC). Force 0-based indexing — Data
            // sliced from another Data preserves the source's index
            // range, which would mis-target our patch offsets.
            var tilePart = Data()
            tilePart.append(contentsOf: tile[sot..<eocOffset])
            precondition(tilePart.startIndex == 0,
                         "stitch: tilePart must be 0-indexed for patchSOTIsot")
            // Patch SOT.Isot to k. The SOT is at offset 0 of tilePart.
            patchSOTIsot(in: &tilePart, sotMarkerOffset: 0, tileIndex: k)
            assembled.append(tilePart)
        }

        // One EOC at the end of the multi-tile codestream.
        assembled.append(0xFF)
        assembled.append(0xD9)

        return assembled
    }
}
