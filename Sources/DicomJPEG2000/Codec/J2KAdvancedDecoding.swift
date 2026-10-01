//
// J2KAdvancedDecoding.swift
// J2KSwift
//
// J2KAdvancedDecoding.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-07.
//

import Foundation
import Synchronization

// # JPEG 2000 Advanced Decoding
//
// Support for advanced decoding modes in JPEG 2000.
//
// Advanced decoding allows selective extraction of image data based on:
// - Quality layers (SNR progressive)
// - Resolution levels (spatial progressive)
// - Spatial regions (ROI decoding)
// - Incremental data availability
//
// ## Decoding Modes
//
// - **Partial Decoding**: Decode up to specific quality layer or resolution
// - **ROI Decoding**: Extract specific rectangular regions
// - **Progressive Decoding**: Incrementally refine quality or resolution
// - **Incremental Decoding**: Process data as it becomes available
//
// ## Usage
//
// ```swift
// let decoder = J2KDecoder()
//
// // Partial quality decoding (preview)
// let preview = try decoder.decodePartial(
//     data,
//     options: J2KPartialDecodingOptions(maxLayer: 2)
// )
//
// // ROI decoding
// let region = J2KRegion(x: 100, y: 100, width: 512, height: 512)
// let roi = try decoder.decodeRegion(data, region: region)
//
// // Resolution progressive (thumbnail)
// let thumbnail = try decoder.decodeResolution(data, level: 2)
// ```

// MARK: - Partial Decoding Options

/// Options for partial decoding operations.
public struct J2KPartialDecodingOptions: Sendable, Equatable {
    /// Maximum quality layer to decode (nil = all layers).
    public let maxLayer: Int?

    /// Maximum resolution level to decode (nil = full resolution).
    ///
    /// Resolution level 0 is the lowest resolution (thumbnail),
    /// higher levels progressively increase resolution.
    public let maxResolutionLevel: Int?

    /// Specific region to decode (nil = full image).
    public let region: J2KRegion?

    /// Enable early stopping optimisation.
    ///
    /// When true, the decoder stops processing as soon as the requested
    /// quality/resolution is achieved, saving computation time.
    public let earlyStop: Bool

    /// Decode only specific components (nil = all components).
    ///
    /// For RGB images: [0, 1, 2] for R, G, B components.
    /// Can be used to decode grayscale from colour images: [0] for Y component.
    public let components: [Int]?

    /// Creates new partial decoding options.
    ///
    /// - Parameters:
    ///   - maxLayer: Maximum quality layer to decode (default: nil for all layers).
    ///   - maxResolutionLevel: Maximum resolution level (default: nil for full resolution).
    ///   - region: Specific region to decode (default: nil for full image).
    ///   - earlyStop: Enable early stopping optimisation (default: true).
    ///   - components: Specific components to decode (default: nil for all components).
    public init(
        maxLayer: Int? = nil,
        maxResolutionLevel: Int? = nil,
        region: J2KRegion? = nil,
        earlyStop: Bool = true,
        components: [Int]? = nil
    ) {
        self.maxLayer = maxLayer
        self.maxResolutionLevel = maxResolutionLevel
        self.region = region
        self.earlyStop = earlyStop
        self.components = components
    }

    /// Validates the options.
    ///
    /// - Parameters:
    ///   - imageWidth: Full image width.
    ///   - imageHeight: Full image height.
    ///   - maxLayers: Maximum available quality layers.
    ///   - maxLevels: Maximum decomposition levels.
    ///   - componentCount: Number of components in the image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if options are invalid.
    public func validate(
        imageWidth: Int,
        imageHeight: Int,
        maxLayers: Int,
        maxLevels: Int,
        componentCount: Int
    ) throws {
        if let layer = maxLayer, layer < 0 || layer >= maxLayers {
            throw J2KError.invalidParameter("maxLayer must be in range [0, \(maxLayers))")
        }

        if let level = maxResolutionLevel, level < 0 || level > maxLevels {
            throw J2KError.invalidParameter("maxResolutionLevel must be in range [0, \(maxLevels)]")
        }

        if let region = region {
            try region.validate(imageWidth: imageWidth, imageHeight: imageHeight)
        }

        if let comps = components {
            if comps.isEmpty {
                throw J2KError.invalidParameter("components array cannot be empty")
            }

            for comp in comps {
                if comp < 0 || comp >= componentCount {
                    throw J2KError.invalidParameter("component \(comp) out of range [0, \(componentCount))")
                }
            }
        }
    }
}

// MARK: - ROI Decoding Options

/// Options for region-of-interest decoding.
public struct J2KROIDecodingOptions: Sendable, Equatable {
    /// The region to decode.
    public let region: J2KRegion

