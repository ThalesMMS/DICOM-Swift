//
// J2KEncoderPipeline.swift
// J2KSwift
//
// J2KEncoderPipeline.swift
// J2KSwift
//
// Encoder pipeline implementation for JPEG 2000 encoding.
//

import Foundation
import Synchronization

#if canImport(Dispatch)
import Dispatch
#endif

#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Encoding Stage

/// Represents the stages of the JPEG 2000 encoding pipeline.
public enum EncodingStage: String, Sendable, CaseIterable {
    /// Input validation and preprocessing.
    case preprocessing = "Preprocessing"

    /// Colour space transformation (RCT or ICT).
    case colorTransform = "Color Transform"

    /// Discrete wavelet transform (forward).
    case waveletTransform = "Wavelet Transform"

    /// Quantization of wavelet coefficients.
    case quantization = "Quantization"

    /// Entropy coding (EBCOT bit-plane coding).
    case entropyCoding = "Entropy Coding"

    /// Rate control and quality layer formation.
    case rateControl = "Rate Control"

    /// Codestream generation with markers.
    case codestreamGeneration = "Codestream Generation"
}

// MARK: - Progress Update

/// Reports progress during encoding.
public struct EncoderProgressUpdate: Sendable {
    /// The current encoding stage.
    public let stage: EncodingStage

    /// Progress within the current stage (0.0 to 1.0).
    public let progress: Double

    /// Overall encoding progress (0.0 to 1.0).
    public let overallProgress: Double
}

// MARK: - Parallel Tier-1 Scheduling

/// Coarse-grained chunk plan for Tier-1 worker execution.
///
/// Uses roughly twice the available parallelism to keep Apple Silicon cores
/// busy without paying the overhead of one task per code-block.
private struct Tier1ChunkPlan: Sendable {
    let workerCount: Int
    let chunkSize: Int

    init(totalBlocks: Int, maxConcurrency: Int, oversubscription: Int = 2) {
        let safeConcurrency = max(1, maxConcurrency)
        workerCount = max(1, min(totalBlocks, safeConcurrency * oversubscription))
        chunkSize = max(1, (totalBlocks + workerCount - 1) / workerCount)
    }

    @inline(__always)
    func range(for workerIndex: Int, totalBlocks: Int) -> Range<Int>? {
        let start = workerIndex * chunkSize
        guard start < totalBlocks else { return nil }
        return start..<min(start + chunkSize, totalBlocks)
    }
}

/// Ordered result buffer for parallel Tier-1 workers.
///
/// Safety invariant: each worker writes only to its own exclusive index range,
/// so there are no overlapping mutations even though the backing storage is
/// shared. This avoids locks and post-sort overhead in the hot path.
private final class Tier1ResultBuffer<T: Sendable>: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<T?>
    private let count: Int
    private let firstStoredError: Mutex<(any Error)?> = Mutex(nil)

    init(count: Int) {
        self.count = count
        storage = .allocate(capacity: count)
        storage.initialize(repeating: nil, count: count)
    }

    deinit {
        storage.deinitialize(count: count)
        storage.deallocate()
    }

    @inline(__always)
    func write(_ value: T, at index: Int) {
        storage[index] = value
    }

    func recordError(_ error: any Error) {
        firstStoredError.withLock { state in
            if state == nil {
                state = error
            }
        }
    }

    var firstError: (any Error)? {
        firstStoredError.withLock { $0 }
    }

    func materialize() throws -> [T] {
        if let error = firstError {
            throw error
        }

        var results: [T] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            guard let value = storage[index] else {
                throw J2KError.internalError("Missing Tier-1 result at index \(index)")
            }
            results.append(value)
        }
        return results
    }
}

/// General-purpose thread-safe collector retained for tests and non-hot paths.
final class ParallelResultCollector<T: Sendable>: Sendable {
    private let _results: Mutex<[T]>
    private let _firstError: Mutex<(any Error)?>

    init(capacity: Int = 0) {
        var initial: [T] = []
        initial.reserveCapacity(capacity)
        _results = Mutex(initial)
        _firstError = Mutex(nil)
    }

    func append(contentsOf elements: [T]) {
        _results.withLock { $0.append(contentsOf: elements) }
    }

    func recordError(_ error: any Error) {
        _firstError.withLock { state in
            if state == nil {
                state = error
            }
        }
    }

    var results: [T] {
        _results.withLock { Array($0) }
    }

    var firstError: (any Error)? {
        _firstError.withLock { $0 }
    }
}

// MARK: - Encoder Pipeline

/// Internal encoding pipeline that connects all JPEG 2000 encoding components.
///
/// The pipeline processes an image through these stages:
/// 1. Preprocessing — validate input, extract component data
/// 2. Colour Transform — apply RCT (lossless) or ICT (lossy)
/// 3. Wavelet Transform — multi-level 2D DWT decomposition
/// 4. Quantization — convert coefficients to integer indices
/// 5. Entropy Coding — EBCOT bit-plane coding per code block
/// 6. Rate Control — quality layer formation
/// 7. Codestream Generation — write JPEG 2000 markers and data
/// Per-packet R-D metadata for v5.37 PSNR-per-byte recovery.
struct PacketRDMetadata: Sendable {
    /// Resolution level of this packet (0 = LL after all decompositions,
    /// > 0 = detail bands at the corresponding level).
    let resolution: Int
    /// Component index.
    let component: Int
    /// Total packet bytes including the empty-flag/header bits and any
    /// raw block data. This is `packetEnd[i] - packetEnd[i-1]` (or
    /// `packetEnd[0] - tileDataOffset` for the first packet).
    let bytes: Int
    /// v5.37 constrained R-D selector:
    /// Sum over all code blocks in this packet of
    /// `block.coefficientSquaredSum × L2norm²[orient][dwtLevel]`.
    /// Approximates the MSE contribution this packet would make if
    /// dropped (missing detail leaves these synthesis-band coefficients
    /// at zero in the reconstruction). Used by
    /// `truncateByConstrainedRD` to rank highest-resolution precincts
    /// by expected PSNR-per-byte gain. 0.0 if not populated.
    let distortionContribution: Double
}

/// Encoded JPEG 2000 codestream paired with structural offsets that
/// describe where the codestream may be safely truncated at LRCP
/// packet boundaries (v5.34.0 strict bounded-rate mode).
///
/// Produced by `EncoderPipeline.encodeWithPacketIndex`. Consumed by
/// `EncoderPipeline.truncateAtPacketBoundary` and the public
/// `.constantBitrateStrict` mode.
struct EncodedCodestreamWithIndex: Sendable {
    /// The full codestream (untruncated).
    let data: Data
    /// Byte offset of the SOT marker (0xFF90) in the codestream.
    /// Used by truncation to rewrite the `Psot` field after slicing
    /// the tile data.
    let sotMarkerOffset: Int
    /// Byte offset of the tile data (just past the SOD marker) in
    /// the codestream. Tile data spans `[tileDataOffset, eocOffset)`.
    let tileDataOffset: Int
    /// Byte offsets in the codestream where each LRCP packet ends.
    /// Each offset is a legal truncation point: slicing the
    /// codestream at `packetEndOffsets[i]`, then appending the
    /// EOC marker, yields a valid (premature-EOC) codestream
    /// containing the first `i+1` packets.
    let packetEndOffsets: [Int]
    /// v5.37: per-packet R-D metadata for `truncateByRDOptimized`.
    /// `nil` when the producer didn't populate it (legacy paths).
    let packetMetadata: [PacketRDMetadata]?

    init(
        data: Data,
        sotMarkerOffset: Int,
        tileDataOffset: Int,
        packetEndOffsets: [Int],
        packetMetadata: [PacketRDMetadata]? = nil
    ) {
        self.data = data
        self.sotMarkerOffset = sotMarkerOffset
        self.tileDataOffset = tileDataOffset
        self.packetEndOffsets = packetEndOffsets
        self.packetMetadata = packetMetadata
    }
}

struct EncoderPipeline: Sendable {
    let config: J2KEncodingConfiguration

    /// Uses the default EBCOT coding style for the benchmark path.
    ///
    /// Selective bypass remains available in the codec, but stays disabled here
    /// because it regresses rate-distortion quality at the fixed comparison bitrate.
    /// For lossless, distortion tracking is disabled — all passes are always retained
    /// so the Int64 multiply/Double accumulation in each inner loop is dead work.
    private var standardEBCOTCodingOptions: CodingOptions {
        CodingOptions(trackDistortion: !config.lossless)
    }

    /// Returns an EBCOT pass cap for the current quality target.
    ///
    /// The very aggressive low-pass cap is now reserved for genuinely low-quality
    /// single-component preview encodes. Medium-quality grayscale and any explicit
    /// bitrate-constrained encode must keep a deeper pass stack so PCRD can make
    /// a meaningful rate-distortion decision.
    private func recommendedEBCOTPassLimit(componentCount: Int) -> Int? {
        guard !config.lossless else { return nil }

        // Multi-component and explicit-bitrate encodes rely on PCRD to spend the
        // full target budget. Do not pre-truncate their coding pass stacks.
        if componentCount > 1 {
            return nil
        }
        switch config.bitrateMode {
        case .constantBitrate, .variableBitrate:
            return nil
        case .constantQuality, .lossless:
            break
        case .fixedQstep, .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            // Fixed-qstep modes include every block; PCRD pass cap
            // doesn't apply. Returning nil disables the cap (same as
            // explicit bitrate modes).
            // .constantBitrateViaQstep delegates to .fixedQstep
            // internally per iteration of the outer search (see
            // J2KEncoder.encodeViaQstepSearch); this branch is only
            // taken if a caller invokes the pipeline directly with
            // .constantBitrateViaQstep — defensive coverage.
            return nil
        }

        // Preserve a shallow fast path only for truly low-quality grayscale
        // previews. Medium-quality constant-quality encodes (for example q=0.5
        // used by the benchmark path) need the full pass stack so PCRD can reach
        // a better rate-distortion point instead of being starved early.
        if config.quality < 0.20 {
            return 6
        }
        if config.quality < 0.35 {
            return 12
        }

        return nil
    }

    // MARK: - Main Encode