    /// Maximum quality layer to decode (nil = all layers).
    public let maxLayer: Int?

    /// Components to decode (nil = all components).
    public let components: [Int]?

    /// Decoding strategy for the region.
    public let strategy: J2KROIDecodingStrategy

    /// Creates new ROI decoding options.
    ///
    /// - Parameters:
    ///   - region: The region to decode.
    ///   - maxLayer: Maximum quality layer (default: nil for all layers).
    ///   - components: Components to decode (default: nil for all).
    ///   - strategy: Decoding strategy (default: .direct).
    public init(
        region: J2KRegion,
        maxLayer: Int? = nil,
        components: [Int]? = nil,
        strategy: J2KROIDecodingStrategy = .direct
    ) {
        self.region = region
        self.maxLayer = maxLayer
        self.components = components
        self.strategy = strategy
    }

    /// Validates the options.
    ///
    /// - Parameters:
    ///   - imageWidth: Full image width.
    ///   - imageHeight: Full image height.
    ///   - maxLayers: Maximum available quality layers.
    ///   - componentCount: Number of components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if options are invalid.
    public func validate(
        imageWidth: Int,
        imageHeight: Int,
        maxLayers: Int,
        componentCount: Int
    ) throws {
        try region.validate(imageWidth: imageWidth, imageHeight: imageHeight)

        if let layer = maxLayer, layer < 0 || layer >= maxLayers {
            throw J2KError.invalidParameter("maxLayer must be in range [0, \(maxLayers))")
        }

        if let comps = components {
            if comps.isEmpty {
                throw J2KError.invalidParameter("components array cannot be empty")
            }

            for comp in comps {
                if comp < 0 || comp >= componentCount {
                    throw J2KError.invalidParameter("component \(comp) out of range [0, \(componentCount))")
                }
            }
        }
    }
}

/// Strategy for ROI decoding.
public enum J2KROIDecodingStrategy: Sendable, Equatable {
    /// Decode the entire image then extract the region.
    ///
    /// Simple but less efficient. Useful when multiple regions will be extracted.
    case fullImageExtraction

    /// Decode only the necessary data for the region.
    ///
    /// More efficient for single region extraction. Requires identifying
    /// which code-blocks contribute to the region.
    case direct

    /// Use cached full image if available, otherwise decode directly.
    case cached
}

// MARK: - Resolution Progressive Decoding

/// Options for resolution progressive decoding.
public struct J2KResolutionDecodingOptions: Sendable, Equatable {
    /// Target resolution level (0 = lowest/thumbnail, higher = more detail).
    public let level: Int

    /// Maximum quality layer to decode at this resolution.
    public let maxLayer: Int?

    /// Components to decode (nil = all components).
    public let components: [Int]?

    /// Whether to upscale to original dimensions.
    ///
    /// If true, the result is upscaled to the original image size.
    /// If false, returns the image at the decoded resolution.
    public let upscale: Bool

    /// Creates resolution decoding options.
    ///
    /// - Parameters:
    ///   - level: Target resolution level.
    ///   - maxLayer: Maximum quality layer (default: nil for all).
    ///   - components: Components to decode (default: nil for all).
    ///   - upscale: Upscale to original dimensions (default: false).
    public init(
        level: Int,
        maxLayer: Int? = nil,
        components: [Int]? = nil,
        upscale: Bool = false
    ) {
        self.level = level
        self.maxLayer = maxLayer
        self.components = components
        self.upscale = upscale
    }

    /// Validates the options.
    ///
    /// - Parameters:
    ///   - maxLevels: Maximum decomposition levels.
    ///   - maxLayers: Maximum quality layers.
    ///   - componentCount: Number of components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if options are invalid.
    public func validate(maxLevels: Int, maxLayers: Int, componentCount: Int) throws {
        if level < 0 || level > maxLevels {
            throw J2KError.invalidParameter("level must be in range [0, \(maxLevels)]")
        }

        if let layer = maxLayer, layer < 0 || layer >= maxLayers {
            throw J2KError.invalidParameter("maxLayer must be in range [0, \(maxLayers))")
        }

        if let comps = components {
            if comps.isEmpty {
                throw J2KError.invalidParameter("components array cannot be empty")
            }

            for comp in comps {
                if comp < 0 || comp >= componentCount {
                    throw J2KError.invalidParameter("component \(comp) out of range [0, \(componentCount))")
                }
            }
        }
    }

    /// Calculates the decoded image dimensions at this resolution level.
    ///
    /// - Parameters:
    ///   - fullWidth: Full image width.
    ///   - fullHeight: Full image height.
    /// - Returns: Tuple of (width, height) at the target resolution level.
    public func calculatedDimensions(fullWidth: Int, fullHeight: Int) -> (width: Int, height: Int) {
        let divisor = 1 << level
        let width = (fullWidth + divisor - 1) / divisor
        let height = (fullHeight + divisor - 1) / divisor
        return (width, height)
    }
}

// MARK: - Quality Progressive Decoding

/// Options for quality progressive decoding.
public struct J2KQualityDecodingOptions: Sendable, Equatable {
    /// Target quality layer.
    public let layer: Int

    /// Components to decode (nil = all components).
    public let components: [Int]?

    /// Whether to include all previous layers.
    ///
    /// If true, decodes all layers up to and including the target layer.
    /// If false, decodes only the target layer (incremental refinement).
    public let cumulative: Bool

    /// Creates quality decoding options.
    ///
    /// - Parameters:
    ///   - layer: Target quality layer.
    ///   - components: Components to decode (default: nil for all).
    ///   - cumulative: Include all previous layers (default: true).
    public init(
        layer: Int,
        components: [Int]? = nil,
        cumulative: Bool = true
    ) {
        self.layer = layer
        self.components = components
        self.cumulative = cumulative
    }

    /// Validates the options.
    ///
    /// - Parameters:
    ///   - maxLayers: Maximum quality layers.
    ///   - componentCount: Number of components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if options are invalid.
    public func validate(maxLayers: Int, componentCount: Int) throws {
        if layer < 0 || layer >= maxLayers {
            throw J2KError.invalidParameter("layer must be in range [0, \(maxLayers))")
        }

        if let comps = components {
            if comps.isEmpty {
                throw J2KError.invalidParameter("components array cannot be empty")
            }

            for comp in comps {
                if comp < 0 || comp >= componentCount {
                    throw J2KError.invalidParameter("component \(comp) out of range [0, \(componentCount))")
                }
            }
        }
    }
}

// MARK: - Incremental Decoding

/// State for incremental decoding operations.
///
/// Maintains decoder state across multiple partial data updates,
/// enabling progressive decoding as data arrives over a network.
///
/// Thread safety is provided by `Mutex` from the `Synchronization` module,
/// replacing the previous `@unchecked Sendable` + `NSLock` pattern.
public final class J2KIncrementalDecoder: Sendable {
    /// Internal mutable state protected by `Mutex`.
    private struct DecoderState: ~Copyable {
        var buffer = Data()
        var isComplete: Bool = false
        var lastDecodedLayer: Int = -1
        var lastDecodedLevel: Int = -1
    }

    /// Thread-safe state management via `Mutex`.
    private let state: Mutex<DecoderState>

    /// Creates a new incremental decoder.
    public init() {
        self.state = Mutex(DecoderState())
    }

    /// Appends new data to the decoder.
    ///
    /// - Parameter data: New data chunk to append.
    public func append(_ data: Data) {
        state.withLock { $0.buffer.append(data) }
    }

    /// Marks the data stream as complete.
    public func complete() {
        state.withLock { $0.isComplete = true }
    }

    /// Checks if enough data is available to decode.
    ///
    /// - Returns: True if decoding can proceed.
    public func canDecode() -> Bool {
        state.withLock { $0.buffer.count > 100 }
    }

    /// Attempts to decode with currently available data.
    ///
    /// - Parameter options: Decoding options.
    /// - Returns: Decoded image if sufficient data is available, nil otherwise.
    /// - Throws: ``J2KError`` if decoding fails.
    public func tryDecode(options: J2KPartialDecodingOptions = J2KPartialDecodingOptions()) throws -> J2KImage? {
        try state.withLock { decoderState in
            guard decoderState.buffer.count > 100 else {
                return nil
            }

            // In a real implementation, this would:
            // 1. Parse what data is available
            // 2. Decode up to the available quality layers
            // 3. Track what has been decoded
            // 4. Return partial results

            // For now, this is a placeholder
            throw J2KError.notImplemented("Incremental decoding not yet fully implemented")
        }
    }

    /// Gets the current buffer size.
    ///
    /// - Returns: Number of bytes currently buffered.
    public func bufferSize() -> Int {
        state.withLock { $0.buffer.count }
    }

    /// Checks if the data stream is complete.
    ///
    /// - Returns: True if `complete()` has been called.
    public func isComplete() -> Bool {
        state.withLock { $0.isComplete }
    }

    /// Resets the decoder state.
    public func reset() {
        state.withLock { decoderState in
            decoderState.buffer.removeAll()
            decoderState.isComplete = false
            decoderState.lastDecodedLayer = -1
            decoderState.lastDecodedLevel = -1
        }
    }
}

// MARK: - Decoder Extensions