    /// Encodes an image through the full JPEG 2000 pipeline.
    ///
    /// - Parameters:
    ///   - image: The image to encode.
    ///   - progress: Optional progress callback.
    /// - Returns: The encoded JPEG 2000 codestream data.
    /// - Throws: ``J2KError`` if encoding fails.
    func encode(
        _ image: J2KImage,
        progress: ((EncoderProgressUpdate) -> Void)? = nil,
        tileOriginX: Int = 0, tileOriginY: Int = 0,
        resolutionLayerCount: Int = 1
    ) async throws -> Data {
        let profiling = ProcessInfo.processInfo.environment["J2K_PROFILE"] != nil
        var stageStart = CFAbsoluteTimeGetCurrent()

        // v6.3.0 F3 — preprocess sub-stage timing instrumentation.
        // Cost: ~4 NSLock acquires per encode. Always-on; data feeds
        // the F3 preprocess profile diagnostic.
        J2KPreprocessSubstageTimings.recordEncodeCall(
            pixels: image.width * image.height)

        let _validateT0 = CFAbsoluteTimeGetCurrent()
        try image.validate()
        J2KPreprocessSubstageTimings.recordImageValidate(
            CFAbsoluteTimeGetCurrent() - _validateT0)

        // v6-alpha3 step 3: optional diagnostic for multi-tile
        // origin propagation. Off by default; opt-in via env var
        // `J2K_HT_TILE_DEBUG_ORIGINS=1`.
        if EncoderPipeline._htTileDebugOrigins {
            let levels = config.decompositionLevels
            let originAware = (tileOriginX != 0 || tileOriginY != 0)
            print(String(format:
                "    HT_TILE_DEBUG: image=%dx%d origin=(%d,%d) levels=%d originAware=%@",
                image.width, image.height,
                tileOriginX, tileOriginY,
                levels, originAware ? "yes" : "no"))
        }

        // Stage 1: Preprocessing — extract component data as Int32 arrays
        reportProgress(progress, stage: .preprocessing, stageProgress: 0.0)
        var componentData = try extractComponentData(from: image)
        reportProgress(progress, stage: .preprocessing, stageProgress: 1.0)

        // DC level shift: for unsigned components, subtract 2^(bitDepth-1) to
        // center values around zero, as required by ISO 15444-1 Annex F.
        // v6.3.0 F3 — sub-stage timing.
        let _dcShiftT0 = CFAbsoluteTimeGetCurrent()
        for (compIdx, component) in image.components.enumerated() {
            if !component.signed {
                let dcOffset = Int32(1 << (component.bitDepth - 1))
                componentData[compIdx].withUnsafeMutableBufferPointer { buf in
                    for i in 0..<buf.count {
                        buf[i] &-= dcOffset
                    }
                }
            }
        }
        J2KPreprocessSubstageTimings.recordDCLevelShift(
            CFAbsoluteTimeGetCurrent() - _dcShiftT0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordPreprocessing(t - stageStart)
            if profiling { print("  PROFILE preprocess: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        // Stage 2: Colour Transform
        reportProgress(progress, stage: .colorTransform, stageProgress: 0.0)
        let (transformedData, transformedFloatData) = try applyColorTransform(componentData, image: image)
        // T.801 Annex J (#2331): after an array-based transformation the coded components carry the transformed
        // range (signed, wider), the SIZ/QCD/CAP describe those coded components and the CBD marker the originals.
        var codedImage = image
        var part2Markers: J2KPart2EncodingMarkers?
        if case .arrayBased(let matrix) = config.mctConfiguration.mode, config.mctConfiguration.perTileMCT.isEmpty {
            (codedImage, part2Markers) = try Self.part2CodedImage(image, matrix: matrix)
        }
        reportProgress(progress, stage: .colorTransform, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordColorTransform(t - stageStart)
            if profiling { print("  PROFILE colorXform: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        // Stage 3: Wavelet Transform
        reportProgress(progress, stage: .waveletTransform, stageProgress: 0.0)
        let (decompositions, actualDecompositionLevels) = try await applyWaveletTransform(
            transformedData, floatComponents: transformedFloatData,
            width: codedImage.width, height: codedImage.height,
            tileOriginX: tileOriginX, tileOriginY: tileOriginY
        )
        reportProgress(progress, stage: .waveletTransform, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordWaveletTransform(t - stageStart)
            if profiling { print("  PROFILE dwt: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        let adaptiveLossyStepSizes = buildAdaptiveLossyStepSizes(
            decompositions,
            image: codedImage,
            totalLevels: actualDecompositionLevels
        )

        // Stage 4: Quantization
        // Quantization is now fused into block extraction for both HTJ2K and EBCOT,
        // eliminating intermediate subband-sized Int32 allocations (~4MB for 1024×1024).
        // - HTJ2K: fused into block encoding
        // - EBCOT lossless (5/3): no quantization needed (integer DWT)
        // - EBCOT lossy (9/7): fused Float→Int32 quantization during block extraction
        reportProgress(progress, stage: .quantization, stageProgress: 0.0)
        let subandsForEntropy: [[SubbandInfo]] = decompositions
        reportProgress(progress, stage: .quantization, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordQuantization(t - stageStart)
            if profiling { print("  PROFILE quantize: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        // Stage 5: Entropy Coding
        reportProgress(progress, stage: .entropyCoding, stageProgress: 0.0)
        let codeBlocks = try await applyEntropyCoding(
            subandsForEntropy,
            image: codedImage,
            adaptiveStepSizes: adaptiveLossyStepSizes,
            totalLevels: actualDecompositionLevels
        )
        reportProgress(progress, stage: .entropyCoding, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordEntropyCoding(t - stageStart)
            if profiling { print("  PROFILE entropy: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        // Stage 6: Rate Control
        reportProgress(progress, stage: .rateControl, stageProgress: 0.0)
        // totalPixels is the number of spatial locations (W × H).
        // qualityToBitrate() returns bits-per-pixel scaled by component count,
        // so the PCRD budget correctly covers all components:
        //   targetBytes = bpp_per_sample × componentCount × totalPixels / 8.
        let layers = try applyRateControl(
            codeBlocks: codeBlocks, totalPixels: codedImage.width * codedImage.height,
            componentCount: codedImage.components.count
        )
        reportProgress(progress, stage: .rateControl, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordRateControl(t - stageStart)
            if profiling { print("  PROFILE rateCtrl: \(String(format: "%.4f", t - stageStart))s") }
            stageStart = t
        }

        // Stage 7: Codestream Generation
        reportProgress(progress, stage: .codestreamGeneration, stageProgress: 0.0)
        let codestream = try generateCodestream(
            image: codedImage,
            codeBlocks: codeBlocks,
            layers: layers,
            actualDecompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveLossyStepSizes,
            part2: part2Markers, resolutionLayerCount: resolutionLayerCount
        )
        reportProgress(progress, stage: .codestreamGeneration, stageProgress: 1.0)

        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordCodestreamGeneration(t - stageStart)
            if profiling { print("  PROFILE codestream: \(String(format: "%.4f", t - stageStart))s") }
        }

        return codestream
    }

    // MARK: - v6-alpha3 step 5: Native Multi-Tile Codestream Assembler

    /// Internal product of `runEncodeStagesForNativeAssembly`:
    /// the tile-data bytes (everything that goes between SOD and
    /// the next SOT or EOC) plus the parameters needed by the
    /// shared main header.
    struct NativeTilePartial: Sendable {
        let tileData: Data
        let actualLevels: Int
        let adaptiveStepSizes: [String: Double]
        let originX: Int
        let originY: Int
        let pixels: Int
        let encodeMs: Double
    }

    /// v6-alpha3 step 5 — native multi-tile codestream assembler.
    ///
    /// Emits ONE legal HTJ2K codestream with a single main header
    /// (SOC + SIZ + CAP/CPF + COD + QCD + COM) plus N tile-parts
    /// (SOT + SOD + tile-data) and a closing EOC. **No standalone
    /// per-tile codestreams are produced and no headers are
    /// stitched.** Each tile is encoded with its real
    /// image-coordinate origin via the parity-aware DWT path
    /// (v6-alpha3 step 1+2), so MR / PX / DX non-32-aligned tile
    /// origins no longer hit the wrap-and-stitch SIZ-vs-content
    /// inconsistency identified in step 4.
    ///
    /// The output's main-header SIZ carries:
    ///   - `Xsiz`/`Ysiz` = full image dimensions
    ///   - `XTsiz`/`YTsiz` = tile dimensions from the layout
    ///   - `XTOsiz`/`YTOsiz` = 0 (J2KSwift always uses tile grid
    ///     origin (0, 0))
    /// — exactly what an external parity-aware decoder needs to
    /// compute each tile's image-coordinate origin and apply the
    /// correct inverse-DWT lifting parity per tile.
    func encodeNativeMultiTile(
        _ image: J2KImage,
        layout: J2KTileLayout,
        // v6-alpha3 step 6A — geometry trace plumbing.
        geometryCollector: GeometryCollector? = nil
    ) async throws -> (codestream: Data, partials: [NativeTilePartial]) {
        precondition(layout.isMultiTile, "encodeNativeMultiTile: layout must be multi-tile")
        try image.validate()

        // 1) Run preprocess + DWT(parity-aware) + entropy + rate
        // control + generateTileData per tile, in parallel across
        // tiles. Each tile is its own JPEG 2000 tile-component:
        // pixels, DWT, entropy, and tile-data emit are all
        // independent of every other tile. Only the final main-
        // header + SOT/SOD/EOC assembly serialises (after all tiles
        // complete).
        //
        // v6-alpha3 step 9: restored the per-tile parallelism that
        // the v5.39 M4 wrap-and-stitch path had. Step 5 introduced
        // the native assembler with a sequential loop ("correctness
        // first"); the step-8 measurement showed multi-tile encode
        // was therefore single-threaded across tiles and SLOWER
        // than v5.38 single-tile encode. Step 9 uses
        // `withThrowingTaskGroup` to dispatch all tile encodes
        // concurrently. The block-level parallelism inside
        // `applyEntropyCodingHTJ2KFused` runs nested within each
        // tile task — Swift's cooperative thread pool absorbs the
        // oversubscription.
        let pipelineCopy = self
        let imageRef = image
        let layoutRef = layout
        let collectorRef = geometryCollector
        let unordered = try await withThrowingTaskGroup(
            of: (Int, NativeTilePartial).self
        ) { group in
            for k in 0..<layout.tileCount {
                let r = layoutRef.rect(forTile: k)
                // v10.25: `.high` priority — per-tile encode carries the
                // whole hot path (slice + DWT + entropy); default priority
                // spills to E-cores. Mirrors the v10.24.2 decode QoS fix.
                group.addTask(priority: .high) {
                    let subImage = try J2KTileImageSlicer.sliceTile(
                        from: imageRef, layout: layoutRef, tileIndex: k)
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let (tileData, levels, stepSizes) =
                        try await pipelineCopy.runEncodeStagesForNativeAssembly(
                            subImage,
                            tileOriginX: r.x, tileOriginY: r.y,
                            tileIndex: k,
                            geometryCollector: collectorRef)
                    let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                    return (k, NativeTilePartial(
                        tileData: tileData,
                        actualLevels: levels,
                        adaptiveStepSizes: stepSizes,
                        originX: r.x, originY: r.y,
                        pixels: r.w * r.h,
                        encodeMs: dt))
                }
            }
            var collected: [(Int, NativeTilePartial)] = []
            collected.reserveCapacity(layout.tileCount)
            for try await result in group {
                collected.append(result)
            }
            return collected
        }
        // Re-order by tile index so `partials[k]` is for tile k.
        // Tile order matters for the SOT/SOD assembly below and
        // for downstream callers that index into `partials`.
        var partialsBuf: [NativeTilePartial?] =
            Array(repeating: nil, count: layout.tileCount)
        for (k, p) in unordered { partialsBuf[k] = p }
        let partials: [NativeTilePartial] = partialsBuf.compactMap { $0 }
        precondition(partials.count == layout.tileCount,
                     "encodeNativeMultiTile: partials count mismatch")

        // 2) All tiles in an HTJ2K lossless 5/3 codestream share the
        // same COD/QCD because epsilons depend only on bit-depth +
        // guard bits + DWT level (content-independent). For the
        // first prototype, take the parameters from tile 0; if any
        // subsequent tile disagrees we fail loudly — that would
        // indicate an unexpected configuration drift.
        let levels = partials[0].actualLevels
        let stepSizes = partials[0].adaptiveStepSizes
        for (k, partial) in partials.enumerated().dropFirst() {
            guard partial.actualLevels == levels else {
                throw J2KError.invalidTileConfiguration(
                    "v6-alpha3 step 5 native assembler: tile \(k) has \(partial.actualLevels) " +
                    "decomposition levels but tile 0 has \(levels). Multi-tile encode requires " +
                    "all tiles to share the same decomposition depth.")
            }
        }

        // 3) Build the multi-tile codestream: main header, then
        // per-tile (SOT + SOD + data), then EOC.
        let totalTileBytes = partials.reduce(0) { $0 + $1.tileData.count }
        var writer = J2KBitWriter(capacity: totalTileBytes + 2048)

        // SOC — Start of Codestream.
        writer.writeMarker(J2KMarker.soc.rawValue)

        // SIZ — main header carries full image dims + tile grid.
        // (Differs from the existing private `writeSIZMarker` which
        // hard-codes single-tile dimensions; the multi-tile variant
        // is implemented inline here so the main header reflects
        // the actual tile grid.)
        try writeSIZMarkerMultiTile(&writer, image: image, layout: layout)

        // CAP/CPF — HTJ2K Part-15 capability markers.
        if config.useHTJ2K {
            try writeCAPMarker(&writer, qcd: qcdSegment(
                image: image, decompositionLevels: levels, adaptiveStepSizes: stepSizes))
            try writeCPFMarker(&writer)
        }

        // COD/QCD — coding style + quantisation, shared across all
        // tiles. Re-uses the existing private writers so bytes match
        // what single-tile encode produces.
        try writeCODMarker(&writer, image: image, decompositionLevels: levels)
        try writeQCDMarker(
            &writer, image: image,
            decompositionLevels: levels,
            adaptiveStepSizes: stepSizes)


        // 4) Per-tile: SOT + SOD + tile-data.
        if config.writeTLMMarker {
            try writeTLMMarker(
                &writer,
                tilePartLengths: partials.enumerated().map {
                    ($0, Self.tilePartHeaderLength + $1.tileData.count)
                })
        }
        for (k, partial) in partials.enumerated() {
            try writeSOTMarker(
                &writer, tileIndex: k, tilePartLength: partial.tileData.count)
            writer.writeMarker(J2KMarker.sod.rawValue)
            writer.writeBytes(partial.tileData)
        }

        // 5) EOC — End of Codestream.
        writer.writeMarker(J2KMarker.eoc.rawValue)

        return (writer.data, partials)
    }

    /// Run preprocess + colour transform + parity-aware DWT +
    /// entropy + rate control + tile-data generation for one tile.
    /// Returns just the tile-data bytes (no header markers,
    /// no SOT/SOD/EOC). The companion `actualLevels` and
    /// `adaptiveStepSizes` are returned so the caller can verify
    /// they match across all tiles before writing the shared main
    /// header.
    func runEncodeStagesForNativeAssembly(
        _ tileImage: J2KImage,
        tileOriginX: Int, tileOriginY: Int,
        // v6-alpha3 step 6A — geometry trace plumbing.
        tileIndex: Int = 0,
        geometryCollector: GeometryCollector? = nil
    ) async throws -> (tileData: Data, actualLevels: Int, adaptiveStepSizes: [String: Double]) {
        try tileImage.validate()

        // v6-alpha4 step 11 — per-stage timing for the multi-tile
        // path. The lock-protected `J2KEncodeTimings` accumulator
        // sums durations across concurrent tile tasks (step 9's
        // `withTaskGroup`), giving us total CPU time per stage
        // across all tiles. Diagnostic harnesses snapshot before
        // and after to derive per-stage CPU sums; comparing to
        // wall time identifies parallelism efficiency per stage.
        // The single-tile path has equivalent instrumentation in
        // `EncoderPipeline.encode(...)` since the original M3
        // diagnosis. Call cost is one NSLock acquire per stage
        // per tile (~µs); negligible vs encode wall.
        var stageStart = CFAbsoluteTimeGetCurrent()

        // Stage 1: Preprocessing — extract component data + DC shift.
        var componentData = try extractComponentData(from: tileImage)
        for (compIdx, component) in tileImage.components.enumerated() {
            if !component.signed {
                let dcOffset = Int32(1 << (component.bitDepth - 1))
                componentData[compIdx].withUnsafeMutableBufferPointer { buf in
                    for i in 0..<buf.count { buf[i] &-= dcOffset }
                }
            }
        }
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordPreprocessing(t - stageStart)
            stageStart = t
        }

        // Stage 2: Colour transform (no-op for single-component
        // medical greyscale — the medical corpus the v6 work
        // targets — but call it for correctness).
        let (transformedData, transformedFloatData) =
            try applyColorTransform(componentData, image: tileImage)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordColorTransform(t - stageStart)
            stageStart = t
        }

        // Stage 3: Parity-aware forward 5/3 DWT — uses the per-tile
        // image-coordinate origin so band layouts match what an
        // external multi-tile decoder will compute when reading the
        // stitched main header's tile grid.
        let (decompositions, actualLevels) = try await applyWaveletTransform(
            transformedData, floatComponents: transformedFloatData,
            width: tileImage.width, height: tileImage.height,
            tileOriginX: tileOriginX, tileOriginY: tileOriginY,
            isMultiTilePerTile: true)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordWaveletTransform(t - stageStart)
            stageStart = t
        }

        // Stage 4: Build adaptive step sizes (lossless reversible →
        // content-independent epsilons; same value per band across
        // all tiles).
        let adaptiveStepSizes = buildAdaptiveLossyStepSizes(
            decompositions, image: tileImage, totalLevels: actualLevels)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordQuantization(t - stageStart)
            stageStart = t
        }

        // Stage 5: Entropy coding (HT or EBCOT depending on config).
        let codeBlocks = try await applyEntropyCoding(
            decompositions, image: tileImage,
            adaptiveStepSizes: adaptiveStepSizes,
            totalLevels: actualLevels,
            tileOriginX: tileOriginX,
            tileOriginY: tileOriginY,
            tileIndex: tileIndex,
            geometryCollector: geometryCollector)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordEntropyCoding(t - stageStart)
            stageStart = t
        }

        // Stage 6: Rate control (lossless → all passes included).
        let layers = try applyRateControl(
            codeBlocks: codeBlocks,
            totalPixels: tileImage.width * tileImage.height,
            componentCount: tileImage.components.count)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordRateControl(t - stageStart)
            stageStart = t
        }

        // Stage 7: Tile-data generation — produces the bytes that
        // sit between SOD and the next SOT/EOC. Note: we do NOT
        // call `generateCodestream` here — that would emit a
        // standalone codestream with full headers. We want only
        // the tile-data portion.
        let (tileData, _) = try generateTileData(
            codeBlocks: codeBlocks, layers: layers,
            decompositionLevels: actualLevels,
            componentCount: tileImage.components.count,
            tileIndex: tileIndex,
            geometryCollector: geometryCollector)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordCodestreamGeneration(t - stageStart)
        }

        return (tileData, actualLevels, adaptiveStepSizes)
    }

    /// Multi-tile variant of `writeSIZMarker`: writes the SIZ for
    /// the FULL image (Xsiz/Ysiz) with a non-trivial tile grid
    /// (XTsiz/YTsiz from the layout). The existing
    /// `writeSIZMarker(_:image:)` hard-codes single-tile dimensions
    /// — this overload exists so the native multi-tile main header
    /// can carry both image and tile-grid dimensions in a single
    /// SIZ marker, the way the JPEG 2000 spec intends.
    private func writeSIZMarkerMultiTile(
        _ writer: inout J2KBitWriter,
        image: J2KImage, layout: J2KTileLayout
    ) throws {
        var segment = J2KBitWriter()
        let capabilities = J2KPart2Capabilities(configuration: config)
        segment.writeUInt16(capabilities.rsizValue)
        segment.writeUInt32(UInt32(image.width))           // Xsiz
        segment.writeUInt32(UInt32(image.height))          // Ysiz
        segment.writeUInt32(0)                             // XOsiz
        segment.writeUInt32(0)                             // YOsiz
        segment.writeUInt32(UInt32(layout.tileWidth))      // XTsiz
        segment.writeUInt32(UInt32(layout.tileHeight))     // YTsiz
        segment.writeUInt32(0)                             // XTOsiz
        segment.writeUInt32(0)                             // YTOsiz
        segment.writeUInt16(UInt16(image.components.count))
        for component in image.components {
            let ssiz = UInt8((component.signed ? 0x80 : 0x00) | ((component.bitDepth - 1) & 0x7F))
            segment.writeUInt8(ssiz)
            segment.writeUInt8(UInt8(component.subsamplingX))
            segment.writeUInt8(UInt8(component.subsamplingY))
        }
        writer.writeMarkerSegment(J2KMarker.siz.rawValue, segmentData: segment.data)
    }

    // MARK: - Packet-Indexed Encode (for v5.34.0 strict bounded-rate)

    /// Encodes an image and returns the codestream paired with the
    /// LRCP packet end offsets needed for safe post-encode truncation.
    ///
    /// Uses the same CPU pipeline as `encode(_:)` but routes through
    /// `generateCodestreamWithIndex` to capture packet boundaries.
    /// Cost over the plain `encode(_:)` path is negligible (one Int
    /// per packet, ~10s of packets typically).
    func encodeWithPacketIndex(
        _ image: J2KImage,
        progress: ((EncoderProgressUpdate) -> Void)? = nil
    ) async throws -> EncodedCodestreamWithIndex {
        try image.validate()

        // Stage 1: Preprocessing
        reportProgress(progress, stage: .preprocessing, stageProgress: 0.0)
        var componentData = try extractComponentData(from: image)
        reportProgress(progress, stage: .preprocessing, stageProgress: 1.0)

        for (compIdx, component) in image.components.enumerated() {
            if !component.signed {
                let dcOffset = Int32(1 << (component.bitDepth - 1))
                componentData[compIdx].withUnsafeMutableBufferPointer { buf in
                    for i in 0..<buf.count {
                        buf[i] &-= dcOffset
                    }
                }
            }
        }

        // Stage 2: Colour Transform
        reportProgress(progress, stage: .colorTransform, stageProgress: 0.0)
        let (transformedData, transformedFloatData) = try applyColorTransform(componentData, image: image)
        reportProgress(progress, stage: .colorTransform, stageProgress: 1.0)

        // Stage 3: Wavelet Transform
        reportProgress(progress, stage: .waveletTransform, stageProgress: 0.0)
        let (decompositions, actualDecompositionLevels) = try await applyWaveletTransform(
            transformedData, floatComponents: transformedFloatData,
            width: image.width, height: image.height
        )
        reportProgress(progress, stage: .waveletTransform, stageProgress: 1.0)

        let adaptiveLossyStepSizes = buildAdaptiveLossyStepSizes(
            decompositions, image: image, totalLevels: actualDecompositionLevels
        )

        // Stage 4: Quantization (fused into entropy stage)
        reportProgress(progress, stage: .quantization, stageProgress: 0.0)
        let subandsForEntropy: [[SubbandInfo]] = decompositions
        reportProgress(progress, stage: .quantization, stageProgress: 1.0)

        // Stage 5: Entropy Coding
        reportProgress(progress, stage: .entropyCoding, stageProgress: 0.0)
        let codeBlocks = try await applyEntropyCoding(
            subandsForEntropy, image: image,
            adaptiveStepSizes: adaptiveLossyStepSizes,
            totalLevels: actualDecompositionLevels
        )
        reportProgress(progress, stage: .entropyCoding, stageProgress: 1.0)

        // Stage 6: Rate Control
        reportProgress(progress, stage: .rateControl, stageProgress: 0.0)
        let layers = try applyRateControl(
            codeBlocks: codeBlocks, totalPixels: image.width * image.height,
            componentCount: image.components.count
        )
        reportProgress(progress, stage: .rateControl, stageProgress: 1.0)

        // Stage 7: Codestream Generation (with packet index)
        reportProgress(progress, stage: .codestreamGeneration, stageProgress: 0.0)
        let indexed = try generateCodestreamWithIndex(
            image: image,
            codeBlocks: codeBlocks,
            layers: layers,
            actualDecompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveLossyStepSizes
        )
        reportProgress(progress, stage: .codestreamGeneration, stageProgress: 1.0)

        return indexed
    }

    // MARK: - v5.35.0d Multi-Precinct Encode (single-layer, fine granularity)

    /// Generates a tile bitstream as a SINGLE LAYER but with multiple
    /// precincts per resolution — finer truncation granularity for
    /// strict bounded-rate mode (v5.35.0d). Unlike multi-layer (which
    /// is theoretically valid but unsupported in practice by OpenJPH
    /// / OpenJPEG HT decoders), precincts are Part 1 functionality
    /// fully supported by all mainstream decoders.
    ///
    /// Each (resolution, component, precinct) emits a separate packet.
    /// With small precinct sizes the highest-resolution band gets many
    /// small packets, giving the truncator many packet boundaries to
    /// land on.
    ///
    /// Returns the tile data along with byte offsets where each
    /// emitted packet ends.
    private func generateMultiPrecinctTileData(
        codeBlocks: [J2KCodeBlock],
        layers: [QualityLayer],
        decompositionLevels: Int,
        componentCount: Int,
        precinctExponents: [PrecinctExponents]
    ) throws -> (data: Data, packetEnds: [Int], packetMetadata: [PacketRDMetadata]) {
        precondition(precinctExponents.count == decompositionLevels + 1)
        let effectiveBlocks = applyLayerTruncation(codeBlocks: codeBlocks, layers: layers)

        let cbWidth = config.codeBlockSize.width
        let cbHeight = config.codeBlockSize.height

        // L2-norm² of 9/7 synthesis basis (ISO/IEC 15444-1 Annex E),
        // indexed [orient][dwtLevel] where orient: 0=LL, 1=HL, 2=LH,
        // 3=HH. Used to weight `coefficientSquaredSum` per code block
        // into a per-packet distortion estimate consumed by
        // `truncateByConstrainedRD`. Mirrors the table in
        // J2KRateControl.dwtNorms97 (private there); duplicated here
        // to keep the distortion accounting local to packet emission.
        let dwtNorms97Sq: [[Double]] = [
            [1.000000, 3.861225, 17.447329, 70.610409,
             282.609721, 1130.439284, 4521.755536, 18087.379121,
             72349.166884, 289397.609649],
            [4.088484, 15.912121, 69.806025, 289.136016,
             1157.836729, 4631.347316, 18525.387664, 74101.550656,
             296406.122624, 1185625.110000],
            [4.088484, 15.912121, 69.806025, 289.136016,
             1157.836729, 4631.347316, 18525.387664, 74101.550656,
             296406.122624, 1185625.110000],
            [4.326400, 14.938225, 69.006249, 295.392969,
             1205.895076, 4823.717409, 19294.598025, 77178.396100,
             308714.295641, 1234858.165564],
        ]
        func subbandWeight(orient: Int, dwtLevel: Int) -> Double {
            let lvl = max(0, min(dwtLevel, dwtNorms97Sq[0].count - 1))
            return dwtNorms97Sq[orient][lvl]
        }
        let maxResolutionLevel = decompositionLevels

        // Group blocks by (res, comp, subband, precinct).
        struct PrecinctKey: Hashable {
            let res: Int; let comp: Int; let subband: J2KSubband
            let py: Int; let px: Int
        }
        // Effective sub-band precinct size for the block's resolution.
        func subbandPrecinctSize(forRes res: Int) -> (w: Int, h: Int) {
            let pp = precinctExponents[res]
            // Per ISO 15444-1 A.6.1: r > 0 sub-band precinct = 2^(PPx-1) × 2^(PPy-1)
            // r == 0 (LL): precinct = 2^PPx × 2^PPy
            let wExp = res == 0 ? pp.widthExp : max(0, pp.widthExp - 1)
            let hExp = res == 0 ? pp.heightExp : max(0, pp.heightExp - 1)
            return (1 << wExp, 1 << hExp)
        }

        var blocksByPrecinct: [PrecinctKey: [J2KCodeBlock]] = [:]
        // Track band max coords per (res, comp, subband) so we know the precinct grid extent.
        struct BandKey: Hashable { let res: Int; let comp: Int; let subband: J2KSubband }
        var bandMaxX: [BandKey: Int] = [:]
        var bandMaxY: [BandKey: Int] = [:]
        for block in effectiveBlocks {
            let bk = BandKey(res: block.resolutionLevel, comp: block.componentIndex, subband: block.subband)
            bandMaxX[bk] = max(bandMaxX[bk] ?? 0, block.x + block.width - 1)
            bandMaxY[bk] = max(bandMaxY[bk] ?? 0, block.y + block.height - 1)
            let (pw, ph) = subbandPrecinctSize(forRes: block.resolutionLevel)
            let py = block.y / ph
            let px = block.x / pw
            let key = PrecinctKey(
                res: block.resolutionLevel, comp: block.componentIndex,
                subband: block.subband, py: py, px: px)
            blocksByPrecinct[key, default: []].append(block)
        }

        let numResolutions = decompositionLevels + 1
        let numComponents = componentCount

        // For each (res, comp), compute precinct grid extent
        // (numPrecinctsX × numPrecinctsY for the resolution level).
        // The grid is determined by the largest sub-band at that
        // resolution; for r > 0 all sub-bands HL/LH/HH share a
        // precinct grid of the same dimensions.
        func precinctGridExtent(res: Int, comp: Int) -> (nx: Int, ny: Int) {
            let subbands: [J2KSubband] = res == 0 ? [.ll] : [.hl, .lh, .hh]
            let (pw, ph) = subbandPrecinctSize(forRes: res)
            var nx = 0, ny = 0
            for sb in subbands {
                let bk = BandKey(res: res, comp: comp, subband: sb)
                if let mx = bandMaxX[bk], let my = bandMaxY[bk] {
                    nx = max(nx, mx / pw + 1)
                    ny = max(ny, my / ph + 1)
                }
            }
            return (max(1, nx), max(1, ny))
        }

        let totalBlockBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var tileWriter = J2KBitWriter(
            capacity: totalBlockBytes + totalBlockBytes / 8 + 1024)
        var packetEnds: [Int] = []
        var packetMetadata: [PacketRDMetadata] = []

        // LRCP: layer × resolution × component × precinct (raster order)
        for _ in 0..<max(1, layers.count) {
            for resLevel in 0..<numResolutions {
                for compIdx in 0..<numComponents {
                    let (nx, ny) = precinctGridExtent(res: resLevel, comp: compIdx)
                    let subbands: [J2KSubband] = resLevel == 0 ? [.ll] : [.hl, .lh, .hh]
                    let (pw, ph) = subbandPrecinctSize(forRes: resLevel)
                    for py in 0..<ny {
                        for px in 0..<nx {
                            let packetStart = tileWriter.count
                            // Gather blocks for this precinct, per sub-band.
                            // Remap each block to precinct-local coordinates
                            // so writePacket's tag-tree dimension calculation
                            // (max(block.x)/cbW + 1) reflects the PRECINCT's
                            // block grid, not the whole band's.
                            let precinctOriginX = px * pw
                            let precinctOriginY = py * ph
                            var bandBlocksList: [[J2KCodeBlock]] = []
                            // v5.37 constrained R-D: accumulate
                            // distortion across all blocks emitted
                            // into this packet, before remapping
                            // (coefficientSquaredSum is invariant
                            // under the precinct-local coordinate
                            // remap — only x/y change).
                            var packetDistortion: Double = 0.0
                            for sb in subbands {
                                let key = PrecinctKey(
                                    res: resLevel, comp: compIdx,
                                    subband: sb, py: py, px: px)
                                let blocks = blocksByPrecinct[key] ?? []
                                let dwtLevel: Int
                                let orient: Int
                                if resLevel == 0 {
                                    dwtLevel = max(0, maxResolutionLevel - 1)
                                    orient = 0
                                } else {
                                    dwtLevel = maxResolutionLevel - resLevel
                                    switch sb {
                                    case .ll: orient = 0
                                    case .hl: orient = 1
                                    case .lh: orient = 2
                                    case .hh: orient = 3
                                    }
                                }
                                let weight = subbandWeight(
                                    orient: orient, dwtLevel: dwtLevel)
                                for b in blocks {
                                    packetDistortion += b.coefficientSquaredSum * weight
                                }
                                let remapped = blocks.map { b -> J2KCodeBlock in
                                    J2KCodeBlock(
                                        index: b.index,
                                        x: b.x - precinctOriginX,
                                        y: b.y - precinctOriginY,
                                        width: b.width,
                                        height: b.height,
                                        subband: b.subband,
                                        componentIndex: b.componentIndex,
                                        resolutionLevel: b.resolutionLevel,
                                        data: b.data,
                                        passeCount: b.passeCount,
                                        zeroBitPlanes: b.zeroBitPlanes,
                                        passSegmentLengths: b.passSegmentLengths,
                                        cumulativePassBytes: b.cumulativePassBytes)
                                }
                                bandBlocksList.append(remapped)
                            }
                            try writePacket(
                                into: &tileWriter,
                                bandBlocks: bandBlocksList,
                                codeBlockWidth: cbWidth,
                                codeBlockHeight: cbHeight)
                            let packetEnd = tileWriter.count
                            packetEnds.append(packetEnd)
                            packetMetadata.append(PacketRDMetadata(
                                resolution: resLevel,
                                component: compIdx,
                                bytes: packetEnd - packetStart,
                                distortionContribution: packetDistortion))
                        }
                    }
                }
            }
        }

        return (tileWriter.data, packetEnds, packetMetadata)
    }

    /// v5.35.0d single-layer multi-precinct encode entry point.
    ///
    /// Reuses the encode pipeline up to entropy coding, then emits a
    /// single-layer codestream where each band is divided into
    /// precincts (Part 1 functionality, fully supported by mainstream
    /// decoders). Strict mode uses this for finer-than-band truncation
    /// granularity, replacing the multi-layer approach (which produced
    /// codestreams incompatible with OpenJPH and OpenJPEG's HT
    /// decoders).
    ///
    /// `precinctExponents`: per-resolution PPx/PPy values per ISO
    /// 15444-1 A.6.1. For r=0 the precinct covers a 2^PPx × 2^PPy
    /// region of LL; for r > 0 the sub-band precinct is half-size.
    /// Suggested: PPx=PPy=9 → 512 LL precinct, 256 sub-band precincts.
    func encodeMultiPrecinctWithPacketIndex(
        _ image: J2KImage,
        qstep: Double,
        precinctExponents: [PrecinctExponents],
        progress: ((EncoderProgressUpdate) -> Void)? = nil
    ) async throws -> EncodedCodestreamWithIndex {
        try image.validate()
        var iterConfig = config
        iterConfig.bitrateMode = .fixedQstep(qstep: qstep)
        iterConfig.lossless = false
        let inner = EncoderPipeline(config: iterConfig)

        // v9.5 — per-stage J2KEncodeTimings capture on the strict-bounded
        // bitrate path. Mirrors the instrumentation in `encode(_:)` and
        // `runEncodeStagesForNativeAssembly`; the corpus benchmark
        // tests reset/snapshot around `cpuEncoder.encode(...)` to
        // derive per-stage means. Pre-v9.5 this path recorded nothing,
        // so per-stage breakdown was identically zero.
        var stageStart = CFAbsoluteTimeGetCurrent()

        var componentData = try inner.extractComponentData(from: image)
        for (compIdx, component) in image.components.enumerated() where !component.signed {
            let dcOffset = Int32(1 << (component.bitDepth - 1))
            componentData[compIdx].withUnsafeMutableBufferPointer { buf in
                for i in 0..<buf.count { buf[i] &-= dcOffset }
            }
        }
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordPreprocessing(t - stageStart)
            stageStart = t
        }

        let (transformedData, transformedFloatData) =
            try inner.applyColorTransform(componentData, image: image)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordColorTransform(t - stageStart)
            stageStart = t
        }

        let (decompositions, actualDecompositionLevels) =
            try await inner.applyWaveletTransform(
                transformedData, floatComponents: transformedFloatData,
                width: image.width, height: image.height)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordWaveletTransform(t - stageStart)
            stageStart = t
        }

        let adaptiveLossyStepSizes = inner.buildAdaptiveLossyStepSizes(
            decompositions, image: image, totalLevels: actualDecompositionLevels)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordQuantization(t - stageStart)
            stageStart = t
        }

        let codeBlocks = try await inner.applyEntropyCoding(
            decompositions, image: image,
            adaptiveStepSizes: adaptiveLossyStepSizes,
            totalLevels: actualDecompositionLevels)
        do {
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordEntropyCoding(t - stageStart)
            stageStart = t
        }

        // Single-layer; the multi-precinct emission gives the truncation
        // granularity, so PCRD doesn't need to split layers.
        let layers = [QualityLayer(
            index: 0, targetRate: nil,
            codeBlockContributions: Dictionary(
                uniqueKeysWithValues: codeBlocks.map { ($0.index, $0.passeCount) }))]

        // Stage 7: codestream with precincts
        let totalBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var writer = J2KBitWriter(capacity: totalBytes + totalBytes / 8 + 2048)

        writer.writeMarker(J2KMarker.soc.rawValue)
        try writeSIZMarker(&writer, image: image)
        if config.useHTJ2K {
            try writeCAPMarker(&writer, qcd: qcdSegment(
                image: image, decompositionLevels: actualDecompositionLevels, adaptiveStepSizes: adaptiveLossyStepSizes))
            try writeCPFMarker(&writer)
        }
        // Pad / truncate precinctExponents to actualDecompositionLevels + 1
        let actualNumRes = actualDecompositionLevels + 1
        let pps: [PrecinctExponents]
        if precinctExponents.count == actualNumRes {
            pps = precinctExponents
        } else if precinctExponents.count > actualNumRes {
            pps = Array(precinctExponents.prefix(actualNumRes))
        } else {
            let pad = precinctExponents.last ?? PrecinctExponents(widthExp: 15, heightExp: 15)
            pps = precinctExponents + Array(repeating: pad, count: actualNumRes - precinctExponents.count)
        }
        try writeCODMarker(
            &writer, image: image,
            decompositionLevels: actualDecompositionLevels,
            numLayers: 1, precinctSizes: pps)
        try writeQCDMarker(
            &writer, image: image,
            decompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveLossyStepSizes)

        let (tileData, packetEndsInTile, packetMetadata) = try generateMultiPrecinctTileData(
            codeBlocks: codeBlocks, layers: layers,
            decompositionLevels: actualDecompositionLevels,
            componentCount: image.components.count,
            precinctExponents: pps)

        let sotMarkerOffset = writer.count
        try writeSOTMarker(
            &writer, tileIndex: 0, tilePartLength: tileData.count)
        writer.writeMarker(J2KMarker.sod.rawValue)
        let tileDataOffset = writer.count
        writer.writeBytes(tileData)
        writer.writeMarker(J2KMarker.eoc.rawValue)

        do {
            // v9.5 — codestream-assembly portion of this path includes
            // SOC/SIZ/CAP/CPF/COD/QCD/COM marker writes + per-precinct
            // packet emission + SOT/SOD/EOC framing. Rate-control isn't
            // applied on this path (single layer; truncation happens
            // post-encode on packet boundaries), so we attribute the
            // post-entropy wall to codestreamGeneration directly.
            let t = CFAbsoluteTimeGetCurrent()
            J2KEncodeTimings.recordCodestreamGeneration(t - stageStart)
        }

        let packetEndsInCodestream = packetEndsInTile.map { $0 + tileDataOffset }
        return EncodedCodestreamWithIndex(
            data: writer.data,
            sotMarkerOffset: sotMarkerOffset,
            tileDataOffset: tileDataOffset,
            packetEndOffsets: packetEndsInCodestream,
            packetMetadata: packetMetadata)
    }

    // MARK: - v5.35.0b Multi-Layer Encode Entry Point

    /// Encodes an image as a MULTI-LAYER LRCP codestream at a fixed
    /// quantization step, returning the codestream paired with per-
    /// layer-packet end offsets for finer-than-packet truncation in
    /// strict bounded-rate mode.
    ///
    /// PCRD-opt assigns each block a first-inclusion layer based on
    /// R-D slope, so layer 0 contains the highest-quality blocks,
    /// layer N-1 the lowest. Truncating the codestream at any layer
    /// boundary yields a valid prefix containing the K best layers.
    ///
    /// Use case: v5.35.0b strict bounded-rate. The strict-mode
    /// encoder calls this with `numLayers=16-32` so post-encode
    /// truncation has finer granularity (16-32× more truncation
    /// boundaries than v5.34's single-layer 6-packet boundary set).
    func encodeMultiLayerWithPacketIndex(
        _ image: J2KImage,
        qstep: Double,
        numLayers: Int,
        progress: ((EncoderProgressUpdate) -> Void)? = nil
    ) async throws -> EncodedCodestreamWithIndex {
        precondition(numLayers >= 1, "numLayers must be ≥ 1")
        try image.validate()

        // Stages 1-5: same as encodeWithPacketIndex but at fixed qstep
        var iterConfig = config
        iterConfig.bitrateMode = .fixedQstep(qstep: qstep)
        iterConfig.lossless = false
        let inner = EncoderPipeline(config: iterConfig)

        reportProgress(progress, stage: .preprocessing, stageProgress: 0.0)
        var componentData = try inner.extractComponentData(from: image)
        for (compIdx, component) in image.components.enumerated() where !component.signed {
            let dcOffset = Int32(1 << (component.bitDepth - 1))
            componentData[compIdx].withUnsafeMutableBufferPointer { buf in
                for i in 0..<buf.count { buf[i] &-= dcOffset }
            }
        }
        reportProgress(progress, stage: .preprocessing, stageProgress: 1.0)

        let (transformedData, transformedFloatData) =
            try inner.applyColorTransform(componentData, image: image)

        let (decompositions, actualDecompositionLevels) =
            try await inner.applyWaveletTransform(
                transformedData, floatComponents: transformedFloatData,
                width: image.width, height: image.height)

        let adaptiveLossyStepSizes = inner.buildAdaptiveLossyStepSizes(
            decompositions, image: image, totalLevels: actualDecompositionLevels)

        let codeBlocks = try await inner.applyEntropyCoding(
            decompositions, image: image,
            adaptiveStepSizes: adaptiveLossyStepSizes,
            totalLevels: actualDecompositionLevels)

        // Stage 6: multi-layer rate control. Build a synthetic
        // RateControlConfiguration that uses the actual encoded byte
        // budget as the layerCount-way split target. This drives PCRD
        // to distribute blocks across N layers by R-D slope.
        let totalEncodedBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        let totalPixels = image.width * image.height
        let totalBpp = Double(totalEncodedBytes * 8) / Double(totalPixels)
        let multiLayerRateConfig = RateControlConfiguration(
            mode: .targetBitrate(totalBpp),
            layerCount: numLayers,
            componentCount: image.components.count,
            useReversibleFilter: config.useReversibleFilter,
            passesPerBitPlane: config.useHTJ2K ? 2 : 3
        )
        let layers = try J2KRateControl(configuration: multiLayerRateConfig)
            .optimizeLayers(codeBlocks: codeBlocks, totalPixels: totalPixels)

        // Stage 7: multi-layer codestream emission
        let totalBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var writer = J2KBitWriter(capacity: totalBytes + totalBytes / 8 + 2048)

        writer.writeMarker(J2KMarker.soc.rawValue)
        try writeSIZMarker(&writer, image: image)
        if config.useHTJ2K {
            try writeCAPMarker(&writer, qcd: qcdSegment(
                image: image, decompositionLevels: actualDecompositionLevels, adaptiveStepSizes: adaptiveLossyStepSizes))
            try writeCPFMarker(&writer)
        }
        try writeCODMarker(
            &writer, image: image,
            decompositionLevels: actualDecompositionLevels,
            numLayers: numLayers)
        try writeQCDMarker(
            &writer, image: image,
            decompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveLossyStepSizes)

        let (tileData, packetEndsInTile) = try generateMultiLayerTileData(
            codeBlocks: codeBlocks, layers: layers,
            decompositionLevels: actualDecompositionLevels,
            componentCount: image.components.count)

        let sotMarkerOffset = writer.count
        try writeSOTMarker(
            &writer, tileIndex: 0, tilePartLength: tileData.count)
        writer.writeMarker(J2KMarker.sod.rawValue)
        let tileDataOffset = writer.count
        writer.writeBytes(tileData)
        writer.writeMarker(J2KMarker.eoc.rawValue)

        let packetEndsInCodestream = packetEndsInTile.map { $0 + tileDataOffset }
        return EncodedCodestreamWithIndex(
            data: writer.data,
            sotMarkerOffset: sotMarkerOffset,
            tileDataOffset: tileDataOffset,
            packetEndOffsets: packetEndsInCodestream)
    }

    /// v5.37 — R-D-aware packet selection under hard cap.
    ///
    /// Replaces LRCP-stream truncation (which drops the highest-
    /// resolution packets first because they appear last in the LRCP
    /// stream) with greedy R-D selection: rank packets by
    /// distortion-saved-per-byte using the L2 norm of each
    /// resolution's wavelet synthesis basis function (ISO 15444-1
    /// Annex E). High-resolution detail bands have synthesis L2 norms
    /// ~1000× larger than LL at deep decomposition, so a coefficient
    /// at res 5 contributes vastly more PSNR than one at res 0 — but
    /// LRCP-truncation drops them first.
    ///
    /// Algorithm:
    ///   1. Always include LL (resolution 0) packets — they're tiny
    ///      and the wavelet inverse needs the LL DC term to produce
    ///      meaningful output.
    ///   2. Rank remaining packets by L2-norm² / packet_bytes
    ///      (descending = best R-D first).
    ///   3. Greedy include in rank order until the byte cap is hit.
    ///   4. Re-emit codestream: for each packet position, emit the
    ///      original packet bytes (if selected) or a 1-byte empty
    ///      packet (if not selected). The decoder reads packets in
    ///      LRCP order; empty packets contribute nothing.
    ///
    /// Returns the rewritten codestream with `Psot` updated, the
    /// truncated tile data, and EOC appended. Output is byte-bounded
    /// ≤ `targetBytes`.
    ///
    /// Falls back to `truncateAtPacketBoundary` if the codestream
    /// has no `packetMetadata` (e.g., produced by the legacy
    /// single-precinct path).
    static func truncateByRDOptimized(
        _ encoded: EncodedCodestreamWithIndex,
        targetBytes: Int
    ) -> Data {
        guard let metadata = encoded.packetMetadata,
              metadata.count == encoded.packetEndOffsets.count
        else {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }
        if encoded.data.count <= targetBytes {
            return encoded.data
        }

        // L2-norm² weights from the 9/7 synthesis-basis L2 norms at
        // deep decomposition (level 1 = highest detail, level 5 = LL).
        // Resolution 0 is LL after all decompositions (smallest); the
        // detail bands at increasing resolution use successively
        // higher levels, so 9/7 norms scale as ~4× per resolution
        // step. These weights are the AVERAGE of HL/LH/HH norms² at
        // each resolution's level, capped to a small table.
        // Intent: rank packets by per-byte PSNR contribution, not
        // exact PCRD-opt accuracy.
        let resolutionWeights: [Double] = [
            1.0,         // res 0 LL (essential — handled separately)
            15.5,        // res 1 detail (level 5 norms ~ 3.99)
            69.4,        // res 2 (level 4 ~ 8.36)
            290.6,       // res 3 (level 3 ~ 17.0)
            1175.0,      // res 4 (level 2 ~ 34.0)
            4715.0,      // res 5 (level 1 ~ 68.7)
            18800.0,     // (level 0 ~ 137 — clamp)
        ]

        let headerBytes = encoded.tileDataOffset
        let eocBytes = 2
        let availableForPackets = targetBytes - headerBytes - eocBytes
        // If the cap doesn't even fit the header + EOC + 1 byte per
        // empty packet, fall back to original truncation.
        let minViable = metadata.count
        if availableForPackets < minViable {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }

        // Always include LL (res 0); compute baseline cost as if
        // every other packet is empty (1 byte each).
        var includedSet = Set<Int>()
        var usedBytes = 0
        for (i, pm) in metadata.enumerated() where pm.resolution == 0 {
            includedSet.insert(i)
            usedBytes += pm.bytes
        }
        let nonLLCount = metadata.count - includedSet.count
        var totalBytes = usedBytes + nonLLCount  // 1 byte per empty packet

        // Rank non-LL packets by R-D slope descending. Tie-break by
        // resolution descending (prefer higher detail), then by
        // smaller bytes (cheaper to include).
        struct RankEntry { let idx: Int; let slope: Double; let resolution: Int; let bytes: Int }
        var ranked: [RankEntry] = []
        ranked.reserveCapacity(nonLLCount)
        for (i, pm) in metadata.enumerated() where pm.resolution > 0 {
            let weightIdx = min(pm.resolution, resolutionWeights.count - 1)
            let weight = resolutionWeights[weightIdx]
            let slope = pm.bytes > 0 ? weight / Double(pm.bytes) : weight
            ranked.append(RankEntry(idx: i, slope: slope, resolution: pm.resolution, bytes: pm.bytes))
        }
        ranked.sort { lhs, rhs in
            if lhs.slope != rhs.slope { return lhs.slope > rhs.slope }
            if lhs.resolution != rhs.resolution { return lhs.resolution > rhs.resolution }
            return lhs.bytes < rhs.bytes
        }

        // Greedy include each packet if its (bytes - 1) net cost fits.
        for entry in ranked {
            let netCost = entry.bytes - 1  // include cost minus the 1-byte empty replacement
            if totalBytes + netCost <= availableForPackets {
                includedSet.insert(entry.idx)
                totalBytes += netCost
            }
        }

        // Build the new tile-data byte stream: for each packet, emit
        // its original bytes (if included) or a single 0x00 (empty
        // packet — the "0" empty flag + byte alignment).
        var newTile = [UInt8]()
        newTile.reserveCapacity(totalBytes)
        var prev = encoded.tileDataOffset
        for (i, end) in encoded.packetEndOffsets.enumerated() {
            if includedSet.contains(i) {
                newTile.append(contentsOf: encoded.data[prev..<end])
            } else {
                newTile.append(0x00)
            }
            prev = end
        }

        // Reassemble: header (up to but not including original tile data)
        //          + new tile data
        //          + EOC (FFD9)
        // Then rewrite Psot in the SOT marker.
        let newPsot = UInt32(2 + 2 + 8 + 2 + newTile.count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerBytes + newTile.count + eocBytes)
        bytes.append(contentsOf: encoded.data.prefix(headerBytes))
        bytes.append(contentsOf: newTile)

        // Patch Psot at sotMarkerOffset + 6 (see truncateAtPacketBoundary).
        let psotOffset = encoded.sotMarkerOffset + 6
        bytes[psotOffset]     = UInt8((newPsot >> 24) & 0xFF)
        bytes[psotOffset + 1] = UInt8((newPsot >> 16) & 0xFF)
        bytes[psotOffset + 2] = UInt8((newPsot >> 8) & 0xFF)
        bytes[psotOffset + 3] = UInt8(newPsot & 0xFF)

        bytes.append(0xFF)
        bytes.append(0xD9)
        return Data(bytes)
    }

    /// v5.37 PSNR-per-byte recovery — constrained coefficient-sum-based
    /// R-D selection that respects the JPEG 2000 wavelet reconstruction
    /// dependency chain.
    ///
    /// The naive R-D selector (`truncateByRDOptimized`) ranks all
    /// non-LL packets by per-byte L2-norm² weight and greedily
    /// includes them. On real medical fixtures it regressed PSNR by
    /// 1-2 dB because dropping intermediate-resolution packets
    /// (e.g. retaining only res-5 detail to maximize per-byte slope)
    /// breaks the hierarchical inverse-DWT — each level's synthesis
    /// consumes the previous LL plus that level's detail bands.
    ///
    /// This method enforces the dependency floor explicitly:
    ///   1. **Always** include all packets at resolution
    ///      `< maxResolution` (LL + every intermediate detail level).
    ///      These form the LRCP-prefix dependency floor; dropping any
    ///      breaks downstream synthesis.
    ///   2. **Greedily** select highest-resolution packets ranked by
    ///      `distortionContribution / bytes` (the actual coefficient-
    ///      sum × subband L2-norm² weight populated by
    ///      `generateMultiPrecinctTileData`). Tie-break by smaller
    ///      bytes (cheaper to include).
    ///   3. Unselected highest-resolution packets are emitted as
    ///      1-byte empty packets, preserving LRCP order so the
    ///      decoder reads through them without parsing failure.
    ///
    /// Falls back to `truncateAtPacketBoundary` when:
    ///   - No metadata is present (legacy codestreams).
    ///   - Distortion contributions are all zero (suggests an
    ///     unpopulated path; LRCP-prefix is safer than zero-ranked
    ///     greedy selection).
    ///   - The mandatory floor (LL + intermediate-res packets +
    ///     1-byte stubs for highest-res) already exceeds the cap;
    ///     the LRCP-prefix truncator is the only viable strategy
    ///     when the floor doesn't fit.
    ///
    /// Output is byte-bounded ≤ `targetBytes`. Same Psot rewrite +
    /// EOC append as `truncateAtPacketBoundary`.
    static func truncateByConstrainedRD(
        _ encoded: EncodedCodestreamWithIndex,
        targetBytes: Int
    ) -> Data {
        guard let metadata = encoded.packetMetadata,
              metadata.count == encoded.packetEndOffsets.count
        else {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }
        if encoded.data.count <= targetBytes {
            return encoded.data
        }
        guard let maxRes = metadata.map(\.resolution).max(), maxRes > 0 else {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }

        let headerBytes = encoded.tileDataOffset
        let eocBytes = 2
        let availableForPackets = targetBytes - headerBytes - eocBytes
        if availableForPackets < metadata.count {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }

        // Floor: always include every packet at resolution < maxRes.
        // Highest-resolution packets start as 1-byte empty stubs, then
        // upgrade to full bytes via greedy R-D selection if budget
        // permits.
        var includedSet = Set<Int>()
        var floorBytes = 0
        var topResIdx: [Int] = []
        topResIdx.reserveCapacity(metadata.count)
        for (i, pm) in metadata.enumerated() {
            if pm.resolution < maxRes {
                includedSet.insert(i)
                floorBytes += pm.bytes
            } else {
                topResIdx.append(i)
            }
        }
        // Each top-res packet costs at least 1 byte (the empty stub).
        var totalBytes = floorBytes + topResIdx.count
        if totalBytes > availableForPackets {
            // Even the dependency floor + 1-byte stubs overflows. Fall
            // back to LRCP-prefix truncation, which will at least
            // honour the cap by dropping later packets entirely.
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }

        // Verify the distortion field has been populated. If every
        // top-res packet has 0 distortion, R-D ranking is meaningless
        // and we should defer to LRCP-prefix.
        let totalTopDistortion = topResIdx.reduce(0.0) {
            $0 + metadata[$1].distortionContribution
        }
        if totalTopDistortion <= 0 {
            return truncateAtPacketBoundary(encoded, targetBytes: targetBytes)
        }

        struct TopRank { let idx: Int; let slope: Double; let bytes: Int }
        var ranked: [TopRank] = []
        ranked.reserveCapacity(topResIdx.count)
        for i in topResIdx {
            let pm = metadata[i]
            // Per-byte distortion saved by including this packet vs
            // emitting a 1-byte stub. Use (bytes - 1) as the marginal
            // cost of upgrading from stub to full packet.
            let netCost = max(1, pm.bytes - 1)
            let slope = pm.distortionContribution / Double(netCost)
            ranked.append(TopRank(idx: i, slope: slope, bytes: pm.bytes))
        }
        ranked.sort { lhs, rhs in
            if lhs.slope != rhs.slope { return lhs.slope > rhs.slope }
            return lhs.bytes < rhs.bytes
        }

        for entry in ranked {
            // Upgrading a stub (1 byte) to full = (bytes - 1) extra.
            let netCost = entry.bytes - 1
            if totalBytes + netCost <= availableForPackets {
                includedSet.insert(entry.idx)
                totalBytes += netCost
            }
        }

        // Build new tile data. For each packet (in original LRCP
        // order): emit full bytes if included, else a 1-byte 0x00
        // empty packet.
        var newTile = [UInt8]()
        newTile.reserveCapacity(totalBytes)
        var prev = encoded.tileDataOffset
        for (i, end) in encoded.packetEndOffsets.enumerated() {
            if includedSet.contains(i) {
                newTile.append(contentsOf: encoded.data[prev..<end])
            } else {
                newTile.append(0x00)
            }
            prev = end
        }

        let newPsot = UInt32(2 + 2 + 8 + 2 + newTile.count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerBytes + newTile.count + eocBytes)
        bytes.append(contentsOf: encoded.data.prefix(headerBytes))
        bytes.append(contentsOf: newTile)

        let psotOffset = encoded.sotMarkerOffset + 6
        bytes[psotOffset]     = UInt8((newPsot >> 24) & 0xFF)
        bytes[psotOffset + 1] = UInt8((newPsot >> 16) & 0xFF)
        bytes[psotOffset + 2] = UInt8((newPsot >> 8) & 0xFF)
        bytes[psotOffset + 3] = UInt8(newPsot & 0xFF)

        bytes.append(0xFF)
        bytes.append(0xD9)
        return Data(bytes)
    }

    /// Truncates a packet-indexed codestream at the largest LRCP
    /// packet boundary that still fits within `targetBytes`.
    ///
    /// JPEG 2000 codestreams are progressively decodable: at any
    /// packet boundary, all preceding packets form a valid prefix.
    /// Decoders treat the missing trailing packets as zero-data
    /// (per ISO/IEC 15444-1 Annex B). Tier-1 decoders (OpenJPH,
    /// Kakadu, J2KSwift) handle premature-EOC by filling the
    /// missing code blocks with zero coefficients.
    ///
    /// The returned codestream:
    ///   - Is byte-exact ≤ `targetBytes`.
    ///   - Has the SOT marker's `Psot` field rewritten to reflect
    ///     the truncated tile-part length.
    ///   - Ends with the EOC marker.
    ///
    /// If `targetBytes` is too small to fit even the codestream
    /// header (SOC..SOD) plus the smallest possible tile (zero
    /// packets) plus EOC, returns the full codestream unchanged
    /// (caller has set an unachievable cap).
    static func truncateAtPacketBoundary(
        _ encoded: EncodedCodestreamWithIndex,
        targetBytes: Int
    ) -> Data {
        // Already within budget — no truncation needed.
        if encoded.data.count <= targetBytes {
            return encoded.data
        }

        // EOC is 2 bytes. We need (truncatedTileEnd + 2) ≤ targetBytes,
        // where truncatedTileEnd is one of `packetEndOffsets` or
        // `tileDataOffset` (zero packets).
        let eocLength = 2
        let maxTileEnd = targetBytes - eocLength
        if maxTileEnd < encoded.tileDataOffset {
            // Not enough room for even the header + EOC. Cannot
            // produce a valid truncated codestream — return original
            // (caller's cap is unachievable).
            return encoded.data
        }

        // Find largest packet-end offset ≤ maxTileEnd. If none,
        // truncate to zero packets (tileDataOffset).
        var chosenEnd = encoded.tileDataOffset
        for offset in encoded.packetEndOffsets {
            if offset <= maxTileEnd {
                chosenEnd = offset
            } else {
                break
            }
        }

        // Build truncated codestream: header bytes + truncated tile
        // bytes + EOC. Then rewrite Psot in the SOT marker.
        let newTilePartLength = chosenEnd - encoded.tileDataOffset
        // Psot = 2 (SOT marker) + 2 (Lsot) + 8 (segment) + 2 (SOD) + tile data
        let newPsot = UInt32(2 + 2 + 8 + 2 + newTilePartLength)

        var bytes = [UInt8]()
        bytes.reserveCapacity(chosenEnd + eocLength)
        bytes.append(contentsOf: encoded.data.prefix(chosenEnd))

        // Rewrite Psot. SOT marker segment layout per ISO 15444-1
        // Annex A.4.2:
        //   offset+0..2 : SOT marker (0xFF90)
        //   offset+2..4 : Lsot — length of segment, including itself
        //                 (always 10 for a single-tile encode)
        //   offset+4..6 : Isot — tile index
        //   offset+6..10: Psot — length of tile-part (4 bytes BE)
        //   offset+10   : TPsot — tile-part index
        //   offset+11   : TNsot — number of tile-parts
        let psotOffset = encoded.sotMarkerOffset + 6
        bytes[psotOffset]     = UInt8((newPsot >> 24) & 0xFF)
        bytes[psotOffset + 1] = UInt8((newPsot >> 16) & 0xFF)
        bytes[psotOffset + 2] = UInt8((newPsot >> 8) & 0xFF)
        bytes[psotOffset + 3] = UInt8(newPsot & 0xFF)

        // EOC marker: 0xFFD9
        bytes.append(0xFF)
        bytes.append(0xD9)

        return Data(bytes)
    }

    // MARK: - GPU-Accelerated Encode

    // MARK: - Stage 1: Preprocessing

    /// Extracts component data from the image as arrays of Int32 values.
    private func extractComponentData(from image: J2KImage) throws -> [[Int32]] {
        var result: [[Int32]] = []

        for component in image.components {
            let pixelCount = component.width * component.height
            var pixels = [Int32](repeating: 0, count: pixelCount)

            let data = component.data
            if component.bitDepth <= 8 {
                // v6.3.0 F3 — sub-stage timing instrumentation.
                let _t0 = CFAbsoluteTimeGetCurrent()
                let byteCount = min(data.count, pixelCount)
                data.withUnsafeBytes { buffer in
                    guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    for i in 0..<byteCount {
                        if component.signed {
                            pixels[i] = Int32(Int8(bitPattern: ptr[i]))
                        } else {
                            pixels[i] = Int32(ptr[i])
                        }
                    }
                }
                J2KPreprocessSubstageTimings.recordExtractComponentData8(
                    CFAbsoluteTimeGetCurrent() - _t0)
            } else if component.bitDepth <= 16 {
                // v6.3.0 F3 — sub-stage timing instrumentation.
                let _t0 = CFAbsoluteTimeGetCurrent()
                let sampleCount = min(data.count / 2, pixelCount)
                // Prefer the caller's explicit byte-order hint when available.
                // Auto-inference via `j2kInfer16BitByteOrder` is reliable for
                // ≤ 14-bit content but can tie at full 16-bit (both readings
                // fit UInt16), producing hard-to-debug round-trip failures on
                // large 16-bit images. Keep inference as a fallback so legacy
                // callers without a hint still work.
                let byteOrder: J2KSampleByteOrder
                switch component.sampleByteOrder {
                case .littleEndian: byteOrder = .littleEndian
                case .bigEndian:    byteOrder = .bigEndian
                case nil:
                    byteOrder = j2kInfer16BitByteOrder(
                        in: data,
                        sampleCount: sampleCount,
                        bitDepth: component.bitDepth,
                        signed: component.signed
                    )
                }
                // v5.38 M7: hoist the (byteOrder × signedness) branches
                // out of the per-pixel hot loop. Both are constant for a
                // single component; specialising the loop to one of 4
                // closed-form bodies lets LLVM auto-vectorise the
                // UInt16 widening into NEON Int32 stores. For 12 MP DX
                // this loop runs 12M iterations per encode.
                data.withUnsafeBytes { buffer in
                    guard let srcPtr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    pixels.withUnsafeMutableBufferPointer { dstBuf in
                        let dst = dstBuf.baseAddress!
                        switch (byteOrder, component.signed) {
                        case (.bigEndian, false):
                            for i in 0..<sampleCount {
                                let v = (UInt16(srcPtr[i &* 2]) << 8) | UInt16(srcPtr[i &* 2 &+ 1])
                                dst[i] = Int32(v)
                            }
                        case (.bigEndian, true):
                            for i in 0..<sampleCount {
                                let v = (UInt16(srcPtr[i &* 2]) << 8) | UInt16(srcPtr[i &* 2 &+ 1])
                                dst[i] = Int32(Int16(bitPattern: v))
                            }
                        case (.littleEndian, false):
                            for i in 0..<sampleCount {
                                let v = UInt16(srcPtr[i &* 2]) | (UInt16(srcPtr[i &* 2 &+ 1]) << 8)
                                dst[i] = Int32(v)
                            }
                        case (.littleEndian, true):
                            for i in 0..<sampleCount {
                                let v = UInt16(srcPtr[i &* 2]) | (UInt16(srcPtr[i &* 2 &+ 1]) << 8)
                                dst[i] = Int32(Int16(bitPattern: v))
                            }
                        }
                    }
                }
                J2KPreprocessSubstageTimings.recordExtractComponentData16(
                    CFAbsoluteTimeGetCurrent() - _t0)
            }

            result.append(pixels)
        }

        return result
    }

    // MARK: - Stage 2: Colour Transform

    /// Applies colour space transformation (RCT/ICT or Part 2 MCT).
    ///
    /// - Parameters:
    ///   - components: The component data.
    ///   - image: The source image.
    ///   - tileIndex: The tile index (default: 0 for non-tiled images).
    /// - Returns: Transformed component data as Int32 and optionally as Double (for ICT lossy path).
    private func applyColorTransform(
        _ components: [[Int32]], image: J2KImage, tileIndex: Int = 0
    ) throws -> ([[Int32]], [[Float]]?) {
        // Check for per-tile MCT override first
        if let tileMatrix = config.mctConfiguration.perTileMCT[tileIndex] {
            return (try applyArrayBasedMCT(components, matrix: tileMatrix, image: image), nil)
        }

        // Check if MCT is enabled in configuration
        switch config.mctConfiguration.mode {
        case .disabled:
            // Use standard Part 1 colour transform
            return try applyStandardColorTransform(components, image: image)

        case .arrayBased(let matrix):
            // Use array-based MCT with specified matrix
            return (try applyArrayBasedMCT(components, matrix: matrix, image: image), nil)

        case .dependency(let depConfig):
            // Use dependency-based MCT
            return (try applyDependencyMCT(components, configuration: depConfig, image: image), nil)

        case let .adaptive(candidates, criteria):
            // Select best matrix adaptively based on criteria
            return try applyAdaptiveMCT(
                components, candidates: candidates,
                criteria: criteria, image: image,
                tileIndex: tileIndex)
        }
    }

    /// Applies standard Part 1 colour transform (RCT/ICT).
    private func applyStandardColorTransform(
        _ components: [[Int32]], image: J2KImage
    ) throws -> ([[Int32]], [[Float]]?) {
        // Colour transform only applies to 3+ component images
        guard components.count >= 3 else { return (components, nil) }

        let mode: J2KColorTransformMode = config.useReversibleFilter ? .reversible : .irreversible
        let ctConfig = J2KColorTransformConfiguration(mode: mode)
        let transform = J2KColorTransform(configuration: ctConfig)

        let y: [Int32]
        let cb: [Int32]
        let cr: [Int32]
        var floatResult: [[Float]]? = nil

        if config.useReversibleFilter {
            // Use RCT (integer-based, perfectly reversible)
            (y, cb, cr) = try transform.forwardRCT(
                red: components[0], green: components[1], blue: components[2]
            )
        } else {
            // Float32 ICT: 2× bandwidth vs Double, sufficient for ≤16-bit images.
            // Eliminates the Int32→Double→Int32 round-trip by computing directly in Float.
            #if canImport(Accelerate)
            let count = components[0].count
            let n = vDSP_Length(count)
            var redF   = [Float](repeating: 0, count: count)
            var greenF = [Float](repeating: 0, count: count)
            var blueF  = [Float](repeating: 0, count: count)
            components[0].withUnsafeBufferPointer { vDSP_vflt32($0.baseAddress!, 1, &redF,   1, n) }
            components[1].withUnsafeBufferPointer { vDSP_vflt32($0.baseAddress!, 1, &greenF, 1, n) }
            components[2].withUnsafeBufferPointer { vDSP_vflt32($0.baseAddress!, 1, &blueF,  1, n) }

            var yF  = [Float](repeating: 0, count: count)
            var cbF = [Float](repeating: 0, count: count)
            var crF = [Float](repeating: 0, count: count)

            // Y = 0.299R + 0.587G + 0.114B
            var cYR: Float = 0.299; vDSP_vsmul(redF, 1, &cYR, &yF, 1, n)
            var cYG: Float = 0.587; yF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(greenF, 1, &cYG, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }
            var cYB: Float = 0.114; yF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(blueF,  1, &cYB, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }

            // Cb = -0.168736R - 0.331264G + 0.5B
            var cCbR: Float = -0.168736; vDSP_vsmul(redF, 1, &cCbR, &cbF, 1, n)
            var cCbG: Float = -0.331264; cbF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(greenF, 1, &cCbG, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }
            var cCbB: Float = 0.5; cbF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(blueF,  1, &cCbB, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }

            // Cr = 0.5R - 0.418688G - 0.081312B
            var cCrR: Float = 0.5; vDSP_vsmul(redF, 1, &cCrR, &crF, 1, n)
            var cCrG: Float = -0.418688; crF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(greenF, 1, &cCrG, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }
            var cCrB: Float = -0.081312; crF.withUnsafeMutableBufferPointer { b in
                vDSP_vsma(blueF,  1, &cCrB, b.baseAddress!, 1, b.baseAddress!, 1, n)
            }

            // Float → Int32 with rounding for the EBCOT coefficient path
            var yI  = [Int32](repeating: 0, count: count)
            var cbI = [Int32](repeating: 0, count: count)
            var crI = [Int32](repeating: 0, count: count)
            vDSP_vfixr32(&yF,  1, &yI,  1, n)
            vDSP_vfixr32(&cbF, 1, &cbI, 1, n)
            vDSP_vfixr32(&crF, 1, &crI, 1, n)
            y = yI; cb = cbI; cr = crI

            // Float output for 9/7 DWT path — no extra conversion needed
            var flt: [[Float]] = [yF, cbF, crF]
            if components.count > 3 {
                flt.append(contentsOf: components[3...].map { vDSPConvert.int32sToFloats($0) })
            }
            floatResult = flt
            #else
            // Fallback: Double-precision ICT (non-Apple platforms)
            let redD = vDSPConvert.int32sToDoubles(components[0])
            let greenD = vDSPConvert.int32sToDoubles(components[1])
            let blueD = vDSPConvert.int32sToDoubles(components[2])
            let (yD, cbD, crD) = try transform.forwardICT(
                red: redD, green: greenD, blue: blueD
            )
            y = vDSPConvert.doublesToInt32s(yD)
            cb = vDSPConvert.doublesToInt32s(cbD)
            cr = vDSPConvert.doublesToInt32s(crD)
            var flt: [[Float]] = [
                vDSPConvert.doublesToFloats(yD),
                vDSPConvert.doublesToFloats(cbD),
                vDSPConvert.doublesToFloats(crD)
            ]
            if components.count > 3 {
                flt.append(contentsOf: components[3...].map { vDSPConvert.int32sToFloats($0) })
            }
            floatResult = flt
            #endif
        }

        var result = [y, cb, cr]
        // Preserve any additional components (alpha, etc.) unchanged
        if components.count > 3 {
            result.append(contentsOf: components[3...])
        }
        return (result, floatResult)
    }

    /// Applies array-based MCT using a transformation matrix.
    private func applyArrayBasedMCT(
        _ components: [[Int32]], matrix: J2KMCTMatrix, image: J2KImage
    ) throws -> [[Int32]] {
        guard components.count == matrix.size else {
            throw J2KError.invalidParameter(
                "Component count (\(components.count)) must match matrix size (\(matrix.size)) for MCT"
            )
        }

        // Convert Int32 to Double for MCT
        let doubleComponents = components.map { component in
            component.map { Double($0) }
        }

        // Apply MCT
        let mctConfig = J2KMCTConfiguration(type: .arrayBased, matrix: matrix)
        let mct = J2KMCT(configuration: mctConfig)
        let transformed = try mct.forwardTransform(components: doubleComponents, matrix: matrix)

        // Convert back to Int32
        return transformed.map { component in
            component.map { j2kClampedInt32($0) }
        }
    }

    /// Applies dependency-based MCT.
    private func applyDependencyMCT(
        _ components: [[Int32]], configuration: J2KMCTDependencyConfiguration, image: J2KImage
    ) throws -> [[Int32]] {
        // Convert Int32 to Double for dependency transform
        let doubleComponents = components.map { component in
            component.map { Double($0) }
        }

        // Apply dependency transform
        let transformer = J2KMCTDependencyTransform()
        let transformed: [[Double]]

        switch configuration.transform {
        case .chain(let chain):
            transformed = try transformer.forwardTransform(components: doubleComponents, chain: chain)

        case .hierarchical(let hierarchical):
            transformed = try transformer.forwardHierarchicalTransform(
                components: doubleComponents,
                transform: hierarchical
            )
        }

        // Convert back to Int32
        return transformed.map { component in
            component.map { j2kClampedInt32($0) }
        }
    }

    /// Applies adaptive MCT by selecting the best matrix based on criteria.
    private func applyAdaptiveMCT(
        _ components: [[Int32]],
        candidates: [J2KMCTMatrix],
        criteria: J2KMCTEncodingConfiguration.AdaptiveSelectionCriteria,
        image: J2KImage,
        tileIndex: Int = 0
    ) throws -> ([[Int32]], [[Float]]?) {
        // For now, use a simple heuristic: correlation-based selection
        // In a full implementation, this would evaluate each candidate matrix
        // and select based on the specified criteria

        // TODO: Implement proper adaptive selection based on:
        // - correlation: Analyse component correlation
        // - rateDistortion: Evaluate R-D performance of each candidate
        // - compressionEfficiency: Compare compression ratios

        // Default to first candidate if available
        guard let selectedMatrix = candidates.first else {
            // Fall back to standard transform
            return try applyStandardColorTransform(components, image: image)
        }

        // Apply the selected matrix
        return (try applyArrayBasedMCT(components, matrix: selectedMatrix, image: image), nil)
    }

    // MARK: - Stage 3: Wavelet Transform

    /// **v7.2.0 Phase A — UMA encode-side boundary elimination.**
    ///
    /// Polymorphic Int32 coefficient storage that lets `SubbandInfo`
    /// (and downstream `DeferredCodeBlock`) carry either:
    ///   - A Swift `[Int32]` (the historical case — CPU-produced or
    ///     GPU-produced-then-readback path), OR
    ///   - A `J2KMetalSharedBufferView<Int32>` directly over a
    ///     `.storageModeShared` MTLBuffer (the v7.2.0 zero-copy path
    ///     when the GPU forward 5/3 DWT is the producer).
    ///
    /// The two variants converge at consumer sites via
    /// `withUnsafeBufferPointer { … }` — Swift arrays already expose
    /// that API; `J2KMetalSharedBufferView` mirrors it. So the
    /// entropy hot loop's coefficient access is unchanged for both
    /// storage variants, and the GPU producer skips the
    /// `readInt32Array(memcpy MTLBuffer.contents() → [Int32])`
    /// readback that fired 4× per level × N levels (= 20 boundaries
    /// on a typical 5-level lossless encode).
    enum CoefficientStorage: Sendable {
        case empty
        case array([Int32])
        var count: Int {
            switch self {
            case .empty:           return 0
            case .array(let a):    return a.count            }
        }

        var isEmpty: Bool { count == 0 }

        /// Calls `body` with an `UnsafeBufferPointer<Int32>` over the
        /// storage. The pointer is valid only for the duration of
        /// `body`; do not capture it.
        func withUnsafeBufferPointer<R>(
            _ body: (UnsafeBufferPointer<Int32>) throws -> R
        ) rethrows -> R {
            switch self {
            case .empty:
                return try body(UnsafeBufferPointer<Int32>(start: nil, count: 0))
            case .array(let a):
                return try a.withUnsafeBufferPointer(body)            }
        }

        subscript(index: Int) -> Int32 {
            switch self {
            case .empty:
                preconditionFailure("CoefficientStorage.empty subscripted")
            case .array(let a):
                return a[index]            }
        }
    }

    /// Information about a subband within a decomposition.
    struct SubbandInfo: Sendable {
        let componentIndex: Int
        let level: Int
        let subband: J2KSubband
        let coefficients: CoefficientStorage
        /// Raw Double DWT coefficients for the 9/7 irreversible path.
        /// When non-nil, quantization uses these instead of `coefficients`
        /// to avoid precision loss from premature Int32 rounding.
        let doubleCoefficients: [Double]?
        /// Raw Float DWT coefficients from the GPU path.
        /// When non-nil, quantization uses these directly to avoid the
        /// Float→Double conversion overhead. Takes priority over `doubleCoefficients`.
        let floatCoefficients: [Float]?
        let width: Int
        let height: Int

        init(
            componentIndex: Int, level: Int, subband: J2KSubband,
            coefficients: [Int32], doubleCoefficients: [Double]?,
            width: Int, height: Int,
            floatCoefficients: [Float]? = nil
        ) {
            self.componentIndex = componentIndex
            self.level = level
            self.subband = subband
            self.coefficients = coefficients.isEmpty ? .empty : .array(coefficients)
            self.doubleCoefficients = doubleCoefficients
            self.floatCoefficients = floatCoefficients
            self.width = width
            self.height = height
        }

        /// v7.2.0 Phase A — view-backed initializer used by the GPU
        /// forward 5/3 DWT path.
        init(
            componentIndex: Int, level: Int, subband: J2KSubband,
            coefficients: CoefficientStorage,
            doubleCoefficients: [Double]?,
            width: Int, height: Int,
            floatCoefficients: [Float]? = nil
        ) {
            self.componentIndex = componentIndex
            self.level = level
            self.subband = subband
            self.coefficients = coefficients
            self.doubleCoefficients = doubleCoefficients
            self.floatCoefficients = floatCoefficients
            self.width = width
            self.height = height
        }
    }

    private struct AdaptiveQuantizationStats: Sendable {
        let mean: Double
        let meanAbsoluteValue: Double
        let variance: Double
        let zeroFraction: Double
    }

    @inline(__always)
    private func adaptiveStepKey(for subband: J2KSubband, level: Int) -> String {
        "\(subband.rawValue)_L\(level)"
    }

    private func sampledStats(for info: SubbandInfo, sampleBudget: Int = 2048) -> AdaptiveQuantizationStats {
        var sampleCount = 0
        var sum = 0.0
        var sumAbs = 0.0
        var sumSquares = 0.0
        var zeroCount = 0

        @inline(__always)
        func accumulate(_ value: Double) {
            sampleCount += 1
            sum += value
            sumAbs += abs(value)
            sumSquares += value * value
            if abs(value) < 1e-9 {
                zeroCount += 1
            }
        }

        if let floats = info.floatCoefficients, !floats.isEmpty {
            let sampleStride = max(1, floats.count / sampleBudget)
            for index in Swift.stride(from: 0, to: floats.count, by: sampleStride) {
                accumulate(Double(floats[index]))
            }
        } else if let doubles = info.doubleCoefficients, !doubles.isEmpty {
            let sampleStride = max(1, doubles.count / sampleBudget)
            for index in Swift.stride(from: 0, to: doubles.count, by: sampleStride) {
                accumulate(doubles[index])
            }
        } else if !info.coefficients.isEmpty {
            let sampleStride = max(1, info.coefficients.count / sampleBudget)
            for index in Swift.stride(from: 0, to: info.coefficients.count, by: sampleStride) {
                accumulate(Double(info.coefficients[index]))
            }
        }

        guard sampleCount > 0 else {
            return AdaptiveQuantizationStats(mean: 0.0, meanAbsoluteValue: 0.0, variance: 0.0, zeroFraction: 1.0)
        }

        let count = Double(sampleCount)
        let mean = sum / count
        let variance = max(0.0, (sumSquares / count) - mean * mean)
        return AdaptiveQuantizationStats(
            mean: mean,
            meanAbsoluteValue: sumAbs / count,
            variance: variance,
            zeroFraction: Double(zeroCount) / count
        )
    }

    private func adaptiveQuantizationScale(
        for stats: AdaptiveQuantizationStats,
        subband: J2KSubband,
        bitDepth: Int
    ) -> Double {
        let dynamicRange = max(1.0, Double(1 << min(22, max(1, bitDepth - 1))))
        let normalizedSigma = sqrt(stats.variance) / dynamicRange
        let normalizedMeanAbs = stats.meanAbsoluteValue / dynamicRange

        var scale = 1.0

        switch subband {
        case .ll:
            scale *= 0.96
        case .hl, .lh:
            break
        case .hh:
            scale *= 1.03
        }

        if normalizedSigma < 0.010 {
            scale *= 0.84
        } else if normalizedSigma < 0.025 {
            scale *= 0.90
        } else if normalizedSigma < 0.050 {
            scale *= 0.96
        } else if normalizedSigma > 0.18 {
            scale *= 1.04
        }

        if stats.zeroFraction > 0.80 && normalizedMeanAbs < 0.02 {
            scale *= 0.92
        } else if stats.zeroFraction < 0.20 && normalizedMeanAbs > 0.10 {
            scale *= 1.03
        }

        return min(1.10, max(0.78, scale))
    }

    private func buildAdaptiveLossyStepSizes(
        _ componentSubbands: [[SubbandInfo]],
        image: J2KImage,
        totalLevels: Int
    ) -> [String: Double] {
        guard !config.useReversibleFilter, !config.lossless else {
            return [:]
        }

        var grouped = [String: [SubbandInfo]]()
        for subbands in componentSubbands {
            for info in subbands where info.width > 0 && info.height > 0 {
                grouped[adaptiveStepKey(for: info.subband, level: info.level), default: []].append(info)
            }
        }

        var steps = [String: Double]()
        steps.reserveCapacity(grouped.count)

        for (key, infos) in grouped {
            guard let representative = infos.first else { continue }
            let bitDepth = infos.map { image.components[$0.componentIndex].bitDepth }.max() ?? 8
            let baseParams = lossyQuantizationParameters(
                bitDepth: bitDepth,
                componentCount: image.components.count
            )
            let nominalStep = J2KStepSizeCalculator.calculateStepSize(
                baseStepSize: baseParams.baseStepSize,
                subband: representative.subband,
                decompositionLevel: representative.level,
                totalLevels: totalLevels,
                reversible: false
            )

            var mean = 0.0
            var meanAbs = 0.0
            var variance = 0.0
            var zeroFraction = 0.0
            for info in infos {
                let stats = sampledStats(for: info)
                mean += stats.mean
                meanAbs += stats.meanAbsoluteValue
                variance += stats.variance
                zeroFraction += stats.zeroFraction
            }
            let invCount = 1.0 / Double(max(1, infos.count))
            let aggregated = AdaptiveQuantizationStats(
                mean: mean * invCount,
                meanAbsoluteValue: meanAbs * invCount,
                variance: variance * invCount,
                zeroFraction: zeroFraction * invCount
            )

            let adaptiveScale = adaptiveQuantizationScale(
                for: aggregated,
                subband: representative.subband,
                bitDepth: bitDepth
            )
            steps[key] = nominalStep * adaptiveScale
        }

        return steps
    }

    private func lossyStepSize(
        for info: SubbandInfo,
        imageBitDepth: Int,
        componentCount: Int,
        totalLevels: Int,
        adaptiveStepSizes: [String: Double]
    ) -> Double {
        let key = adaptiveStepKey(for: info.subband, level: info.level)
        if let step = adaptiveStepSizes[key] {
            return step
        }

        let params = lossyQuantizationParameters(bitDepth: imageBitDepth, componentCount: componentCount)
        return J2KStepSizeCalculator.calculateStepSize(
            baseStepSize: params.baseStepSize,
            subband: info.subband,
            decompositionLevel: info.level,
            totalLevels: totalLevels,
            reversible: false
        )
    }

    /// Applies the forward wavelet transform to all components.
    ///
    /// - Returns: A tuple of (subbands per component, actual decomposition levels used).
    private func applyWaveletTransform(
        _ components: [[Int32]], floatComponents: [[Float]]? = nil,
        width: Int, height: Int,
        tileOriginX: Int = 0, tileOriginY: Int = 0,
        // v10.25 — set by the multi-tile per-tile entry. The GPU
        // forward 5/3 pixel threshold was designed to exclude
        // multi-tile per-tile dispatches ("per-tile dim is always
        // ≪ 4 MP for the production .auto layouts"), but the v9.6
        // MG 2x2 override produces 4.21 MP tiles that breach it by
        // size alone. Make the design intent explicit instead of
        // implicit in a size assumption.
        isMultiTilePerTile: Bool = false
    ) async throws -> ([[SubbandInfo]], Int) {
        // Select filter based on wavelet kernel configuration
        let filter: J2KDWT1D.Filter
        switch config.waveletKernelConfiguration {
        case .standard:
            // Use standard Part 1 wavelets
            filter = config.useReversibleFilter ? .reversible53 : .irreversible97
        case .arbitrary(let kernel):
            // Use arbitrary kernel for all components
            filter = kernel.toDWTFilter()
        case .perTileComponent:
            // Per-tile-component selection handled below
            filter = config.useReversibleFilter ? .reversible53 : .irreversible97
        }

        // Clamp decomposition levels to what the image dimensions can support
        let maxLevels = max(0, Int(log2(Double(min(width, height)))) - 1)
        let levels = min(config.decompositionLevels, maxLevels)

        // No-decomp fast path: all components share the same `levels` value, so
        // handle the levels==0 case before spinning up the task group.
        guard levels >= 1 else {
            let allSubbands = components.enumerated().map { (compIdx, compData) in
                [SubbandInfo(
                    componentIndex: compIdx, level: 0, subband: .ll,
                    coefficients: compData, doubleCoefficients: nil,
                    width: width, height: height
                )]
            }
            return (allSubbands, levels)
        }

        // Pre-compute per-component filter outside the task group to avoid
        // capturing `config` (non-Sendable) in @Sendable task closures.
        let componentFilters: [J2KDWT1D.Filter] = (0..<components.count).map { compIdx in
            if case .perTileComponent(let kernelMap) = config.waveletKernelConfiguration {
                let key = J2KWaveletKernelConfiguration.TileComponentKey(tileIndex: 0, componentIndex: compIdx)
                if let kernel = kernelMap[key] { return kernel.toDWTFilter() }
                return config.useReversibleFilter ? .reversible53 : .irreversible97
            }
            return filter
        }

        var allSubbands: [[SubbandInfo]] = Array(repeating: [], count: components.count)
        try await withThrowingTaskGroup(of: (Int, [SubbandInfo]).self) { group in
            for (compIdx, compData) in components.enumerated() {
                let componentFilter = componentFilters[compIdx]
                let floatComp: [Float]? = floatComponents.flatMap { fc in
                    compIdx < fc.count ? fc[compIdx] : nil
                }

                // v10.25: `.high` priority — the forward DWT is the
                // dominant encode stage (~60% of DX wall); a default-
                // priority task is E-core-eligible (3-4× slower).
                // Mirrors the v10.24.2 decode-entropy QoS fix.
                group.addTask(priority: .high) {
                    let use97DoublePrecision: Bool
                    if case .irreversible97 = componentFilter { use97DoublePrecision = true }
                    else { use97DoublePrecision = false }

                    let useAcceleratedPath: Bool
                    switch componentFilter {
                    case .irreversible97, .reversible53: useAcceleratedPath = true
                    case .custom: useAcceleratedPath = false
                    }

                    var subbands: [SubbandInfo] = []

                    if use97DoublePrecision && useAcceleratedPath {
                        let flatFloat: [Float] = floatComp ?? vDSPConvert.int32sToFloats(compData)
                        let decomposition = await AcceleratedDWT2D.forwardDecomposition(
                            data: flatFloat, width: width, height: height, levels: levels
                        )
                        for (levelIdx, level) in decomposition.levels.enumerated() {
                            let decomLevel = levelIdx + 1
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hl,
                                coefficients: [], doubleCoefficients: nil,
                                width: level.hlW, height: level.hlH, floatCoefficients: level.hl))
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .lh,
                                coefficients: [], doubleCoefficients: nil,
                                width: level.lhW, height: level.lhH, floatCoefficients: level.lh))
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hh,
                                coefficients: [], doubleCoefficients: nil,
                                width: level.hhW, height: level.hhH, floatCoefficients: level.hh))
                        }
                        subbands.insert(SubbandInfo(componentIndex: compIdx, level: 0, subband: .ll,
                            coefficients: [], doubleCoefficients: nil,
                            width: decomposition.llW, height: decomposition.llH,
                            floatCoefficients: decomposition.coarsestLL), at: 0)

                    } else if !use97DoublePrecision && useAcceleratedPath {
                            // v6-alpha3 step 3: route through the parity-aware
                            // overload so per-tile image-coordinate origin is
                            // honoured. When (tileOriginX, tileOriginY) == (0, 0)
                            // the parity-aware overload routes to the no-origin
                            // fast path at every level, so single-tile output is
                            // byte-identical to v5.38 / v5.39 / v6-alpha2.
                            let decomposition = await AcceleratedDWT2D.forwardDecomposition53(
                                data: compData, width: width, height: height, levels: levels,
                                tileOriginX: tileOriginX, tileOriginY: tileOriginY
                            )
                            for (levelIdx, level) in decomposition.levels.enumerated() {
                                let decomLevel = levelIdx + 1
                                subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hl,
                                    coefficients: level.hl, doubleCoefficients: nil,
                                    width: level.hlW, height: level.hlH))
                                subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .lh,
                                    coefficients: level.lh, doubleCoefficients: nil,
                                    width: level.lhW, height: level.lhH))
                                subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hh,
                                    coefficients: level.hh, doubleCoefficients: nil,
                                    width: level.hhW, height: level.hhH))
                            }
                            subbands.insert(SubbandInfo(componentIndex: compIdx, level: 0, subband: .ll,
                                coefficients: decomposition.coarsestLL, doubleCoefficients: nil,
                                width: decomposition.llW, height: decomposition.llH), at: 0)

                    } else if use97DoublePrecision {
                        var img2D: [[Double]] = []
                        img2D.reserveCapacity(height)
                        if let fc = floatComp {
                            for row in 0..<height {
                                let rs = row * width
                                img2D.append(fc[rs..<rs + width].map { Double($0) })
                            }
                        } else {
                            for row in 0..<height {
                                let rs = row * width
                                img2D.append(compData[rs..<rs + width].map { Double($0) })
                            }
                        }
                        let decomposition = try J2KDWT2D.forwardDecompositionDouble(
                            image: img2D, levels: levels, filter: componentFilter
                        )
                        for levelIdx in 0..<decomposition.levelCount {
                            let level = decomposition.levels[levelIdx]
                            let decomLevel = levelIdx + 1
                            let hlFlat = level.hl.flatMap { $0 }
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hl,
                                coefficients: vDSPConvert.doublesToInt32s(hlFlat), doubleCoefficients: hlFlat,
                                width: level.hl.isEmpty ? 0 : level.hl[0].count, height: level.hl.count))
                            let lhFlat = level.lh.flatMap { $0 }
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .lh,
                                coefficients: vDSPConvert.doublesToInt32s(lhFlat), doubleCoefficients: lhFlat,
                                width: level.lh.isEmpty ? 0 : level.lh[0].count, height: level.lh.count))
                            let hhFlat = level.hh.flatMap { $0 }
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hh,
                                coefficients: vDSPConvert.doublesToInt32s(hhFlat), doubleCoefficients: hhFlat,
                                width: level.hh.isEmpty ? 0 : level.hh[0].count, height: level.hh.count))
                        }
                        let coarsestLL = decomposition.coarsestLL
                        let llFlat = coarsestLL.flatMap { $0 }
                        subbands.insert(SubbandInfo(componentIndex: compIdx, level: 0, subband: .ll,
                            coefficients: vDSPConvert.doublesToInt32s(llFlat), doubleCoefficients: llFlat,
                            width: coarsestLL.isEmpty ? 0 : coarsestLL[0].count,
                            height: coarsestLL.count), at: 0)

                    } else {
                        var image2D: [[Int32]] = []
                        image2D.reserveCapacity(height)
                        for row in 0..<height {
                            let rs = row * width
                            image2D.append(Array(compData[rs..<rs + width]))
                        }
                        let decomposition = try J2KDWT2D.forwardDecomposition(
                            image: image2D, levels: levels, filter: componentFilter
                        )
                        for levelIdx in 0..<decomposition.levelCount {
                            let level = decomposition.levels[levelIdx]
                            let decomLevel = levelIdx + 1
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hl,
                                coefficients: level.hl.flatMap { $0 }, doubleCoefficients: nil,
                                width: level.hl.isEmpty ? 0 : level.hl[0].count, height: level.hl.count))
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .lh,
                                coefficients: level.lh.flatMap { $0 }, doubleCoefficients: nil,
                                width: level.lh.isEmpty ? 0 : level.lh[0].count, height: level.lh.count))
                            subbands.append(SubbandInfo(componentIndex: compIdx, level: decomLevel, subband: .hh,
                                coefficients: level.hh.flatMap { $0 }, doubleCoefficients: nil,
                                width: level.hh.isEmpty ? 0 : level.hh[0].count, height: level.hh.count))
                        }
                        let coarsestLL = decomposition.coarsestLL
                        subbands.insert(SubbandInfo(componentIndex: compIdx, level: 0, subband: .ll,
                            coefficients: coarsestLL.flatMap { $0 }, doubleCoefficients: nil,
                            width: coarsestLL.isEmpty ? 0 : coarsestLL[0].count,
                            height: coarsestLL.count), at: 0)
                    }

                    return (compIdx, subbands)
                }
            }
            for try await (idx, subbands) in group {
                allSubbands[idx] = subbands
            }
        }

        return (allSubbands, levels)
    }

    // MARK: - Stage 4: Quantization

    /// Builds lossy quantization parameters matched to the source precision and
    /// the current bitrate budget.
    private func lossyQuantizationParameters(bitDepth: Int, componentCount: Int) -> J2KQuantizationParameters {
        let baseParameters = J2KQuantizationParameters.fromQuality(config.quality, bitDepth: bitDepth)

        let perComponentTargetBpp: Double?
        switch config.bitrateMode {
        case .constantBitrate(let bitsPerPixel):
            perComponentTargetBpp = bitsPerPixel / Double(max(1, componentCount))
        case .variableBitrate(_, let maxBitsPerPixel):
            perComponentTargetBpp = maxBitsPerPixel / Double(max(1, componentCount))
        case .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            // Each search iteration substitutes .fixedQstep, so this
            // branch should not be reached during normal flow. If a
            // caller invokes the pipeline directly with this mode,
            // fall through to the .fixedQstep behavior.
            preconditionFailure(".constantBitrateViaQstep / .constantBitrateBounded / .constantBitrateStrict should be intercepted by J2KEncoder.encode and converted to .fixedQstep per iteration")
        case .constantQuality, .lossless:
            perComponentTargetBpp = nil
        case .fixedQstep(let qstep):
            // Fixed-qstep mode (v5.18.0): bypass the bpp-aware
            // scaleFactor heuristics entirely. Return the user-
            // supplied qstep directly via baseStepSize, leaving
            // the LL/HL/LH/HH gain weighting (in J2KStepSizeCalculator)
            // as the only multiplier applied downstream. Matches
            // OpenJPH's qstep-only model.
            return J2KQuantizationParameters(
                mode: baseParameters.mode,
                baseStepSize: qstep,
                deadzoneWidth: baseParameters.deadzoneWidth,
                guardBits: baseParameters.guardBits,
                implicitStepSizes: baseParameters.implicitStepSizes,
                explicitStepSizes: baseParameters.explicitStepSizes,
                tcqConfiguration: baseParameters.tcqConfiguration)
        }

        let scaleFactor: Double
        if bitDepth > 8 {
            // High-bit-depth quantizer — bpp-aware ramp. At low bpp the
            // stepsize stays coarse so PCRD doesn't over-populate the pass
            // stack. At high bpp the stepsize shrinks so the encoder
            // generates a deep enough bit-plane stack to reach near-lossless
            // quality. A mid-range transition (1.25 → 2.0 bpp) prevents the
            // discontinuity that previously caused MG/XA to undershoot their
            // byte budget at bpp=2.0.
            if let target = perComponentTargetBpp {
                if target <= 0.35 {
                    scaleFactor = 2.5
                } else if target <= 0.50 {
                    scaleFactor = 1.75
                } else if target <= 0.75 {
                    scaleFactor = 1.25
                } else if target <= 2.0 {
                    scaleFactor = 1.0
                } else if target <= 3.0 {
                    scaleFactor = 0.60
                } else {
                    scaleFactor = 0.40
                }
            } else if config.quality <= 0.55 {
                scaleFactor = 1.75
            } else if config.quality <= 0.75 {
                scaleFactor = 1.25
            } else if config.quality <= 0.90 {
                scaleFactor = 1.0
            } else {
                scaleFactor = 0.60
            }
        } else if let target = perComponentTargetBpp, componentCount > 1 {
            if target <= 0.20 {
                scaleFactor = 1.0
            } else if target <= 0.35 {
                scaleFactor = 1.25
            } else if target <= 0.50 {
                scaleFactor = 1.10
            } else {
                scaleFactor = 1.0
            }
        } else if let target = perComponentTargetBpp, componentCount == 1 {
            if target <= 1.00 && target > 0.50 {
                scaleFactor = 0.95
            } else {
                scaleFactor = 1.0
            }
        } else if componentCount > 1, perComponentTargetBpp == nil {
            if config.quality <= 0.55 {
                scaleFactor = 0.12
            } else if config.quality <= 0.75 {
                scaleFactor = 0.45
            } else if config.quality <= 0.90 {
                scaleFactor = 0.80
            } else {
                scaleFactor = 1.0
            }
        } else if componentCount == 1, perComponentTargetBpp == nil {
            if config.quality <= 0.55 {
                scaleFactor = 0.70
            } else if config.quality <= 0.75 {
                scaleFactor = 0.85
            } else {
                scaleFactor = 1.0
            }
        } else {
            scaleFactor = 1.0
        }

        guard scaleFactor != 1.0 else {
            return baseParameters
        }

        return J2KQuantizationParameters(
            mode: baseParameters.mode,
            baseStepSize: baseParameters.baseStepSize * scaleFactor,
            deadzoneWidth: baseParameters.deadzoneWidth,
            guardBits: baseParameters.guardBits,
            implicitStepSizes: baseParameters.implicitStepSizes,
            explicitStepSizes: baseParameters.explicitStepSizes,
            tcqConfiguration: baseParameters.tcqConfiguration
        )
    }

    /// Applies quantization to all subbands.
    private func applyQuantization(
        _ componentSubbands: [[SubbandInfo]],
        image: J2KImage,
        adaptiveStepSizes: [String: Double],
        totalLevels: Int
    ) throws -> [[SubbandInfo]] {
        var result: [[SubbandInfo]] = []

        for subbands in componentSubbands {
            var quantizedSubbands: [SubbandInfo] = []
            for info in subbands {
                let componentBitDepth = image.components[info.componentIndex].bitDepth
                let params: J2KQuantizationParameters
                if config.useReversibleFilter {
                    params = .lossless
                } else {
                    let base = lossyQuantizationParameters(
                        bitDepth: componentBitDepth,
                        componentCount: image.components.count
                    )
                    let step = lossyStepSize(
                        for: info,
                        imageBitDepth: componentBitDepth,
                        componentCount: image.components.count,
                        totalLevels: totalLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    params = J2KQuantizationParameters(
                        mode: base.mode,
                        baseStepSize: base.baseStepSize,
                        deadzoneWidth: base.deadzoneWidth,
                        guardBits: base.guardBits,
                        implicitStepSizes: false,
                        explicitStepSizes: ["\(info.subband.rawValue)\(info.level + 1)": step],
                        tcqConfiguration: base.tcqConfiguration
                    )
                }
                let quantizer = J2KQuantizer(parameters: params)

                // v7.2.0 Phase A — for lossless reversible 5/3 with
                // Int32 input, quantization is the identity map; the
                // existing `coefficients.map { quantizeCoefficient(..., 1.0) }`
                // call still allocates a fresh `[Int32]` even though
                // the values don't change. For the UMA-elimination
                // path the input may be a `J2KMetalSharedBufferView<Int32>`
                // — materialising it into an Array here would re-add
                // the readback memcpy we eliminated upstream. Instead,
                // pass `info.coefficients` straight through as
                // `CoefficientStorage` (bit-exact for lossless).
                if config.useReversibleFilter
                    && info.floatCoefficients == nil
                    && info.doubleCoefficients == nil
                {
                    quantizedSubbands.append(SubbandInfo(
                        componentIndex: info.componentIndex,
                        level: info.level,
                        subband: info.subband,
                        coefficients: info.coefficients,
                        doubleCoefficients: nil,
                        width: info.width,
                        height: info.height
                    ))
                    continue
                }

                let quantized: [Int32]
                if let floatCoeffs = info.floatCoefficients {
                    // Use Float-precision path for GPU DWT output — avoids Float→Double conversion
                    quantized = try quantizer.quantize(
                        coefficients: floatCoeffs,
                        subband: info.subband,
                        decompositionLevel: info.level,
                        totalLevels: totalLevels
                    )
                } else if let doubleCoeffs = info.doubleCoefficients {
                    // Use Double-precision path for 9/7 irreversible to preserve fractional precision
                    quantized = try quantizer.quantize(
                        coefficients: doubleCoeffs,
                        subband: info.subband,
                        decompositionLevel: info.level,
                        totalLevels: totalLevels
                    )
                } else {
                    // Lossy reversible-5/3 with Int32 input. Materialise
                    // the storage into an Array here (one-time memcpy
                    // for the lossy path; lossless took the bypass above).
                    let int32Array: [Int32] = info.coefficients.withUnsafeBufferPointer { buf in
                        Array(buf)
                    }
                    quantized = try quantizer.quantize(
                        coefficients: int32Array,
                        subband: info.subband,
                        decompositionLevel: info.level,
                        totalLevels: totalLevels
                    )
                }

                quantizedSubbands.append(SubbandInfo(
                    componentIndex: info.componentIndex,
                    level: info.level,
                    subband: info.subband,
                    coefficients: quantized,
                    doubleCoefficients: nil,
                    width: info.width,
                    height: info.height
                ))
            }
            result.append(quantizedSubbands)
        }

        return result
    }

    // MARK: - Stage 5: Entropy Coding

    /// Describes a pending code-block to be encoded.
    private struct PendingCodeBlock: Sendable {
        let index: Int
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let subband: J2KSubband
        let componentIndex: Int
        let resolutionLevel: Int
        let coefficients: [Int32]
        let bitDepth: Int
        let coefficientSquaredSum: Double
        let bitPlanePopulation: [Int]
    }

    /// Lightweight block descriptor for deferred-extraction HTJ2K encoding.
    ///
    /// Stores a CoW reference to the subband coefficient array plus extraction
    /// coordinates, deferring the per-block memcpy to the parallel encoding loop.
    private struct DeferredCodeBlock: Sendable {
        let index: Int
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let subband: J2KSubband
        let componentIndex: Int
        let resolutionLevel: Int
        let bitDepth: Int
        /// CoW reference to the subband's full coefficient array (Int32, quantized or lossless).
        /// **v7.2.0 Phase A**: now polymorphic over Swift `[Int32]` and
        /// `J2KMetalSharedBufferView<Int32>` so the GPU forward DWT
        /// path can hand its output to the entropy coder without a
        /// readback memcpy on Apple Silicon UMA.
        let subbandCoefficients: CoefficientStorage
        /// Width of the subband (row stride in elements).
        let subbandWidth: Int
        /// Origin of this block within the subband.
        let originX: Int
        let originY: Int
        /// Raw Float DWT coefficients for fused quantization (9/7 lossy HTJ2K path).
        /// When non-nil, block extraction quantizes inline using `quantizationStep`.
        let floatSubbandCoefficients: [Float]?
        /// Quantization step size for inline Float→Int32 conversion.
        let quantizationStep: Float
    }

    /// Applies entropy coding to all subbands, producing code blocks.
    ///
    /// When `config.useHTJ2K` is true, uses a fused extract-and-encode path
    /// that defers coefficient extraction to the parallel encoding loop,
    /// eliminating the sequential first pass. Otherwise uses legacy EBCOT
    /// bit-plane coding per ISO/IEC 15444-1.
    private func applyEntropyCoding(
        _ componentSubbands: [[SubbandInfo]],
        image: J2KImage,
        adaptiveStepSizes: [String: Double],
        totalLevels: Int,
        // v6-alpha3 step 6A — tile origin for canvas-anchored
        // code-block partitioning (ISO/IEC 15444-1 B.7). Default
        // (0, 0) preserves single-tile behaviour byte-for-byte.
        tileOriginX: Int = 0,
        tileOriginY: Int = 0,
        // v6-alpha3 step 6A — geometry trace plumbing.
        tileIndex: Int = 0,
        geometryCollector: GeometryCollector? = nil
    ) async throws -> [J2KCodeBlock] {
        let profiling = ProcessInfo.processInfo.environment["J2K_PROFILE"] != nil
        let entropyStart = CFAbsoluteTimeGetCurrent()

        let cbWidth = config.codeBlockSize.width
        let cbHeight = config.codeBlockSize.height

        // Determine decomposition levels actually used.
        // Prefer the caller-provided value so the quantizer, entropy path, and
        // codestream marker signaling all use the same level count.
        let actualLevels = max(
            totalLevels,
            componentSubbands.first.map { subbands -> Int in
                return subbands.count > 1 ? (subbands.count - 1) / 3 : 0
            } ?? config.decompositionLevels
        )

        // Guard bits and range bits for Kb computation (must match QCD marker)
        let quantExt = J2KPart2QuantizationExtensions(configuration: config)
        let guardBits = Int(quantExt.extendedGuardBits)

        // HTJ2K fast path: build lightweight descriptors and fuse coefficient
        // extraction into the parallel encoding loop to eliminate the sequential
        // first pass.
        if config.useHTJ2K {
            return try await applyEntropyCodingHTJ2KFused(
                componentSubbands,
                image: image,
                actualLevels: actualLevels,
                guardBits: guardBits,
                cbWidth: cbWidth,
                cbHeight: cbHeight,
                profiling: profiling,
                entropyStart: entropyStart,
                adaptiveStepSizes: adaptiveStepSizes,
                tileOriginX: tileOriginX,
                tileOriginY: tileOriginY,
                tileIndex: tileIndex,
                geometryCollector: geometryCollector
            )
        }

        // Legacy EBCOT path: build lightweight descriptors and defer per-block
        // extraction to the encoding loop. This avoids allocating one `[Int32]`
        // array per code-block before Tier-1 coding starts.
        var deferred: [DeferredCodeBlock] = []
        var blockIndex = 0

        for subbands in componentSubbands {
            for info in subbands {
                guard info.width > 0 && info.height > 0 else { continue }

                let imageBitDepth = image.components[info.componentIndex].bitDepth
                let resolutionLevel: Int
                if info.subband == .ll {
                    resolutionLevel = 0
                } else {
                    resolutionLevel = actualLevels - info.level + 1
                }

                let bandKb: Int
                if config.useReversibleFilter {
                    let gainExponent: Int
                    switch info.subband {
                    case .ll: gainExponent = 0
                    case .hl, .lh: gainExponent = 1
                    case .hh: gainExponent = 2
                    }
                    let epsilon = imageBitDepth + gainExponent
                    bandKb = epsilon + guardBits - 1
                } else {
                    // For irreversible 9/7, the QCD/Kb signaling must include
                    // the JPEG 2000 detail-band gain exponents so external
                    // decoders reconstruct the same quantization steps.
                    let gainExponent: Int
                    switch info.subband {
                    case .ll: gainExponent = 0
                    case .hl, .lh: gainExponent = 1
                    case .hh: gainExponent = 2
                    }
                    let rangeBits = imageBitDepth + gainExponent
                    let step = lossyStepSize(
                        for: info,
                        imageBitDepth: imageBitDepth,
                        componentCount: image.components.count,
                        totalLevels: actualLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    let (epsilon, _) = Self.encodeJ2KStepSize(step, rangeBits: rangeBits)
                    bandKb = epsilon + guardBits - 1
                }

                // Compute the effective quantizer stepsize for this subband once,
                // and keep it for PCRD (passed as `pcrdStep` below) so per-pass
                // distortion can be converted from quantized-coefficient units
                // to subband MSE. Lossless / already-quantized paths use step = 1.
                let pcrdStep: Double
                let fusedInvStep: Float?
                if info.floatCoefficients != nil && !config.useReversibleFilter {
                    let step = lossyStepSize(
                        for: info,
                        imageBitDepth: imageBitDepth,
                        componentCount: image.components.count,
                        totalLevels: actualLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    fusedInvStep = Float(1.0 / step)
                    pcrdStep = step
                } else if info.doubleCoefficients != nil && !config.useReversibleFilter && info.coefficients.isEmpty {
                    let step = lossyStepSize(
                        for: info,
                        imageBitDepth: imageBitDepth,
                        componentCount: image.components.count,
                        totalLevels: actualLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    fusedInvStep = Float(1.0 / step)
                    pcrdStep = step
                } else if !config.useReversibleFilter {
                    // Pre-quantized integer subband path — recover the nominal step.
                    pcrdStep = lossyStepSize(
                        for: info,
                        imageBitDepth: imageBitDepth,
                        componentCount: image.components.count,
                        totalLevels: actualLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    fusedInvStep = nil
                } else {
                    pcrdStep = 1.0
                    fusedInvStep = nil
                }

                // v7.2.0 Phase A — `quantizedSubband` is now
                // `CoefficientStorage` so the lossless / pass-through
                // branch can carry a `J2KMetalSharedBufferView<Int32>`
                // straight into `DeferredCodeBlock.subbandCoefficients`
                // without an Array materialisation. The lossy paths
                // produce a fresh `[Int32]` and wrap it via `.array(...)`.
                let quantizedSubband: CoefficientStorage
                if let floatCoeffs = info.floatCoefficients, var invStep = fusedInvStep {
                    #if canImport(Accelerate)
                    let n = vDSP_Length(floatCoeffs.count)
                    var scaled = [Float](repeating: 0, count: floatCoeffs.count)
                    vDSP_vsmul(floatCoeffs, 1, &invStep, &scaled, 1, n)
                    var result = [Int32](repeating: 0, count: floatCoeffs.count)
                    vDSP_vfix32(&scaled, 1, &result, 1, n)
                    quantizedSubband = .array(result)
                    #else
                    quantizedSubband = .array(floatCoeffs.map { val in
                        let mag = Int32(abs(val) * invStep)
                        return val >= 0 ? mag : -mag
                    })
                    #endif
                } else if let doubleCoeffs = info.doubleCoefficients, let invStep = fusedInvStep {
                    let dInvStep = Double(invStep)
                    quantizedSubband = .array(doubleCoeffs.map { val in
                        let mag = Int32(abs(val) * dInvStep)
                        return val >= 0 ? mag : -mag
                    })
                } else {
                    quantizedSubband = info.coefficients
                }

                let blocksX = (info.width + cbWidth - 1) / cbWidth
                let blocksY = (info.height + cbHeight - 1) / cbHeight
                deferred.reserveCapacity(deferred.count + blocksX * blocksY)

                for by in 0..<blocksY {
                    for bx in 0..<blocksX {
                        let blockW = min(cbWidth, info.width - bx * cbWidth)
                        let blockH = min(cbHeight, info.height - by * cbHeight)

                        deferred.append(DeferredCodeBlock(
                            index: blockIndex,
                            x: bx * cbWidth,
                            y: by * cbHeight,
                            width: blockW,
                            height: blockH,
                            subband: info.subband,
                            componentIndex: info.componentIndex,
                            resolutionLevel: resolutionLevel,
                            bitDepth: bandKb,
                            subbandCoefficients: quantizedSubband,
                            subbandWidth: info.width,
                            originX: bx * cbWidth,
                            originY: by * cbHeight,
                            floatSubbandCoefficients: nil,
                            quantizationStep: Float(pcrdStep)
                        ))
                        blockIndex += 1
                    }
                }
            }
        }

        if profiling {
            let extractEnd = CFAbsoluteTimeGetCurrent()
            print("    PROFILE entropy-extract: \(deferred.count) blocks in \(String(format: "%.4f", extractEnd - entropyStart))s")
        }

        let encodeStart = CFAbsoluteTimeGetCurrent()
        let allCodeBlocks = try await encodeDeferredCodeBlocksEBCOT(
            deferred,
            isLossless: config.lossless,
            cbWidth: cbWidth,
            cbHeight: cbHeight
        )

        if profiling {
            let encodeEnd = CFAbsoluteTimeGetCurrent()
            print("    PROFILE entropy-encode: \(String(format: "%.4f", encodeEnd - encodeStart))s (parallel=\(config.enableParallelCodeBlocks && deferred.count > 1))")
        }

        return allCodeBlocks
    }

    /// Standard J2K fused EBCOT path: lightweight descriptors followed by
    /// per-chunk extraction directly into reusable scratch buffers.
    private func encodeDeferredCodeBlocksEBCOT(
        _ deferred: [DeferredCodeBlock],
        isLossless: Bool,
        cbWidth: Int,
        cbHeight: Int
    ) async throws -> [J2KCodeBlock] {
        let totalBlocks = deferred.count
        guard totalBlocks > 0 else { return [] }

        let maxConcurrency = config.maxThreads > 0 ? config.maxThreads : ProcessInfo.processInfo.activeProcessorCount
        let chunkPlan = Tier1ChunkPlan(totalBlocks: totalBlocks, maxConcurrency: maxConcurrency)
        let maxBlockSize = cbWidth * cbHeight
        let componentCount = max(1, Set(deferred.map(\.componentIndex)).count)
        let maxPassesLimit = recommendedEBCOTPassLimit(componentCount: componentCount)
        let orderedResults = Tier1ResultBuffer<J2KCodeBlock>(count: totalBlocks)

        let encodeRange: @Sendable (Range<Int>) throws -> Void = { range in
            let encoder = CodeBlockEncoder()
            let scratch = EBCOTScratchBuffers(maxSize: maxBlockSize)
            let shouldCollectRateControlMetrics = !isLossless
            var coeffsBuffer = [Int32](repeating: 0, count: maxBlockSize)

            for i in range {
                let d = deferred[i]
                let blockSize = d.width * d.height

                d.subbandCoefficients.withUnsafeBufferPointer { src in
                    coeffsBuffer.withUnsafeMutableBufferPointer { dst in
                        guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                        for row in 0..<d.height {
                            let srcStart = (d.originY + row) * d.subbandWidth + d.originX
                            memcpy(
                                dstBase + row * d.width,
                                srcBase + srcStart,
                                d.width * MemoryLayout<Int32>.size
                            )
                        }
                    }
                }

                let analysis = scratch.separateAndAnalyze(
                    coeffsBuffer,
                    count: blockSize,
                    totalBitPlanes: d.bitDepth,
                    collectRateControlMetrics: shouldCollectRateControlMetrics
                )

                var codeBlock = try encoder.encode(
                    coefficients: coeffsBuffer,
                    width: d.width,
                    height: d.height,
                    subband: d.subband,
                    bitDepth: d.bitDepth,
                    options: standardEBCOTCodingOptions,
                    coefficientCount: blockSize,
                    maxPasses: maxPassesLimit,
                    scratch: scratch,
                    collectRateControlMetrics: shouldCollectRateControlMetrics,
                    precomputedAnalysis: analysis
                )

                codeBlock = J2KCodeBlock(
                    index: d.index,
                    x: d.x,
                    y: d.y,
                    width: d.width,
                    height: d.height,
                    subband: codeBlock.subband,
                    componentIndex: d.componentIndex,
                    resolutionLevel: d.resolutionLevel,
                    data: codeBlock.data,
                    passeCount: codeBlock.passeCount,
                    zeroBitPlanes: codeBlock.zeroBitPlanes,
                    passSegmentLengths: codeBlock.passSegmentLengths,
                    cumulativePassBytes: codeBlock.cumulativePassBytes,
                    coefficientSquaredSum: codeBlock.coefficientSquaredSum,
                    bitPlanePopulation: codeBlock.bitPlanePopulation,
                    cumulativePassDistortion: codeBlock.cumulativePassDistortion,
                    perPassSnapshotData: codeBlock.perPassSnapshotData,
                    mqCheckpoints: codeBlock.mqCheckpoints,
                    rawMQOutput: codeBlock.rawMQOutput,
                    quantizationStep: config.useReversibleFilter ? nil : Double(d.quantizationStep)
                )
                orderedResults.write(codeBlock, at: d.index)
            }
        }

        #if canImport(Dispatch)
        if config.enableParallelCodeBlocks && chunkPlan.workerCount > 1 {
            DispatchQueue.global(qos: .userInteractive).sync {
                DispatchQueue.concurrentPerform(iterations: chunkPlan.workerCount) { workerIndex in
                    if orderedResults.firstError != nil { return }
                    guard let range = chunkPlan.range(for: workerIndex, totalBlocks: totalBlocks) else { return }

                    autoreleasepool {
                        do {
                            try encodeRange(range)
                        } catch {
                            orderedResults.recordError(error)
                        }
                    }
                }
            }
            return try orderedResults.materialize()
        }
        #endif

        try encodeRange(0..<totalBlocks)
        return try orderedResults.materialize()
    }

    // MARK: - HTJ2K Fused Extract-and-Encode

    /// HTJ2K fast path: builds lightweight block descriptors in a single sequential
    /// scan, then performs coefficient extraction + HT encoding in a parallel loop.
    ///
    /// Compared to the legacy two-pass approach (extract all, then encode all),
    /// this eliminates:
    /// - Sequential per-block coefficient array allocations (~4MB for 1024×1024)
    /// - The `pendingBlocks` array holding all coefficient arrays simultaneously
    /// - A full sequential pass over all subbands

    private func applyEntropyCodingHTJ2KFused(
        _ componentSubbands: [[SubbandInfo]],
        image: J2KImage,
        actualLevels: Int,
        guardBits: Int,
        cbWidth: Int,
        cbHeight: Int,
        profiling: Bool,
        entropyStart: CFAbsoluteTime,
        adaptiveStepSizes: [String: Double],
        // v6-alpha3 step 6A — tile origin for canvas-anchored
        // code-block partitioning. Default (0, 0) → tile-relative
        // partition (production single-tile path), byte-identical to
        // pre-v6-alpha3 output.
        tileOriginX: Int = 0,
        tileOriginY: Int = 0,
        // v6-alpha3 step 6A — geometry trace plumbing.
        tileIndex: Int = 0,
        geometryCollector: GeometryCollector? = nil
    ) async throws -> [J2KCodeBlock] {
        // Force the one-time init of `useNEONHotPath` on this thread
        // before any parallel code-block dispatch. `static let` is
        // already thread-safe (the Swift runtime guards it with a
        // one-time token), so this is not a correctness fix — it just
        // keeps the worker threads from each entering `_dispatch_once`
        // contention on the first fused HT encode.
        _ = HTBlockEncoderConformant.useNEONHotPath

        // Build lightweight block descriptors (no coefficient copy).
        var deferred: [DeferredCodeBlock] = []
        var blockIndex = 0

        for subbands in componentSubbands {
            for info in subbands {
                guard info.width > 0 && info.height > 0 else { continue }
                let imageBitDepth = image.components[info.componentIndex].bitDepth
                let resolutionLevel: Int
                if info.subband == .ll {
                    resolutionLevel = 0
                } else {
                    resolutionLevel = actualLevels - info.level + 1
                }

                let bandKb: Int
                let subbandStepSize: Float
                if config.useReversibleFilter {
                    // Conformant HT path: use the reversible-5/3-safe magnitude
                    // window gain (matches OpenJPH; prevents the deep-LL / RCT
                    // coefficient-overflow data-loss bug). This MUST match the
                    // ε signalled by `writeQCDMarker` for the same subband so
                    // the per-block `mag << (31 - K_max)` shift and the decoder
                    // agree.
                    let gainExponent: Int
                    let rctActive = config.useReversibleFilter && image.components.count >= 3
                    gainExponent = Self.htConformantReversibleGain(
                        subband: info.subband, rctActive: rctActive)
                    bandKb = imageBitDepth + gainExponent + guardBits - 1
                    subbandStepSize = 1.0  // Identity quantization for lossless
                } else {
                    // Match JPEG 2000 / OpenJPEG detail-band signaling for 9/7:
                    // the encoded precision uses gain {0,1,1,2} for LL/HL/LH/HH.
                    let gainExponent: Int
                    switch info.subband {
                    case .ll: gainExponent = 0
                    case .hl, .lh: gainExponent = 1
                    case .hh: gainExponent = 2
                    }
                    let rangeBits = imageBitDepth + gainExponent
                    let step = lossyStepSize(
                        for: info,
                        imageBitDepth: imageBitDepth,
                        componentCount: image.components.count,
                        totalLevels: actualLevels,
                        adaptiveStepSizes: adaptiveStepSizes
                    )
                    let (epsilon, _) = Self.encodeJ2KStepSize(step, rangeBits: rangeBits)
                    bandKb = epsilon + guardBits - 1
                    subbandStepSize = Float(step)
                }

                // For 9/7 lossy with Float DWT output, defer quantization to the
                // block extraction loop (P6 fused quantization). This eliminates
                // the full quantized subband array allocation.
                let hasFloatCoeffs = info.floatCoefficients != nil && !config.useReversibleFilter

                // v6-alpha3 step 6A — canvas-anchored code-block
                // partition per ISO/IEC 15444-1 B.7. The partition
                // is anchored at the band's canvas origin (0, 0);
                // each tile's blocks are those canvas-aligned cells
                // intersecting the tile's band region. For non-zero
                // tile band canvas origin (`tbx0, tby0` per Eq.
                // B-15), the first/last blocks may be partial.
                //
                // For tile origin (0, 0) the formula reduces to the
                // legacy `ceil(bandW / cbW)` cell-count, with all
                // blocks having `originX == bx * cbW` — single-tile
                // bytes are byte-identical to v5.38 / v5.39 / v6-alpha2.
                let bandDepth: Int
                if info.subband == .ll { bandDepth = actualLevels }
                else { bandDepth = info.level }
                let div  = 1 << bandDepth
                let half = bandDepth >= 1 ? (1 << (bandDepth - 1)) : 0
                let xOff = (info.subband == .hl || info.subband == .hh) ? half : 0
                let yOff = (info.subband == .lh || info.subband == .hh) ? half : 0
                let tbx0 = Self.ceilDivIntegerOrigin(tileOriginX - xOff, div)
                let tby0 = Self.ceilDivIntegerOrigin(tileOriginY - yOff, div)

                // floor(tbx0 / cbW) for non-negative tbx0 (which is
                // always the case here: spec band canvas origins are
                // non-negative for non-negative tile origins because
                // tile origins are J2KSwift-non-negative).
                let firstCanvasX = tbx0 / cbWidth
                let firstCanvasY = tby0 / cbHeight
                let lastCanvasX = (tbx0 + info.width  + cbWidth  - 1) / cbWidth
                let lastCanvasY = (tby0 + info.height + cbHeight - 1) / cbHeight
                let blocksX = lastCanvasX - firstCanvasX
                let blocksY = lastCanvasY - firstCanvasY

                deferred.reserveCapacity(deferred.count + blocksX * blocksY)
                // v6-alpha3 step 6A — accumulate per-band pending-block
                // geometry for the trace collector if one was supplied.
                var traceBlocks: [GeometryPendingBlock] = []
                if geometryCollector != nil {
                    traceBlocks.reserveCapacity(blocksX * blocksY)
                }
                for by in 0..<blocksY {
                    let canvasStartY = (firstCanvasY + by) * cbHeight
                    let canvasEndY   = canvasStartY + cbHeight
                    let tileStartY   = max(0, canvasStartY - tby0)
                    let tileEndY     = min(info.height, canvasEndY - tby0)
                    let blockH       = tileEndY - tileStartY
                    for bx in 0..<blocksX {
                        let canvasStartX = (firstCanvasX + bx) * cbWidth
                        let canvasEndX   = canvasStartX + cbWidth
                        let tileStartX   = max(0, canvasStartX - tbx0)
                        let tileEndX     = min(info.width, canvasEndX - tbx0)
                        let blockW       = tileEndX - tileStartX

                        deferred.append(DeferredCodeBlock(
                            index: blockIndex,
                            // x/y are tag-tree cell coordinates (so
                            // `writePacket`'s `block.x / cbW` formula
                            // gives the right tag-tree dim).
                            x: bx * cbWidth,
                            y: by * cbHeight,
                            width: blockW,
                            height: blockH,
                            subband: info.subband,
                            componentIndex: info.componentIndex,
                            resolutionLevel: resolutionLevel,
                            bitDepth: bandKb,
                            subbandCoefficients: info.coefficients,
                            subbandWidth: info.width,
                            // originX/Y are the tile-band-relative
                            // extraction coordinates (where the
                            // encoder reads the block's coefficients
                            // from `info.coefficients`).
                            originX: tileStartX,
                            originY: tileStartY,
                            floatSubbandCoefficients: hasFloatCoeffs ? info.floatCoefficients : nil,
                            quantizationStep: subbandStepSize
                        ))
                        if geometryCollector != nil {
                            traceBlocks.append(GeometryPendingBlock(
                                x: bx * cbWidth, y: by * cbHeight,
                                width: blockW, height: blockH,
                                originX: tileStartX, originY: tileStartY))
                        }
                        blockIndex += 1
                    }
                }

                if let collector = geometryCollector {
                    collector.addBand(GeometryBand(
                        tileIndex: tileIndex,
                        componentIndex: info.componentIndex,
                        dwtLevel: info.level,
                        subband: info.subband,
                        resolutionLevel: resolutionLevel,
                        bandWidth: info.width,
                        bandHeight: info.height,
                        codeBlockWidth: cbWidth,
                        codeBlockHeight: cbHeight,
                        blocksX: blocksX,
                        blocksY: blocksY,
                        pendingBlocks: traceBlocks))
                }
            }
        }

        if profiling {
            let t = CFAbsoluteTimeGetCurrent()
            print("    PROFILE htj2k-descriptors: \(deferred.count) blocks in \(String(format: "%.4f", t - entropyStart))s")
        }

        // Parallel encode with fused coefficient extraction.
        let totalBlocks = deferred.count
        guard totalBlocks > 0 else { return [] }

        // v6-alpha6 phase 1.3 — GPU forward HT entropy gate.
        // Routes the entire entropy stage to a batched GPU classify
        // + CPU emit path when:
        //   - opt-in flag is set (env var or programmatic)
        //   - block format is conformant (the only format the GPU
        //     classifier targets)
        //   - lossless reversible path (Phase 0 plan §8 non-goal: lossy parked)
        //   - block count ≥ threshold (256 default — see Phase 0.5
        //     dispatch-probe data; below this dispatch overhead
        //     dominates)
        //   - Metal is available
        //
        // When any predicate is false, falls through to the existing
        // CPU path (telemetry records the skip reason). Production
        // default is unchanged (`_gpuForwardHTEntropyEnabled = false`).
        let _override = Self._maxEncodeWorkersOverride
        let maxConcurrency = _override > 0 ? _override
            : (config.maxThreads > 0 ? config.maxThreads : ProcessInfo.processInfo.processorCount)
        // Only use parallel dispatch when there are enough blocks to amortize
        // the GCD overhead and per-chunk buffer allocations. For small images
        // with ≤2× the core count of blocks, the sequential path (single set
        // of reusable allocations) is faster.
        let parallelThreshold = max(4, maxConcurrency * 2)
        let useParallel = config.enableParallelCodeBlocks && totalBlocks >= parallelThreshold

        let encodeStart = CFAbsoluteTimeGetCurrent()
        let allCodeBlocks: [J2KCodeBlock]

        if useParallel {
            let chunkSize = max(1, totalBlocks / maxConcurrency)
            let chunks = stride(from: 0, to: totalBlocks, by: chunkSize).map { start in
                let end = min(start + chunkSize, totalBlocks)
                return start..<end
            }

            let maxBlockSize = cbWidth * cbHeight
            let isLossless = config.lossless
            let pipeline = self
            let capturedDeferred = deferred

            allCodeBlocks = try await withThrowingTaskGroup(
                of: [(Int, J2KCodeBlock)].self
            ) { group in
                for range in chunks {
                    group.addTask {
                        var localResults: [(Int, J2KCodeBlock)] = []
                        localResults.reserveCapacity(range.count)

                        // Per-chunk reusable resources
                        var coeffsBuffer = [Int32](repeating: 0, count: maxBlockSize)
                        var absMags = [Int32](repeating: 0, count: maxBlockSize)
                        var sigPacked = [UInt64](repeating: 0, count: (maxBlockSize + 63) / 64)
                        let maxRefBytes = max(4, (maxBlockSize * 2 + 7) / 8)
                        var sigPropWriter = HTFastBitWriter(capacity: maxRefBytes)
                        var magRefWriter = HTFastBitWriter(capacity: maxRefBytes)
                        var mel = HTMELCoder(capacity: max(16, maxBlockSize / 4))
                        var vlc = HTVLCCoder(capacity: max(16, maxBlockSize / 2))
                        var magsgn = HTMagSgnCoder(capacity: max(16, maxBlockSize * 10 / 8))
                        // v5.38 M8: pre-allocate the Part-15 conformant
                        // entropy encoders so their internal `[UInt8]`
                        // buffers grow once and stabilise instead of
                        // allocating fresh per block.
                        var cMagsgn = HTMagSgnEncoderConformant()
                        var cMel = HTMELEncoderConformant()
                        var cVlc = HTReverseBitEmitterConformant()
                        // v5.38 M9: reusable [UInt32] buffer for the
                        // sign-magnitude conversion fed to the
                        // conformant encoder. Sized to maxBlockSize so
                        // the inner resize check skips re-allocation
                        // for full-size blocks (the common case).
                        var cInBuf = [UInt32](repeating: 0, count: maxBlockSize)
                        // v9.1 Phase 2d: per-worker raw-pointer engine
                        // buffers. Allocated once per worker scope.
                        let _useRawEngines = Self._rawPointerEnginesEnabled
                        let _rawCap = Self._rawEngineBufferCapacity
                        let _rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        let _rawMelBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        let _rawVlcBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        // v9.5 Phase 5E: per-worker NEON output buffers.
                        // Same 16 KB capacity as raw engines (HT spec
                        // bound). Allocated only when the NEON hot path
                        // is enabled; same lifetime as the worker scope
                        // (deallocated below).
                        let _useNEON = HTBlockEncoderConformant.useNEONHotPath
                        let _neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        let _neonMelBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        let _neonVlcBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                            ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                        defer {
                            _rawMagsgnBuf?.deallocate()
                            _rawMelBuf?.deallocate()
                            _rawVlcBuf?.deallocate()
                            _neonMagsgnBuf?.deallocate()
                            _neonMelBuf?.deallocate()
                            _neonVlcBuf?.deallocate()
                        }

                        for i in range {
                            let d = capturedDeferred[i]

                            let blockSize = d.width * d.height
                            var sqSum: Double = 0
                            var bpPop: [Int] = []
                            var distortionFused = false
                            if let floatCoeffs = d.floatSubbandCoefficients {
                                let invStep = 1.0 / d.quantizationStep
                                let totalBitPlanes = d.bitDepth
                                bpPop = [Int](repeating: 0, count: totalBitPlanes)
                                floatCoeffs.withUnsafeBufferPointer { src in
                                    coeffsBuffer.withUnsafeMutableBufferPointer { dst in
                                        // Degenerate / empty block — skip;
                                        // coeffsBuffer stays zero-filled.
                                        guard let dstBase = dst.baseAddress,
                                              let srcBase = src.baseAddress else { return }
                                        for row in 0..<d.height {
                                            let srcRow = (d.originY + row) * d.subbandWidth + d.originX
                                            let dstRow = row * d.width
                                            for col in 0..<d.width {
                                                let coeff = srcBase[srcRow + col]
                                                let mag = Int32(abs(coeff) * invStep)
                                                dstBase[dstRow + col] = coeff >= 0 ? mag : -mag
                                                sqSum += Double(mag) * Double(mag)
                                                if mag > 0 {
                                                    let msb = 31 &- Int(UInt32(mag).leadingZeroBitCount)
                                                    if msb < totalBitPlanes { bpPop[msb] += 1 }
                                                }
                                            }
                                        }
                                    }
                                }
                                distortionFused = true
                            } else {
                            d.subbandCoefficients.withUnsafeBufferPointer { src in
                                coeffsBuffer.withUnsafeMutableBufferPointer { dst in
                                    // Degenerate / empty block — skip;
                                    // coeffsBuffer stays zero-filled.
                                    guard let srcBase = src.baseAddress,
                                          let dstBase = dst.baseAddress else { return }
                                    for row in 0..<d.height {
                                        let srcStart = (d.originY + row) * d.subbandWidth + d.originX
                                        memcpy(
                                            dstBase + row * d.width,
                                            srcBase + srcStart,
                                            d.width * MemoryLayout<Int32>.size
                                        )
                                    }
                                }
                            }
                            } // end else (Int32 extraction)

                            if !isLossless && !distortionFused {
                                #if canImport(Accelerate)
                                if blockSize >= 16 {
                                    coeffsBuffer.withUnsafeBufferPointer { ptr in
                                        var absF = [Float](unsafeUninitializedCapacity: blockSize) { buf, count in
                                            vDSP_vflt32(ptr.baseAddress!, 1, buf.baseAddress!, 1, vDSP_Length(blockSize))
                                            count = blockSize
                                        }
                                        vDSP_vabs(absF, 1, &absF, 1, vDSP_Length(blockSize))
                                        var dotResult: Float = 0
                                        vDSP_dotpr(absF, 1, absF, 1, &dotResult, vDSP_Length(blockSize))
                                        sqSum = Double(dotResult)
                                    }
                                } else {
                                    for j in 0..<blockSize { sqSum += Double(coeffsBuffer[j]) * Double(coeffsBuffer[j]) }
                                }
                                #else
                                for j in 0..<blockSize {
                                    let v = Double(abs(coeffsBuffer[j]))
                                    sqSum += v * v
                                }
                                #endif

                                let totalBitPlanes = d.bitDepth
                                bpPop = [Int](repeating: 0, count: totalBitPlanes)
                                for j in 0..<blockSize {
                                    let mag = UInt32(abs(coeffsBuffer[j]))
                                    if mag > 0 {
                                        let msb = 31 - mag.leadingZeroBitCount
                                        if msb < totalBitPlanes { bpPop[msb] += 1 }
                                    }
                                }
                            }

                            let blockCoeffs = Array(coeffsBuffer[0..<blockSize])

                            let pending = PendingCodeBlock(
                                index: d.index, x: d.x, y: d.y,
                                width: d.width, height: d.height,
                                subband: d.subband,
                                componentIndex: d.componentIndex,
                                resolutionLevel: d.resolutionLevel,
                                coefficients: blockCoeffs,
                                bitDepth: d.bitDepth,
                                coefficientSquaredSum: sqSum,
                                bitPlanePopulation: bpPop
                            )

                            let codeBlock = try pipeline.encodeCodeBlockHTJ2KFast(
                                pending,
                                absMags: &absMags,
                                sigPacked: &sigPacked,
                                sigPropWriter: &sigPropWriter,
                                magRefWriter: &magRefWriter,
                                mel: &mel,
                                vlc: &vlc,
                                magsgn: &magsgn,
                                conformantMagsgn: &cMagsgn,
                                conformantMel: &cMel,
                                conformantVlc: &cVlc,
                                conformantInBuf: &cInBuf,
                                useSIMDClassification: Self._htSIMDClassificationEnabled,
                                rawMagsgnBuf: _rawMagsgnBuf,
                                rawMelBuf: _rawMelBuf,
                                rawVlcBuf: _rawVlcBuf,
                                neonMagsgnBuf: _neonMagsgnBuf,
                                neonMelBuf: _neonMelBuf,
                                neonVlcBuf: _neonVlcBuf
                            )
                            localResults.append((d.index, codeBlock))
                        }

                        return localResults
                    }
                }

                var combined: [(Int, J2KCodeBlock)] = []
                combined.reserveCapacity(totalBlocks)
                for try await chunkResults in group {
                    combined.append(contentsOf: chunkResults)
                }
                return combined
            }.sorted { $0.0 < $1.0 }.map { $0.1 }
        } else {
            // Sequential path
            var results: [J2KCodeBlock] = []
            results.reserveCapacity(totalBlocks)

            let maxBlockSize = cbWidth * cbHeight
            var coeffsBuffer = [Int32](repeating: 0, count: maxBlockSize)
            var absMags = [Int32](repeating: 0, count: maxBlockSize)
            var sigPacked = [UInt64](repeating: 0, count: (maxBlockSize + 63) / 64)
            let maxRefBytes = max(4, (maxBlockSize * 2 + 7) / 8)
            var sigPropWriter = HTFastBitWriter(capacity: maxRefBytes)
            var magRefWriter = HTFastBitWriter(capacity: maxRefBytes)
            var mel = HTMELCoder(capacity: max(16, maxBlockSize / 4))
            var vlc = HTVLCCoder(capacity: max(16, maxBlockSize / 2))
            var magsgn = HTMagSgnCoder(capacity: max(16, maxBlockSize * 10 / 8))
            // v5.38 M8: pre-allocated conformant entropy encoders.
            var cMagsgn = HTMagSgnEncoderConformant()
            var cMel = HTMELEncoderConformant()
            var cVlc = HTReverseBitEmitterConformant()
            // v5.38 M9: reusable [UInt32] sign-magnitude buffer.
            var cInBuf = [UInt32](repeating: 0, count: maxBlockSize)
            // v9.1 Phase 2d: pre-allocate raw-pointer engine buffers
            // ONCE per worker scope; reused across all blocks processed
            // by this worker. Eliminates per-block buffer alloc when
            // `_rawPointerEnginesEnabled` is set. The buffers are owned
            // by this scope and freed via `defer { ... deallocate() }`.
            let _useRawEngines = Self._rawPointerEnginesEnabled
            let _rawCap = Self._rawEngineBufferCapacity
            let _rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _rawMelBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _rawVlcBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            // v9.5 Phase 5E: per-worker NEON output buffers (sequential).
            let _useNEON = HTBlockEncoderConformant.useNEONHotPath
            let _neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _neonMelBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _neonVlcBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            defer {
                _rawMagsgnBuf?.deallocate()
                _rawMelBuf?.deallocate()
                _rawVlcBuf?.deallocate()
                _neonMagsgnBuf?.deallocate()
                _neonMelBuf?.deallocate()
                _neonVlcBuf?.deallocate()
            }

            let isLossless = config.lossless
            for d in deferred {
                let blockSize = d.width * d.height
                var sqSum: Double = 0
                var bpPop: [Int] = []
                var distortionFused = false
                if let floatCoeffs = d.floatSubbandCoefficients {
                    let invStep = 1.0 / d.quantizationStep
                    let totalBitPlanes = d.bitDepth
                    bpPop = [Int](repeating: 0, count: totalBitPlanes)
                    floatCoeffs.withUnsafeBufferPointer { src in
                        coeffsBuffer.withUnsafeMutableBufferPointer { dst in
                            // Degenerate / empty block — skip;
                            // coeffsBuffer stays zero-filled.
                            guard let dstBase = dst.baseAddress,
                                  let srcBase = src.baseAddress else { return }
                            for row in 0..<d.height {
                                let srcRow = (d.originY + row) * d.subbandWidth + d.originX
                                let dstRow = row * d.width
                                for col in 0..<d.width {
                                    let coeff = srcBase[srcRow + col]
                                    let mag = Int32(abs(coeff) * invStep)
                                    dstBase[dstRow + col] = coeff >= 0 ? mag : -mag
                                    sqSum += Double(mag) * Double(mag)
                                    if mag > 0 {
                                        let msb = 31 &- Int(UInt32(mag).leadingZeroBitCount)
                                        if msb < totalBitPlanes { bpPop[msb] += 1 }
                                    }
                                }
                            }
                        }
                    }
                    distortionFused = true
                } else {
                d.subbandCoefficients.withUnsafeBufferPointer { src in
                    coeffsBuffer.withUnsafeMutableBufferPointer { dst in
                        // Degenerate / empty block — skip;
                        // coeffsBuffer stays zero-filled.
                        guard let srcBase = src.baseAddress,
                              let dstBase = dst.baseAddress else { return }
                        for row in 0..<d.height {
                            let srcStart = (d.originY + row) * d.subbandWidth + d.originX
                            memcpy(
                                dstBase + row * d.width,
                                srcBase + srcStart,
                                d.width * MemoryLayout<Int32>.size
                            )
                        }
                    }
                }
                } // end else (Int32 extraction)

                // Compute distortion stats for lossy rate control (skip if already fused above)
                if !isLossless && !distortionFused {
                    #if canImport(Accelerate)
                    if blockSize >= 16 {
                        coeffsBuffer.withUnsafeBufferPointer { ptr in
                            var absF = [Float](unsafeUninitializedCapacity: blockSize) { buf, count in
                                vDSP_vflt32(ptr.baseAddress!, 1, buf.baseAddress!, 1, vDSP_Length(blockSize))
                                count = blockSize
                            }
                            vDSP_vabs(absF, 1, &absF, 1, vDSP_Length(blockSize))
                            var dotResult: Float = 0
                            vDSP_dotpr(absF, 1, absF, 1, &dotResult, vDSP_Length(blockSize))
                            sqSum = Double(dotResult)
                        }
                    } else {
                        for j in 0..<blockSize { sqSum += Double(coeffsBuffer[j]) * Double(coeffsBuffer[j]) }
                    }
                    #else
                    for j in 0..<blockSize {
                        let v = Double(abs(coeffsBuffer[j]))
                        sqSum += v * v
                    }
                    #endif

                    let totalBitPlanes = d.bitDepth
                    bpPop = [Int](repeating: 0, count: totalBitPlanes)
                    for j in 0..<blockSize {
                        let mag = UInt32(abs(coeffsBuffer[j]))
                        if mag > 0 {
                            let msb = 31 - mag.leadingZeroBitCount
                            if msb < totalBitPlanes { bpPop[msb] += 1 }
                        }
                    }
                }

                let blockCoeffs = Array(coeffsBuffer[0..<blockSize])

                let pending = PendingCodeBlock(
                    index: d.index, x: d.x, y: d.y,
                    width: d.width, height: d.height,
                    subband: d.subband,
                    componentIndex: d.componentIndex,
                    resolutionLevel: d.resolutionLevel,
                    coefficients: blockCoeffs,
                    bitDepth: d.bitDepth,
                    coefficientSquaredSum: sqSum,
                    bitPlanePopulation: bpPop
                )

                let codeBlock = try encodeCodeBlockHTJ2KFast(
                    pending,
                    absMags: &absMags,
                    sigPacked: &sigPacked,
                    sigPropWriter: &sigPropWriter,
                    magRefWriter: &magRefWriter,
                    mel: &mel,
                    vlc: &vlc,
                    magsgn: &magsgn,
                    conformantMagsgn: &cMagsgn,
                    conformantMel: &cMel,
                    conformantVlc: &cVlc,
                    conformantInBuf: &cInBuf,
                    useSIMDClassification: Self._htSIMDClassificationEnabled,
                    rawMagsgnBuf: _rawMagsgnBuf,
                    rawMelBuf: _rawMelBuf,
                    rawVlcBuf: _rawVlcBuf,
                    neonMagsgnBuf: _neonMagsgnBuf,
                    neonMelBuf: _neonMelBuf,
                    neonVlcBuf: _neonVlcBuf
                )
                results.append(codeBlock)
            }
            allCodeBlocks = results
        }

        if profiling {
            let encodeEnd = CFAbsoluteTimeGetCurrent()
            print("    PROFILE htj2k-encode: \(String(format: "%.4f", encodeEnd - encodeStart))s (parallel=\(useParallel), blocks=\(totalBlocks))")
        }

        return allCodeBlocks
    }

    /// Encodes code-blocks sequentially.
    ///
    /// Dispatches to HTJ2K FBCOT block coding when `config.useHTJ2K` is true,
    /// otherwise uses legacy EBCOT bit-plane coding.
    private func encodeCodeBlocksSequential(
        _ pendingBlocks: [PendingCodeBlock]
    ) throws -> [J2KCodeBlock] {
        var results: [J2KCodeBlock] = []
        results.reserveCapacity(pendingBlocks.count)

        if config.useHTJ2K {
            // HTJ2K fast path: pre-allocate reusable arrays + writers
            let maxBlockSize = config.codeBlockSize.width * config.codeBlockSize.height
            var absMags = [Int32](repeating: 0, count: maxBlockSize)
            var sigPacked = [UInt64](repeating: 0, count: (maxBlockSize + 63) / 64)
            let maxRefBytes = max(4, (maxBlockSize * 2 + 7) / 8)
            var sigPropWriter = HTFastBitWriter(capacity: maxRefBytes)
            var magRefWriter = HTFastBitWriter(capacity: maxRefBytes)
            var mel = HTMELCoder(capacity: max(16, maxBlockSize / 4))
            var vlc = HTVLCCoder(capacity: max(16, maxBlockSize / 2))
            var magsgn = HTMagSgnCoder(capacity: max(16, maxBlockSize * 10 / 8))
            // v5.38 M8: pre-allocated conformant entropy encoders.
            var cMagsgn = HTMagSgnEncoderConformant()
            var cMel = HTMELEncoderConformant()
            var cVlc = HTReverseBitEmitterConformant()
            // v5.38 M9: reusable [UInt32] sign-magnitude buffer.
            var cInBuf = [UInt32](repeating: 0, count: maxBlockSize)
            // v9.1 Phase 2d: per-worker raw-pointer engine buffers.
            let _useRawEngines = Self._rawPointerEnginesEnabled
            let _rawCap = Self._rawEngineBufferCapacity
            let _rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _rawMelBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _rawVlcBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            // v9.5 Phase 5E: per-worker NEON output buffers (sequential HT).
            let _useNEON = HTBlockEncoderConformant.useNEONHotPath
            let _neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _neonMelBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            let _neonVlcBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
            defer {
                _rawMagsgnBuf?.deallocate()
                _rawMelBuf?.deallocate()
                _rawVlcBuf?.deallocate()
                _neonMagsgnBuf?.deallocate()
                _neonMelBuf?.deallocate()
                _neonVlcBuf?.deallocate()
            }

            for pending in pendingBlocks {
                let codeBlock = try encodeCodeBlockHTJ2KFast(
                    pending,
                    absMags: &absMags,
                    sigPacked: &sigPacked,
                    sigPropWriter: &sigPropWriter,
                    magRefWriter: &magRefWriter,
                    mel: &mel,
                    vlc: &vlc,
                    magsgn: &magsgn,
                    conformantMagsgn: &cMagsgn,
                    conformantMel: &cMel,
                    conformantVlc: &cVlc,
                    conformantInBuf: &cInBuf,
                    useSIMDClassification: Self._htSIMDClassificationEnabled,
                    rawMagsgnBuf: _rawMagsgnBuf,
                    rawMelBuf: _rawMelBuf,
                    rawVlcBuf: _rawVlcBuf,
                    neonMagsgnBuf: _neonMagsgnBuf,
                    neonMelBuf: _neonMelBuf,
                    neonVlcBuf: _neonVlcBuf
                )
                results.append(codeBlock)
            }
        } else {
            // Legacy path: use EBCOT bit-plane coding with pre-allocated scratch buffers
            let encoder = CodeBlockEncoder()
            let maxBlockSize = config.codeBlockSize.width * config.codeBlockSize.height
            let scratch = EBCOTScratchBuffers(maxSize: maxBlockSize)
            let componentCount = max(1, Set(pendingBlocks.map(\.componentIndex)).count)
            let maxPassesLimit = recommendedEBCOTPassLimit(componentCount: componentCount)
            for pending in pendingBlocks {
                var codeBlock = try encoder.encode(
                    coefficients: pending.coefficients,
                    width: pending.width,
                    height: pending.height,
                    subband: pending.subband,
                    bitDepth: pending.bitDepth,
                    options: standardEBCOTCodingOptions,
                    maxPasses: maxPassesLimit,
                    scratch: scratch,
                    collectRateControlMetrics: false
                )

                codeBlock = J2KCodeBlock(
                    index: pending.index,
                    x: pending.x,
                    y: pending.y,
                    width: pending.width,
                    height: pending.height,
                    subband: codeBlock.subband,
                    componentIndex: pending.componentIndex,
                    resolutionLevel: pending.resolutionLevel,
                    data: codeBlock.data,
                    passeCount: codeBlock.passeCount,
                    zeroBitPlanes: codeBlock.zeroBitPlanes,
                    passSegmentLengths: codeBlock.passSegmentLengths,
                    cumulativePassBytes: codeBlock.cumulativePassBytes,
                    coefficientSquaredSum: pending.coefficientSquaredSum,
                    bitPlanePopulation: pending.bitPlanePopulation,
                    cumulativePassDistortion: codeBlock.cumulativePassDistortion,
                    perPassSnapshotData: codeBlock.perPassSnapshotData,
                    mqCheckpoints: codeBlock.mqCheckpoints,
                    rawMQOutput: codeBlock.rawMQOutput
                )

                results.append(codeBlock)
            }
        }

        return results
    }

    /// Encodes code-blocks in parallel using coarse-grained chunk workers.
    ///
    /// Each worker owns its own MQ/HT state and scratch buffers and processes a
    /// contiguous index range. This avoids one-task-per-block overhead, reduces
    /// ARC churn, and provides deterministic output ordering.
    private func encodeCodeBlocksParallel(
        _ pendingBlocks: [PendingCodeBlock]
    ) async throws -> [J2KCodeBlock] {
        let maxConcurrency = config.maxThreads > 0 ? config.maxThreads : ProcessInfo.processInfo.activeProcessorCount
        return try encodeCodeBlocksParallel(blocks: pendingBlocks, maxConcurrency: maxConcurrency)
    }

    /// Synchronous Tier-1 worker scheduler used by the async pipeline entry point.
    private func encodeCodeBlocksParallel(
        blocks pendingBlocks: [PendingCodeBlock],
        maxConcurrency: Int
    ) throws -> [J2KCodeBlock] {
        let totalBlocks = pendingBlocks.count
        guard totalBlocks > 0 else { return [] }

        let chunkPlan = Tier1ChunkPlan(totalBlocks: totalBlocks, maxConcurrency: maxConcurrency)
        let useHT = config.useHTJ2K
        let cbW = config.codeBlockSize.width
        let cbH = config.codeBlockSize.height
        let pipeline = self
        let componentCount = max(1, Set(pendingBlocks.map(\.componentIndex)).count)
        let maxPassesLimit = recommendedEBCOTPassLimit(componentCount: componentCount)
        let orderedResults = Tier1ResultBuffer<J2KCodeBlock>(count: totalBlocks)

        let encodeRange: @Sendable (Range<Int>) throws -> Void = { range in
            if useHT {
                let maxBlockSize = cbW * cbH
                var absMags = [Int32](repeating: 0, count: maxBlockSize)
                var sigPacked = [UInt64](repeating: 0, count: (maxBlockSize + 63) / 64)
                let maxRefBytes = max(4, (maxBlockSize * 2 + 7) / 8)
                var sigPropWriter = HTFastBitWriter(capacity: maxRefBytes)
                var magRefWriter = HTFastBitWriter(capacity: maxRefBytes)
                var mel = HTMELCoder(capacity: max(16, maxBlockSize / 4))
                var vlc = HTVLCCoder(capacity: max(16, maxBlockSize / 2))
                var magsgn = HTMagSgnCoder(capacity: max(16, maxBlockSize * 10 / 8))
                // v5.38 M8: pre-allocated conformant entropy encoders.
                var cMagsgn = HTMagSgnEncoderConformant()
                var cMel = HTMELEncoderConformant()
                var cVlc = HTReverseBitEmitterConformant()
                // v5.38 M9: reusable [UInt32] sign-magnitude buffer.
                var cInBuf = [UInt32](repeating: 0, count: maxBlockSize)
                // v9.1 Phase 2d: per-worker raw-pointer engine buffers.
                let _useRawEngines = Self._rawPointerEnginesEnabled
                let _rawCap = Self._rawEngineBufferCapacity
                let _rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                let _rawMelBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                let _rawVlcBuf: UnsafeMutablePointer<UInt8>? = _useRawEngines
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                // v9.5 Phase 5E: per-worker NEON output buffers (parallel HT).
                let _useNEON = HTBlockEncoderConformant.useNEONHotPath
                let _neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                let _neonMelBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                let _neonVlcBuf: UnsafeMutablePointer<UInt8>? = _useNEON
                    ? UnsafeMutablePointer<UInt8>.allocate(capacity: _rawCap) : nil
                defer {
                    _rawMagsgnBuf?.deallocate()
                    _rawMelBuf?.deallocate()
                    _rawVlcBuf?.deallocate()
                    _neonMagsgnBuf?.deallocate()
                    _neonMelBuf?.deallocate()
                    _neonVlcBuf?.deallocate()
                }

                for index in range {
                    let pending = pendingBlocks[index]
                    let codeBlock = try pipeline.encodeCodeBlockHTJ2KFast(
                        pending,
                        absMags: &absMags,
                        sigPacked: &sigPacked,
                        sigPropWriter: &sigPropWriter,
                        magRefWriter: &magRefWriter,
                        mel: &mel,
                        vlc: &vlc,
                        magsgn: &magsgn,
                        conformantMagsgn: &cMagsgn,
                        conformantMel: &cMel,
                        conformantVlc: &cVlc,
                        conformantInBuf: &cInBuf,
                        useSIMDClassification: Self._htSIMDClassificationEnabled,
                        rawMagsgnBuf: _rawMagsgnBuf,
                        rawMelBuf: _rawMelBuf,
                        rawVlcBuf: _rawVlcBuf,
                        neonMagsgnBuf: _neonMagsgnBuf,
                        neonMelBuf: _neonMelBuf,
                        neonVlcBuf: _neonVlcBuf
                    )
                    orderedResults.write(codeBlock, at: pending.index)
                }
            } else {
                let encoder = CodeBlockEncoder()
                let maxBlockSize = cbW * cbH
                let scratch = EBCOTScratchBuffers(maxSize: maxBlockSize)

                for index in range {
                    let pending = pendingBlocks[index]
                    var codeBlock = try encoder.encode(
                        coefficients: pending.coefficients,
                        width: pending.width,
                        height: pending.height,
                        subband: pending.subband,
                        bitDepth: pending.bitDepth,
                        options: standardEBCOTCodingOptions,
                        maxPasses: maxPassesLimit,
                        scratch: scratch,
                        collectRateControlMetrics: false
                    )

                    codeBlock = J2KCodeBlock(
                        index: pending.index,
                        x: pending.x,
                        y: pending.y,
                        width: pending.width,
                        height: pending.height,
                        subband: codeBlock.subband,
                        componentIndex: pending.componentIndex,
                        resolutionLevel: pending.resolutionLevel,
                        data: codeBlock.data,
                        passeCount: codeBlock.passeCount,
                        zeroBitPlanes: codeBlock.zeroBitPlanes,
                        passSegmentLengths: codeBlock.passSegmentLengths,
                        cumulativePassBytes: codeBlock.cumulativePassBytes,
                        coefficientSquaredSum: pending.coefficientSquaredSum,
                        bitPlanePopulation: pending.bitPlanePopulation,
                        cumulativePassDistortion: codeBlock.cumulativePassDistortion,
                        perPassSnapshotData: codeBlock.perPassSnapshotData,
                        mqCheckpoints: codeBlock.mqCheckpoints,
                        rawMQOutput: codeBlock.rawMQOutput
                    )

                    orderedResults.write(codeBlock, at: pending.index)
                }
            }
        }

        #if canImport(Dispatch)
        if chunkPlan.workerCount > 1 {
            DispatchQueue.global(qos: .userInteractive).sync {
                DispatchQueue.concurrentPerform(iterations: chunkPlan.workerCount) { workerIndex in
                    if orderedResults.firstError != nil { return }
                    guard let range = chunkPlan.range(for: workerIndex, totalBlocks: totalBlocks) else { return }

                    autoreleasepool {
                        do {
                            try encodeRange(range)
                        } catch {
                            orderedResults.recordError(error)
                        }
                    }
                }
            }
            return try orderedResults.materialize()
        }
        #endif

        try encodeRange(0..<totalBlocks)
        return try orderedResults.materialize()
    }

    /// Estimates the effective total target bitrate used for HT refinement truncation.
    ///
    /// This keeps HTJ2K from spending CPU on very deep tail bit-planes that the
    /// final PCRD pass will almost certainly discard at lower rates.
    private func effectiveHTTargetBitsPerPixel() -> Double {
        switch config.bitrateMode {
        case .constantBitrate(let bitsPerPixel):
            return max(0.05, bitsPerPixel)
        case .variableBitrate(_, let maxBitsPerPixel):
            return max(0.05, maxBitsPerPixel)
        case .constantQuality:
            let quality = max(0.0, min(1.0, config.quality))
            if quality >= 0.95 { return 2.0 }
            if quality >= 0.80 { return 1.2 }
            if quality >= 0.50 { return 0.7 }
            if quality >= 0.20 { return 0.35 }
            return 0.18
        case .lossless:
            return Double.greatestFiniteMagnitude
        case .fixedQstep, .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            // Fixed-qstep modes include every block; HT refinement cap
            // is irrelevant since rate control is bypassed.
            return Double.greatestFiniteMagnitude
        }
    }

    /// Recommends how many HT refinement bit-planes to emit for a block.
    ///
    /// Lossy HTJ2K quality is dominated by the upper refinement planes; the
    /// deepest tail planes often add bytes and CPU with negligible value. Bias
    /// the cap toward LL and high-energy blocks while trimming low-value tails.
    private func recommendedHTRefinementPlanes(for pending: PendingCodeBlock, topBitPlane: Int) -> Int {
        guard topBitPlane > 0 else { return 0 }
        guard !config.lossless else { return topBitPlane }

        let targetBitsPerPixel = effectiveHTTargetBitsPerPixel()
        var planeLimit: Int
        switch targetBitsPerPixel {
        case ..<0.35:
            planeLimit = 4
        case ..<0.75:
            planeLimit = 5
        case ..<1.25:
            planeLimit = 6
        case ..<2.0:
            planeLimit = 8
        default:
            planeLimit = topBitPlane
        }

        if config.useReversibleFilter {
            planeLimit += 1
        }

        switch pending.subband {
        case .ll:
            planeLimit += (config.useReversibleFilter && targetBitsPerPixel <= 1.0) ? 2 : 1
        case .hh:
            planeLimit -= (config.useReversibleFilter && targetBitsPerPixel <= 1.0) ? 2 : 1
        case .hl, .lh:
            if config.useReversibleFilter && targetBitsPerPixel <= 1.0 {
                planeLimit -= 1
            }
        }

        let sampleCount = max(1, pending.width * pending.height)
        let meanEnergy = pending.coefficientSquaredSum / Double(sampleCount)
        if meanEnergy > 4096 {
            planeLimit += 1
        } else if meanEnergy < 64 {
            planeLimit -= 1
        }

        return min(topBitPlane, max(2, planeLimit))
    }

    // MARK: - HTJ2K Block Encoding

    /// Encodes a single code-block using HTJ2K FBCOT block coding.
    ///
    /// Converts the pipeline's Int32 coefficients to the HTBlockEncoder's Int interface,
    /// runs the HT cleanup + refinement passes, and wraps the result in a `J2KCodeBlock`
    /// that is compatible with the rest of the encoding pipeline (rate control, Tier-2,
    /// codestream generation).
    ///
    /// - Parameter pending: The pending code-block with coefficients and metadata.
    /// - Returns: A `J2KCodeBlock` with HT-encoded data.
    /// - Throws: ``J2KError/encodingError(_:)`` if HT encoding fails.
    private func encodeCodeBlockHTJ2K(_ pending: PendingCodeBlock) throws -> J2KCodeBlock {
        return try encodeCodeBlockConformant(pending)
    }

    // MARK: - HTJ2K Fast Block Encoding (Reusing Allocations)

    /// Encodes a single code-block using HTJ2K FBCOT block coding with pre-allocated
    /// scratch arrays and reusable writers.
    ///
    /// This is the fast path called from `encodeCodeBlocksParallel`. It eliminates
    /// per-block allocation of `absMags`, `sigPacked`, and per-refinement-pass
    // MARK: - Part-15 dispatch

    /// Encode one code-block using the Part-15 cleanup-pass coder.
    /// Produces a single-cleanup-pass J2KCodeBlock; SigProp/MagRef
    /// refinement passes are intentionally not emitted (Part-15
    /// scalar is cleanup-only per OpenJPH's scalar path).
    ///
    /// `pending.bitDepth` is J2KSwift's `bandKb = bitDepth + gain +
    /// guardBits - 1`. OpenJPH reads the SAME value from QCD (our
    /// QCD writer emits `SPqcd = bitDepth + gain` without OpenJPH's
    /// `- guardBits` subtraction), so the encoder/decoder shift is
    /// consistent as long as we use `pending.bitDepth` directly.
    private func encodeCodeBlockConformant(_ pending: PendingCodeBlock) throws
        -> J2KCodeBlock
    {
        // v5.38 M8/M9 entry: legacy call site without reusable buffers.
        // Allocates a fresh trio of encoders + conformantIn buffer per
        // call. Internal call sites in the chunk loops use the inout
        // overload below which threads pre-allocated buffers through
        // to amortise their growth across many blocks.
        // v6-alpha6 phase 1.4 — forward the production SIMD toggle so
        // single-block test/diagnostic call sites see the same path
        // production hot loops do.
        var ms = HTMagSgnEncoderConformant()
        var ml = HTMELEncoderConformant()
        var vl = HTReverseBitEmitterConformant()
        var cBuf = [UInt32]()
        return try encodeCodeBlockConformant(
            pending,
            magsgnEnc: &ms, melEnc: &ml, vlcEnc: &vl,
            conformantInBuf: &cBuf,
            useSIMDClassification: Self._htSIMDClassificationEnabled)
    }

    /// v5.39 M1: cached env-var read for SIMD-classification opt-in.
    /// Reading `ProcessInfo.processInfo.environment` per chunk is not
    /// free, so we cache it once at process startup. Values: `1`,
    /// `true`, `yes` enable; anything else (including unset) leaves
    /// the SIMD path off (production default).
    ///
    /// **v6-alpha6 phase 1.4 (approach E) measurement — left default
    /// OFF.** Phase 1.3 measured GPU approach B regressing at every
    /// medical-corpus scale on Apple M2. Phase 1.4 proposed approach
    /// E (CPU-SIMD only) as the production pivot. The empirical
    /// wall-time A/B (`HTApproachECPUSIMDTests.testApproachE_WallTimeAB_AcrossCorpus`)
    /// across the 6-fixture corpus was a **wash**: 4/6 fixtures
    /// within ±3% noise, 1 fixture +10%, 1 fixture −7% in opposite
    /// directions at the same block count. Default left OFF because
    /// no consistent population-level win was demonstrated; the env
    /// var + programmatic flag remain available for per-call A/B and
    /// future cross-device retesting (M3 / M4 / M4 Pro / M4 Max may
    /// shift the SIMD/scalar curve enough to flip the decision).
    ///
    /// Bytes byte-identical to the scalar path (verified by
    /// `HTSIMDIntegrationTests` over a 25K random-block sweep +
    /// `HTSampleInfoSIMDPrototypeTests` over 180K (sample, p)
    /// pairs + `HTApproachECPUSIMDTests.testApproachE_BytesIdentical_AllCorpus`
    /// over the full medical corpus).
    ///
    /// `var` (was `let` before phase 1.4) so tests can A/B without
    /// spawning a subprocess. Initial value is read from the env var
    /// once per process; subsequent test mutations take effect on the
    /// next encode call. Production code never writes to it.
    nonisolated(unsafe) static var _htSIMDClassificationEnabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["J2K_HT_SIMD"] {
            switch v.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: break
            }
        }
        return false
    }()

    /// v9.1 Path B Phase 2c — raw-pointer engine production integration.
    ///
    /// When `true`, `encodeCodeBlockConformant` routes through the
    /// raw-pointer-backed HT block-encoder variant
    /// (HTMagSgnEncoderRawConformant et al.) instead of the Array-
    /// backed variant. This eliminates per-byte `Array.append` ARC +
    /// capacity-grow contention measured at 5× concurrent inflation
    /// on M2 (see V9_1_PHASE_2_BREAKTHROUGH.md).
    ///
    /// Opt-in via env var `J2K_RAW_POINTER_ENGINES=1`. Default OFF
    /// pending A/B medical-corpus benchmark and cross-codec parity
    /// validation. **Codestream is bit-exact** between Array and Raw
    /// paths — verified by V91Phase2cArrayVsRawParityTests (200-trial
    /// random sweep + sparse/dense/non-pow2 block sizes + missingMSBs
    /// sweep). Default-flip gated on ≥3 ms DX wall improvement (v7.4
    /// acceptance discipline).
    nonisolated(unsafe) static var _rawPointerEnginesEnabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["J2K_RAW_POINTER_ENGINES"] {
            switch v.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: break
            }
        }
        return false
    }()

    /// v9.2 Path B Phase 0c — encode worker-count override.
    ///
    /// When `J2K_MAX_ENCODE_WORKERS` is set to a positive integer, that
    /// value is used as the encoder's TaskGroup worker count regardless
    /// of `config.maxThreads` or `processorCount`. Default `0` means "use
    /// the existing logic" (config.maxThreads if > 0, else
    /// processorCount).
    ///
    /// Rationale: M4 has 4P + 6E cores (`processorCount = 10`), but
    /// E-cores deliver only ~30-50% of P-core throughput. Splitting work
    /// into 10 equal chunks creates a long tail where P-core chunks
    /// finish in ~half the time of E-core chunks. Restricting workers
    /// to P-core count alone (4) eliminates the tail at the cost of
    /// some E-core idle time. The empirical sweet spot depends on
    /// fixture size and the per-block work imbalance.
    ///
    /// Probe via:
    ///   `J2K_MAX_ENCODE_WORKERS=4 swift test --filter Encode...`
    ///
    /// 0 = disabled, ≥1 = override. Always-on, no production code path
    /// difference when unset.
    nonisolated(unsafe) static var _maxEncodeWorkersOverride: Int = {
        if let v = ProcessInfo.processInfo.environment["J2K_MAX_ENCODE_WORKERS"],
           let n = Int(v), n >= 1 {
            return n
        }
        return 0
    }()

    // MARK: - v6-alpha6 phase 1.2: GPU forward HT entropy gate
    //
    // Symmetric to the forward 5/3 INT gate above but for the
    // **encode-side HT entropy** stage (the ~45 % of DX wall that
    // v6.0.0 didn't accelerate). Off by default; opt in via env var
    // `J2K_GPU_FORWARD_HT_ENTROPY=1` or programmatic
    // `_gpuForwardHTEntropyEnabled = true`. See
    // `docs/V6_ALPHA6_GPU_FORWARD_HT_ENTROPY_PLAN.md` for the
    // background and `J2KGPUForwardHTEntropyTelemetry` for the
    // observability surface.
    //
    // Phase 1.2 ships the gate + the standalone batched API
    // (`encodeBlockBatchWithGPUClassifier(...)` below). Phase 1.3
    // wires the API through `applyEntropyCodingHTJ2KFused`.

    /// v6-alpha3 step 3: per-tile origin propagation diagnostic.
    /// Off by default; set `J2K_HT_TILE_DEBUG_ORIGINS=1` to print
    /// per-tile origin/dim/level/origin-aware lines from
    /// `EncoderPipeline.encode(...)`. Used to verify that the
    /// multi-tile encoder is actually passing non-zero origins
    /// down to the DWT call (vs. the v6-alpha1/2 wrap-and-stitch
    /// path which always passed (0, 0)).
    static let _htTileDebugOrigins: Bool = {
        if let v = ProcessInfo.processInfo.environment["J2K_HT_TILE_DEBUG_ORIGINS"] {
            switch v.lowercased() {
            case "1", "true", "yes": return true
            default: return false
            }
        }
        return false
    }()

    /// v5.39 M2: HT parallelism experiment selector. The encoder's
    /// per-block (`enableParallelCodeBlocks`) path scales the entropy
    /// stage, but on large fixtures the DWT row pass is still serial
    /// — Amdahl's law caps speedup at ~3× even with 8 cores. This env
    /// gate selects the experimental DWT row-parallel path so it can
    /// be A/B tested without affecting the default code path.
    /// Values: `dwt-row-parallel` enables; anything else (including
    /// unset) means baseline.
    enum HTParallelMode {
        case baseline
        case dwtRowParallel
    }
    static let _htParallelMode: HTParallelMode = {
        if let v = ProcessInfo.processInfo.environment["J2K_HT_PARALLEL_MODE"] {
            switch v.lowercased() {
            case "dwt-row-parallel": return .dwtRowParallel
            default: return .baseline
            }
        }
        return .baseline
    }()

    /// v5.38 M8/M9 — same as `encodeCodeBlockConformant(_:)` but
    /// accepts pre-allocated buffers:
    /// - HT entropy encoders (`magsgnEnc` / `melEnc` / `vlcEnc`) so
    ///   their internal `[UInt8]` byte streams reuse capacity (M8).
    /// - `conformantInBuf: [UInt32]` reusable buffer for the
    ///   sign-magnitude-converted coefficients fed to the encoder.
    ///   Resized in place to fit the current block's `count`. Across
    ///   a 12 MP DX encode this saves ~36 MB of `[UInt32]` allocator
    ///   churn (16 KB × 2300 blocks) (M9).
    ///
    /// Each encoder is `reset()` inside `HTBlockEncoderConformant.encode`
    /// before use, so prior block contents cannot leak into this
    /// output. **Bit-exact equivalent** of the no-arg overload.
    /// Capacity of the per-worker raw-pointer engine output buffers.
    /// HT block output is bounded by the spec; 16 KB per stream is safe
    /// for any 64×64 block at 30-bit precision. Three buffers per
    /// worker (one each for MagSgn, MEL, VLC) → 48 KB worker pool.
    @usableFromInline internal static let _rawEngineBufferCapacity = 16 * 1024

    private func encodeCodeBlockConformant(
        _ pending: PendingCodeBlock,
        magsgnEnc: inout HTMagSgnEncoderConformant,
        melEnc: inout HTMELEncoderConformant,
        vlcEnc: inout HTReverseBitEmitterConformant,
        conformantInBuf: inout [UInt32],
        useSIMDClassification: Bool,
        // v9.1 Phase 2d: optional pre-allocated raw-pointer engine
        // buffers, owned by the caller's worker scope. When non-nil
        // AND `_rawPointerEnginesEnabled == true`, the encode routes
        // through the raw-pointer engine variant using these buffers;
        // each is fresh-initialised per call via lightweight raw-engine
        // constructors (no allocation in the hot path). When nil, the
        // function falls back to per-call buffer allocation (initial
        // Phase 2c integration) which still works correctly.
        rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = nil,
        rawMelBuf: UnsafeMutablePointer<UInt8>? = nil,
        rawVlcBuf: UnsafeMutablePointer<UInt8>? = nil,
        // v9.5 Phase 5E — optional pre-allocated NEON output buffers
        // owned by the caller's worker scope. When non-nil AND
        // `HTBlockEncoderConformant.useNEONHotPath == true` AND the
        // block fits the C entry-point envelope, the encode routes
        // through `encodeNEONIntoBuffers` + `assembleDataFromRaw(...,
        // vlcReversed: false)`. Mirrors v9.1 Phase 2d raw-engine
        // hoist; eliminates per-block buffer alloc + [UInt8]
        // materialization. When nil, the existing per-call NEON path
        // (via encodeViaNEONHotPath) applies through HTBlockEncoder-
        // Conformant.encode.
        neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = nil,
        neonMelBuf: UnsafeMutablePointer<UInt8>? = nil,
        neonVlcBuf: UnsafeMutablePointer<UInt8>? = nil
    ) throws -> J2KCodeBlock {
        let count = pending.width * pending.height
        precondition(pending.coefficients.count == count,
                     "Part-15 dispatch: coefficient count mismatch")

        // K_max must match what a Part-15 decoder recovers from our
        // QCD segment. The decoder formula is K_max = (ε - 1) + guardBits.
        //
        // **Lossless / reversible** branch: `writeQCDMarker` emits
        //   ε_b = B + G_b + 1 - guardBits  (see v5.1.1 fix).
        // Decoder reconstructs K_max = (B + G_b + 1 - guardBits) - 1
        //                              + guardBits = B + G_b.
        // Since `pending.bitDepth = B + G + guardBits - 1`, that equals
        // `pending.bitDepth - guardBits + 1`. The `+1` over the v5.0/
        // v5.1.0 K_max fixes the pixel-0 edge case: for an unsigned
        // B-bit input, DC-shifting maps 0 to -2^(B-1), whose |magnitude|
        // equals 2^(B-1). The old K_max = B + G - 1 could only
        // represent magnitudes up to 2^(B+G-1) - 1, so the extreme
        // point rolled over to zero and 16-bit medical DICOM samples
        // lost every pixel-0 voxel.
        //
        // **Lossy / irreversible** branch: `writeQCDMarker` emits the
        // step-derived ε with NO conformant adjustment (`epsilonBias`
        // is gated on the reversible branch — line 3596). Decoder
        // reconstructs K_max = (ε - 1) + guardBits = ε + guardBits - 1.
        // Encoder bandKb = ε + guardBits - 1 ↔ pending.bitDepth, so
        // K_max should equal `pending.bitDepth` here, NOT
        // `pending.bitDepth - guardBits + 1`. The pre-v5.16 formula
        // wrote magnitudes shifted by `(31 - K_max)` with K_max one
        // less than the decoder's reconstructed value, putting every
        // coefficient one bit too low in the magnitude window. Result:
        // bitstream-level mismatch with ojph_expand at lossy
        // (cross-decode produced ~18 dB on real medical content while
        // J2KSwift's own self-round-trip mirrored the wrong shift and
        // measured ~65 dB at 8 bpp). Fixing the K_max formula here
        // closes both halves of that gap (V5_16_0_PHASE1_RD_DIAGNOSTIC.md).
        let quantExt = J2KPart2QuantizationExtensions(configuration: config)
        let guardBits = Int(quantExt.extendedGuardBits)
        let kMax: Int
        if config.useReversibleFilter {
            kMax = pending.bitDepth - guardBits + 1
        } else {
            kMax = pending.bitDepth
        }
        let shift = 31 - kMax
        let missingMSBs = kMax - 1

        // Zero-block short-circuit (mirrors OpenJPH's
        // `if (mv >= 1u << (31 - K_max))` guard). Emits no block
        // bytes — tier-2 packet header signals zero-block instead.
        var maxAbs: Int32 = 0
        for v in pending.coefficients {
            let a = v < 0 ? -v : v
            if a > maxAbs { maxAbs = a }
        }
        guard maxAbs > 0 else {
            return J2KCodeBlock(
                index: pending.index, x: pending.x, y: pending.y,
                width: pending.width, height: pending.height,
                subband: pending.subband,
                componentIndex: pending.componentIndex,
                resolutionLevel: pending.resolutionLevel,
                data: Data(), passeCount: 0,
                zeroBitPlanes: pending.bitDepth,
                passSegmentLengths: [], cumulativePassBytes: [],
                coefficientSquaredSum: pending.coefficientSquaredSum,
                bitPlanePopulation: pending.bitPlanePopulation)
        }

        // Convert pipeline's Int32 2's-complement coefficients to
        // OpenJPH sign-magnitude convention: `sign_bit | |v| << shift`
        // (matches `gen_rev_tx_to_cb32` in OpenJPH 0.26).
        //
        // v5.38 M9: the converted [UInt32] is written into the
        // caller-provided `conformantInBuf`, which holds its capacity
        // across blocks. Most blocks in a chunk share the same
        // dimensions, so the inner `count == buf.count` check usually
        // skips re-allocation. The `HTBlockEncoderConformant.encode`
        // call below uses `withUnsafeBufferPointer` to pass a buffer
        // pointer + count to the encoder, satisfying its
        // `coefficients.count == width * height` precondition without
        // requiring a fresh array per block.
        if conformantInBuf.count != count {
            conformantInBuf = [UInt32](repeating: 0, count: count)
        }
        conformantInBuf.withUnsafeMutableBufferPointer { dstBuf in
            let dst = dstBuf.baseAddress!
            pending.coefficients.withUnsafeBufferPointer { srcBuf in
                let src = srcBuf.baseAddress!
                for i in 0..<count {
                    let v = src[i]
                    let sign: UInt32 = (v < 0) ? 0x8000_0000 : 0
                    let mag = UInt32(v < 0 ? -Int64(v) : Int64(v))
                    dst[i] = sign | (mag << shift)
                }
            }
        }

        // v9.5 Phase 5E — direct NEON dispatch with hoisted buffers.
        // When the NEON path is enabled AND hoisted buffers are
        // provided AND the block fits the C entry-point envelope,
        // skip the entire HTBlockEncoderConformant + assembleData
        // chain and call the C path directly. Eliminates per-block
        // buffer alloc + [UInt8] materialization. Bit-exact verified
        // by the existing 548+ assertion suite (V94NEONHotPath...,
        // HTCrossCodec..., V91Phase2c..., etc.).
        if HTBlockEncoderConformant.useNEONHotPath,
           let nMag = neonMagsgnBuf,
           let nMel = neonMelBuf,
           let nVlc = neonVlcBuf,
           pending.width >= 1, pending.width <= 64,
           pending.height >= 1, pending.height <= 64,
           missingMSBs < 30,
           !useSIMDClassification
        {
            let rawCap = Self._rawEngineBufferCapacity
            let counts = conformantInBuf.withUnsafeBufferPointer { buf in
                HTBlockEncoderConformant.encodeNEONIntoBuffers(
                    coefficients: buf,
                    width: pending.width, height: pending.height,
                    missingMSBs: missingMSBs,
                    magsgnBuf: nMag, magsgnCap: rawCap,
                    melBuf: nMel, melCap: rawCap,
                    vlcBuf: nVlc, vlcCap: rawCap)
            }
            // NEON path outputs VLC in FORWARD on-wire order; matches
            // assembleDataFromRaw with vlcReversed: false.
            let blockData = try HTBlockLayoutConformant.assembleDataFromRaw(
                magsgnPtr: nMag, magsgnCount: counts.magsgnCount,
                melPtr: nMel, melCount: counts.melCount,
                vlcPtr: nVlc, vlcCount: counts.vlcCount,
                vlcReversed: false)
            return J2KCodeBlock(
                index: pending.index, x: pending.x, y: pending.y,
                width: pending.width, height: pending.height,
                subband: pending.subband,
                componentIndex: pending.componentIndex,
                resolutionLevel: pending.resolutionLevel,
                data: blockData,
                passeCount: 1,
                zeroBitPlanes: missingMSBs,
                passSegmentLengths: [blockData.count],
                cumulativePassBytes: [blockData.count],
                coefficientSquaredSum: pending.coefficientSquaredSum,
                bitPlanePopulation: pending.bitPlanePopulation,
                cumulativePassDistortion: [pending.coefficientSquaredSum])
        }

        if Self._rawPointerEnginesEnabled {
            // v9.1 Path B Phase 2c/2d — raw-pointer engine path.
            // Eliminates per-byte Array.append ARC + capacity-grow
            // contention by writing bytes directly to caller-owned
            // UnsafeMutableBufferPointer<UInt8> buffers.
            //
            // Buffer source priority:
            //   1. If caller passed pre-allocated buffers (Phase 2d
            //      per-worker hoisting), use them. No per-call alloc.
            //   2. Else allocate per-call (Phase 2c initial integration).
            //
            // Both paths are bit-exact equivalent — only the buffer
            // allocator changes.
            let rawCap = Self._rawEngineBufferCapacity
            let mBuf: UnsafeMutablePointer<UInt8>
            let lBuf: UnsafeMutablePointer<UInt8>
            let vBuf: UnsafeMutablePointer<UInt8>
            let needsDealloc: Bool
            if let pm = rawMagsgnBuf, let pl = rawMelBuf, let pv = rawVlcBuf {
                mBuf = pm
                lBuf = pl
                vBuf = pv
                needsDealloc = false
            } else {
                mBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: rawCap)
                lBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: rawCap)
                vBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: rawCap)
                needsDealloc = true
            }
            defer {
                if needsDealloc {
                    mBuf.deallocate()
                    lBuf.deallocate()
                    vBuf.deallocate()
                }
            }
            // v9.2 Path B Phase 3a — raw-engine path goes directly to
            // `assembleDataFromRaw`, skipping the 4 per-block Array
            // extraction allocs (magsgn, mel, vlc reversed, vlc final)
            // that the pre-Phase-3a path paid before this point.
            var rawM = HTMagSgnEncoderRawConformant(buf: mBuf, capacity: rawCap)
            var rawL = HTMELEncoderRawConformant(buf: lBuf, capacity: rawCap)
            var rawV = HTReverseBitEmitterRawConformant(buf: vBuf, capacity: rawCap)
            let counts = conformantInBuf.withUnsafeBufferPointer { buf in
                HTBlockEncoderConformant.encode(
                    coefficients: buf,
                    width: pending.width, height: pending.height,
                    missingMSBs: missingMSBs,
                    magsgnEnc: &rawM, melEnc: &rawL, vlcEnc: &rawV,
                    useSIMDClassification: useSIMDClassification)
            }
            let blockData = try HTBlockLayoutConformant.assembleDataFromRaw(
                magsgnPtr: mBuf, magsgnCount: counts.magsgnCount,
                melPtr: lBuf, melCount: counts.melCount,
                vlcPtr: vBuf, vlcCount: counts.vlcCount,
                vlcReversed: true)
            return J2KCodeBlock(
                index: pending.index, x: pending.x, y: pending.y,
                width: pending.width, height: pending.height,
                subband: pending.subband,
                componentIndex: pending.componentIndex,
                resolutionLevel: pending.resolutionLevel,
                data: blockData,
                passeCount: 1,
                zeroBitPlanes: missingMSBs,
                passSegmentLengths: [blockData.count],
                cumulativePassBytes: [blockData.count],
                coefficientSquaredSum: pending.coefficientSquaredSum,
                bitPlanePopulation: pending.bitPlanePopulation,
                cumulativePassDistortion: [pending.coefficientSquaredSum])
        }
        let result = conformantInBuf.withUnsafeBufferPointer { buf in
            HTBlockEncoderConformant.encode(
                coefficients: buf,
                width: pending.width, height: pending.height,
                missingMSBs: missingMSBs,
                magsgnEnc: &magsgnEnc, melEnc: &melEnc, vlcEnc: &vlcEnc,
                useSIMDClassification: useSIMDClassification)
        }
        // v9.2 Path B Phase 3a — assembleData (Data-returning) skips
        // the per-block `[UInt8]` intermediate that was wrapped in
        // `Data(blockBytes)` pre-Phase-3a. Bit-exact equivalent of the
        // legacy `assemble(...) -> [UInt8] + Data(_:)` two-step.
        let blockData = try HTBlockLayoutConformant.assembleData(
            magsgn: result.magsgn, mel: result.mel, vlc: result.vlc)

        // zeroBitPlanes is encoded into the packet-header tag tree as
        // missing_msbs. OpenJPH requires `missing_msbs < K_max`.
        // OpenJPH itself writes `missing_msbs = K_max - 1`, so we
        // match that.
        //
        // cumulativePassDistortion: the conformant single cleanup
        // pass losslessly transmits every quantized coefficient
        // integer that reached this block. After this one pass, no
        // codeable distortion remains — `coefficientSquaredSum` is
        // the full distortion this pass eliminates. Without this
        // signal, rate-control's `estimateDistortion` fallback
        // models the cleanup pass as coding a single bit-plane
        // (passNumber=0 → codedPlanes=1 in J2KRateControl.swift)
        // and therefore assigns it a slope that's `4^(K_max-1)` too
        // small relative to its actual quality contribution. PCRD-opt
        // then deprioritises every conformant block at low bpp,
        // producing the catastrophic R-D collapse measured pre-v5.16
        // (e.g. 18.88 dB at 1.0 bpp on CT, vs 32.62 dB EBCOT). See
        // V5_16_0_PHASE1_RD_DIAGNOSTIC.md for the full audit trail.
        return J2KCodeBlock(
            index: pending.index, x: pending.x, y: pending.y,
            width: pending.width, height: pending.height,
            subband: pending.subband,
            componentIndex: pending.componentIndex,
            resolutionLevel: pending.resolutionLevel,
            data: blockData,
            passeCount: 1,
            zeroBitPlanes: missingMSBs,
            passSegmentLengths: [blockData.count],
            cumulativePassBytes: [blockData.count],
            coefficientSquaredSum: pending.coefficientSquaredSum,
            bitPlanePopulation: pending.bitPlanePopulation,
            cumulativePassDistortion: [pending.coefficientSquaredSum])
    }

    /// writer allocations by reusing caller-provided buffers.
    ///
    /// - Parameters:
    ///   - pending: The pending code-block with coefficients and metadata.
    ///   - absMags: Pre-allocated absolute magnitude array (reused across blocks).
    ///   - sigPacked: Pre-allocated significance bitfield (reused across blocks).
    ///   - sigPropWriter: Pre-allocated SigProp writer (reused across refinement passes).
    ///   - magRefWriter: Pre-allocated MagRef writer (reused across refinement passes).
    ///   - mel: Pre-allocated MEL coder (reset and reused per block).
    ///   - vlc: Pre-allocated VLC coder (reset and reused per block).
    ///   - magsgn: Pre-allocated MagSgn coder (reset and reused per block).
    /// - Returns: A `J2KCodeBlock` with HT-encoded data.
    /// - Throws: ``J2KError/encodingError(_:)`` if HT encoding fails.
    private func encodeCodeBlockHTJ2KFast(
        _ pending: PendingCodeBlock,
        absMags: inout [Int32],
        sigPacked: inout [UInt64],
        sigPropWriter: inout HTFastBitWriter,
        magRefWriter: inout HTFastBitWriter,
        mel: inout HTMELCoder,
        vlc: inout HTVLCCoder,
        magsgn: inout HTMagSgnCoder,
        // v5.38 M8: pre-allocated conformant entropy encoders, reset
        // per block. Amortises internal `[UInt8]` buffer growth across
        // a chunk of blocks instead of allocating fresh per call.
        conformantMagsgn: inout HTMagSgnEncoderConformant,
        conformantMel: inout HTMELEncoderConformant,
        conformantVlc: inout HTReverseBitEmitterConformant,
        // v5.38 M9: pre-allocated `[UInt32]` buffer for the sign-
        // magnitude conversion of coefficients. Resized in place by
        // the conformant encoder when block size changes.
        conformantInBuf: inout [UInt32],
        // v5.39 M1: opt-in SIMD per-quad classification. When false
        // (production default), the encoder runs the proven scalar
        // path. When true (env J2K_HT_SIMD=1 or test override), the
        // SIMD classifier replaces 4 per-quad sampleInfo calls with
        // one SIMD4<UInt32> pass; output bytes are identical to the
        // scalar path (verified by HTSIMDIntegrationTests over a
        // 25K random-block sweep).
        useSIMDClassification: Bool = false,
        // v9.1 Phase 2d: optional pre-allocated raw-pointer engine
        // buffers, owned by the caller's worker scope. Forwarded to
        // encodeCodeBlockConformant when `_rawPointerEnginesEnabled`
        // is set.
        rawMagsgnBuf: UnsafeMutablePointer<UInt8>? = nil,
        rawMelBuf: UnsafeMutablePointer<UInt8>? = nil,
        rawVlcBuf: UnsafeMutablePointer<UInt8>? = nil,
        // v9.5 Phase 5E: optional pre-allocated NEON output buffers,
        // owned by the caller's worker scope. Forwarded to
        // encodeCodeBlockConformant which routes directly through the
        // C entry point when these + NEON envelope match.
        neonMagsgnBuf: UnsafeMutablePointer<UInt8>? = nil,
        neonMelBuf: UnsafeMutablePointer<UInt8>? = nil,
        neonVlcBuf: UnsafeMutablePointer<UInt8>? = nil
    ) throws -> J2KCodeBlock {
        return try encodeCodeBlockConformant(
            pending,
            magsgnEnc: &conformantMagsgn,
            melEnc: &conformantMel,
            vlcEnc: &conformantVlc,
            conformantInBuf: &conformantInBuf,
            useSIMDClassification: useSIMDClassification,
            rawMagsgnBuf: rawMagsgnBuf,
            rawMelBuf: rawMelBuf,
            rawVlcBuf: rawVlcBuf,
            neonMagsgnBuf: neonMagsgnBuf,
            neonMelBuf: neonMelBuf,
            neonVlcBuf: neonVlcBuf)
    }

    // MARK: - SIMD Helpers

    /// Computes the maximum absolute value in an array using SIMD operations.
    ///
    /// Processes 4 elements at a time using SIMD4 vectors for improved throughput
    /// on coefficient arrays during bit depth computation.
    ///
    /// - Parameter values: The array of Int32 values.
    /// - Returns: The maximum absolute value in the array.
    static func maxAbsValue(_ values: [Int32]) -> Int32 {
        guard !values.isEmpty else { return 0 }

        return values.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            let count = ptr.count
            let simdCount = count / 4

            var maxVec = SIMD4<Int32>.zero

            for i in 0..<simdCount {
                let offset = i * 4
                let v = SIMD4<Int32>(
                    base[offset],
                    base[offset + 1],
                    base[offset + 2],
                    base[offset + 3]
                )
                // Compute absolute values: abs(v) = v < 0 ? -v : v
                let negative = v .< SIMD4<Int32>.zero
                let absV = v.replacing(with: SIMD4<Int32>.zero &- v, where: negative)
                maxVec = pointwiseMax(maxVec, absV)
            }

            // Reduce SIMD4 to scalar max
            var result = Swift.max(
                Swift.max(maxVec[0], maxVec[1]),
                Swift.max(maxVec[2], maxVec[3])
            )

            // Handle remainder
            let remStart = simdCount * 4
            for i in remStart..<count {
                result = Swift.max(result, abs(base[i]))
            }

            return result
        }
    }

    // MARK: - Stage 6: Rate Control

    /// Applies rate control and quality layer formation.
    private func applyRateControl(
        codeBlocks: [J2KCodeBlock], totalPixels: Int,
        componentCount: Int
    ) throws -> [QualityLayer] {
        guard !codeBlocks.isEmpty else {
            return [QualityLayer(index: 0)]
        }

        // Fast path: lossless mode — include all passes from every block.
        // Skip J2KRateControl instantiation and dictionary creation entirely.
        if config.lossless {
            var contributions = [Int: Int](minimumCapacity: codeBlocks.count)
            for cb in codeBlocks where cb.passeCount > 0 {
                contributions[cb.index] = cb.passeCount
            }
            return [QualityLayer(index: 0, targetRate: nil,
                                 codeBlockContributions: contributions)]
        }

        // v5.18.0: fixed-qstep mode also includes every block unchanged.
        // The user picked the qstep; PCRD-opt would just decide which
        // blocks to drop, defeating the deterministic-quality contract.
        // v5.19.0 (.constantBitrateViaQstep): the J2KEncoder.encode
        // entry point intercepts and converts to .fixedQstep per
        // iteration, so the same fast-path applies as a defensive
        // fallback when the pipeline is invoked directly.
        switch config.bitrateMode {
        case .fixedQstep, .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            var contributions = [Int: Int](minimumCapacity: codeBlocks.count)
            for cb in codeBlocks where cb.passeCount > 0 {
                contributions[cb.index] = cb.passeCount
            }
            return [QualityLayer(index: 0, targetRate: nil,
                                 codeBlockContributions: contributions)]
        default:
            break
        }

        let rateConfig: RateControlConfiguration
        let ppbp = config.useHTJ2K ? 2 : 3
        // The current packet writer emits one final truncated layer rather than
        // a true multi-layer LRCP codestream. Use a single cumulative PCRD
        // target here so bitrate increases remain monotonic and are not skewed
        // by provisional intermediate-layer commitments.
        let effectiveLayerCount = 1
        switch config.bitrateMode {
        case .constantBitrate(let bpp):
            rateConfig = RateControlConfiguration(
                mode: .targetBitrate(bpp),
                layerCount: effectiveLayerCount,
                componentCount: componentCount,
                useReversibleFilter: config.useReversibleFilter,
                passesPerBitPlane: ppbp
            )
        case .constantQuality:
            rateConfig = RateControlConfiguration(
                mode: .constantQuality(max(0.0, min(1.0, config.quality))),
                layerCount: effectiveLayerCount,
                componentCount: componentCount,
                useReversibleFilter: config.useReversibleFilter,
                passesPerBitPlane: ppbp
            )
        case .variableBitrate(_, let maxBpp):
            rateConfig = RateControlConfiguration(
                mode: .targetBitrate(maxBpp),
                layerCount: effectiveLayerCount,
                componentCount: componentCount,
                useReversibleFilter: config.useReversibleFilter,
                passesPerBitPlane: ppbp
            )
        case .lossless:
            rateConfig = .lossless
        case .fixedQstep, .constantBitrateViaQstep, .constantBitrateBounded, .constantBitrateStrict:
            // Already short-circuited above. This branch only exists
            // for switch exhaustiveness — should be unreachable.
            preconditionFailure(".fixedQstep / .constantBitrateViaQstep / .constantBitrateBounded should have been handled by the fast-path above")
        }

        let rateControl = J2KRateControl(configuration: rateConfig)
        return try rateControl.optimizeLayers(codeBlocks: codeBlocks, totalPixels: totalPixels)
    }

    // MARK: - Stage 7: Codestream Generation

    /// Generates a JPEG 2000 codestream with proper markers.
    /// Coded image for an Annex J array-based transformation: every component becomes signed with the width the
    /// forward matrix needs, and the marker set that lets a decoder undo the transformation.
    static func part2CodedImage(_ image: J2KImage, matrix: J2KMCTMatrix) throws -> (J2KImage, J2KPart2EncodingMarkers) {
        let n = image.components.count
        guard matrix.size == n else {
            throw J2KError.invalidParameter("the multiple component transformation matrix is \(matrix.size)×\(matrix.size) for \(n) components")
        }
        guard image.components.allSatisfy({ $0.subsamplingX == 1 && $0.subsamplingY == 1 && $0.width == image.width && $0.height == image.height }) else {
            throw J2KError.invalidParameter("Annex J transformations require components of equal geometry")
        }
        let inverse = try matrix.inverse()
        let integerForward = matrix.coefficients.allSatisfy { $0 == $0.rounded() }
        let integerInverse = inverse.coefficients.allSatisfy { abs($0 - $0.rounded()) < 1e-9 }
        let reversible = integerForward && integerInverse
        let inputDepth = image.components.map(\.bitDepth).max() ?? 8
        let depths = J2KPart2EncodingMarkers.codedDepth(forwardMatrix: matrix.coefficients, size: n, inputDepth: inputDepth)
        let coded = image.components.enumerated().map { index, component in
            J2KComponent(index: component.index, bitDepth: depths[index], signed: true, width: component.width, height: component.height,
                         subsamplingX: component.subsamplingX, subsamplingY: component.subsamplingY,
                         data: component.data, sampleByteOrder: component.sampleByteOrder)
        }
        let markers = J2KPart2EncodingMarkers(
            outputDepths: image.components.map { .init(bitDepth: $0.bitDepth, signed: $0.signed) },
            decodingMatrix: reversible ? inverse.coefficients.map { $0.rounded() } : inverse.coefficients,
            offsets: image.components.map { $0.signed ? 0 : Int32(1 << ($0.bitDepth - 1)) },
            reversible: reversible
        )
        return (J2KImage(width: image.width, height: image.height, components: coded, colorSpace: image.colorSpace), markers)
    }

    private func generateCodestream(
        image: J2KImage,
        codeBlocks: [J2KCodeBlock],
        layers: [QualityLayer],
        actualDecompositionLevels: Int,
        adaptiveStepSizes: [String: Double],
        part2: J2KPart2EncodingMarkers? = nil, resolutionLayerCount: Int = 1
    ) throws -> Data {
        return try generateCodestreamWithIndex(
            image: image,
            codeBlocks: codeBlocks,
            layers: layers,
            actualDecompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveStepSizes,
            part2: part2, resolutionLayerCount: resolutionLayerCount
        ).data
    }

    /// Generates a JPEG 2000 codestream and returns the codestream
    /// alongside structural offsets needed for safe post-encode
    /// truncation at packet boundaries (v5.34.0 strict-rate mode).
    ///
    /// `packetEndOffsets` are byte offsets in the returned codestream
    /// where each LRCP packet ends. Truncating the codestream at any
    /// of these offsets and updating the SOT marker's `Psot` field
    /// produces a valid (premature-EOC) JPEG 2000 codestream.
    func generateCodestreamWithIndex(
        image: J2KImage,
        codeBlocks: [J2KCodeBlock],
        layers: [QualityLayer],
        actualDecompositionLevels: Int,
        adaptiveStepSizes: [String: Double],
        part2: J2KPart2EncodingMarkers? = nil, resolutionLayerCount: Int = 1
    ) throws -> EncodedCodestreamWithIndex {
        // Pre-size buffer based on total code block data + marker/header overhead
        let totalBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var writer = J2KBitWriter(capacity: totalBytes + totalBytes / 8 + 2048)

        // v6.3.0 F1 — sub-stage timing instrumentation (mirror of #308's
        // J2KTier2Timings pattern). Cost: ~10 NSLock acquires per encode.
        // Always-on; data feeds the F1 codestream-stage profile diagnostic.
        J2KCodestreamMarkerTimings.recordEncodeCall()

        // SOC — Start of Codestream
        var t = CFAbsoluteTimeGetCurrent()
        writer.writeMarker(J2KMarker.soc.rawValue)
        J2KCodestreamMarkerTimings.recordSOC(CFAbsoluteTimeGetCurrent() - t)

        // SIZ — Image and Tile Size
        t = CFAbsoluteTimeGetCurrent()
        try writeSIZMarker(&writer, image: image)
        J2KCodestreamMarkerTimings.recordSIZ(CFAbsoluteTimeGetCurrent() - t)

        // CAP — Extended Capabilities (HTJ2K Part 15)
        // CPF — Corresponding Profile (HTJ2K Part 15)
        // These markers must appear before COD when HTJ2K is enabled
        if config.useHTJ2K {
            t = CFAbsoluteTimeGetCurrent()
            try writeCAPMarker(&writer, qcd: qcdSegment(
                image: image, decompositionLevels: actualDecompositionLevels, adaptiveStepSizes: adaptiveStepSizes))
            J2KCodestreamMarkerTimings.recordCAP(CFAbsoluteTimeGetCurrent() - t)

            t = CFAbsoluteTimeGetCurrent()
            try writeCPFMarker(&writer)
            J2KCodestreamMarkerTimings.recordCPF(CFAbsoluteTimeGetCurrent() - t)
        }

        // COD — Coding Style Default
        t = CFAbsoluteTimeGetCurrent()
        try writeCODMarker(&writer, image: image, decompositionLevels: actualDecompositionLevels,
                           numLayers: resolutionLayerCount, part2Active: part2 != nil,
                           progressionOverride: resolutionLayerCount > 1 && config.progressionOrder == .rlcp ? 1 : nil)
        J2KCodestreamMarkerTimings.recordCOD(CFAbsoluteTimeGetCurrent() - t)

        // QCD — Quantization Default
        t = CFAbsoluteTimeGetCurrent()
        try writeQCDMarker(
            &writer,
            image: image,
            decompositionLevels: actualDecompositionLevels,
            adaptiveStepSizes: adaptiveStepSizes
        )
        J2KCodestreamMarkerTimings.recordQCD(CFAbsoluteTimeGetCurrent() - t)
        // CBD/MCT/MCC/MCO — T.801 Annex J array-based multiple component transformation (#2331).
        if let part2 {
            writer.writeBytes(part2.encodedSegments())
        }


        // SOT — Start of Tile-part (single tile for now)
        // Collect all tile data first so we know the length
        // (Note: generateTileData is the tier-2 stage from PR #308 —
        // its sub-stages are accumulated separately via J2KTier2Timings.
        // Not double-counted here.)
        let (tileData, packetEndsInTile) = try generateTileData(
            codeBlocks: codeBlocks, layers: layers,
            decompositionLevels: actualDecompositionLevels,
            componentCount: image.components.count, resolutionLayerCount: resolutionLayerCount
        )
        // TLM — one entry for the single tile-part (DICOM PS3.5 10.18.1).
        if config.writeTLMMarker {
            try writeTLMMarker(
                &writer, tilePartLengths: [(0, Self.tilePartHeaderLength + tileData.count)])
        }
        let sotMarkerOffset = writer.count
        t = CFAbsoluteTimeGetCurrent()
        try writeSOTMarker(&writer, tileIndex: 0, tilePartLength: tileData.count)
        J2KCodestreamMarkerTimings.recordSOT(CFAbsoluteTimeGetCurrent() - t)

        // SOD — Start of Data
        t = CFAbsoluteTimeGetCurrent()
        writer.writeMarker(J2KMarker.sod.rawValue)
        J2KCodestreamMarkerTimings.recordSOD(CFAbsoluteTimeGetCurrent() - t)

        // Tile bitstream data
        let tileDataOffset = writer.count
        t = CFAbsoluteTimeGetCurrent()
        writer.writeBytes(tileData)
        J2KCodestreamMarkerTimings.recordTileDataAppend(
            CFAbsoluteTimeGetCurrent() - t, bytes: tileData.count)

        // EOC — End of Codestream
        t = CFAbsoluteTimeGetCurrent()
        writer.writeMarker(J2KMarker.eoc.rawValue)
        J2KCodestreamMarkerTimings.recordEOC(CFAbsoluteTimeGetCurrent() - t)

        let packetEndsInCodestream = packetEndsInTile.map { $0 + tileDataOffset }
        return EncodedCodestreamWithIndex(
            data: writer.data,
            sotMarkerOffset: sotMarkerOffset,
            tileDataOffset: tileDataOffset,
            packetEndOffsets: packetEndsInCodestream
        )
    }

    /// Writes the SIZ marker segment (Image and Tile Size).
    private func writeSIZMarker(_ writer: inout J2KBitWriter, image: J2KImage) throws {
        var segment = J2KBitWriter()

        // Rsiz — Capabilities
        // Compute Part 2 capabilities from configuration
        let capabilities = J2KPart2Capabilities(configuration: config)
        segment.writeUInt16(capabilities.rsizValue)
        // Xsiz — Image width
        segment.writeUInt32(UInt32(image.width))
        // Ysiz — Image height
        segment.writeUInt32(UInt32(image.height))
        // XOsiz — Horizontal offset (0)
        segment.writeUInt32(0)
        // YOsiz — Vertical offset (0)
        segment.writeUInt32(0)
        // XTsiz — Tile width (image width for single-tile mode)
        // Note: Multi-tile encoding is not yet supported; always use full image
        // dimensions to ensure the single SOT/SOD pair covers the entire image.
        let tileW = image.width
        segment.writeUInt32(UInt32(tileW))
        // YTsiz — Tile height (image height for single-tile mode)
        let tileH = image.height
        segment.writeUInt32(UInt32(tileH))
        // XTOsiz — Tile offset X (0)
        segment.writeUInt32(0)
        // YTOsiz — Tile offset Y (0)
        segment.writeUInt32(0)
        // Csiz — Number of components
        segment.writeUInt16(UInt16(image.components.count))

        // Per-component parameters
        for component in image.components {
            // Ssiz — Bit depth (bit 7 = signed flag, bits 0-6 = depth - 1)
            let ssiz = UInt8((component.signed ? 0x80 : 0x00) | ((component.bitDepth - 1) & 0x7F))
            segment.writeUInt8(ssiz)
            // XRsiz — Horizontal subsampling
            segment.writeUInt8(UInt8(component.subsamplingX))
            // YRsiz — Vertical subsampling
            segment.writeUInt8(UInt8(component.subsamplingY))
        }

        writer.writeMarkerSegment(J2KMarker.siz.rawValue, segmentData: segment.data)
    }

    /// Writes the CAP marker segment (Extended Capabilities) for HTJ2K.
    ///
    /// The CAP marker signals HTJ2K support and capabilities to the decoder.
    /// Format per ISO/IEC 15444-15:
    /// - Pcap (4 bytes): Part capabilities (bit 17 set for Part 15)
    /// - Ccap (2 × N bytes): Capability pairs (HT support flags)
    private func writeCAPMarker(_ writer: inout J2KBitWriter, qcd: Data) throws {
        var segment = J2KBitWriter()

        // Pcap (4 bytes): bit 14 (0x00020000) declares the Part 15 capabilities word.
        let pcap: UInt32 = 0x00020000
        segment.writeUInt32(pcap)

        // Ccap15 (T.814 A.3.2): bits 15–14 = 0 (every code-block uses the HT
        // coder, single HT set), bit 5 = irreversible transform in use, bits
        // 0–4 = MAGB, the largest number of magnitude bit-planes B = G + ε - 1
        // over the sub-bands signalled in the QCD segment.
        var ccap15: UInt16 = config.useReversibleFilter ? 0x0000 : 0x0020
        ccap15 |= UInt16(Self.magbCode(maximumMagnitudeBitPlanes: Self.maximumMagnitudeBitPlanes(qcd: qcd)))
        segment.writeUInt16(ccap15)

        writer.writeMarkerSegment(J2KMarker.cap.rawValue, segmentData: segment.data)
    }

    /// B = max(G + εb − 1) from a QCD segment (Sqcd + SPqcd bytes).
    static func maximumMagnitudeBitPlanes(qcd: Data) -> Int {
        guard let sqcd = qcd.first else { return 8 }
        let guardBits = Int(sqcd >> 5)
        let style = Int(sqcd & 0x1F)
        var maxExponent = 0
        let body = qcd.dropFirst()
        if style == 0 {
            for byte in body { maxExponent = max(maxExponent, Int(byte >> 3)) }
        } else {
            var index = body.startIndex
            while index + 1 < body.endIndex {
                maxExponent = max(maxExponent, Int(body[index]) >> 3)
                index += 2
            }
        }
        return max(0, guardBits + maxExponent - 1)
    }

    /// MAGB encoding of T.814 Table A.6: 0 → B ≤ 8, 1…19 → B = 8 + v, 20…31 → B = 4(v − 19) + 27.
    static func magbCode(maximumMagnitudeBitPlanes b: Int) -> Int {
        if b <= 8 { return 0 }
        if b <= 27 { return b - 8 }
        return min(31, 19 + (b - 27 + 3) / 4)
    }


    /// Writes the CPF marker segment (Corresponding Profile) for HTJ2K.
    ///
    /// The CPF marker specifies the HTJ2K profile used for encoding.
    /// Format per ISO/IEC 15444-15:
    /// - Pcpf (2 bytes): Profile capabilities
    ///   - 0: Part 15 reversible (5/3 wavelet, lossless)
    ///   - 1: Part 15 irreversible (9/7 wavelet, lossy)
    ///
    /// Note: Broadcast profile (value 2) is defined in the standard but not yet implemented.
    private func writeCPFMarker(_ writer: inout J2KBitWriter) throws {
        var segment = J2KBitWriter()

        // Pcpf (2 bytes): Profile selection
        // Select profile based on compression mode
        let pcpf: UInt16 = config.useReversibleFilter ? 0 : 1

        segment.writeUInt16(pcpf)

        writer.writeMarkerSegment(J2KMarker.cpf.rawValue, segmentData: segment.data)
    }

    /// Per-resolution precinct size exponents. Width = 2^widthExp,
    /// height = 2^heightExp. ISO 15444-1 A.6.1: for resolution 0 (LL)
    /// the precinct covers a 2^PPx × 2^PPy region of LL; for r > 0
    /// the precinct covers 2^(PPx-1) × 2^(PPy-1) in each HL/LH/HH
    /// sub-band. Range 0–15 each.
    struct PrecinctExponents: Sendable, Equatable {
        let widthExp: Int
        let heightExp: Int
    }

    /// Writes the COD marker segment (Coding Style Default).
    ///
    /// `precinctSizes` (v5.35.0d): if provided, must have one entry
    /// per resolution (decompositionLevels + 1). Sets Scod bit 0 = 1
    /// and emits per-resolution precinct exponents at the end of
    /// SPcod. Pass `nil` for the default precinct behaviour (one
    /// precinct per band, equivalent to PPx=PPy=15).
    /// SGcod value whose packet sequence equals the one the tile writers emit.
    static func signalledProgressionOrder(
        _ order: J2KProgressionOrder, numLayers: Int, customPrecincts: Bool
    ) -> UInt8 {
        guard numLayers <= 1, !customPrecincts else { return 0 }
        switch order {
        case .lrcp: return 0
        case .rlcp: return 1
        case .rpcl: return 2
        default: return 0
        }
    }

    /// Writes a TLM marker segment (T.800 A.7.1): Ztlm 0, Stlm 0x60 (16-bit
    /// Ttlm, 32-bit Ptlm) and one (tile index, tile-part length) entry per
    /// tile-part. `tilePartLengths` are the full tile-part lengths from the
    /// SOT marker to the end of the tile-part data (the Psot values).
    private func writeTLMMarker(
        _ writer: inout J2KBitWriter, tilePartLengths: [(tileIndex: Int, length: Int)]
    ) throws {
        // Ltlm = 4 + 6 × entries must fit in 16 bits.
        guard tilePartLengths.count <= 10_920 else {
            throw J2KError.encodingError(
                "TLM marker cannot describe \(tilePartLengths.count) tile-parts")
        }
        var segment = J2KBitWriter()
        segment.writeUInt8(0)
        segment.writeUInt8(0x60)
        for part in tilePartLengths {
            guard part.tileIndex <= 0xFFFF, part.length <= 0xFFFF_FFFF else {
                throw J2KError.encodingError("TLM entry out of range")
            }
            segment.writeUInt16(UInt16(part.tileIndex))
            segment.writeUInt32(UInt32(part.length))
        }
        writer.writeMarkerSegment(J2KMarker.tlm.rawValue, segmentData: segment.data)
    }

    private func writeCODMarker(
        _ writer: inout J2KBitWriter,
        image: J2KImage,
        decompositionLevels: Int,
        numLayers: Int = 1,
        precinctSizes: [PrecinctExponents]? = nil,
        part2Active: Bool = false,
        progressionOverride: UInt8? = nil
    ) throws {
        var segment = J2KBitWriter()

        // Scod — Coding style flags
        // Bit 0: User-defined precinct sizes specified (else default)
        // Bit 1: SOP markers
        // Bit 2: EPH markers
        // Bits 3-7: reserved (must be 0)
        var scod: UInt8 = 0
        if precinctSizes != nil {
            scod |= 0x01
        }
        segment.writeUInt8(scod)

        // SGcod — Progression order. The tile writers emit one packet per
        // (resolution, component) in resolution-major order, which is the
        // LRCP, RLCP and RPCL sequence whenever there is one layer and one
        // precinct per resolution (T.800 B.12). Anything else is recorded as
        // LRCP because that is the sequence actually written.
        segment.writeUInt8(progressionOverride ?? Self.signalledProgressionOrder(
            config.progressionOrder, numLayers: numLayers, customPrecincts: precinctSizes != nil))

        // Number of layers (v5.35.0b: configurable for multi-layer strict
        // mode; default 1 keeps existing single-layer encodes byte-identical)
        segment.writeUInt16(UInt16(max(1, numLayers)))

        // Multiple component transform (1 = RCT/ICT, 0 = none)
        // MCT is applied whenever the encoder performs a colour transform (3+ components)
        // T.801 Table A.8: 2 signals the Annex J transformation carried by the MCC/MCO marker segments.
        let useMCT: Bool = image.components.count >= 3 && !part2Active
        segment.writeUInt8(part2Active ? 2 : (useMCT ? 1 : 0))

        // SPcod — Coding parameters
        // Number of decomposition levels
        segment.writeUInt8(UInt8(decompositionLevels))

        // Code-block width exponent (offset by 2)
        let cbWidthExp = Int(log2(Double(config.codeBlockSize.width)))
        segment.writeUInt8(UInt8(cbWidthExp - 2))

        // Code-block height exponent (offset by 2)
        let cbHeightExp = Int(log2(Double(config.codeBlockSize.height)))
        segment.writeUInt8(UInt8(cbHeightExp - 2))

        // Code-block style
        // Bit 0: Selective arithmetic coding bypass
        // Bit 1: Reset context probabilities
        // Bit 2: Termination on each coding pass
        // Bit 3: Vertically causal context
        // Bit 4: Predictable termination
        // Bit 5: Segmentation symbols
        // Bit 6: HT block coding (1 = HTJ2K, 0 = legacy EBCOT)
        var codeBlockStyle: UInt8 = 0
        if standardEBCOTCodingOptions.bypassEnabled {
            codeBlockStyle |= 0x01 // Set bit 0 for selective arithmetic coding bypass
        }
        if config.useHTJ2K {
            codeBlockStyle |= 0x40 // Set bit 6 for HTJ2K mode
        }
        segment.writeUInt8(codeBlockStyle)

        // Wavelet transform type (0 = 9/7 irreversible, 1 = 5/3 reversible)
        segment.writeUInt8(config.useReversibleFilter ? 1 : 0)

        // Optional: per-resolution precinct sizes. ISO 15444-1 A.6.1.
        // One byte per resolution; low nibble = width exponent,
        // high nibble = height exponent.
        if let pps = precinctSizes {
            precondition(pps.count == decompositionLevels + 1,
                "precinctSizes must have one entry per resolution")
            for pp in pps {
                let lo = UInt8(pp.widthExp & 0x0F)
                let hi = UInt8((pp.heightExp & 0x0F) << 4)
                segment.writeUInt8(hi | lo)
            }
        }

        writer.writeMarkerSegment(J2KMarker.cod.rawValue, segmentData: segment.data)
    }

    /// Writes the COC marker segment (Coding Style Component).
    ///
    /// The COC marker allows per-component coding parameters that override
    /// the default COD parameters for a specific component. This is optional
    /// and only written when component-specific parameters are needed.
    ///
    /// - Parameters:
    ///   - writer: The bit writer to write to.
    ///   - componentIndex: The component index (0-based).
    ///   - componentCount: Total number of components.
    private func writeCOCMarker(
        _ writer: inout J2KBitWriter,
        componentIndex: Int,
        componentCount: Int
    ) throws {
        var segment = J2KBitWriter()

        // Ccoc — Component index
        if componentCount < 257 {
            // 1 byte for component index if < 257 components
            segment.writeUInt8(UInt8(componentIndex))
        } else {
            // 2 bytes for component index if >= 257 components
            segment.writeUInt16(UInt16(componentIndex))
        }

        // Scoc — Coding style for this component
        // Same structure as COD's SPcod

        // Number of decomposition levels
        segment.writeUInt8(UInt8(config.decompositionLevels))

        // Code-block width exponent (offset by 2)
        let cbWidthExp = Int(log2(Double(config.codeBlockSize.width)))
        segment.writeUInt8(UInt8(cbWidthExp - 2))

        // Code-block height exponent (offset by 2)
        let cbHeightExp = Int(log2(Double(config.codeBlockSize.height)))
        segment.writeUInt8(UInt8(cbHeightExp - 2))

        // Code-block style (with selective arithmetic bypass and HT bit if enabled)
        var codeBlockStyle: UInt8 = 0
        if standardEBCOTCodingOptions.bypassEnabled {
            codeBlockStyle |= 0x01 // Set bit 0 for selective arithmetic coding bypass
        }
        if config.useHTJ2K {
            codeBlockStyle |= 0x40 // Set bit 6 for HTJ2K mode
        }
        segment.writeUInt8(codeBlockStyle)

        // Wavelet transform type (0 = 9/7 irreversible, 1 = 5/3 reversible)
        segment.writeUInt8(config.useReversibleFilter ? 1 : 0)

        // HT set parameters (ISO/IEC 15444-15) — only when HTJ2K is enabled
        if config.useHTJ2K {
            // For HT set A (default), write the HT set configuration byte
            // Bits 0-3: Reserved (set to 0)
            // Bit 4: Lossless flag (0 = lossy, 1 = lossless)
            // Bits 5-7: Reserved (set to 0)
            var htSetConfig: UInt8 = 0
            if config.lossless {
                htSetConfig |= 0x10 // Set bit 4 for lossless mode
            }
            segment.writeUInt8(htSetConfig)
        }

        writer.writeMarkerSegment(J2KMarker.coc.rawValue, segmentData: segment.data)
    }

    /// Writes the QCD marker segment (Quantization Default).
    /// Magnitude-window gain (bits above the component bit-depth) for a
    /// reversible 5/3 subband in the **HT Part-15 conformant** path.
    ///
    /// The conformant encoder converts coefficients to OpenJPH sign-magnitude
    /// as `sign | (|v| << (31 - K_max))`, where `K_max = bitDepth + gain`.
    /// The previous single-level gain `{LL:0, HL/LH:1, HH:2}` undersized the
    /// window: a multi-level reversible 5/3 transform expands the coefficient
    /// range (the deep LL band especially), so high-contrast content (e.g.
    /// 8-bit 0↔255 edges) produces coefficients whose magnitude exceeds
    /// `2^K_max`. `|v| << shift` then overflows bit 31 (the sign bit) and the
    /// top bitplane is silently lost — a lossless-mode data-loss bug that
    /// `OpenJPH` (the reference decoder) reproduces from our codestream,
    /// confirming the defect is in our encoder, not the decoder.
    ///
    /// These values match OpenJPH's proven-sufficient reversible K_max
    /// (LL = B+1, finest-level detail = B+1, coarser detail = B+2; one more
    /// bit when the reversible colour transform is active, which widens the
    /// U/V components by a bit), taking `max` with the previous gain so the
    /// window can only grow — never shrink below what already round-tripped.
    /// Level-independent (uses the coarser-band gain for all detail levels)
    /// to keep the QCD marker and per-block shift trivially consistent.
    static func htConformantReversibleGain(subband: J2KSubband, rctActive: Bool) -> Int {
        let rct = rctActive ? 1 : 0
        switch subband {
        case .ll:      return max(0, rct + 1)
        case .hl, .lh: return max(1, rct + 2)
        case .hh:      return max(2, rct + 2)
        }
    }

    private func writeQCDMarker(
        _ writer: inout J2KBitWriter,
        image: J2KImage,
        decompositionLevels: Int,
        adaptiveStepSizes: [String: Double]
    ) throws {
        writer.writeMarkerSegment(
            J2KMarker.qcd.rawValue,
            segmentData: try qcdSegment(
                image: image, decompositionLevels: decompositionLevels, adaptiveStepSizes: adaptiveStepSizes))
    }

    /// Sqcd + SPqcd bytes of the QCD marker segment.
    func qcdSegment(
        image: J2KImage,
        decompositionLevels: Int,
        adaptiveStepSizes: [String: Double]
    ) throws -> Data {
        var segment = J2KBitWriter()

        // Sqcd byte layout: guard bits (bits 5-7) | quantization style (bits 0-4)
        // Use extended guard bits from Part 2 configuration if applicable
        let quantExt = J2KPart2QuantizationExtensions(configuration: config)

        if config.useReversibleFilter {
            // No quantization (style = 0) for reversible transforms
            let sqcd = quantExt.encodeSqcd(quantizationStyle: 0x00)
            segment.writeUInt8(sqcd)

            // SPqcd: Exponent values for each subband
            // Per JPEG 2000 (ISO 15444-1 Table E.1), for the reversible 5/3 filter:
            //   epsilon_b = R_I + G_b  where R_I = bit depth, G_b = subband gain exponent
            //   LL: G=0, HL/LH: G=1, HH: G=2
            let bitDepth = image.components.first?.bitDepth ?? 8
            let guardBits = Int(quantExt.extendedGuardBits)

            // Part-15 conformant path encodes ε_b = B + G_b + 1 -
            // guardBits for each subband. A Part-15 decoder computes
            // K_max = (ε - 1) + guardBits = B + G_b, giving a
            // magnitude range of [0, 2^(B+G_b) - 1] that covers the
            // DC-shifted extreme `|2^(B-1)|` cleanly.
            //
            // This is one more than OpenJPH 0.26's native ε
            // (`B + G - guardBits`). Its block decoder's magnitude
            // range is driven entirely by the signalled K_max, so
            // raising ε by 1 preserves Part-15 interop while fixing
            // the pixel-0 rollover that OpenJPH itself exhibits with
            // its native epsilon (memory note #5 / v5.1.1 fix).
            //
            // Gate on `useHTJ2K` so the Part-15 epsilon shift never leaks
            // into legacy EBCOT codestreams.
            let conformant = config.useHTJ2K
            let epsilonBias = conformant ? guardBits : 0
            let epsilonConformantAdjust = conformant ? 1 : 0

            // Subband magnitude-window gain. For the conformant HT path use the
            // reversible-5/3-safe gain (matches OpenJPH; covers multi-level LL
            // range growth that the old single-level {0,1,2} undersized — see
            // `htConformantReversibleGain`). Non-conformant (legacy EBCOT /
            // custom HT) keeps the original {LL:0, HL/LH:1, HH:2} so those
            // codestreams are byte-identical to before. The per-block shift in
            // `encodeCodeBlockConformant` derives K_max from the SAME gain, so
            // encoder and decoder stay consistent via this QCD ε.
            let rctActive = config.useReversibleFilter && image.components.count >= 3
            let gLL = conformant ? Self.htConformantReversibleGain(subband: .ll, rctActive: rctActive) : 0
            let gHL = conformant ? Self.htConformantReversibleGain(subband: .hl, rctActive: rctActive) : 1
            let gLH = conformant ? Self.htConformantReversibleGain(subband: .lh, rctActive: rctActive) : 1
            let gHH = conformant ? Self.htConformantReversibleGain(subband: .hh, rctActive: rctActive) : 2

            // LL subband at coarsest level
            let epsilonLL = UInt8(max(1, bitDepth + gLL + epsilonConformantAdjust - epsilonBias))
            segment.writeUInt8(epsilonLL << 3) // Exponent in bits 3-7

            // Detail subbands (HL, LH, HH) at each level (from coarsest to finest)
            for _ in 0..<decompositionLevels {
                let epsilonHL = UInt8(max(1, bitDepth + gHL + epsilonConformantAdjust - epsilonBias))
                let epsilonLH = UInt8(max(1, bitDepth + gLH + epsilonConformantAdjust - epsilonBias))
                let epsilonHH = UInt8(max(1, bitDepth + gHH + epsilonConformantAdjust - epsilonBias))
                segment.writeUInt8(epsilonHL << 3)
                segment.writeUInt8(epsilonLH << 3)
                segment.writeUInt8(epsilonHH << 3)
            }
        } else {
            // Scalar expounded quantization (style = 2) for lossy transforms
            let sqcd = quantExt.encodeSqcd(quantizationStyle: 0x02)
            segment.writeUInt8(sqcd)

            // Compute step sizes using the SAME parameters as the actual quantizer
            // in Stage 4 (applyQuantization), so the QCD marker matches encoding.
            let bitDepth = image.components.first?.bitDepth ?? 8
            // For the irreversible 9/7 path, the DWT normalization already
            // equalizes subband energy, so the effective QCD range-bits use the
            // base image precision for all subbands. This matches the OpenJPEG
            // convention and keeps encode/decode step reconstruction aligned.
            let baseRangeBits = bitDepth

            // SPqcd: Step size values for each subband (2 bytes each)
            // Per ISO 15444-1 Eq. E.3:
            //   Δ_b = 2^(R_b - ε_b) × (1 + μ_b / 2^11)
            // We solve for (ε_b, μ_b) given the actual step Δ_b:
            //   ε_b = R_b - floor(log2(Δ_b))
            //   μ_b = round((Δ_b / 2^(R_b - ε_b) - 1) × 2^11)

            // LL subband (quantizer uses decompositionLevel=0 for LL, gain=0)
            let llStep = adaptiveStepSizes[adaptiveStepKey(for: .ll, level: 0)] ?? J2KStepSizeCalculator.calculateStepSize(
                baseStepSize: lossyQuantizationParameters(bitDepth: bitDepth, componentCount: image.components.count).baseStepSize,
                subband: .ll,
                decompositionLevel: 0,
                totalLevels: decompositionLevels,
                reversible: false
            )
            let llRangeBits = baseRangeBits + 0 // G_LL = 0
            let (llExp, llMant) = Self.encodeJ2KStepSize(llStep, rangeBits: llRangeBits)
            segment.writeUInt16(UInt16((llExp & 0x1F) << 11 | (llMant & 0x7FF)))

            // Detail subbands: QCD lists from coarsest to finest.
            // In the encoder, the quantizer uses decompositionLevel = decomLevel
            // where decomLevel=1 is finest detail and decomLevel=NL is coarsest.
            // QCD order: coarsest first → iterate NL down to 1.
            if decompositionLevels > 0 {
                for level in (1...decompositionLevels).reversed() {
                    for subband in [J2KSubband.hl, .lh, .hh] {
                        let step = adaptiveStepSizes[adaptiveStepKey(for: subband, level: level)] ?? J2KStepSizeCalculator.calculateStepSize(
                            baseStepSize: lossyQuantizationParameters(bitDepth: bitDepth, componentCount: image.components.count).baseStepSize,
                            subband: subband,
                            decompositionLevel: level,
                            totalLevels: decompositionLevels,
                            reversible: false
                        )
                        let gainExponent: Int
                        switch subband {
                        case .ll: gainExponent = 0
                        case .hl, .lh: gainExponent = 1
                        case .hh: gainExponent = 2
                        }
                        let rangeBits = baseRangeBits + gainExponent
                        let (exp, mant) = Self.encodeJ2KStepSize(step, rangeBits: rangeBits)
                        segment.writeUInt16(UInt16((exp & 0x1F) << 11 | (mant & 0x7FF)))
                    }
                }
            }
        }

        return segment.data
    }

    /// Writes the SOT marker segment (Start of Tile-part).
    /// SOT marker (2) + Lsot (2) + segment (8) + SOD marker (2).
    static let tilePartHeaderLength = 14

    private func writeSOTMarker(
        _ writer: inout J2KBitWriter, tileIndex: Int, tilePartLength: Int
    ) throws {
        var segment = J2KBitWriter()

        // Isot — Tile index
        segment.writeUInt16(UInt16(tileIndex))
        // Psot — Length of tile-part (includes SOT marker + segment + SOD + data)
        let totalLength = Self.tilePartHeaderLength + tilePartLength
        segment.writeUInt32(UInt32(totalLength))
        // TPsot — Tile-part index (0 = first part)
        segment.writeUInt8(0)
        // TNsot — Number of tile-parts (1 = single part)
        segment.writeUInt8(1)

        writer.writeMarkerSegment(J2KMarker.sot.rawValue, segmentData: segment.data)
    }

    /// Applies rate control layer truncation to code blocks.
    ///
    /// For each code block, the quality layer specifies how many coding passes
    /// to include. Blocks not in the layer are excluded entirely. Blocks with
    /// fewer passes than encoded are truncated using per-pass byte boundaries.
    ///
    /// After PCRD layer truncation, a global rate envelope is applied to ensure
    /// the total output does not exceed the target bitrate derived from the
    /// quality parameter.
    private func applyLayerTruncation(
        codeBlocks: [J2KCodeBlock], layers: [QualityLayer]
    ) -> [J2KCodeBlock] {
        // Fast path: lossless mode — all passes are included, no truncation needed.
        if config.lossless {
            return codeBlocks
        }

        // Step 1: Apply PCRD layer truncation if available.
        // Merge contributions from ALL layers — each layer's contributions
        // only contains blocks updated in that layer, so we need to take
        // the maximum pass count across all layers for each block.
        var truncated: [J2KCodeBlock]
        var mergedContributions = [Int: Int]()
        for layer in layers {
            for (blockIdx, passes) in layer.codeBlockContributions {
                mergedContributions[blockIdx] = max(
                    mergedContributions[blockIdx] ?? 0, passes
                )
            }
        }
        if !mergedContributions.isEmpty {
            // Cache environment check outside hot loop
            let dumpPasses = ProcessInfo.processInfo.environment["J2K_DUMP_PASSES"] != nil
            truncated = codeBlocks.map { block in
                let maxPasses = mergedContributions[block.index]
                if dumpPasses {
                    print("TRUNCATION: block=\(block.index) passes=\(block.passeCount) layer_maxPasses=\(String(describing: maxPasses)) data=\(block.data.count)")
                }
                // Blocks not selected by PCRD should contribute zero data
                guard let maxPasses = maxPasses, maxPasses > 0 else {
                    return J2KCodeBlock(
                        index: block.index,
                        x: block.x, y: block.y,
                        width: block.width, height: block.height,
                        subband: block.subband,
                        componentIndex: block.componentIndex,
                        resolutionLevel: block.resolutionLevel,
                        data: Data(),
                        passeCount: 0,
                        zeroBitPlanes: block.zeroBitPlanes
                    )
                }
                // If PCRD assigned all passes, no truncation needed
                guard maxPasses < block.passeCount,
                      block.passeCount > 0 else {
                    return block
                }

                // Reconstruct the properly terminated data at the truncation
                // point. Prefer lightweight checkpoint reconstruction (O(1)
                // per block) over stored snapshot data.
                let truncatedData: Data
                if !block.mqCheckpoints.isEmpty && maxPasses <= block.mqCheckpoints.count {
                    // Reconstruct from checkpoint + shared raw MQ output
                    let cp = block.mqCheckpoints[maxPasses - 1]
                    truncatedData = MQEncoder.reconstructFromCheckpoint(cp, rawOutput: block.rawMQOutput)
                } else if !block.perPassSnapshotData.isEmpty && maxPasses <= block.perPassSnapshotData.count {
                    truncatedData = block.perPassSnapshotData[maxPasses - 1]
                } else {
                    let truncatedLength: Int
                    if !block.cumulativePassBytes.isEmpty && maxPasses <= block.cumulativePassBytes.count {
                        truncatedLength = min(block.cumulativePassBytes[maxPasses - 1], block.data.count)
                    } else if !block.passSegmentLengths.isEmpty && maxPasses <= block.passSegmentLengths.count {
                        truncatedLength = block.passSegmentLengths.prefix(maxPasses).reduce(0, +)
                    } else {
                        truncatedLength = Int(Double(block.data.count) * Double(maxPasses) / Double(block.passeCount))
                    }
                    let safeLength = min(max(0, truncatedLength), block.data.count)
                    truncatedData = block.data.prefix(safeLength)
                }

                return J2KCodeBlock(
                    index: block.index,
                    x: block.x, y: block.y,
                    width: block.width, height: block.height,
                    subband: block.subband,
                    componentIndex: block.componentIndex,
                    resolutionLevel: block.resolutionLevel,
                    data: truncatedData,
                    passeCount: maxPasses,
                    zeroBitPlanes: block.zeroBitPlanes,
                    passSegmentLengths: block.passSegmentLengths.isEmpty
                        ? [] : Array(block.passSegmentLengths.prefix(maxPasses)),
                    cumulativePassBytes: block.cumulativePassBytes.isEmpty
                        ? [] : Array(block.cumulativePassBytes.prefix(maxPasses))
                )
            }
        } else {
            truncated = codeBlocks
        }

        // Step 2: Global rate envelope — only apply when PCRD layer truncation
        // was NOT applied. When PCRD has already optimized the allocation,
        // a secondary heuristic truncation degrades quality.
        if !config.lossless, case .constantQuality = config.bitrateMode,
           mergedContributions.isEmpty {
            let quality = config.quality
            guard quality < 1.0 else { return truncated }

            // Target bits per pixel: quadratic mapping matching J2KRateControl
            let bpp = 0.1 + 7.9 * pow(quality, 1.5)
            // bpp already accounts for all components. Estimate spatial
            // pixel count by dividing total code block samples by components.
            let componentCount = max(1, Set(truncated.map { $0.componentIndex }).count)
            let codeBlockPixels = truncated.reduce(0) { $0 + $1.width * $1.height }
            let imagePixels = codeBlockPixels / componentCount
            let targetBytes = Int(bpp * Double(imagePixels) / 8.0)
            let actualBytes = truncated.reduce(0) { $0 + $1.data.count }

            guard actualBytes > targetBytes, targetBytes > 0 else { return truncated }

            // Resolution-aware truncation: distribute truncation more
            // uniformly across resolution levels. LL (res 0) gets light
            // protection but NOT full immunity, while higher-frequency
            // subbands get proportionally more truncation.
            // This prevents the previous issue of destroying all edge detail
            // while leaving LL completely untouched.
            let maxRes = truncated.map { $0.resolutionLevel }.max() ?? 0
            let bytesToRemove = actualBytes - targetBytes

            // Calculate how much each resolution level contributes
            struct ResInfo {
                var bytes: Int = 0
                var weight: Double = 0.0  // truncation aggressiveness
            }
            var resInfos = [Int: ResInfo]()
            for block in truncated where block.data.count > 0 {
                let res = block.resolutionLevel
                resInfos[res, default: ResInfo()].bytes += block.data.count
                // Uniform truncation weight with mild LL protection:
                // LL (res 0) = 0.3, mid res = 0.6-0.8, highest res = 1.0
                // This distributes truncation more evenly for better quality
                resInfos[res, default: ResInfo()].weight = maxRes > 0
                    ? 0.3 + 0.7 * Double(res) / Double(maxRes) : 1.0
            }

            // Compute weighted total for distributing truncation
            let weightedTotal = resInfos.reduce(0.0) { $0 + $1.value.weight * Double($1.value.bytes) }
            guard weightedTotal > 0 else { return truncated }

            // Per-resolution truncation ratio
            var resTruncRatio = [Int: Double]()
            for (res, info) in resInfos {
                let share = info.weight * Double(info.bytes) / weightedTotal
                let bytesFromThisRes = Double(bytesToRemove) * share
                resTruncRatio[res] = max(0.0, 1.0 - bytesFromThisRes / Double(info.bytes))
            }

            truncated = truncated.map { block in
                guard block.data.count > 0, block.passeCount > 0 else { return block }

                let ratio = resTruncRatio[block.resolutionLevel] ?? 1.0
                guard ratio < 1.0 else { return block }

                // Determine truncated pass count and data length
                let newPasses = max(1, Int(ceil(Double(block.passeCount) * ratio)))
                let newLength: Int
                if !block.cumulativePassBytes.isEmpty && newPasses <= block.cumulativePassBytes.count {
                    newLength = min(block.cumulativePassBytes[newPasses - 1], block.data.count)
                } else {
                    newLength = max(1, Int(Double(block.data.count) * ratio))
                }
                let safeLength = min(newLength, block.data.count)

                return J2KCodeBlock(
                    index: block.index,
                    x: block.x, y: block.y,
                    width: block.width, height: block.height,
                    subband: block.subband,
                    componentIndex: block.componentIndex,
                    resolutionLevel: block.resolutionLevel,
                    data: block.data.prefix(safeLength),
                    passeCount: min(newPasses, block.passeCount),
                    zeroBitPlanes: block.zeroBitPlanes,
                    passSegmentLengths: block.passSegmentLengths.isEmpty
                        ? [] : Array(block.passSegmentLengths.prefix(newPasses)),
                    cumulativePassBytes: block.cumulativePassBytes.isEmpty
                        ? [] : Array(block.cumulativePassBytes.prefix(newPasses))
                )
            }
        }

        return truncated
    }

    /// Generates the tile bitstream data from code blocks and layers.
    ///
    /// Uses LRCP progression: Layer → Resolution → Component → Precinct.
    /// Each packet uses raw bit packet headers per ISO/IEC 15444-1 Annex B.
    ///
    /// Returns the tile data along with byte offsets (within tileData)
    /// marking the END of each emitted packet. These are legal LRCP
    /// truncation points — slicing tileData at `packetEnds[i]` keeps
    /// the first `i+1` packets intact and produces a smaller-but-valid
    /// (premature-EOC) tile.
    private func generateTileData(
        codeBlocks: [J2KCodeBlock], layers: [QualityLayer],
        decompositionLevels: Int, componentCount: Int, resolutionLayerCount: Int = 1,
        // v6-alpha3 step 6A — geometry trace plumbing.
        tileIndex: Int = 0,
        geometryCollector: GeometryCollector? = nil
    ) throws -> (data: Data, packetEnds: [Int]) {
        let profiling = ProcessInfo.processInfo.environment["J2K_PROFILE"] != nil
        // Pre-size writer buffer based on total code block data
        let totalBlockBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var tileWriter = J2KBitWriter(capacity: totalBlockBytes + totalBlockBytes / 8 + 1024)

        // Apply rate control truncation: truncate code blocks per the quality layer
        var truncStart: CFAbsoluteTime = 0
        if profiling { truncStart = CFAbsoluteTimeGetCurrent() }
        let effectiveBlocks = applyLayerTruncation(codeBlocks: codeBlocks, layers: layers)
        if profiling {
            let t = CFAbsoluteTimeGetCurrent()
            print("      PROFILE truncation: \(String(format: "%.4f", t - truncStart))s")
        }

        // Group code blocks by (resolutionLevel, componentIndex, subband)
        struct BandKey: Hashable {
            let res: Int; let comp: Int; let subband: J2KSubband
        }
        var blocksByBand: [BandKey: [J2KCodeBlock]] = [:]
        for block in effectiveBlocks {
            let key = BandKey(res: block.resolutionLevel, comp: block.componentIndex, subband: block.subband)
            blocksByBand[key, default: []].append(block)
        }

        // Use actual decomposition levels and component count from the pipeline,
        // not from code blocks, to ensure every expected packet is emitted even
        // when subbands contain all-zero code blocks.
        let numResolutions = decompositionLevels + 1
        let numComponents = componentCount
        let cbWidth = config.codeBlockSize.width
        let cbHeight = config.codeBlockSize.height

        var packetEnds: [Int] = []
        packetEnds.reserveCapacity(resolutionLayerCount * numResolutions * numComponents)

        // One precinct per resolution. Assign each resolution's complete blocks to its first layer;
        // every other packet for that resolution is empty, so no code-block continuation is required.
        // With one layer this retains the existing resolution -> component byte sequence.
        let resolutionFirst = config.progressionOrder == .rlcp
        let outerCount = resolutionFirst ? numResolutions : resolutionLayerCount
        let innerCount = resolutionFirst ? resolutionLayerCount : numResolutions
        for outer in 0..<outerCount {
            for inner in 0..<innerCount {
                try Task.checkCancellation()
                let resLevel = resolutionFirst ? outer : inner
                let layer = resolutionFirst ? inner : outer
                let firstLayer = resLevel * resolutionLayerCount / numResolutions
                for compIdx in 0..<numComponents {
                    if layer != firstLayer {
                        tileWriter.writeUInt8(0) // Empty packet header, byte aligned.
                        packetEnds.append(tileWriter.count)
                        continue
                    }
                    // Sub-bands for this resolution
                    let subbands: [J2KSubband] = resLevel == 0 ? [.ll] : [.hl, .lh, .hh]

                    var bandBlocksList: [[J2KCodeBlock]] = []
                    for sb in subbands {
                        let key = BandKey(res: resLevel, comp: compIdx, subband: sb)
                        bandBlocksList.append(blocksByBand[key] ?? [])
                    }

                    try writePacket(
                        into: &tileWriter,
                        bandBlocks: bandBlocksList,
                        codeBlockWidth: cbWidth,
                        codeBlockHeight: cbHeight,
                        tileIndex: tileIndex,
                        resolutionLevel: resLevel,
                        component: compIdx,
                        firstInclusionLayer: firstLayer,
                        geometryCollector: geometryCollector
                    )
                    packetEnds.append(tileWriter.count)
                }
            }
        }

        return (tileWriter.data, packetEnds)
    }

    // MARK: - v5.35.0b Multi-Layer Tile Data Generation

    /// Generates a multi-layer JPEG 2000 tile bitstream for strict
    /// bounded-rate mode (v5.35.0b).
    ///
    /// Unlike `generateTileData` (which emits ONE packet per
    /// resolution × component, all blocks in one layer), this function
    /// emits N packets per resolution × component — one per layer.
    /// PCRD assigns each block a "first inclusion layer" based on its
    /// R-D slope; the block's data appears exactly once, in that
    /// layer's packet for its band. Higher-layer packets for the same
    /// band emit only inclusion-tag-tree continuation bits.
    ///
    /// This gives the strict-mode codestream truncator N× more legal
    /// truncation boundaries, so a 1.0× cap can land much closer to
    /// achieved bytes than the single-layer 6-packet boundary set
    /// (which on px_001 / dx_002 dropped to 0.31× of cap).
    ///
    /// Returns the tile data along with byte offsets where each
    /// emitted packet ends — N × numResolutions × numComponents
    /// packet boundaries total. Truncation picks the largest offset
    /// that fits the byte cap.
    private func generateMultiLayerTileData(
        codeBlocks: [J2KCodeBlock], layers: [QualityLayer],
        decompositionLevels: Int, componentCount: Int
    ) throws -> (data: Data, packetEnds: [Int]) {
        precondition(layers.count >= 1, "must have at least 1 layer")

        // Build per-block first-inclusion-layer map. PCRD's
        // QualityLayer.codeBlockContributions[blockIdx] is the
        // cumulative pass count assigned to that block by layer L
        // (or earlier). For HT cleanup-only the only meaningful
        // values are 0 (excluded) and 1 (included). The layer where
        // the value first becomes > 0 is the first-inclusion layer.
        let neverIncludedSentinel: Int32 = 999
        var firstInclusion: [Int: Int32] = [:]
        for (layerIdx, layer) in layers.enumerated() {
            for (blockIdx, passCount) in layer.codeBlockContributions
            where passCount > 0 && firstInclusion[blockIdx] == nil {
                firstInclusion[blockIdx] = Int32(layerIdx)
            }
        }

        let totalBlockBytes = codeBlocks.reduce(0) { $0 + $1.data.count }
        var tileWriter = J2KBitWriter(
            capacity: totalBlockBytes + totalBlockBytes / 8 + 1024)

        // Group blocks by (resolution, component, subband)
        struct BandKey: Hashable {
            let res: Int; let comp: Int; let subband: J2KSubband
        }
        var blocksByBand: [BandKey: [J2KCodeBlock]] = [:]
        for block in codeBlocks where block.passeCount > 0 || firstInclusion[block.index] != nil {
            // Include all blocks that PCRD assigned to any layer; the
            // per-layer packet emitter only emits data for the layer
            // matching the block's first-inclusion layer.
            let key = BandKey(
                res: block.resolutionLevel,
                comp: block.componentIndex,
                subband: block.subband)
            blocksByBand[key, default: []].append(block)
        }

        // Build per-band tag trees — persistent across layers. Each
        // call to .encode(threshold:) emits only the new bits needed
        // to advance the threshold. The `known` flag in the tree's
        // node state means already-included leaves don't re-emit bits.
        struct BandTrees {
            var inclusion: J2KTagTree
            var zbp: J2KTagTree
        }
        let cbWidth = config.codeBlockSize.width
        let cbHeight = config.codeBlockSize.height
        var trees: [BandKey: BandTrees] = [:]
        for (key, band) in blocksByBand {
            guard !band.isEmpty else { continue }
            let blocksX = band.map { $0.x / cbWidth }.max()! + 1
            let blocksY = band.map { $0.y / cbHeight }.max()! + 1
            var inc = J2KTagTree(width: blocksX, height: blocksY)
            var zbp = J2KTagTree(width: blocksX, height: blocksY)
            for (idx, block) in band.enumerated() {
                let layerVal = firstInclusion[block.index] ?? neverIncludedSentinel
                inc.setValue(leafIndex: idx, value: layerVal)
                if layerVal != neverIncludedSentinel {
                    zbp.setValue(leafIndex: idx, value: Int32(block.zeroBitPlanes))
                }
            }
            trees[key] = BandTrees(inclusion: inc, zbp: zbp)
        }

        let numResolutions = decompositionLevels + 1
        let numComponents = componentCount

        var packetEnds: [Int] = []
        packetEnds.reserveCapacity(layers.count * numResolutions * numComponents)

        // LRCP outer loop: layer → resolution → component (single-precinct)
        for layerIdx in 0..<layers.count {
            for resLevel in 0..<numResolutions {
                for compIdx in 0..<numComponents {
                    let subbands: [J2KSubband] = resLevel == 0
                        ? [.ll] : [.hl, .lh, .hh]

                    let bandKeys = subbands.map {
                        BandKey(res: resLevel, comp: compIdx, subband: $0)
                    }

                    // Determine if this packet has any newly-included blocks
                    var newlyIncludedBlocks: [J2KCodeBlock] = []
                    for key in bandKeys {
                        if let band = blocksByBand[key] {
                            for block in band where firstInclusion[block.index] == Int32(layerIdx) {
                                newlyIncludedBlocks.append(block)
                            }
                        }
                    }

                    tileWriter.setByteStuffing(true)

                    if newlyIncludedBlocks.isEmpty {
                        // Empty packet for this (layer, res, comp) —
                        // tag trees still don't emit bits for this
                        // packet (skipped). Decoders handle empty
                        // packets identically.
                        tileWriter.writeBit(false)
                        tileWriter.alignToByte()
                        tileWriter.setByteStuffing(false)
                        packetEnds.append(tileWriter.count)
                        continue
                    }

                    tileWriter.writeBit(true)

                    // Emit per-band header
                    for key in bandKeys {
                        guard let band = blocksByBand[key], !band.isEmpty,
                              var bandTrees = trees[key] else { continue }

                        for (idx, block) in band.enumerated() {
                            let firstInc = firstInclusion[block.index]
                                ?? neverIncludedSentinel
                            // Inclusion: encode threshold = layerIdx + 1.
                            // Tree state tracks `known` so already-included
                            // blocks (firstInc < layerIdx) emit nothing,
                            // never-included blocks (firstInc > layerIdx)
                            // emit continuation 0-bits, newly-included
                            // (firstInc == layerIdx) emit final 1-bit.
                            bandTrees.inclusion.encode(
                                writer: &tileWriter,
                                leafIndex: idx,
                                threshold: Int32(layerIdx + 1))

                            // Only newly-included blocks contribute data
                            guard firstInc == Int32(layerIdx) else { continue }

                            // ZBP tag tree (one-time per block)
                            bandTrees.zbp.encode(
                                writer: &tileWriter,
                                leafIndex: idx,
                                threshold: Int32(block.zeroBitPlanes) + 1)

                            // Number of new coding passes — HT cleanup-only
                            // is always 1 pass per block. Table B.4: "0"
                            // encodes 1 pass.
                            tileWriter.writeBit(false)

                            // Length per ISO 15444-1 B.10.7. For HT
                            // cleanup-only, passes = 1 → log2(passes) = 0.
                            // Lblock starts at 3 and grows until totalBits
                            // covers the length.
                            let length = block.data.count
                            var lblock = 3
                            var totalBits = lblock
                            let bitsNeeded = length > 0
                                ? (Int.bitWidth - length.leadingZeroBitCount)
                                : 1
                            while totalBits < bitsNeeded {
                                tileWriter.writeBit(true)
                                lblock += 1
                                totalBits = lblock
                            }
                            tileWriter.writeBit(false)
                            if totalBits > 0 {
                                try tileWriter.writeBits(
                                    UInt32(length), count: totalBits)
                            }
                        }
                        // Persist mutated tree state back
                        trees[key] = bandTrees
                    }

                    // Pad header to byte boundary, then disable byte
                    // stuffing for raw block data
                    tileWriter.alignToByte()
                    tileWriter.setByteStuffing(false)

                    // Append raw bytes for newly-included blocks (band order, raster)
                    for key in bandKeys {
                        if let band = blocksByBand[key] {
                            for block in band where firstInclusion[block.index] == Int32(layerIdx) {
                                tileWriter.appendRawBytes(block.data)
                            }
                        }
                    }

                    packetEnds.append(tileWriter.count)
                }
            }
        }

        return (tileWriter.data, packetEnds)
    }

    /// Writes a single JPEG 2000 packet directly into a shared bit writer.
    ///
    /// Per ISO/IEC 15444-1 Annex B.10, inclusion and zero bit-plane information
    /// are encoded using tag trees. Code-block order within each band follows
    /// raster (row-major) scan order.
    ///
    /// - Parameters:
    ///   - writer: The shared bit writer to append the packet into.
    ///   - bandBlocks: Array of code-block arrays, one per sub-band.
    ///   - codeBlockWidth: Nominal code-block width.
    ///   - codeBlockHeight: Nominal code-block height.
    private func writePacket(
        into writer: inout J2KBitWriter,
        bandBlocks: [[J2KCodeBlock]],
        codeBlockWidth: Int,
        codeBlockHeight: Int,
        // v6-alpha3 step 6A — geometry trace plumbing. Production
        // callers leave both nil; the cost is then a single nil-check
        // per band (negligible).
        tileIndex: Int = 0,
        resolutionLevel: Int = 0,
        component: Int = 0,
        firstInclusionLayer: Int = 0,
        geometryCollector: GeometryCollector? = nil
    ) throws {
        // Enable JPEG 2000 byte stuffing for packet headers (ISO 15444-1 B.10.1)
        writer.setByteStuffing(true)

        // Check if any code block across all bands has data
        let anyIncluded = bandBlocks.contains { band in
            band.contains { !$0.data.isEmpty && $0.passeCount > 0 }
        }

        if !anyIncluded {
            writer.writeBit(false) // empty packet
            writer.alignToByte()
            writer.setByteStuffing(false)
            return
        }

        // Non-empty packet
        writer.writeBit(true)

        // Collect included blocks in band order for appending data later
        var allIncludedBlocks: [J2KCodeBlock] = []

        // v6-alpha3 step 6A — accumulate per-band geometry for the
        // collector if one was supplied.
        var traceBands: [GeometryPacketBand] = []

        // Process each band completely before moving to next
        for band in bandBlocks {
            guard !band.isEmpty else { continue }

            // Compute code-block grid dimensions for this band
            let blocksX = band.map { $0.x / codeBlockWidth }.max()! + 1
            let blocksY = band.map { $0.y / codeBlockHeight }.max()! + 1

            // v6-alpha7 phase 1 — sub-stage timing: tag tree build
            // (construction + setValue per block).
            let tBuild0 = CFAbsoluteTimeGetCurrent()

            // Earlier empty packets did not advance the tag tree; signal the actual first inclusion layer.
            var inclusionTree = J2KTagTree(width: blocksX, height: blocksY)
            // Create zero bit-plane tag tree
            var zbpTree = J2KTagTree(width: blocksX, height: blocksY)

            // Set tag tree values
            for (idx, block) in band.enumerated() {
                let included = !block.data.isEmpty && block.passeCount > 0
                inclusionTree.setValue(leafIndex: idx, value: included ? Int32(firstInclusionLayer) : 999)
                zbpTree.setValue(leafIndex: idx, value: Int32(block.zeroBitPlanes))
            }
            J2KTier2Timings.recordTagTreeBuild(CFAbsoluteTimeGetCurrent() - tBuild0)

            // v6-alpha3 step 6A — record one entry per block in the
            // tag-tree iteration order. `bodyOrderIndex` is set after
            // the loop for included blocks.
            var traceEntries: [GeometryPacketBlockEntry] = []
            if geometryCollector != nil {
                traceEntries.reserveCapacity(band.count)
            }

            // Encode each code-block in raster order
            for (idx, block) in band.enumerated() {
                let included = !block.data.isEmpty && block.passeCount > 0

                // 1. Inclusion: the first nonempty packet contributes the complete code block.
                let tInc0 = CFAbsoluteTimeGetCurrent()
                inclusionTree.encode(writer: &writer, leafIndex: idx, threshold: Int32(firstInclusionLayer + 1))
                J2KTier2Timings.recordTagTreeInclusionEncode(
                    CFAbsoluteTimeGetCurrent() - tInc0)

                if geometryCollector != nil {
                    traceEntries.append(GeometryPacketBlockEntry(
                        x: block.x, y: block.y,
                        width: block.width, height: block.height,
                        included: included,
                        bodyOrderIndex: included ? allIncludedBlocks.count : nil))
                }

                guard included else { continue }

                // 2. Zero bit-planes: tag tree encode (encode exact value P)
                let tZBP0 = CFAbsoluteTimeGetCurrent()
                zbpTree.encode(writer: &writer, leafIndex: idx, threshold: Int32(block.zeroBitPlanes) + 1)
                J2KTier2Timings.recordTagTreeZBPEncode(
                    CFAbsoluteTimeGetCurrent() - tZBP0)

                // 3. Number of coding passes per ISO 15444-1 Table B.4
                let tPasses0 = CFAbsoluteTimeGetCurrent()
                let passes = block.passeCount
                if passes == 1 {
                    // 0
                    writer.writeBit(false)
                } else if passes == 2 {
                    // 10
                    writer.writeBit(true); writer.writeBit(false)
                } else if passes <= 5 {
                    // 11 + 2-bit value (passes - 3)
                    writer.writeBit(true); writer.writeBit(true)
                    let val = passes - 3
                    writer.writeBit(val & 0x02 != 0)
                    writer.writeBit(val & 0x01 != 0)
                } else if passes <= 36 {
                    // 1111 + 5-bit value (passes - 6) per ISO 15444-1 Table B.4
                    writer.writeBit(true); writer.writeBit(true)
                    writer.writeBit(true); writer.writeBit(true)
                    try writer.writeBits(UInt32(passes - 6), count: 5)
                } else {
                    // 1111 + 11111 + 7-bit value (passes - 37) per ISO 15444-1 Table B.4
                    writer.writeBit(true); writer.writeBit(true)
                    writer.writeBit(true); writer.writeBit(true)
                    try writer.writeBits(31, count: 5)
                    try writer.writeBits(UInt32(passes - 37), count: 7)
                }
                J2KTier2Timings.recordPassesEncoding(
                    CFAbsoluteTimeGetCurrent() - tPasses0)

                // 4. Data length per ISO 15444-1 B.10.7
                // Total bits = Lblock + floor(log2(numpasses))
                let tLen0 = CFAbsoluteTimeGetCurrent()
                let length = block.data.count
                let passLog = passes > 1 ? (Int.bitWidth - passes.leadingZeroBitCount - 1) : 0
                var lblock = 3
                var totalBits = lblock + passLog
                let bitsNeeded = length > 0 ? (Int.bitWidth - length.leadingZeroBitCount) : 1
                while totalBits < bitsNeeded {
                    writer.writeBit(true)
                    lblock += 1
                    totalBits = lblock + passLog
                }
                writer.writeBit(false)
                if totalBits > 0 {
                    try writer.writeBits(UInt32(length), count: totalBits)
                }
                J2KTier2Timings.recordLengthSignaling(
                    CFAbsoluteTimeGetCurrent() - tLen0)
                allIncludedBlocks.append(block)
            }

            if geometryCollector != nil {
                let subband = band.first!.subband   // band non-empty by guard above
                traceBands.append(GeometryPacketBand(
                    subband: subband,
                    tagTreeWidth: blocksX,
                    tagTreeHeight: blocksY,
                    entries: traceEntries))
            }
        }

        // Pad header to byte boundary, then disable stuffing for raw block data
        writer.alignToByte()
        writer.setByteStuffing(false)

        // Append code-block bitstream data in band order directly into shared writer
        let tRaw0 = CFAbsoluteTimeGetCurrent()
        for block in allIncludedBlocks {
            writer.appendRawBytes(block.data)
        }
        J2KTier2Timings.recordRawDataAppend(CFAbsoluteTimeGetCurrent() - tRaw0)
        J2KTier2Timings.recordWritePacketCall(includedBlocks: allIncludedBlocks.count)

        if let collector = geometryCollector, !traceBands.isEmpty {
            collector.addPacket(GeometryPacket(
                tileIndex: tileIndex,
                resolutionLevel: resolutionLevel,
                componentIndex: component,
                bands: traceBands))
        }
    }

    // MARK: - Progress Reporting

    private func reportProgress(
        _ callback: ((EncoderProgressUpdate) -> Void)?,
        stage: EncodingStage,
        stageProgress: Double
    ) {
        guard let callback = callback else { return }
        let stages = EncodingStage.allCases
        guard let stageIndex = stages.firstIndex(of: stage) else { return }
        let stageWeight = 1.0 / Double(stages.count)
        let overall = Double(stageIndex) * stageWeight + stageProgress * stageWeight
        callback(EncoderProgressUpdate(
            stage: stage,
            progress: stageProgress,
            overallProgress: min(overall, 1.0)
        ))
    }

    // MARK: - JPEG 2000 Step Size Encoding

    /// Encodes a quantization step size as a JPEG 2000 (ε_b, μ_b) pair.
    ///
    /// Per ISO/IEC 15444-1 Eq. E.3, the decoder reconstructs the step as:
    /// ```
    ///   Δ_b = 2^(R_b - ε_b) × (1 + μ_b / 2^11)
    /// ```
    /// Given the actual step `Δ_b` and `R_b` (rangeBits = bitDepth + guardBits),
    /// we solve:
    /// ```
    ///   ε_b = R_b - floor(log2(Δ_b))
    ///   μ_b = round((Δ_b / 2^(R_b - ε_b) - 1) × 2048)
    /// ```
    ///
    /// - Parameters:
    ///   - step: The actual quantization step size used during encoding.
    ///   - rangeBits: R_b = image bit depth + guard bits.
    /// - Returns: Tuple of (exponent, mantissa) for the QCD marker.
    static func encodeJ2KStepSize(_ step: Double, rangeBits: Int) -> (exponent: Int, mantissa: Int) {
        guard step > 0 else { return (0, 0) }

        // floor(log2(step)) gives the power-of-2 part
        let log2Step = Foundation.log2(step)
        let floorLog2 = Int(Foundation.floor(log2Step))

        // ε_b = R_b - floorLog2
        let exponent = rangeBits - floorLog2
        let clampedExponent = max(0, min(31, exponent))

        // Reconstruct what 2^(R_b - ε_b) would be with clamped exponent
        let basePow = Foundation.pow(2.0, Double(rangeBits - clampedExponent))

        // μ_b = round((step / basePow - 1) × 2048)
        let mantissa: Int
        if basePow > 0 {
            let normalized = step / basePow
            mantissa = max(0, min(2047, Int((normalized - 1.0) * 2048.0 + 0.5)))
        } else {
            mantissa = 0
        }

        return (clampedExponent, mantissa)
    }

    /// Mathematical ceiling division for a possibly-negative numerator
    /// and positive denominator. Used by the canvas-anchored
    /// code-block partition (ISO/IEC 15444-1 B.7) to compute the
    /// band canvas-coord origin per Eq. B-15:
    ///   `tbx0 = ceil((tcx0 - x_offset_b) / 2^d)`
    /// where the numerator `tcx0 - x_offset_b` can be negative when
    /// the tile origin is smaller than the subband's `2^(d-1)` offset
    /// (e.g. an HL band of a tile at origin (0, …)).
    ///
    /// Swift's integer `/` truncates toward zero, so `-5 / 3 == -1`
    /// rather than the mathematical floor `-2`. The ceiling is:
    ///   - num ≥ 0: `(num + den - 1) / den`
    ///   - num < 0: `-((-num) / den)` (since `ceil(num/den) = -floor(-num/den)`).
    static func ceilDivIntegerOrigin(_ num: Int, _ den: Int) -> Int {
        precondition(den > 0)
        if num >= 0 { return (num + den - 1) / den }
        return -((-num) / den)
    }
}