extension J2KDecoder {
    /// Decodes a JPEG 2000 image with combined partial-decoding options.
    ///
    /// **v10.8.0** — `decodePartial` is the umbrella API composing the
    /// partial-decode capabilities shipped across v10.5.0–v10.7.0:
    ///
    /// - `maxResolutionLevel` — decode at a reduced resolution level
    ///   (v10.5.0 true partial-resolution decode: code-block filter +
    ///   inverse-DWT truncation; 3-8× faster than full decode).
    /// - `region` — decode a spatial region of interest (v10.6.0
    ///   entropy-skip + v10.7.0 tile-skip). The region is interpreted
    ///   in full-image pixel coordinates.
    /// - `components` — return only the requested image components,
    ///   in the requested order.
    ///
    /// When both `maxResolutionLevel` and `region` are set, the image
    /// is decoded at the resolution level and the region (full-image
    /// coordinates) is mapped onto the reduced-resolution grid.
    ///
    /// `maxLayer` (quality-layer truncation) is **not** supported — the
    /// decoder's packet loop is single-layer. A `maxLayer` that keeps
    /// every layer is a harmless no-op; one that would exclude layers
    /// throws ``J2KError/notImplemented(_:)``. `earlyStop` is advisory
    /// — partial decode inherently skips work — and currently has no
    /// effect on the result.
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 data to decode.
    ///   - options: Combined partial-decoding options.
    /// - Returns: The decoded image at the requested resolution / region / components.
    /// - Throws: ``J2KError`` if decoding fails or an unsupported option is requested.
    public func decodePartial(_ data: Data, options: J2KPartialDecodingOptions) async throws -> J2KImage {
        try await decodePartialReporting(data, options: options).image
    }

    /// `decodePartial` plus the packet-byte accounting of the decode (issue #2382). `maxLayer` combines with
    /// resolution and region: the multi-layer packet parse keeps every layer's headers in step and entropy-
    /// decodes only layers `0...maxLayer`; region and resolution filters then drop the blocks outside the
    /// request as in a full-quality partial decode. A `session` reuses the tier-2 parse between refinements.
    public func decodePartialReporting(
        _ data: Data,
        options: J2KPartialDecodingOptions,
        session: J2KQualityRefinementSession? = nil
    ) async throws -> (image: J2KImage, report: J2KPartialDecodeReport) {
        if let session, session.data != data {
            throw J2KError.invalidParameter("quality refinement session belongs to a different codestream")
        }
        let metadata = try DecoderPipeline.peekMetadata(data)
        let levels = metadata.configuration.decompositionLevels
        let layers = max(metadata.configuration.qualityLayers, 1)
        let componentCount = metadata.componentCount

        try options.validate(
            imageWidth: metadata.width, imageHeight: metadata.height,
            maxLayers: layers, maxLevels: levels, componentCount: componentCount)

        let accounting = J2KPartialDecodeAccounting()
        let state = J2KDecodeSessionState(accounting: accounting, cache: session?.cache)
        // A maxLayer that keeps every layer is the plain decode of that layer count.
        let maxLayer: Int? = options.maxLayer.flatMap { $0 < layers - 1 ? $0 : nil }

        // --- Resolution-aware decode ---
        var image: J2KImage
        var resolutionFactor = 1
        if let level = options.maxResolutionLevel, level >= 0, level < levels {
            // v10.5.0 true partial-resolution decode.
            image = try await decodePartialResolution(data: data, level: level, maxLayer: maxLayer, session: state)
            resolutionFactor = 1 << (levels - level)
        } else if let region = options.region {
            // v10.6.0/v10.7.0 ROI decode — entropy-skip + tile-skip.
            // Returns a full-dimension image; cropped below.
            image = try await decodeRegionDirect(data: data, region: region, maxLayer: maxLayer, session: state)
        } else if let maxLayer {
            image = try await decodeQualityLayers(data: data, maxLayer: maxLayer, session: state)
        } else {
            var pipeline = makePipeline()
            pipeline.partialAccounting = accounting
            pipeline.layeredBlockCache = session?.cache
            image = try await pipeline.decode(data)
        }

        // --- Region crop ---
        if let region = options.region {
            let crop: J2KRegion
            if resolutionFactor == 1 {
                crop = region
            } else {
                // The region is full-image coordinates; map it onto the
                // reduced-resolution grid produced by the partial-
                // resolution decode.
                let f = resolutionFactor
                let rx = min(region.x / f, max(0, image.width - 1))
                let ry = min(region.y / f, max(0, image.height - 1))
                let rw = max(1, min((region.width + f - 1) / f, image.width - rx))
                let rh = max(1, min((region.height + f - 1) / f, image.height - ry))
                crop = J2KRegion(x: rx, y: ry, width: rw, height: rh)
            }
            image = try extractRegion(from: image, region: crop)
        }

        // --- Component selection ---
        if let comps = options.components {
            let selected = comps.compactMap { idx in
                image.components.first(where: { $0.index == idx })
            }
            guard selected.count == comps.count else {
                throw J2KError.invalidParameter(
                    "decodePartial: requested components \(comps) not all present in the decoded image")
            }
            image = J2KImage(
                width: image.width, height: image.height,
                components: selected, colorSpace: image.colorSpace)
        }

        var report = accounting.report
        if report.totalLayers == 0 { report = J2KPartialDecodeReport(decodedLayers: layers, totalLayers: layers, consumedPacketBytes: report.consumedPacketBytes, skippedPacketBytes: 0, parsedTiles: report.parsedTiles, reusedTiles: report.reusedTiles) }
        return (image, report)
    }

    /// Decodes a specific region of interest from a JPEG 2000 image.
    ///
    /// **v10.6.0 — true ROI decode (`.direct` strategy)**: the decoder
    /// keeps only the code-blocks whose inverse-DWT spatial footprint
    /// overlaps the requested region and skips the dominant entropy
    /// decode stage for the rest. The inverse DWT still runs full-tile
    /// (off-region code-blocks reconstruct as zeros), then the result
    /// is cropped to the region. The cropped output is bit-identical
    /// to a full `decode()` followed by the same crop — every block
    /// influencing an in-region pixel is retained.
    ///
    /// - `.fullImageExtraction` decodes the whole image then crops —
    ///   simple, no entropy saving, useful when several regions will
    ///   be extracted from one decode.
    /// - `.direct` / `.cached` skip entropy decode for off-region
    ///   code-blocks. Faster for a single region of a large image.
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 data to decode.
    ///   - options: ROI decoding options.
    /// - Returns: The decoded region as an image.
    /// - Throws: ``J2KError`` if decoding fails.
    public func decodeRegion(_ data: Data, options: J2KROIDecodingOptions) async throws -> J2KImage {
        switch options.strategy {
        case .fullImageExtraction:
            // Decode full image then extract.
            let fullImage = try await decode(data)
            return try extractRegion(from: fullImage, region: options.region)

        case .direct, .cached:
            // True ROI decode — entropy decode is skipped for code-blocks
            // outside the region's inverse-DWT footprint. The pipeline
            // still produces a full-dimension image (the inverse DWT runs
            // full-tile); cropping yields the region. `.cached` has no
            // cache layer yet, so it falls back to the direct decode per
            // its documented behaviour.
            let fullImage = try await decodeRegionDirect(data: data, region: options.region)
            return try extractRegion(from: fullImage, region: options.region)
        }
    }

    /// Decodes a JPEG 2000 image at a specific resolution level.
    ///
    /// **v10.5.0 — true partial-resolution decode**: Stage B.1 skips
    /// entropy decode for code-blocks at higher decomposition levels
    /// than needed for the target resolution (the dominant stage);
    /// Stage B.2 truncates the inverse DWT at the target level so the
    /// pipeline outputs reduced-dimension data directly — no
    /// downsample step. Phase 1 (v10.4.0) was decode-then-downsample
    /// only.
    ///
    /// **v10.25 — multi-tile support**: each tile's truncated iDWT
    /// output is composited into the reduced canvas at ceil-div
    /// offsets per ISO/IEC 15444-1, so multi-tile codestreams (the
    /// production `.auto` encode shape for ≥3 MP images) get the same
    /// true partial-resolution speedup as single-tile. (v10.5.0
    /// through v10.24 mis-composited multi-tile partial decodes;
    /// v10.25.0 interim builds fell back to decode-then-downsample.)
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 data to decode.
    ///   - options: Resolution decoding options.
    /// - Returns: The decoded image at the requested resolution (or full if `upscale = true`).
    /// - Throws: ``J2KError`` if decoding fails.
    public func decodeResolution(_ data: Data, options: J2KResolutionDecodingOptions) async throws -> J2KImage {
        // v10.5.0 Stage B.1 + B.2 — true partial-resolution decode:
        // the pipeline filters code-blocks at extract (B.1) and
        // truncates the inverse DWT at the target level (B.2),
        // producing reduced-dimension output directly. No
        // downsample step needed.
        let partial = try await decodePartialResolution(data: data, level: options.level)

        if options.upscale && partial.width != 0 && partial.height != 0 {
            // Caller wants original dimensions: upscale via nearest-
            // neighbour. We need to know the original codestream dims
            // — peek the metadata.
            let originalMetadata = try DecoderPipeline.peekMetadata(data)
            let origW = originalMetadata.width
            let origH = originalMetadata.height
            if partial.width == origW && partial.height == origH {
                return partial
            }
            let factor = max(1, origW / partial.width)
            return try Self.upscaleByPowerOf2(
                image: partial,
                targetWidth: origW, targetHeight: origH,
                factor: factor)
        }
        return partial
    }