// MARK: - vDSP-Accelerated Type Conversions

/// Vectorised type conversion helpers using Accelerate/vDSP when available.
///
/// These replace scalar `map { Float($0) }` / `map { Int32($0) }` conversions
/// with vDSP vector operations that are 2–4× faster for large arrays.
/// Falls back to scalar conversion on non-Apple platforms.
enum vDSPConvert: Sendable {
    /// Converts `[Int32]` to `[Float]` using vDSP.
    @inline(__always)
    static func int32sToFloats(_ input: [Int32]) -> [Float] {
        #if canImport(Accelerate)
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vflt32(
                    UnsafePointer<Int32>(src.baseAddress!), 1,
                    dst.baseAddress!, 1,
                    vDSP_Length(input.count)
                )
            }
        }
        return output
        #else
        return input.map { Float($0) }
        #endif
    }

    /// Converts `[Double]` to `[Float]` using vDSP.
    @inline(__always)
    static func doublesToFloats(_ input: [Double]) -> [Float] {
        #if canImport(Accelerate)
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vdpsp(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
        return output
        #else
        return input.map { Float($0) }
        #endif
    }

    /// Converts `[Float]` to `[Double]` using vDSP.
    @inline(__always)
    static func floatsToDoubles(_ input: [Float]) -> [Double] {
        #if canImport(Accelerate)
        var output = [Double](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vspdp(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
        return output
        #else
        return input.map { Double($0) }
        #endif
    }

    /// Converts `[Float]` to `[Int32]` with rounding using vDSP.
    @inline(__always)
    static func floatsToInt32s(_ input: [Float]) -> [Int32] {
        #if canImport(Accelerate)
        var output = [Int32](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vfixr32(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
        return output
        #else
        return input.map { j2kClampedInt32(Double($0)) }
        #endif
    }

    /// Converts `[Int32]` to `[Double]` using vDSP.
    @inline(__always)
    static func int32sToDoubles(_ input: [Int32]) -> [Double] {
        #if canImport(Accelerate)
        var output = [Double](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vflt32D(
                    UnsafePointer<Int32>(src.baseAddress!), 1,
                    dst.baseAddress!, 1,
                    vDSP_Length(input.count)
                )
            }
        }
        return output
        #else
        return input.map { Double($0) }
        #endif
    }

    /// Converts `[Double]` to `[Int32]` with rounding using vDSP.
    @inline(__always)
    static func doublesToInt32s(_ input: [Double]) -> [Int32] {
        #if canImport(Accelerate)
        var output = [Int32](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vfixr32D(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(input.count))
            }
        }
        return output
        #else
        return input.map { j2kClampedInt32($0) }
        #endif
    }
}