    /// Power-of-2 downscale via block-average (separable). Handles both
    /// 8-bit and 16-bit components.
    // internal (not private): no production callers since the v10.25
    // multi-tile partial-resolution fallback was removed, but kept as
    // the reference block-mean downsample for the decodeResolution
    // content-correlation tests (V10_10_DecodeResolutionSmokeTests).
    static func downscaleByPowerOf2(
        image: J2KImage, targetWidth: Int, targetHeight: Int, factor: Int
    ) throws -> J2KImage {
        guard factor >= 1 else {
            throw J2KError.invalidParameter("downscale factor must be ≥ 1")
        }
        if factor == 1 { return image }

        let scaledComponents: [J2KComponent] = image.components.map { comp in
            let srcW = comp.width
            let bytesPerSample = (comp.bitDepth + 7) / 8
            let littleEndian = comp.sampleByteOrder == .littleEndian
            let dstBytes = targetWidth * targetHeight * bytesPerSample
            var dst = Data(count: dstBytes)

            comp.data.withUnsafeBytes { srcRaw in
                dst.withUnsafeMutableBytes { dstRaw in
                    if bytesPerSample == 2 {
                        // 16-bit samples in the component's byte order.
                        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                        let out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                        for dy in 0..<targetHeight {
                            for dx in 0..<targetWidth {
                                var sum: UInt32 = 0
                                var cnt: UInt32 = 0
                                for ky in 0..<factor {
                                    let sy = dy * factor + ky
                                    if sy >= comp.height { continue }
                                    for kx in 0..<factor {
                                        let sx = dx * factor + kx
                                        if sx >= srcW { continue }
                                        let off = (sy * srcW + sx) * 2
                                        let v = littleEndian
                                            ? (UInt32(src[off + 1]) << 8) | UInt32(src[off])
                                            : (UInt32(src[off]) << 8) | UInt32(src[off + 1])
                                        sum &+= v
                                        cnt &+= 1
                                    }
                                }
                                let avg: UInt32 = cnt == 0 ? 0 : sum / cnt
                                let outOff = (dy * targetWidth + dx) * 2
                                let high = UInt8(truncatingIfNeeded: (avg >> 8) & 0xFF)
                                let low = UInt8(truncatingIfNeeded: avg & 0xFF)
                                out[outOff]     = littleEndian ? low : high
                                out[outOff + 1] = littleEndian ? high : low
                            }
                        }
                    } else {
                        // 8-bit fallback.
                        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                        let out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                        for dy in 0..<targetHeight {
                            for dx in 0..<targetWidth {
                                var sum: UInt32 = 0
                                var cnt: UInt32 = 0
                                for ky in 0..<factor {
                                    let sy = dy * factor + ky
                                    if sy >= comp.height { continue }
                                    for kx in 0..<factor {
                                        let sx = dx * factor + kx
                                        if sx >= srcW { continue }
                                        sum &+= UInt32(src[sy * srcW + sx])
                                        cnt &+= 1
                                    }
                                }
                                out[dy * targetWidth + dx] = UInt8(cnt == 0 ? 0 : sum / cnt)
                            }
                        }
                    }
                }
            }

            return J2KComponent(
                index: comp.index, bitDepth: comp.bitDepth, signed: comp.signed,
                width: targetWidth, height: targetHeight,
                subsamplingX: comp.subsamplingX, subsamplingY: comp.subsamplingY,
                data: dst,
                sampleByteOrder: comp.sampleByteOrder)
        }

        return J2KImage(
            width: targetWidth, height: targetHeight,
            components: scaledComponents,
            colorSpace: image.colorSpace)
    }

    /// Nearest-neighbour upscale (only used when `options.upscale = true`).
    private static func upscaleByPowerOf2(
        image: J2KImage, targetWidth: Int, targetHeight: Int, factor: Int
    ) throws -> J2KImage {
        guard factor >= 1 else {
            throw J2KError.invalidParameter("upscale factor must be ≥ 1")
        }
        if factor == 1 { return image }

        let upscaled: [J2KComponent] = image.components.map { comp in
            let bytesPerSample = (comp.bitDepth + 7) / 8
            let dstBytes = targetWidth * targetHeight * bytesPerSample
            var dst = Data(count: dstBytes)
            comp.data.withUnsafeBytes { srcRaw in
                dst.withUnsafeMutableBytes { dstRaw in
                    if bytesPerSample == 2 {
                        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                        let out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                        for dy in 0..<targetHeight {
                            let sy = min(comp.height - 1, dy / factor)
                            for dx in 0..<targetWidth {
                                let sx = min(comp.width - 1, dx / factor)
                                let srcOff = (sy * comp.width + sx) * 2
                                let dstOff = (dy * targetWidth + dx) * 2
                                out[dstOff]     = src[srcOff]
                                out[dstOff + 1] = src[srcOff + 1]
                            }
                        }
                    } else {
                        let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                        let out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                        for dy in 0..<targetHeight {
                            let sy = min(comp.height - 1, dy / factor)
                            for dx in 0..<targetWidth {
                                let sx = min(comp.width - 1, dx / factor)
                                out[dy * targetWidth + dx] = src[sy * comp.width + sx]
                            }
                        }
                    }
                }
            }
            return J2KComponent(
                index: comp.index, bitDepth: comp.bitDepth, signed: comp.signed,
                width: targetWidth, height: targetHeight,
                subsamplingX: comp.subsamplingX, subsamplingY: comp.subsamplingY,
                data: dst,
                sampleByteOrder: comp.sampleByteOrder)
        }
        return J2KImage(width: targetWidth, height: targetHeight,
                        components: upscaled, colorSpace: image.colorSpace)
    }

    /// Decodes a JPEG 2000 image up to a specific quality layer.
    ///
    /// **v10.9.0** — quality-layer progressive decode. A multi-layer
    /// (LRCP) codestream distributes each code-block's coding passes
    /// across `qualityLayers` quality layers, layer 0 carrying the
    /// coarsest contribution. `decodeQuality(layer: L)` reconstructs
    /// the image from layers `0...L`, discarding the refinement in
    /// higher layers — a lower-bitrate, lower-quality preview.
    ///
    /// Decoding *every* layer (`layer == qualityLayers - 1`) is the
    /// same as `decode()`. On a single-layer codestream the only
    /// valid `layer` is 0 and the result equals `decode()`.
    ///
    /// `cumulative` must be `true` (decode layers `0...layer`) — the
    /// only image-meaningful semantics; `cumulative: false`
    /// (single-layer refinement delta) throws ``J2KError/notImplemented(_:)``.
    /// `components` selects an image-component subset.
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 data to decode.
    ///   - options: Quality decoding options.
    /// - Returns: The decoded image at the requested quality layer.
    /// - Throws: ``J2KError`` if decoding fails or an unsupported option is requested.
    public func decodeQuality(_ data: Data, options: J2KQualityDecodingOptions) async throws -> J2KImage {
        let metadata = try DecoderPipeline.peekMetadata(data)
        let layers = max(1, metadata.configuration.qualityLayers)
        try options.validate(maxLayers: layers, componentCount: metadata.componentCount)

        guard options.cumulative else {
            throw J2KError.notImplemented(
                "decodeQuality: non-cumulative (single-layer refinement delta) decode — "
                + "only cumulative quality decode (layers 0...layer) is supported")
        }

        // Decode layers 0...options.layer. On a single-layer codestream
        // this is a plain decode (maxQualityLayer is ignored).
        var image = try await decodeQualityLayers(data: data, maxLayer: options.layer, session: nil)

        // Component selection.
        if let comps = options.components {
            let selected = comps.compactMap { idx in
                image.components.first(where: { $0.index == idx })
            }
            guard selected.count == comps.count else {
                throw J2KError.invalidParameter(
                    "decodeQuality: requested components \(comps) not all present in the decoded image")
            }
            image = J2KImage(
                width: image.width, height: image.height,
                components: selected, colorSpace: image.colorSpace)
        }
        return image
    }

    // MARK: - Helper Methods

    /// Extracts a region from a decoded image.
    ///
    /// - Parameters:
    ///   - image: The full image.
    ///   - region: The region to extract.
    /// - Returns: A new image containing only the specified region.
    /// - Throws: ``J2KError`` if extraction fails.
    private func extractRegion(from image: J2KImage, region: J2KRegion) throws -> J2KImage {
        try region.validate(imageWidth: image.width, imageHeight: image.height)

        // Create new components with extracted data. Samples may be 1 or 2
        // bytes wide — medical fixtures are 16-bit, so the crop copies
        // `bytesPerSample` bytes per pixel rather than assuming 8-bit.
        let regionComponents = image.components.map { component in
            let bytesPerSample = (component.bitDepth + 7) / 8
            let srcStride = component.width
            let dstRowBytes = region.width * bytesPerSample
            var regionData = Data(count: region.height * dstRowBytes)

            component.data.withUnsafeBytes { srcRaw in
                regionData.withUnsafeMutableBytes { dstRaw in
                    guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                    for y in 0..<region.height {
                        let srcY = region.y + y
                        let srcOffset = (srcY * srcStride + region.x) * bytesPerSample
                        let dstOffset = y * dstRowBytes
                        memcpy(dst + dstOffset, src + srcOffset, dstRowBytes)
                    }
                }
            }

            return J2KComponent(
                index: component.index,
                bitDepth: component.bitDepth,
                signed: component.signed,
                width: region.width,
                height: region.height,
                subsamplingX: component.subsamplingX,
                subsamplingY: component.subsamplingY,
                data: regionData,
                sampleByteOrder: component.sampleByteOrder
            )
        }

        // Create new image with region dimensions
        return J2KImage(
            width: region.width,
            height: region.height,
            components: regionComponents,
            colorSpace: image.colorSpace
        )
    }
}

// MARK: - CustomStringConvertible

extension J2KPartialDecodingOptions: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []

        if let layer = maxLayer {
            parts.append("maxLayer: \(layer)")
        }

        if let level = maxResolutionLevel {
            parts.append("maxLevel: \(level)")
        }

        if let region = region {
            parts.append("region: \(region)")
        }

        if let comps = components {
            parts.append("components: \(comps)")
        }

        if earlyStop {
            parts.append("earlyStop: true")
        }

        return "J2KPartialDecodingOptions(\(parts.joined(separator: ", ")))"
    }
}

extension J2KROIDecodingOptions: CustomStringConvertible {
    public var description: String {
        var parts = ["region: \(region)"]

        if let layer = maxLayer {
            parts.append("maxLayer: \(layer)")
        }

        if let comps = components {
            parts.append("components: \(comps)")
        }

        parts.append("strategy: \(strategy)")

        return "J2KROIDecodingOptions(\(parts.joined(separator: ", ")))"
    }
}

extension J2KROIDecodingStrategy: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fullImageExtraction:
            return "fullImageExtraction"
        case .direct:
            return "direct"
        case .cached:
            return "cached"
        }
    }
}

extension J2KResolutionDecodingOptions: CustomStringConvertible {
    public var description: String {
        var parts = ["level: \(level)"]

        if let layer = maxLayer {
            parts.append("maxLayer: \(layer)")
        }

        if let comps = components {
            parts.append("components: \(comps)")
        }

        if upscale {
            parts.append("upscale: true")
        }

        return "J2KResolutionDecodingOptions(\(parts.joined(separator: ", ")))"
    }
}

extension J2KQualityDecodingOptions: CustomStringConvertible {
    public var description: String {
        var parts = ["layer: \(layer)"]

        if let comps = components {
            parts.append("components: \(comps)")
        }

        if cumulative {
            parts.append("cumulative: true")
        }

        return "J2KQualityDecodingOptions(\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Quality refinement session (issue #2382)

/// Decodes one codestream at increasing quality layers, reusing the tier-2 packet parse between refinements.
/// The first decode parses every packet once and keeps the per-block per-layer contributions; every later
/// `decode(layer:)` truncates those blocks and runs only tier-1 (EBCOT), dequantisation and the inverse DWT for
/// the requested layer. Region and resolution options combine with the layer. Cancellation is honoured between
/// stages and code-blocks.
public final class J2KQualityRefinementSession: @unchecked Sendable {
    public let data: Data
    let cache = J2KLayeredBlockCache()
    private let decoder = J2KDecoder()
    private let lock = NSLock()
    private var _history: [J2KPartialDecodeReport] = []

    public init(data: Data) {
        self.data = data
    }

    /// Cumulative decode of layers `0...layer` (nil = every layer) with optional region/resolution.
    public func decode(layer: Int?, region: J2KRegion? = nil, maxResolutionLevel: Int? = nil) async throws
        -> (image: J2KImage, report: J2KPartialDecodeReport) {
        let result = try await decoder.decodePartialReporting(
            data, options: J2KPartialDecodingOptions(maxLayer: layer, maxResolutionLevel: maxResolutionLevel, region: region), session: self)
        record(result.report)
        return result
    }

    /// Packet bytes per quality layer, available after the first decode (or after `index()`).
    public var bytesPerLayer: [Int] { cache.bytesPerLayer }

    private func record(_ report: J2KPartialDecodeReport) {
        lock.lock(); defer { lock.unlock() }
        _history.append(report)
    }

    public var history: [J2KPartialDecodeReport] {
        lock.lock(); defer { lock.unlock() }
        return _history
    }

    /// Runs only the tier-2 packet parse of every tile (no entropy decode) to learn the per-layer byte totals.
    public func index() async throws -> [Int] {
        if !cache.bytesPerLayer.isEmpty { return cache.bytesPerLayer }
        var pipeline = DecoderPipeline()
        pipeline.layeredBlockCache = cache
        try pipeline.indexQualityLayers(data)
        return cache.bytesPerLayer
    }
}
