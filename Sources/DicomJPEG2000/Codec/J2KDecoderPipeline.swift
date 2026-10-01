//
// J2KDecoderPipeline.swift
// J2KSwift
//
// J2KDecoderPipeline.swift
// J2KSwift
//
// Decoder pipeline implementation for JPEG 2000 decoding.
// Modified for Isis #2341: cooperative decode cancellation and inherited task priorities.
//

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

// MARK: - Decoding Stage

/// Represents the stages of the JPEG 2000 decoding pipeline.
public enum DecodingStage: String, Sendable, CaseIterable {
    /// Codestream parsing and marker validation.
    case codestreamParsing = "Codestream Parsing"

    /// Tile data extraction from packets.
    case tileExtraction = "Tile Extraction"

    /// Entropy decoding (EBCOT bit-plane decoding).
    case entropyDecoding = "Entropy Decoding"

    /// Dequantization of wavelet coefficients.
    case dequantization = "Dequantization"

    /// Inverse wavelet transform.
    case inverseWaveletTransform = "Inverse Wavelet Transform"

    /// Inverse colour space transformation.
    case inverseColorTransform = "Inverse Color Transform"

    /// Image reconstruction.
    case imageReconstruction = "Image Reconstruction"
}

// MARK: - Progress Update

/// Reports progress during decoding.
public struct DecoderProgressUpdate: Sendable {
    /// The current decoding stage.
    public let stage: DecodingStage

    /// Progress within the current stage (0.0 to 1.0).
    public let progress: Double

    /// Overall decoding progress (0.0 to 1.0).
    public let overallProgress: Double
}

// MARK: - Decoder Configuration

/// Configuration for the decoder pipeline.
struct DecoderConfiguration: Sendable {
    /// Number of decomposition levels (from COD marker).
    var decompositionLevels: Int = 5

    /// Code block size (from COD marker).
    var codeBlockSize: (width: Int, height: Int) = (32, 32)

    /// Whether to use reversible colour transform.
    var useReversibleTransform: Bool = true
    /// SGcod multiple component transformation value: 0 none, 1 Part 1 RCT/ICT, 2 Part 2 Annex J (T.801 Table A.8).
    var mctMode: Int = 0

    /// Number of quality layers (from COD marker).
    var qualityLayers: Int = 1

    /// Progression order (from COD marker).
    var progressionOrder: J2KProgressionOrder = .lrcp

    /// Wavelet filter type (from COD marker).
    var waveletFilter: J2KDWT1D.Filter = .reversible53

    /// Whether HTJ2K block coding is used (from COD marker bit 6).
    var useHTJ2K: Bool = false

    /// Per-resolution precinct size exponents (from COD when Scod bit 0
    /// is set; nil for default precinct sizes — one precinct per band).
    /// Each entry is `(widthExp, heightExp)`. ISO 15444-1 A.6.1: at
    /// resolution 0 (LL) the precinct covers a 2^widthExp × 2^heightExp
    /// region of LL; at r > 0 each sub-band precinct is 2^(widthExp-1)
    /// × 2^(heightExp-1). v5.35.0d-decode addition.
    var precinctExponents: [(widthExp: Int, heightExp: Int)]? = nil


    // Code-block style, SPcod/SPcoc byte (ISO/IEC 15444-1 Table A.19). Every bit changes how the entropy data is
    // segmented or how contexts are formed, so a bit that is read but not honoured decodes wrong pixels silently.

    /// Selective arithmetic coding bypass (bit 0): after the first ten passes the significance-propagation and
    /// magnitude-refinement passes are raw, and each raw or arithmetic run is its own codeword segment.
    var useSelectiveArithmeticBypass: Bool = false

    /// Reset context probabilities at every coding pass boundary (bit 1).
    var resetContextOnEachPass: Bool = false

    /// Terminate the codeword segment at every coding pass, RESTART (bit 2).
    var terminateOnEachPass: Bool = false

    /// Vertically causal context formation (bit 3): a stripe's contexts ignore the stripe below.
    var verticallyCausalContext: Bool = false

    /// Predictable termination (bit 4). The MQ decoder reads such segments unchanged; the bit only lets a
    /// decoder check the spare bits, which this one does not.
    var usePredictableTermination: Bool = false

    /// Segmentation symbols (bit 5): a four-symbol `0xA` sentinel after every cleanup pass.
    var useSegmentationSymbols: Bool = false

    /// Applies the SPcod/SPcoc code-block style byte.
    mutating func applyCodeBlockStyle(_ style: UInt8) {
        useSelectiveArithmeticBypass = style & 0x01 != 0
        resetContextOnEachPass = style & 0x02 != 0
        terminateOnEachPass = style & 0x04 != 0
        verticallyCausalContext = style & 0x08 != 0
        usePredictableTermination = style & 0x10 != 0
        useSegmentationSymbols = style & 0x20 != 0
        useHTJ2K = style & 0x40 != 0
    }

    /// Per-component DC offset values from DCO marker segment (Part 2).
    ///
    /// When non-nil, the decoder applies these offsets after inverse wavelet
    /// transform to restore original component values.
    var dcOffsets: [J2KDCOffsetValue]?

    /// Extended precision configuration (Part 2).
    ///
    /// Controls guard bit count and rounding mode for coefficient processing.
    var extendedPrecision: J2KExtendedPrecisionConfiguration = .default

    /// Wavelet kernel configuration (Part 2).
    ///
    /// Specifies which wavelet kernels to use per tile-component.
    /// When nil, uses the waveletFilter property for all components.
    var waveletKernelConfiguration: J2KWaveletKernelConfiguration?
}

// MARK: - Codestream Metadata

/// Metadata extracted from codestream markers.
struct CodestreamMetadata: Sendable {
    /// Image width.
    var width: Int

    /// Image height.
    var height: Int

    /// Number of components.
    var componentCount: Int

    /// Component information.
    var components: [ComponentInfo]

    /// Tile size.
    var tileSize: (width: Int, height: Int)

    /// Image offset (XOsiz, YOsiz).
    var imageOffset: (x: Int, y: Int) = (0, 0)

    /// Tile offset (XTOsiz, YTOsiz).
    var tileOffset: (x: Int, y: Int) = (0, 0)

    /// Configuration from COD marker.
    var configuration: DecoderConfiguration

    /// Quantization step sizes from QCD marker.
    var quantizationSteps: [String: Double]

    /// Guard bits from QCD marker Sqcd byte.
    var quantizationGuardBits: Int

    /// Band-level Kb values (number of magnitude bit-planes) per subband.
    /// Keyed by "{subband}_{level}" matching quantizationSteps keys.
    var bandKbValues: [String: Int]

    /// DCO marker segment from codestream (Part 2).
    ///
    /// Present when the codestream contains a DCO marker segment (0xFF5C)
    /// signaling per-component DC offset values.
    var dcoMarkerSegment: J2KDCOMarkerSegment?
    /// Annex J multiple component transformations of the main header (MCT/MCC/MCO/CBD), nil when absent.
    var part2: J2KPart2ComponentTransforms? = nil

    /// Number of tiles in X direction (T.800 B-5: ⌈(Xsiz − XTOsiz) / XTsiz⌉).
    var numTilesX: Int { max(1, (imageOffset.x + width - tileOffset.x + tileSize.width - 1) / tileSize.width) }

    /// Number of tiles in Y direction.
    var numTilesY: Int { max(1, (imageOffset.y + height - tileOffset.y + tileSize.height - 1) / tileSize.height) }

    /// Total number of tiles.
    var totalTiles: Int { numTilesX * numTilesY }

    /// Whether this is a multi-tile codestream.
    var isMultiTile: Bool { totalTiles > 1 }

    /// A tile's origin on the reference grid and its size, clipped to the image (T.800 Eq. B-7). With zero image
    /// and tile offsets the origin is also the tile's position in the decoded image.
    func tileDimensions(tileIndex: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let col = tileIndex % numTilesX
        let row = tileIndex / numTilesX
        let x0 = max(tileOffset.x + col * tileSize.width, imageOffset.x)
        let y0 = max(tileOffset.y + row * tileSize.height, imageOffset.y)
        let x1 = min(tileOffset.x + (col + 1) * tileSize.width, imageOffset.x + width)
        let y1 = min(tileOffset.y + (row + 1) * tileSize.height, imageOffset.y + height)
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// Whether the image or tile grid starts away from the reference-grid origin.
    var hasGridOffsets: Bool { imageOffset != (0, 0) || tileOffset != (0, 0) }

    struct ComponentInfo: Sendable {
        var bitDepth: Int
        var signed: Bool
        var subsamplingX: Int
        var subsamplingY: Int
        /// Reconstructed depth/sign from a CBD marker segment (T.801 Annex J); nil when the coded depth is the output.
        var outputBitDepth: Int? = nil
        var outputSigned: Bool? = nil
    }
}

// MARK: - Decoder Pipeline

/// Internal decoding pipeline that connects all JPEG 2000 decoding components.
///
/// The pipeline processes a codestream through these stages:
/// 1. Codestream Parsing — parse markers and extract metadata
/// 2. Tile Extraction — extract tile data from packets
/// 3. Entropy Decoding — EBCOT bit-plane decoding per code block
/// 4. Dequantization — convert integer indices to coefficients
/// 5. Inverse Wavelet Transform — multi-level 2D IDWT reconstruction
/// 6. Inverse Colour Transform — YCbCr → RGB conversion
/// 7. Image Reconstruction — assemble final image
struct DecoderPipeline: Sendable {
    /// v10.5.0 Stage B.1 — partial-resolution decode target level.
    /// When non-nil, `extractTileData` filters code-blocks to only
    /// those needed for resolution level `r ∈ [0, N]` where
    /// `N = metadata.configuration.decompositionLevels`:
    ///   - `r = 0` → only the LL (deepest); thumbnail output
    ///   - `r = N` → all blocks; full decode
    ///   - `r ∈ (0, N)` → LL + deepest r detail levels
    ///
    /// Set by `J2KDecoder.decodeResolution(_:options:)` via the
    /// public API. Stage B.1 saves the dominant entropy decode stage
    /// for skipped blocks; Stage B.2 also truncates the inverse DWT
    /// and outputs reduced-dimension data directly (no separate
    /// downsample step).
    var partialResolutionLevel: Int? = nil

    /// v10.5.0 Stage B.2 — reduced output dimensions for partial
    /// resolution decode. Set in tandem with `partialResolutionLevel`
    /// before the decode runs:
    ///   width  = ⌈metadata.width  / 2^(N-r)⌉
    ///   height = ⌈metadata.height / 2^(N-r)⌉
    /// The downstream stages (color transform, DC unshift,
    /// reconstructImage) substitute this for
    /// `metadata.width × metadata.height` to allocate / iterate
    /// reduced buffers.
    ///
    /// When nil, downstream stages use the full metadata dimensions
    /// (preserves v10.4.0 and earlier behaviour).
    var outputDimensions: (width: Int, height: Int)? = nil

    /// v10.6.0 ROI decode — region of interest in full-image pixel
    /// coordinates. When set, `extractTileData` keeps only code-blocks
    /// whose inverse-DWT spatial footprint (plus a conservative
    /// synthesis-filter halo) overlaps the region; entropy decode is
    /// skipped for the rest. The inverse DWT still runs full-tile —
    /// off-region blocks reconstruct as zeros, which is harmless
    /// because the caller crops to the region afterwards. Every block
    /// influencing an in-region pixel is retained, so the cropped
    /// output is bit-identical to a full decode + crop.
    ///
    /// Set by `J2KDecoder.decodeRegion(_:options:)` for the `.direct`
    /// strategy. nil = no spatial filtering (full decode).
    var regionOfInterest: J2KRegion? = nil

    /// v10.9.0 quality-layer decode — when set, the multi-layer packet
    /// decode (`extractTileDataMultiLayer`) processes only quality
    /// layers `0...maxQualityLayer`, discarding the refinement carried
    /// by higher layers. nil = decode every layer (full quality). Has
    /// no effect on single-layer codestreams. Set by
    /// `J2KDecoder.decodeQuality(_:options:)`.
    var maxQualityLayer: Int? = nil

    /// Byte order of 16-bit output samples (issue #2902). Big-endian by default, as the PGM writers expect; the DICOM
    /// backend asks for little-endian so a frame needs no second pass.
    var outputByteOrder: J2KComponent.ByteOrder = .bigEndian

    /// Byte accounting of a quality-limited decode (issue #2382): packet bytes of layers beyond `maxQualityLayer`
    /// are parsed but never entropy-decoded. Shared by reference so parallel tiles add into one report.
    var partialAccounting: J2KPartialDecodeAccounting? = nil

    /// Tier-2 reuse between refinements (issue #2382): the multi-layer packet parse of every tile is kept with
    /// per-layer contributions, so decoding a higher layer truncates the cached blocks instead of re-reading
    /// packets. Tier-1 and the inverse DWT run again for the refined layer.
    var layeredBlockCache: J2KLayeredBlockCache? = nil

    // MARK: - v6.2.0 — GPU inverse 5/3 INT DWT routing gate
    //
    // Originally proposed as a default-on flip mirroring v6.1.0's
    // encode-side `_gpuForward53Enabled` (#310). PR #313 had measured
    // that default `decode(_:)` runs entirely on CPU at DX 6.4 MP
    // (gpuHT = 0 across the corpus) and iDWT was 36.3 % of DX wall,
    // so default-on looked like a free 30 %+ win.
    //
    // **Empirical reality (this PR's wall-time A/B): a regression on
    // every corpus fixture including DX (−8.3 %).** Routing through
    // `decodeGPU` for lossless 5/3 INT pays dispatch + per-decode
    // pipeline init cost without enough savings — the CPU 5/3 INT
    // iDWT (Accelerate-vectorised) is already very fast on M2, and
    // the GPU iDWT path was tuned for lossy 9/7 Float where it has
    // bigger relative gains. Per memory `project_gpu97_warm_session_ceiling.md`
    // the real win is at ≥3 MP via `decodeWithGPUHT` (which ALSO
    // sets `useGPUHT = true` for HT entropy on GPU); just routing to
    // `decodeGPU` (iDWT only) doesn't move the needle.
    //
    // **Default left OFF** in this PR. Gate infrastructure ships
    // for future work that pursues the right routing target (likely
    // `useGPUHT = true` together with the iDWT routing — Phase D2).
    //
    // Decoded J2KImage pixel data IS byte-identical between gate-on
    // and forced-off paths (lossless contract preserved when this
    // flag is flipped manually) — the regression is wall-time only,
    // not correctness.

    /// v7.2.0 Phase E — gate flag for the cross-tile batched-entropy
    /// decode path (`decodeMultiTileGPUBatched`). When true AND the
    /// codestream is multi-tile + HT-conformant + lossless 5/3 with
    /// a Metal session, the multi-tile decode path aggregates all
    /// tiles' eligible HT codeblocks into a single GPU dispatch
    /// before per-tile post-processing. Amortises the per-tile
    /// MTLCommandBuffer overhead × N tiles which dominates wall-time
    /// on small per-tile sizes (per V720PhaseEThresholdSweepTests).
    /// Default ON — gate exists so tests / probes can opt out for
    /// A/B comparison against the v7.1.1 per-tile-CB shape.
    /// **v8.2 fix**: re-enabled by default. The v7.5.1 hotfix
    /// disabled this path because of silent decode corruption on
    /// 16+ MP mammography fixtures (smallest reproducer 1760×2392
    /// split 2x2). Root cause located 2026-05-10 in
    /// `decodeTilePayloadGPU`: when `preBatchedGPUCoefficients`
    /// short-circuits the entropy stage's GPU dispatch, the
    /// entropy returns `(coeffs, batch=nil)` — `gpuBatch` is `nil`
    /// downstream, so `applyInverseWaveletTransformGPU`'s
    /// `hasFusedFromCodeblocksPlan` CPU-fallback branch does not
    /// fire and the GPU multi-tile-per-tile IDWT runs. That GPU
    /// IDWT path silently corrupts output on certain dimensions.
    /// The fix forces CPU IDWT explicitly when `preBatched` is set
    /// (matching the per-tile path's behaviour with a non-nil
    /// `gpuBatch`). Verified bit-exact across the v8.2 diagnostic
    /// sweep (10 dimensions including the original mg fixture)
    /// and `MgRegressionTriageTest`. The cross-tile entropy
    /// amortisation that v7.2.0 measured (3 % DX 2x2) is restored.
    nonisolated(unsafe) static var _multiTileBatchedEntropyEnabled: Bool = true

    /// **v10.3 (refinement) — default `false`, but the predicate at the
    /// call site (`decodeTilePayloadGPU` line ~1270) now gates on
    /// per-tile pixel size.** Original behaviour: forced CPU IDWT
    /// whenever `preBatchedGPUCoefficients` was set, to sidestep the
    /// GPU multi-tile-per-tile IDWT corruption documented in
    /// V8_2_0_MG_CORRUPTION_ROOT_CAUSE.md (v8.3 root-caused and fixed
    /// the underlying GPU defect, PR #400).
    ///
    /// d117dcc shipped a global `false → true` flip that unlocked the
    /// MG GPU IDWT win but regressed DX/PX in the substitute corpus.
    /// This commit reverts the default to `false` and adds a per-tile
    /// size predicate at the call site:
    ///   - tile < 3 MP: CPU IDWT (keeps DX/PX 4x4 multi-tile wins)
    ///   - tile ≥ 3 MP: GPU IDWT (captures MG 2x2 multi-tile win)
    ///
    /// Setting this flag to `true` overrides the size gate and forces
    /// GPU IDWT for every tile regardless of size — kept for
    /// diagnostic A/B (replicates d117dcc's behaviour for comparison).
    ///
    /// v8.3 conformance suite + V8_3_GPUIDWTRootCauseDiagnostic +
    /// V8_2_MgBatchedDiagnostic + MgRegressionTriageTest +
    /// V10_3_V82BypassCrossCodecCheck (9 medical-real fixtures
    /// bit-exact) all PASS under both flag states.
    nonisolated(unsafe) static var _v82_disableIDWTRoutingFix: Bool = false

    /// Decodes a JPEG 2000 codestream through the full pipeline.
    ///
    /// - Parameters:
    ///   - data: The JPEG 2000 codestream data.
    ///   - progress: Optional progress callback.
    /// - Returns: The decoded image.
    /// - Throws: ``J2KError`` if decoding fails.
    func decode(
        _ data: Data,
        progress: ((DecoderProgressUpdate) -> Void)? = nil
    ) async throws -> J2KImage {
        // Stage 1: Parse codestream and extract metadata
        try Task.checkCancellation()
        reportProgress(progress, stage: .codestreamParsing, stageProgress: 0.0)
        let (metadata, tiles) = try parseCodestream(data)
        try Task.checkCancellation()
        reportProgress(progress, stage: .codestreamParsing, stageProgress: 1.0)

        // v10.5.0 Stage B.2 — `outputDimensions` is computed by the
        // caller (`J2KDecoder.decodePartialResolution`) and set on the
        // pipeline before this call when partial-resolution decode is
        // active; `decode` reads it but does not mutate `self`.


        // A grid offset puts the tile at a canvas origin other than zero, which the multi-tile path anchors.
        if metadata.isMultiTile || metadata.hasGridOffsets {
            return try await decodeMultiTile(metadata: metadata, tiles: tiles, progress: progress)
        } else {
            // A nominal tile larger than the image codes only the image (Eq. B-7).
            var metadata = metadata
            metadata.tileSize = (width: metadata.width, height: metadata.height)
            let tileData = tiles.first?.tileData ?? Data()
            return try await decodeSingleTile(metadata: metadata, tileData: tileData, progress: progress)
        }
    }

    /// Populates the layer cache from packet headers/bodies without allocating or reconstructing image samples.
    func indexQualityLayers(_ data: Data) throws {
        try Task.checkCancellation()
        let (metadata, tiles) = try parseCodestream(data)
        for tile in tiles {
            try Task.checkCancellation()
            let (x, y, width, height) = metadata.tileDimensions(tileIndex: tile.tileIndex)
            var tileMetadata = metadata
            tileMetadata.width = width
            tileMetadata.height = height
            tileMetadata.tileSize = (width: width, height: height)
            _ = try extractTileDataMultiLayer(tile.tileData, metadata: tileMetadata,
                                             tileOriginX: x, tileOriginY: y, maxQualityLayer: nil)
        }
    }

    // MARK: - GPU-Accelerated Decode

    /// v5.12: maximum number of tiles that can have GPU command
    /// buffers in flight at the same time. Higher values amortize
    /// dispatch overhead but increase peak heap residency. 8 covers
    /// most codestreams without exhausting the default 256 MB heap.
    private static let maxInFlightTilesGPU = 8

    /// v5.12: maximum number of tiles that can be CPU-decoded in
    /// parallel. CPU concurrency scales with available cores; the
    /// bound primarily prevents unbounded memory growth on
    /// codestreams with many large tiles.
    private static let maxInFlightTilesCPU = 8

    /// Decodes a single-tile codestream (original path).
    private func decodeSingleTile(
        metadata: CodestreamMetadata,
        tileData: Data,
        progress: ((DecoderProgressUpdate) -> Void)?
    ) async throws -> J2KImage {
        let profileDecode = ProcessInfo.processInfo.environment["J2K_PROFILE_DECODE"] != nil

        // Stage 2: Extract tile data
        try Task.checkCancellation()
        reportProgress(progress, stage: .tileExtraction, stageProgress: 0.0)
        var t0 = DispatchTime.now()
        let codeBlocks = try extractTileData(
            tileData, metadata: metadata,
            maxResolutionLevel: partialResolutionLevel, regionOfInterest: regionOfInterest,
            maxQualityLayer: maxQualityLayer)
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordExtractTileData(dt / 1000)
            if profileDecode {
                print("PROFILE: extractTileData        = \(String(format: "%.1f", dt)) ms (\(codeBlocks.count) blocks)")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .tileExtraction, stageProgress: 1.0)

        // Stage 3: Entropy decoding
        try Task.checkCancellation()
        reportProgress(progress, stage: .entropyDecoding, stageProgress: 0.0)
        t0 = DispatchTime.now()
        let decodedBlocks = try await applyEntropyDecoding(codeBlocks, metadata: metadata)
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordEntropyDecoding(dt / 1000)
            if profileDecode {
                print("PROFILE: entropyDecoding         = \(String(format: "%.1f", dt)) ms (\(decodedBlocks.count) subbands)")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .entropyDecoding, stageProgress: 1.0)

        // Stage 4: Dequantization
        try Task.checkCancellation()
        reportProgress(progress, stage: .dequantization, stageProgress: 0.0)
        t0 = DispatchTime.now()
        let dequantizedSubbands = try await applyDequantization(decodedBlocks, metadata: metadata)
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordDequantization(dt / 1000)
            if profileDecode {
                print("PROFILE: dequantization          = \(String(format: "%.1f", dt)) ms")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .dequantization, stageProgress: 1.0)

        // Stage 5: Inverse wavelet transform
        try Task.checkCancellation()
        reportProgress(progress, stage: .inverseWaveletTransform, stageProgress: 0.0)
        t0 = DispatchTime.now()
        var spatialData = try await applyInverseWaveletTransform(dequantizedSubbands, metadata: metadata)
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordInverseWaveletTransform(dt / 1000)
            if profileDecode {
                print("PROFILE: inverseWaveletTransform = \(String(format: "%.1f", dt)) ms (\(spatialData.count) components)")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .inverseWaveletTransform, stageProgress: 1.0)

        // Stage 6: Inverse colour transform (in-place to avoid 2 large buffer allocations)
        try Task.checkCancellation()
        reportProgress(progress, stage: .inverseColorTransform, stageProgress: 0.0)
        t0 = DispatchTime.now()
        var part2Shifts: [Double]?
        if let part2 = metadata.part2, part2.isActive {
            part2Shifts = try part2.applyInverse(to: &spatialData, codedDepths: metadata.components.map { ($0.bitDepth, $0.signed) })
        } else {
            try applyInverseColorTransformInPlace(&spatialData, metadata: metadata)
        }
        var rgbData = spatialData
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordInverseColorTransform(dt / 1000)
            if profileDecode {
                print("PROFILE: inverseColorTransform   = \(String(format: "%.1f", dt)) ms")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .inverseColorTransform, stageProgress: 1.0)

        // DC level unshift: for unsigned components, add back 2^(bitDepth-1)
        t0 = DispatchTime.now()
        for (compIdx, compInfo) in metadata.components.enumerated() {
            guard compIdx < rgbData.count else { break }
            if let part2Shifts {
                var dcOffset = compIdx < part2Shifts.count ? part2Shifts[compIdx] : 0
                if dcOffset != 0 {
                    rgbData[compIdx].withUnsafeMutableBufferPointer { buf in
                        #if canImport(Accelerate)
                        vDSP_vsaddD(buf.baseAddress!, 1, &dcOffset, buf.baseAddress!, 1, vDSP_Length(buf.count))
                        #else
                        for i in 0..<buf.count { buf[i] += dcOffset }
                        #endif
                    }
                }
            } else if !compInfo.signed {
                var dcOffset = Double(1 << (compInfo.bitDepth - 1))
                rgbData[compIdx].withUnsafeMutableBufferPointer { buf in
                    #if canImport(Accelerate)
                    vDSP_vsaddD(buf.baseAddress!, 1, &dcOffset, buf.baseAddress!, 1, vDSP_Length(buf.count))
                    #else
                    for i in 0..<buf.count { buf[i] += dcOffset }
                    #endif
                }
            }
        }
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordDcLevelUnshift(dt / 1000)
            if profileDecode {
                print("PROFILE: dcLevelUnshift          = \(String(format: "%.1f", dt)) ms")
            }
        }

        // Stage 7: Image reconstruction
        try Task.checkCancellation()
        reportProgress(progress, stage: .imageReconstruction, stageProgress: 0.0)
        t0 = DispatchTime.now()
        let image = try reconstructImage(rgbData, metadata: metadata)
        do {
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            J2KDecodeTimings.recordReconstructImage(dt / 1000)
            if profileDecode {
                print("PROFILE: reconstructImage        = \(String(format: "%.1f", dt)) ms")
            }
        }
        try Task.checkCancellation()
        reportProgress(progress, stage: .imageReconstruction, stageProgress: 1.0)

        return image
    }

    /// Decodes a multi-tile codestream by processing each tile independently
    /// and assembling the results into the full image.
    /// Result of a per-tile decode: the spatial-domain pixels plus the
    /// destination rectangle so the caller can composite into the full image.
    private struct DecodedTile: Sendable {
        let tileX: Int
        let tileY: Int
        let tileW: Int
        let tileH: Int
        let rgb: [[Double]]
    }

    /// v10.6.0 ROI Stage 1 skipped entropy decode for off-region
    /// code-blocks but still ran the inverse DWT full-tile. v10.7.0
    /// Stage 2 — tile-granular skip: when `regionOfInterest` is set and
    /// a tile lies entirely outside it, every pixel the tile would
    /// produce is cropped away by `decodeRegion`. JPEG 2000 tiles
    /// decode independently — no inverse-DWT halo crosses a tile
    /// boundary — so the whole tile (entropy, dequant, inverse DWT,
    /// colour transform, DC shift) can be skipped. Returns a
    /// correctly-shaped zero `DecodedTile` to short-circuit with, or
    /// nil when the tile overlaps the region and must be decoded.
    /// The region of interest, given in image coordinates, on the reference grid the tiles are placed on.
    private func canvasRegionOfInterest(_ metadata: CodestreamMetadata) -> J2KRegion? {
        regionOfInterest.map {
            J2KRegion(x: $0.x + metadata.imageOffset.x, y: $0.y + metadata.imageOffset.y,
                      width: $0.width, height: $0.height)
        }
    }

    private func roiSkippedTile(
        tileX: Int, tileY: Int, tileW: Int, tileH: Int,
        metadata: CodestreamMetadata
    ) -> DecodedTile? {
        guard let roi = canvasRegionOfInterest(metadata) else { return nil }
        let overlaps = tileX < roi.x + roi.width && tileX + tileW > roi.x
                    && tileY < roi.y + roi.height && tileY + tileH > roi.y
        if overlaps { return nil }
        let zeroRGB: [[Double]] = metadata.components.map { comp in
            let w = max(0, tileW / comp.subsamplingX)
            let h = max(0, tileH / comp.subsamplingY)
            return [Double](repeating: 0, count: w * h)
        }
        return DecodedTile(tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH, rgb: zeroRGB)
    }

    /// End-to-end decode of a single tile (extract → entropy → dequant →
    /// IDWT → colour transform → DC level unshift). Pure function on
    /// `tileMeta` and `tileData`; safe to invoke concurrently across tiles
    /// since each task gets its own metadata copy and the inner stages
    /// allocate their own scratch buffers.
    private func decodeTilePayload(
        metadata: CodestreamMetadata,
        tileIndex: Int,
        tileData: Data
    ) async throws -> DecodedTile {
        let (tileX, tileY, tileW, tileH) = metadata.tileDimensions(tileIndex: tileIndex)

        // v10.7.0 ROI Stage 2 — skip tiles entirely outside the region.
        if let skipped = roiSkippedTile(
            tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH, metadata: metadata) {
            return skipped
        }

        var tileMeta = metadata
        tileMeta.width = tileW
        tileMeta.height = tileH
        tileMeta.tileSize = (width: tileW, height: tileH)

        // v7.2.0 Phase 0 — per-tile stage instrumentation. Mirrors the
        // `decodeSingleTile` pattern. Stage times are accumulated into
        // process-global `J2KDecodeTimings` counters; on multi-tile
        // decodes invoked from `withThrowingTaskGroup`, each parallel
        // tile contributes its CPU-time to the same accumulator, so a
        // sum across stages can exceed the decode wall (semantics
        // identical to the encode-side stage profile).
        var t0 = DispatchTime.now()
        let codeBlocks = try extractTileData(
            tileData, metadata: tileMeta,
            tileOriginX: tileX, tileOriginY: tileY,
            maxResolutionLevel: partialResolutionLevel, regionOfInterest: canvasRegionOfInterest(metadata),
            maxQualityLayer: maxQualityLayer)
        J2KDecodeTimings.recordExtractTileData(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        t0 = DispatchTime.now()
        let decodedBlocks = try await applyEntropyDecoding(codeBlocks, metadata: tileMeta)
        J2KDecodeTimings.recordEntropyDecoding(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        t0 = DispatchTime.now()
        let dequantizedSubbands = try await applyDequantization(decodedBlocks, metadata: tileMeta)
        J2KDecodeTimings.recordDequantization(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        t0 = DispatchTime.now()
        var spatialDataTile = try await applyInverseWaveletTransform(
            dequantizedSubbands, metadata: tileMeta,
            tileOriginX: tileX, tileOriginY: tileY)
        J2KDecodeTimings.recordInverseWaveletTransform(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        t0 = DispatchTime.now()
        var tileShifts: [Double]?
        if let part2 = metadata.part2, part2.isActive {
            tileShifts = try part2.applyInverse(to: &spatialDataTile, codedDepths: metadata.components.map { ($0.bitDepth, $0.signed) })
        } else {
            try applyInverseColorTransformInPlace(&spatialDataTile, metadata: tileMeta)
        }
        J2KDecodeTimings.recordInverseColorTransform(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        t0 = DispatchTime.now()
        for (compIdx, compInfo) in metadata.components.enumerated() {
            guard compIdx < spatialDataTile.count else { break }
            if let tileShifts {
                var dcOffset = compIdx < tileShifts.count ? tileShifts[compIdx] : 0
                if dcOffset != 0 {
                    spatialDataTile[compIdx].withUnsafeMutableBufferPointer { buf in
                        vDSP_vsaddD(buf.baseAddress!, 1, &dcOffset, buf.baseAddress!, 1, vDSP_Length(buf.count))
                    }
                }
            } else if !compInfo.signed {
                var dcOffset = Double(1 << (compInfo.bitDepth - 1))
                spatialDataTile[compIdx].withUnsafeMutableBufferPointer { buf in
                    vDSP_vsaddD(buf.baseAddress!, 1, &dcOffset, buf.baseAddress!, 1, vDSP_Length(buf.count))
                }
            }
        }
        J2KDecodeTimings.recordDcLevelUnshift(
            Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000)

        return DecodedTile(tileX: tileX, tileY: tileY, tileW: tileW, tileH: tileH, rgb: spatialDataTile)
    }

    /// v10.25 — number of resolution halvings active for partial-
    /// resolution decode: `N - r` for `partialResolutionLevel = r`
    /// (clamped to [0, N]), 0 when partial-resolution decode is off.
    /// The reduced canvas is the full canvas ceil-divided by
    /// `2^halvings` per ISO/IEC 15444-1 Eq. B-15.
    private func partialResolutionHalvings(metadata: CodestreamMetadata) -> Int {
        guard let r = partialResolutionLevel else { return 0 }
        let levels = metadata.configuration.decompositionLevels
        return levels - min(max(r, 0), levels)
    }

    /// Composites a decoded tile into the full-image component buffers.
    /// Each tile writes to a non-overlapping rectangle, so calling this
    /// sequentially after all tiles have decoded is safe and fast.
    ///
    /// v10.25 multi-tile partial-resolution — when
    /// `partialResolutionLevel` is active, each tile's `rgb` holds the
    /// truncated-iDWT output whose dimensions follow the spec ceil-div
    /// canvas formula at depth `h = N - r`:
    ///   srcW = ⌈tcx1 / 2^h⌉ - ⌈tcx0 / 2^h⌉   (tcx0/tcx1 = tile-
    ///   srcH = ⌈tcy1 / 2^h⌉ - ⌈tcy0 / 2^h⌉    component canvas bounds)
    /// and its destination rectangle in the REDUCED canvas starts at
    /// (⌈tcx0 / 2^h⌉, ⌈tcy0 / 2^h⌉) with row stride ⌈compW / 2^h⌉.
    /// Because ceil-div intervals of adjacent tiles share endpoints,
    /// the reduced tiles partition the reduced canvas exactly — no
    /// gaps, no overlap. For h = 0 every formula degenerates to the
    /// historical full-resolution composite.
    private func compositeTile(
        _ tile: DecodedTile,
        into fullComponents: inout [[Double]],
        metadata: CodestreamMetadata
    ) {
        let halvings = partialResolutionHalvings(metadata: metadata)
        let f = 1 << halvings
        func ceilDiv(_ n: Int) -> Int { EncoderPipeline.ceilDivIntegerOrigin(n, f) }

        let numComponents = metadata.componentCount
        for compIdx in 0..<min(numComponents, tile.rgb.count) {
            let compInfo = metadata.components[compIdx]
            let fullW = ceilDiv(metadata.width / compInfo.subsamplingX)
            // Tiles sit at their reference-grid origin less the image offset.
            let tcx0 = (tile.tileX - metadata.imageOffset.x) / compInfo.subsamplingX
            let tcy0 = (tile.tileY - metadata.imageOffset.y) / compInfo.subsamplingY
            let tcx1 = tcx0 + tile.tileW / compInfo.subsamplingX
            let tcy1 = tcy0 + tile.tileH / compInfo.subsamplingY
            let compTileX = ceilDiv(tcx0)
            let compTileY = ceilDiv(tcy0)
            let compTileW = ceilDiv(tcx1) - compTileX
            let compTileH = ceilDiv(tcy1) - compTileY

            tile.rgb[compIdx].withUnsafeBufferPointer { srcBuf in
                fullComponents[compIdx].withUnsafeMutableBufferPointer { dstBuf in
                    let srcP = srcBuf.baseAddress!
                    let dstP = dstBuf.baseAddress!
                    for row in 0..<compTileH {
                        let srcOffset = row * compTileW
                        let dstOffset = (compTileY + row) * fullW + compTileX
                        let copyW = min(compTileW, srcBuf.count - srcOffset)
                        guard copyW > 0, dstOffset + copyW <= dstBuf.count else { continue }
                        (dstP + dstOffset).update(from: srcP + srcOffset, count: copyW)
                    }
                }
            }
        }
    }

    // MARK: - JP3D bridge SPI (v10.20-research Phase 1)
    //
    // Two new internal entry points that EXPOSE the pipeline split
    // between dequantization and inverse-wavelet-transform without
    // changing the production single-tile decode path. The composition
    //
    //     iDWTAndFinalizeCoefficients(decodeToCoefficients(data))
    //
    // is byte-identical to `decodeSingleTile(parseCodestream(data))`
    // on every single-tile codestream — which is what JP3D's slice-
    // stack codec emits for each Z-slice. The JP3D side then has the
    // freedom to:
    //
    //  • decode N slices to coefficients (Stage A — entropy + dequant)
    //  • submit ONE batched GPU iDWT dispatch across all N slices
    //  • finalize each slice (Stage C — colour + DC + reconstruct)
    //
    // which is the structural shape Phase 2 needs. Phase 1 ships only
    // the split — single-slice batched iDWT collapses to today's behaviour.

    /// v10.21-research — per-component byte-level crop. Mirrors
    /// `J2KDecoder.extractRegion` (private in J2KAdvancedDecoding)
    /// so the JP3D bridge can produce region-sized images without
    /// reaching into a sibling file's private. 1-byte and 2-byte
    /// samples both supported; `sampleByteOrder` preserved.
    static func cropImage(_ image: J2KImage, region: J2KRegion) throws -> J2KImage {
        try region.validate(imageWidth: image.width, imageHeight: image.height)
        let cropped = image.components.map { component -> J2KComponent in
            let bytesPerSample = (component.bitDepth + 7) / 8
            let srcStride = component.width
            let dstRowBytes = region.width * bytesPerSample
            var dst = Data(count: region.height * dstRowBytes)
            component.data.withUnsafeBytes { srcRaw in
                dst.withUnsafeMutableBytes { dstRaw in
                    guard let src = srcRaw.baseAddress,
                          let out = dstRaw.baseAddress else { return }
                    for y in 0..<region.height {
                        let srcY = region.y + y
                        let srcOffset = (srcY * srcStride + region.x) * bytesPerSample
                        let dstOffset = y * dstRowBytes
                        memcpy(out + dstOffset, src + srcOffset, dstRowBytes)
                    }
                }
            }
            return J2KComponent(
                index: component.index, bitDepth: component.bitDepth,
                signed: component.signed,
                width: region.width, height: region.height,
                subsamplingX: component.subsamplingX,
                subsamplingY: component.subsamplingY,
                data: dst, sampleByteOrder: component.sampleByteOrder)
        }
        return J2KImage(
            width: region.width, height: region.height,
            components: cropped, colorSpace: image.colorSpace)
    }

    private func decodeMultiTile(
        metadata: CodestreamMetadata,
        tiles: [(tileIndex: Int, tileData: Data)],
        progress: ((DecoderProgressUpdate) -> Void)?
    ) async throws -> J2KImage {
        let numComponents = metadata.componentCount

        // Prepare full-image component buffers.
        //
        // v10.25 multi-tile partial-resolution — when
        // `partialResolutionLevel` is active the per-tile truncated
        // iDWT outputs reduced-dimension data, so the canvas buffers
        // are allocated at the reduced dimensions (ceil-div by
        // 2^halvings, matching `compositeTile`'s destination mapping
        // and `reconstructImage`'s `outputDimensions`). halvings = 0
        // (full decode) preserves the historical allocation exactly.
        let halvings = partialResolutionHalvings(metadata: metadata)
        var fullComponents: [[Double]] = (0..<numComponents).map { compIdx in
            let compInfo = metadata.components[compIdx]
            let w = EncoderPipeline.ceilDivIntegerOrigin(
                metadata.width / compInfo.subsamplingX, 1 << halvings)
            let h = EncoderPipeline.ceilDivIntegerOrigin(
                metadata.height / compInfo.subsamplingY, 1 << halvings)
            return [Double](repeating: 0.0, count: w * h)
        }

        try Task.checkCancellation()
        reportProgress(progress, stage: .tileExtraction, stageProgress: 0.0)

        // Tiles are independent: extract → entropy decode → dequant → IDWT
        // → colour transform → DC unshift can run concurrently because each
        // task allocates its own scratch buffers and writes to its own
        // tileRGB. Composition into `fullComponents` runs sequentially after
        // all tiles complete (each tile occupies a unique rectangle, so the
        // writes don't collide, but Swift's [Double] would CoW under
        // concurrent withUnsafeMutableBufferPointer — sequential composite
        // sidesteps that without measurable cost since composite is just
        // memcpy).
        //
        // v5.12: bounded concurrency. Same chunked-TaskGroup pattern
        // as the GPU multi-tile path; see decodeMultiTileGPU for
        // rationale. CPU concurrency cap at `maxInFlightTilesCPU`
        // primarily prevents unbounded memory growth on codestreams
        // with many large tiles — Swift's structured concurrency
        // already throttles compute via cooperative scheduling.
        var decodedTiles: [DecodedTile] = []
        decodedTiles.reserveCapacity(tiles.count)
        let chunkSize = max(1, Self.maxInFlightTilesCPU)
        var tileIdx = 0
        while tileIdx < tiles.count {
            try Task.checkCancellation()
            let end = min(tileIdx + chunkSize, tiles.count)
            let chunk = Array(tiles[tileIdx..<end])
            let chunkResults = try await withThrowingTaskGroup(of: DecodedTile.self) { group in
                for tile in chunk {
                    let captured = tile
                    let metadataCopy = metadata
                    // v10.25: `.high` priority — matches the inner
                    // entropy buckets (v10.24.2).
                    group.addTask {
                        try Task.checkCancellation()
                        return try await self.decodeTilePayload(
                            metadata: metadataCopy,
                            tileIndex: captured.tileIndex,
                            tileData: captured.tileData
                        )
                    }
                }
                var results: [DecodedTile] = []
                results.reserveCapacity(chunk.count)
                for try await decoded in group {
                    results.append(decoded)
                }
                return results
            }
            decodedTiles.append(contentsOf: chunkResults)
            tileIdx = end
        }

        try Task.checkCancellation()
        reportProgress(progress, stage: .tileExtraction, stageProgress: 1.0)

        for tile in decodedTiles {
            compositeTile(tile, into: &fullComponents, metadata: metadata)
        }

        try Task.checkCancellation()
        reportProgress(progress, stage: .imageReconstruction, stageProgress: 0.0)
        let image = try reconstructImage(fullComponents, metadata: metadata)
        try Task.checkCancellation()
        reportProgress(progress, stage: .imageReconstruction, stageProgress: 1.0)

        return image
    }

    // MARK: - Stage 1: Codestream Parsing

    /// Parses the JPEG 2000 codestream and extracts metadata and tile data.
    /// Internal (was private through v7.0.0); promoted to allow
    /// v7.1.0 H1.0 Defect A diagnostic test to extract per-tile
    /// codeblock data. Not part of the public API surface.
    /// v10.5.0 Stage B.2 — peek metadata without committing to a
    /// full decode. Used by `J2KDecoder.decodePartialResolution` to
    /// compute the reduced output dimensions from the codestream's
    /// SIZ + COD markers before the decode runs.
    static func peekMetadata(_ data: Data) throws -> CodestreamMetadata {
        let pipeline = DecoderPipeline()
        let (metadata, _) = try pipeline.parseCodestream(data)
        return metadata
    }

    func parseCodestream(_ data: Data) throws -> (CodestreamMetadata, [(tileIndex: Int, tileData: Data)]) {
        var reader = J2KBitReader(data: data)

        // Verify SOC marker
        guard try reader.readMarker() == J2KMarker.soc.rawValue else {
            throw J2KError.decodingError("Invalid codestream: missing SOC marker")
        }

        var metadata: CodestreamMetadata?
        var configuration = DecoderConfiguration()
        var quantizationSteps: (steps: [String: Double], guardBits: Int, bandKb: [String: Int]) = ([:], 2, [:])
        var tiles: [(tileIndex: Int, tileData: Data)] = []
        var part2 = J2KPart2ComponentTransforms()

        // Parse main header markers
        while reader.position < data.count {
            let marker = try reader.readMarker()

            switch marker {
            case J2KMarker.siz.rawValue:
                // Parse SIZ marker
                metadata = try parseSIZMarker(&reader)

            case J2KMarker.cod.rawValue:
                // Parse COD marker
                configuration = try parseCODMarker(&reader)

            case J2KMarker.qcd.rawValue:
                // Parse QCD marker
                let bitDepth = metadata?.components.first?.bitDepth ?? 8
                quantizationSteps = try parseQCDMarker(&reader, config: configuration, bitDepth: bitDepth)


            case J2KMarker.mct.rawValue, J2KMarker.mcc.rawValue, J2KMarker.mco.rawValue, J2KMarker.cbd.rawValue:
                // T.801 Annex J signalling (#2331): kept for the inverse component transformation after the IDWT.
                let length = Int(try reader.readUInt16())
                guard length >= 2 else { throw J2KError.decodingError("Part 2 marker segment has an invalid length") }
                let body = try reader.readBytes(length - 2)
                switch marker {
                case J2KMarker.mct.rawValue: part2.arrays.append(try J2KPart2MCTArray.parse(body))
                case J2KMarker.mcc.rawValue: part2.collections.append(try J2KPart2MCCMarker.parse(body))
                case J2KMarker.mco.rawValue: part2.order = try J2KPart2MCOMarker.parse(body)
                default:
                    let count = metadata?.components.count ?? 0
                    part2.bitDepths = try J2KPart2CBDMarker.parse(body, componentCount: count)
                }

            case J2KMarker.sot.rawValue:
                // Tile-parts of one tile are concatenated in codestream order (T.800 A.4.2: TPsot ascending).
                let (tileIndex, tilepartData) = try parseSOTMarker(&reader)
                if let existing = tiles.firstIndex(where: { $0.tileIndex == tileIndex }) {
                    tiles[existing].tileData.append(tilepartData)
                } else {
                    tiles.append((tileIndex: tileIndex, tileData: tilepartData))
                }

            case J2KMarker.eoc.rawValue:
                // End of codestream
                break

            default:
                // Skip unknown marker segment
                if marker >= 0xFF30 {
                    let length = Int(try reader.readUInt16())
                    if length > 2 {
                        try reader.skip(length - 2)
                    }
                }
            }

            if marker == J2KMarker.eoc.rawValue {
                break
            }
        }

        guard var meta = metadata else {
            throw J2KError.decodingError("Missing SIZ marker in codestream")
        }

        meta.configuration = configuration
        if part2.isActive || part2.bitDepths != nil {
            // The reconstructed depths (CBD) apply only when an Annex J transformation produces the components.
            if let depths = part2.bitDepths?.depths, part2.isActive, depths.count == meta.components.count {
                for index in meta.components.indices {
                    meta.components[index].outputBitDepth = depths[index].bitDepth
                    meta.components[index].outputSigned = depths[index].signed
                }
            }
            meta.part2 = part2
            // Validate the stage set once so malformed markers fail before any tile is decoded.
            _ = try part2.resolvedStages(componentCount: meta.components.count)
        }
        meta.quantizationSteps = quantizationSteps.steps
        meta.quantizationGuardBits = quantizationSteps.guardBits
        meta.bandKbValues = quantizationSteps.bandKb

        // If no tiles were found via SOT, but we have remaining data,
        // treat everything after the main header as a single tile
        if tiles.isEmpty {
            // Calculate remaining data after main header
            let remaining = data.subdata(in: reader.position..<data.count)
            if !remaining.isEmpty {
                tiles.append((tileIndex: 0, tileData: remaining))
            }
        }

        return (meta, tiles)
    }

    /// Parses the SIZ marker segment.
    private func parseSIZMarker(_ reader: inout J2KBitReader) throws -> CodestreamMetadata {
        let length = Int(try reader.readUInt16())
        let startPos = reader.position

        // Rsiz — Capabilities
        _ = try reader.readUInt16()

        // Image dimensions
        let width = Int(try reader.readUInt32())
        let height = Int(try reader.readUInt32())

        // Image offset
        let xOsiz = Int(try reader.readUInt32())
        let yOsiz = Int(try reader.readUInt32())

        // Tile dimensions
        let tileWidth = Int(try reader.readUInt32())
        let tileHeight = Int(try reader.readUInt32())

        // Tile offset
        let xtOsiz = Int(try reader.readUInt32())
        let ytOsiz = Int(try reader.readUInt32())

        // Number of components
        let componentCount = Int(try reader.readUInt16())

        // Parse component information
        var components: [CodestreamMetadata.ComponentInfo] = []
        for _ in 0..<componentCount {
            let ssiz = try reader.readUInt8()
            let signed = (ssiz & 0x80) != 0
            let bitDepth = Int((ssiz & 0x7F)) + 1
            let subsamplingX = Int(try reader.readUInt8())
            let subsamplingY = Int(try reader.readUInt8())

            components.append(CodestreamMetadata.ComponentInfo(
                bitDepth: bitDepth,
                signed: signed,
                subsamplingX: subsamplingX,
                subsamplingY: subsamplingY
            ))
        }

        // Verify we read the expected amount
        let bytesRead = reader.position - startPos
        if bytesRead < length - 2 {
            try reader.skip(length - 2 - bytesRead)
        }

        // `width`/`height` are the image extent (Xsiz − XOsiz), the size of the decoded image; tiles keep their
        // nominal size and are clipped to the reference grid by `tileDimensions` (T.800 Eq. B-7, #2900).
        return CodestreamMetadata(
            width: width - xOsiz,
            height: height - yOsiz,
            componentCount: componentCount,
            components: components,
            tileSize: (width: tileWidth, height: tileHeight),
            imageOffset: (x: xOsiz, y: yOsiz),
            tileOffset: (x: xtOsiz, y: ytOsiz),
            configuration: DecoderConfiguration(),
            quantizationSteps: [:],
            quantizationGuardBits: 2,
            bandKbValues: [:]
        )
    }

    /// Parses the COD marker segment.
    private func parseCODMarker(_ reader: inout J2KBitReader) throws -> DecoderConfiguration {
        let length = Int(try reader.readUInt16())
        let startPos = reader.position

        var config = DecoderConfiguration()

        // Scod — Coding style flags
        let scod = try reader.readUInt8()
        // Bits 3-4: HT set extensions (legacy non-standard; current encoder
        // no longer sets these, but decode them for backward compatibility).
        let htSetBits = (scod >> 3) & 0x03
        let hasHTSets = htSetBits != 0

        // Progression order
        let progOrder = try reader.readUInt8()
        switch progOrder {
        case 0: config.progressionOrder = .lrcp
        case 1: config.progressionOrder = .rlcp
        case 2: config.progressionOrder = .rpcl
        case 3: config.progressionOrder = .pcrl
        case 4: config.progressionOrder = .cprl
        default: config.progressionOrder = .lrcp
        }

        // Number of layers
        config.qualityLayers = Int(try reader.readUInt16())

        // Multiple component transform
        let mct = try reader.readUInt8()
        config.mctMode = Int(mct)
        config.useReversibleTransform = (mct == 1)

        // Number of decomposition levels
        config.decompositionLevels = Int(try reader.readUInt8())

        // Code-block dimensions
        let cbWidthExp = Int(try reader.readUInt8()) + 2
        let cbHeightExp = Int(try reader.readUInt8()) + 2
        config.codeBlockSize = (width: 1 << cbWidthExp, height: 1 << cbHeightExp)

        // Code-block style (Table A.19)
        config.applyCodeBlockStyle(try reader.readUInt8())

        // Wavelet transform type
        let transformType = try reader.readUInt8()
        config.waveletFilter = (transformType == 1) ? .reversible53 : .irreversible97

        // HT set parameters (ISO/IEC 15444-15) — only when bits 3-4 of Scod are non-zero
        // If HT sets are signaled, the configuration byte must be read regardless of useHTJ2K flag
        if hasHTSets {
            // Read HT set configuration byte
            _ = try reader.readUInt8()
            // We read and ignore for now - parameters are advisory
        }

        // Per-resolution precinct sizes (Scod bit 0). v5.35.0d-decode:
        // ISO 15444-1 A.6.1 — one byte per resolution level (decompositionLevels + 1
        // entries); low nibble = width exponent, high nibble = height exponent.
        if (scod & 0x01) != 0 {
            var pps: [(widthExp: Int, heightExp: Int)] = []
            for _ in 0...config.decompositionLevels {
                let byte = try reader.readUInt8()
                let wExp = Int(byte & 0x0F)
                let hExp = Int((byte >> 4) & 0x0F)
                pps.append((widthExp: wExp, heightExp: hExp))
            }
            config.precinctExponents = pps
        }

        // Verify we read the expected amount
        let bytesRead = reader.position - startPos
        if bytesRead < length - 2 {
            try reader.skip(length - 2 - bytesRead)
        }

        return config
    }

    /// Parses the COC marker segment (Coding Style Component).
    ///
    /// The COC marker provides per-component coding parameters that override
    /// the default COD parameters for a specific component.
    ///
    /// - Parameters:
    ///   - reader: The bit reader to read from.
    ///   - componentCount: Total number of components in the image.
    ///   - baseConfig: The base configuration from COD marker.
    /// - Returns: A tuple of (component index, component-specific configuration).
    private func parseCOCMarker(
        _ reader: inout J2KBitReader,
        componentCount: Int,
        baseConfig: DecoderConfiguration
    ) throws -> (componentIndex: Int, config: DecoderConfiguration) {
        let length = Int(try reader.readUInt16())
        let startPos = reader.position

        // Start with base configuration
        var config = baseConfig

        // Ccoc — Component index
        let componentIndex: Int
        if componentCount < 257 {
            // 1 byte for component index
            componentIndex = Int(try reader.readUInt8())
        } else {
            // 2 bytes for component index
            componentIndex = Int(try reader.readUInt16())
        }

        // Scoc — Coding style for this component

        // Number of decomposition levels
        config.decompositionLevels = Int(try reader.readUInt8())

        // Code-block dimensions
        let cbWidthExp = Int(try reader.readUInt8()) + 2
        let cbHeightExp = Int(try reader.readUInt8()) + 2
        config.codeBlockSize = (width: 1 << cbWidthExp, height: 1 << cbHeightExp)

        // Code-block style (Table A.19)
        config.applyCodeBlockStyle(try reader.readUInt8())

        // Wavelet transform type
        let transformType = try reader.readUInt8()
        config.waveletFilter = (transformType == 1) ? .reversible53 : .irreversible97

        // HT set parameters (ISO/IEC 15444-15) — only when HTJ2K is enabled
        // Note: COC doesn't have its own Scod, so we check if HTJ2K mode is set
        if config.useHTJ2K {
            // Check if there's enough data left to read HT set configuration byte
            let currentBytesRead = reader.position - startPos
            if currentBytesRead < length - 2 {
                // Read HT set configuration byte
                _ = try reader.readUInt8()
                // We read and ignore for now - parameters are advisory
            }
        }

        // Verify we read the expected amount
        let bytesRead = reader.position - startPos
        if bytesRead < length - 2 {
            try reader.skip(length - 2 - bytesRead)
        }

        return (componentIndex, config)
    }

    /// Parses the QCD marker segment.
    private func parseQCDMarker(
        _ reader: inout J2KBitReader,
        config: DecoderConfiguration,
        bitDepth: Int = 8
    ) throws -> (steps: [String: Double], guardBits: Int, bandKb: [String: Int]) {
        let length = Int(try reader.readUInt16())
        let startPos = reader.position

        var stepSizes: [String: Double] = [:]
        var bandKb: [String: Int] = [:]

        // Sqcd — Quantization style
        let sqcd = try reader.readUInt8()
        let quantStyle = sqcd & 0x1F
        let guardBits = Int((sqcd >> 5) & 0x07)

        if quantStyle == 0 {
            // No quantization (reversible) — step size is 1.0
            // Read exponent values (used only for Kb computation)
            let llExp = Int(try reader.readUInt8() >> 3)
            stepSizes["LL_0"] = 1.0
            bandKb["LL_0"] = llExp + guardBits - 1  // Kb = εb + Gb - 1

            if config.decompositionLevels > 0 {
                for level in 1...config.decompositionLevels {
                    for subband in ["HL", "LH", "HH"] {
                        let exp = Int(try reader.readUInt8() >> 3)
                        stepSizes["\(subband)_\(level)"] = 1.0
                        bandKb["\(subband)_\(level)"] = exp + guardBits - 1  // Kb = εb + Gb - 1
                    }
                }
            }
        } else if quantStyle == 2 {
            // Scalar expounded quantization.
            // For the 9/7 irreversible path, the stored QCD exponents are
            // interpreted using the base image precision for every subband.
            // This matches the encoder's OpenJPEG-compatible signaling and keeps
            // the dequantization step sizes consistent across decode paths.
            let baseRangeBits = bitDepth

            func decodeStepSize(_ value: UInt16, subbandGain: Int) -> Double {
                let exp = Int((value >> 11) & 0x1F)
                let mant = Double(value & 0x7FF)
                let rangeBits = baseRangeBits + subbandGain
                return pow(2.0, Double(rangeBits - exp)) * (1.0 + mant / 2048.0)
            }

            // LL subband (gain = 0)
            let llValue = try reader.readUInt16()
            let llExp = Int((llValue >> 11) & 0x1F)
            stepSizes["LL_0"] = decodeStepSize(llValue, subbandGain: 0)
            bandKb["LL_0"] = llExp + guardBits - 1  // Kb = εb + Gb - 1

            if config.decompositionLevels > 0 {
                for level in 1...config.decompositionLevels {
                    for subband in ["HL", "LH", "HH"] {
                        let value = try reader.readUInt16()
                        let exp = Int((value >> 11) & 0x1F)
                        let gainExponent: Int
                        switch subband {
                        case "HL", "LH": gainExponent = 1
                        case "HH": gainExponent = 2
                        default: gainExponent = 0
                        }
                        stepSizes["\(subband)_\(level)"] = decodeStepSize(value, subbandGain: gainExponent)
                        bandKb["\(subband)_\(level)"] = exp + guardBits - 1  // Kb = εb + Gb - 1
                    }
                }
            }
        }

        // Verify we read the expected amount
        let bytesRead = reader.position - startPos
        if bytesRead < length - 2 {
            try reader.skip(length - 2 - bytesRead)
        }

        return (steps: stepSizes, guardBits: guardBits, bandKb: bandKb)
    }

    /// Parses a COM (comment) marker and returns `true` iff the
    /// payload matches the J2KSwift block-format signature that
    /// signals `.conformant` HTJ2K blocks.
    /// Parses the SOT marker segment and extracts tile data.
    private func parseSOTMarker(_ reader: inout J2KBitReader) throws -> (Int, Data) {
        // SOT: Lsot, Isot, Psot, TPsot, TNsot. Psot counts from the first byte of the SOT marker (which the reader has
        // already consumed) to the end of the tile-part data; 0 means "until EOC" (last tile-part only).
        let segmentStart = reader.position - 2
        let lsot = Int(try reader.readUInt16())
        guard lsot == 10 else { throw J2KError.decodingError("SOT marker segment length \(lsot) is not 10") }
        let tileIndex = Int(try reader.readUInt16())
        let tilepartLength = Int(try reader.readUInt32())
        _ = try reader.readUInt8() // TPsot
        _ = try reader.readUInt8() // TNsot
        // Tile-part header marker segments before SOD (T.800 A.4.2). Packet-length and comment segments carry no
        // decoding state; per-tile coding-parameter overrides are not implemented and fail typed.
        while true {
            let marker = try reader.readMarker()
            if marker == J2KMarker.sod.rawValue { break }
            switch marker {
            case J2KMarker.plt.rawValue, J2KMarker.com.rawValue, J2KMarker.tlm.rawValue:
                let length = Int(try reader.readUInt16())
                guard length >= 2 else { throw J2KError.decodingError("Invalid tile-part header segment length \(length)") }
                try reader.skip(length - 2)
            case J2KMarker.cod.rawValue, J2KMarker.coc.rawValue, J2KMarker.qcd.rawValue, J2KMarker.qcc.rawValue,
                 J2KMarker.rgn.rawValue, J2KMarker.poc.rawValue, J2KMarker.ppt.rawValue:
                throw J2KError.notImplemented(
                    "tile-part header marker 0x\(String(marker, radix: 16, uppercase: true)) (tile-specific coding "
                    + "parameters, progression change or packed packet headers) is not supported")
            default:
                throw J2KError.decodingError("Unexpected marker 0x\(String(marker, radix: 16, uppercase: true)) in tile-part header")
            }
        }
        let headerBytes = reader.position - segmentStart
        if tilepartLength == 0 {
            // Until EOC: take the rest of the codestream and drop a trailing EOC marker.
            var tileData = try reader.readBytes(reader.bytesRemaining)
            if tileData.count >= 2, tileData[tileData.count - 2] == 0xFF, tileData[tileData.count - 1] == 0xD9 {
                tileData.removeLast(2)
            }
            return (tileIndex, tileData)
        }
        guard tilepartLength >= headerBytes else { throw J2KError.decodingError("SOT Psot \(tilepartLength) is shorter than its header") }
        let tileData = try reader.readBytes(tilepartLength - headerBytes)
        return (tileIndex, tileData)
    }

    // MARK: - Stage 2: Tile Extraction

    /// Information about a code block extracted from tile data.
    /// Passes and bytes one code-block received from one quality layer (issue #2382).
    struct LayerContribution: Sendable, Equatable {
        let layer: Int
        let passes: Int
        let byteCount: Int
        /// The lengths this packet signalled, one per codeword-segment piece (B.10.7.2), summing to `byteCount`.
        var segmentBytes: [Int] = []
        /// Whether the first piece extends the segment an earlier layer left open.
        var continuesSegment = false
    }

    struct CodeBlockInfo: Sendable {
        let componentIndex: Int
        let level: Int
        let subband: J2KSubband
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let data: Data
        let passCount: Int
        let zeroBitPlanes: Int
        let bandKb: Int
        /// Per-layer contributions when the block came from the multi-layer packet decode; nil on the
        /// single-layer path. Lets a refinement reuse the parsed tier-2 state: `truncated(toLayer:)` keeps the
        /// passes and bytes of layers `0...layer` without re-reading packets.
        var layerContributions: [LayerContribution]? = nil
        /// Byte length of each MQ or raw codeword segment; empty when the block is one segment, the default style.
        var segmentLengths: [Int] = []

        init(componentIndex: Int, level: Int, subband: J2KSubband, x: Int, y: Int, width: Int, height: Int, data: Data,
             passCount: Int, zeroBitPlanes: Int, bandKb: Int, layerContributions: [LayerContribution]? = nil,
             segmentLengths: [Int] = []) {
            self.componentIndex = componentIndex; self.level = level; self.subband = subband
            self.x = x; self.y = y; self.width = width; self.height = height
            self.data = data; self.passCount = passCount; self.zeroBitPlanes = zeroBitPlanes; self.bandKb = bandKb
            self.layerContributions = layerContributions
            self.segmentLengths = segmentLengths.count > 1 ? segmentLengths : []
            if let layerContributions, segmentLengths.isEmpty {
                // Pieces signalled in successive layers join into one segment until the coding style closes it.
                var merged: [Int] = []
                for contribution in layerContributions {
                    for (index, bytes) in contribution.segmentBytes.enumerated() {
                        if index == 0, contribution.continuesSegment, !merged.isEmpty {
                            merged[merged.count - 1] += bytes
                        } else {
                            merged.append(bytes)
                        }
                    }
                }
                self.segmentLengths = merged.count > 1 ? merged : []
            }
        }

        /// The block as it would have been decoded with `maxQualityLayer = layer` (cumulative layers 0...layer).
        func truncated(toLayer layer: Int) -> CodeBlockInfo? {
            guard let contributions = layerContributions else { return self }
            let kept = contributions.filter { $0.layer <= layer }
            guard !kept.isEmpty else { return nil }
            let bytes = kept.reduce(0) { $0 + $1.byteCount }
            let passes = kept.reduce(0) { $0 + $1.passes }
            return CodeBlockInfo(componentIndex: componentIndex, level: level, subband: subband, x: x, y: y, width: width, height: height,
                                 data: data.prefix(bytes), passCount: passes, zeroBitPlanes: zeroBitPlanes, bandKb: bandKb,
                                 layerContributions: kept)
        }
    }

    /// Extracts code blocks from tile data using ISO/IEC 15444-1 packet format.
    ///
    /// Parses packet headers using tag trees for code-block inclusion and
    /// zero bit-planes, Table B.4 for coding passes, and Lblock for data lengths.
    ///
    /// Multi-precinct support (v5.35.0d-decode): when the codestream's COD
    /// marker specifies precinct sizes (Scod bit 0 = 1), each (resolution,
    /// component) emits one packet per precinct. Iterates the precinct
    /// grid in raster order; for each precinct, reads ONE packet whose
    /// tag trees cover only the blocks within that precinct's region.
    /// Default codestreams (one precinct per band) work as before.
    /// Internal (was private through v7.0.0); promoted to allow
    /// v7.1.0 H1.0 Defect A diagnostic test to inspect per-tile
    /// codeblock layout. Not part of the public API surface.
    func extractTileData(
        _ tileData: Data,
        metadata: CodestreamMetadata,
        // v6-alpha3 step 6B slice 4 — tile-component canvas-coord
        // origin used to canvas-anchor the code-block partition
        // per ISO/IEC 15444-1 B.7. Default (0, 0) preserves
        // single-tile and 32-aligned multi-tile decode bit-for-bit.
        tileOriginX: Int = 0,
        tileOriginY: Int = 0,
        // v10.5.0 Stage B.1 — partial-resolution decode filter.
        // When non-nil, code-blocks at decomposition levels outside
        // the kept range are dropped after parsing (their data bytes
        // are still consumed from the stream to keep the reader in
        // sync, but they don't enter the result array). Filter rule:
        //   keep iff (block.level == 0)           // LL (deepest)
        //         OR (block.level > N - r)        // details at deepest r levels
        // where N = metadata.configuration.decompositionLevels and
        // r = maxResolutionLevel ∈ [0, N]. nil = full decode.
        //
        // This saves the dominant entropy decode stage when the
        // caller wants a partial-resolution output. Stage B.2 will
        // also truncate the inverse DWT to skip iDWT levels.
        maxResolutionLevel: Int? = nil,
        // v10.6.0 ROI decode — region of interest in full-image pixel
        // coordinates. When non-nil, code-blocks whose inverse-DWT
        // spatial footprint (plus a conservative synthesis-filter
        // halo) does not overlap the region are dropped after parsing
        // — entropy decode is skipped for them, just like the B.1
        // resolution filter above. The LL band is always kept. Every
        // block influencing an in-region pixel is retained, so a full
        // decode + crop and an ROI decode + crop produce bit-identical
        // region pixels.
        regionOfInterest: J2KRegion? = nil,
        // v10.9.0 quality-layer decode — caps the multi-layer packet
        // decode at layers `0...maxQualityLayer`. nil = all layers.
        // Ignored for single-layer codestreams.
        maxQualityLayer: Int? = nil
    ) throws -> [CodeBlockInfo] {
        var blocks: [CodeBlockInfo] = []

        let cbWidth = metadata.configuration.codeBlockSize.width
        let cbHeight = metadata.configuration.codeBlockSize.height
        let levels = metadata.configuration.decompositionLevels
        let tileWidth = metadata.tileSize.width
        let tileHeight = metadata.tileSize.height
        // HT code-blocks keep one length per contribution; the EBCOT style bits split it per codeword segment.
        let segmentedByPass = metadata.configuration.terminateOnEachPass && !metadata.configuration.useHTJ2K
        let segmentedByBypass = metadata.configuration.useSelectiveArithmeticBypass && !metadata.configuration.useHTJ2K
        var reader = J2KBitReader(data: tileData)
        // Enable JPEG 2000 byte stuffing for packet headers (ISO 15444-1 B.10.1)
        reader.setByteStuffing(true)

        // Precinct size in BAND-LOCAL coords for a given resolution.
        // r=0 (LL): 2^PPx × 2^PPy. r > 0: 2^(PPx-1) × 2^(PPy-1).
        // Default (no precinct sizes in COD): 2^15 (effectively one
        // precinct covers the whole band).
        let precinctExps = metadata.configuration.precinctExponents
        func bandPrecinctSize(forRes res: Int) -> (w: Int, h: Int) {
            guard let exps = precinctExps, res < exps.count else {
                return (1 << 15, 1 << 15)
            }
            let pp = exps[res]
            let wExp = res == 0 ? pp.widthExp : max(0, pp.widthExp - 1)
            let hExp = res == 0 ? pp.heightExp : max(0, pp.heightExp - 1)
            return (1 << wExp, 1 << hExp)
        }

        struct PendingBlock {
            let componentIndex: Int
            let decomLevel: Int
            let subband: J2KSubband
            let x, y, width, height: Int
            let passCount: Int
            let zeroBitPlanes: Int
            let bandKb: Int
            let dataLength: Int
            let segmentLengths: [Int]
        }

        // LRCP progression: layer × resolution × component × precinct.
        //
        // v10.9.0 — codestreams with more than one quality layer need
        // the layer-aware packet decode. The loop below handles the
        // single-layer case (the common path, byte-exact unchanged);
        // multi-layer codestreams route to `extractTileDataMultiLayer`.
        if metadata.configuration.qualityLayers > 1 {
            let mlBlocks = try extractTileDataMultiLayer(
                tileData, metadata: metadata,
                tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                maxQualityLayer: maxQualityLayer)
            return applyPartialDecodeFilters(
                mlBlocks, levels: levels,
                tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                maxResolutionLevel: maxResolutionLevel, regionOfInterest: regionOfInterest)
        }

        // Single-layer packet decode — precincts iterated in raster
        // order per (resolution, component).
        let sequence = Self.packetSequence(metadata: metadata, tileWidth: tileWidth, tileHeight: tileHeight, tileOriginX: tileOriginX, tileOriginY: tileOriginY, layers: 1)
        for packet in sequence {
            try Task.checkCancellation()
            let resLevel = packet.res
            do {
                let compIdx = packet.comp
                let subbands: [J2KSubband] = resLevel == 0 ? [.ll] : [.hl, .lh, .hh]

                // Determine the precinct grid extent at this resolution.
                // For r > 0, all sub-bands HL/LH/HH share the same grid;
                // use one of them as a reference. For r = 0, the LL band's
                // dimensions define the grid.
                // T.800 B.6: the precinct partition is anchored at the origin of the resolution grid; a
                // resolution with an empty band still carries its packets, and empty precincts carry none.
                let grid = Self.resolutionPrecinctGrid(
                    tileWidth: tileWidth, tileHeight: tileHeight,
                    tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                    levels: levels, resLevel: resLevel, precinctExps: precinctExps)
                guard grid.count.x > 0 && grid.count.y > 0 else { continue }
                let (pw, ph) = grid.bandPrecinct

                do {

                    let py = packet.py
                    do {
                        let px = packet.px
                        guard reader.bytesRemaining > 0 || reader.bitOffset > 0 else { break }
                        try Self.skipSOPMarker(&reader)
                        let notEmpty = try reader.readBit()
                        guard notEmpty else {
                            try reader.alignToByte()
                            Self.skipEPHMarker(&reader)
                            continue
                        }

                        var pendingBlocks: [PendingBlock] = []

                        for subband in subbands {
                            let (sbWidth, sbHeight) = Self.subbandDimensions(
                                tileWidth: tileWidth, tileHeight: tileHeight,
                                tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                                levels: levels, resLevel: resLevel, subband: subband)
                            guard sbWidth > 0 && sbHeight > 0 else { continue }

                            // v6-alpha3 step 6B slice 4 — canvas-anchored
                            // code-block partition per ISO/IEC 15444-1 B.7.
                            // Mirror of the encoder's step-6A canvas-anchored
                            // grid in `applyEntropyCodingHTJ2KFused`. For
                            // tile origin (0, 0) the formulas reduce to the
                            // legacy tile-relative grid; single-tile and
                            // 32-aligned multi-tile decode are byte-identical.
                            let (tbx0, tby0) = Self.subbandCanvasOrigin(
                                tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                                levels: levels, resLevel: resLevel, subband: subband)

                            // Precinct region intersected with the tile band.
                            // Default precinct (2^15 × 2^15) covers the whole
                            // band, so px/py are always 0 in that case and
                            // pStartX/pStartY are 0. For non-default precincts
                            // this preserves the precinct-anchored sub-region
                            // while the inner block grid is canvas-anchored.
                            let bpx0 = max(tbx0, (grid.first.x + px) * pw)
                            let bpy0 = max(tby0, (grid.first.y + py) * ph)
                            let bpx1 = min(tbx0 + sbWidth, (grid.first.x + px + 1) * pw)
                            let bpy1 = min(tby0 + sbHeight, (grid.first.y + py + 1) * ph)
                            guard bpx1 > bpx0, bpy1 > bpy0 else { continue }
                            // B.7: code-blocks are capped by the band precinct size and anchored at 0.
                            let cbw = min(cbWidth, pw), cbh = min(cbHeight, ph)

                            // Canvas-anchored cell range intersecting this
                            // precinct's tile-band region [tbx0+pStartX,
                            // tbx0+pEndX) × [tby0+pStartY, tby0+pEndY).
                            let firstCanvasX = bpx0 / cbw
                            let firstCanvasY = bpy0 / cbh
                            let lastCanvasX  = (bpx1 + cbw - 1) / cbw
                            let lastCanvasY  = (bpy1 + cbh - 1) / cbh
                            let pBlocksX = lastCanvasX - firstCanvasX
                            let pBlocksY = lastCanvasY - firstCanvasY
                            let pBlockCount = pBlocksX * pBlocksY

                            let bandKey: String
                            if subband == .ll {
                                bandKey = "LL_0"
                            } else {
                                bandKey = "\(subband.rawValue)_\(resLevel)"
                            }
                            let kb = metadata.bandKbValues[bandKey] ?? (metadata.components[compIdx].bitDepth + metadata.quantizationGuardBits)
                            let decomLevel = resLevel == 0 ? 0 : (levels - resLevel + 1)

                            // Per-precinct tag trees (fresh for each
                            // packet — the standard's "tag tree per
                            // precinct" model).
                            var inclusionTree = J2KTagTree(width: pBlocksX, height: pBlocksY)
                            var zbpTree = J2KTagTree(width: pBlocksX, height: pBlocksY)

                            for localLeafIdx in 0..<pBlockCount {
                                let included = try inclusionTree.decode(
                                    reader: &reader, leafIndex: localLeafIdx, threshold: 1)
                                guard included else { continue }

                                var zbp: Int32 = 0
                                while !(try zbpTree.decode(
                                    reader: &reader, leafIndex: localLeafIdx, threshold: zbp + 1)) {
                                    zbp += 1
                                    if zbp > 100 { break }
                                }

                                let passes = try Self.decodeCodingPasses(&reader)
                                var lengthState = SegmentLengthState()
                                let segmentLengths = try lengthState.readLengths(
                                    &reader, passes: passes, terminateOnEachPass: segmentedByPass,
                                    bypass: segmentedByBypass).pieces
                                let length = segmentLengths.reduce(0, +)

                                let localY = localLeafIdx / pBlocksX
                                let localX = localLeafIdx % pBlocksX

                                // Canvas position of this block in band-canvas
                                // coords, then clipped to tile-band-relative
                                // [pStartX, pEndX) × [pStartY, pEndY).
                                let canvasStartX = (firstCanvasX + localX) * cbw
                                let canvasEndX   = canvasStartX + cbw
                                let canvasStartY = (firstCanvasY + localY) * cbh
                                let canvasEndY   = canvasStartY + cbh
                                // Tile-band-relative coordinates the dequant /
                                // IDWT scatter expects (matches encoder's
                                // PendingCodeBlock.originX/originY).
                                let tileStartX = max(bpx0, canvasStartX) - tbx0
                                let tileEndX   = min(bpx1, canvasEndX) - tbx0
                                let tileStartY = max(bpy0, canvasStartY) - tby0
                                let tileEndY   = min(bpy1, canvasEndY) - tby0
                                let actualW    = tileEndX - tileStartX
                                let actualH    = tileEndY - tileStartY

                                pendingBlocks.append(PendingBlock(
                                    componentIndex: compIdx,
                                    decomLevel: decomLevel,
                                    subband: subband,
                                    x: tileStartX, y: tileStartY,
                                    width: actualW, height: actualH,
                                    passCount: passes,
                                    zeroBitPlanes: Int(zbp),
                                    bandKb: kb,
                                    dataLength: length,
                                    segmentLengths: segmentLengths))
                            }
                        }

                        try reader.alignToByte()

                        Self.skipEPHMarker(&reader)
                        reader.setByteStuffing(false)

                        for pb in pendingBlocks {
                            let blockData = try reader.readBytes(pb.dataLength)
                            blocks.append(CodeBlockInfo(
                                componentIndex: pb.componentIndex,
                                level: pb.decomLevel,
                                subband: pb.subband,
                                x: pb.x, y: pb.y,
                                width: pb.width, height: pb.height,
                                data: blockData,
                                passCount: pb.passCount,
                                zeroBitPlanes: pb.zeroBitPlanes,
                                bandKb: pb.bandKb,
                                segmentLengths: pb.segmentLengths))
                        }
                        reader.setByteStuffing(true)
                    }
                }
            }
        }

        return applyPartialDecodeFilters(
            blocks, levels: levels,
            tileOriginX: tileOriginX, tileOriginY: tileOriginY,
            maxResolutionLevel: maxResolutionLevel, regionOfInterest: regionOfInterest)
    }

    /// Applies the v10.5.0 Stage B.1 partial-resolution code-block
    /// filter and the v10.6.0 ROI spatial filter. Factored out of
    /// `extractTileData` so the single-layer and multi-layer packet
    /// decode paths share one implementation.
    private func applyPartialDecodeFilters(
        _ blocks: [CodeBlockInfo], levels: Int,
        tileOriginX: Int, tileOriginY: Int,
        maxResolutionLevel: Int?, regionOfInterest: J2KRegion?
    ) -> [CodeBlockInfo] {
        var blocks = blocks

        // v10.5.0 Stage B.1 — partial-resolution filter. Keep blocks
        // where level == 0 (the LL, always needed) OR level > N - r
        // (detail bands at the deepest r levels).
        if let r = maxResolutionLevel {
            let keepThreshold = levels - r
            blocks = blocks.filter { block in
                block.level == 0 || block.level > keepThreshold
            }
        }

        // v10.6.0 ROI decode — spatial code-block filter. A code-block
        // at decomposition depth d holds band samples that upsample to
        // full-image pixels at scale 2^d; its image-space footprint is
        // the band rect scaled by 2^d, anchored at the tile origin,
        // expanded by a conservative 8·2^d synthesis-filter halo. A
        // block is kept iff that footprint overlaps the region.
        if let roi = regionOfInterest {
            let haloFactor = 8
            blocks = blocks.filter { block in
                if block.level == 0 { return true }
                let d = block.level
                let scale = 1 << d
                let halo = haloFactor << d
                let fpX0 = tileOriginX + block.x * scale - halo
                let fpX1 = tileOriginX + (block.x + block.width) * scale + halo
                let fpY0 = tileOriginY + block.y * scale - halo
                let fpY1 = tileOriginY + (block.y + block.height) * scale + halo
                let overlapsX = fpX0 < (roi.x + roi.width) && fpX1 > roi.x
                let overlapsY = fpY0 < (roi.y + roi.height) && fpY1 > roi.y
                return overlapsX && overlapsY
            }
        }

        return blocks
    }

    /// v10.9.0 — multi-layer (LRCP) packet decode per ISO/IEC 15444-1
    /// B.10. The single-layer `extractTileData` loop reads one packet
    /// per `(resolution, component, precinct)`; a codestream with
    /// `qualityLayers > 1` emits `layer × resolution × component ×
    /// precinct` packets, with each code-block's coding passes
    /// distributed across the layers it contributes to.
    ///
    /// This routine adds the layer loop, persists the per-precinct
    /// inclusion / zero-bit-plane tag-trees and the per-block `Lblock`
    /// state across layers, and accumulates each block's passes and
    /// data into a single `CodeBlockInfo`. When `maxQualityLayer` is
    /// set, only layers `0...maxQualityLayer` are processed — the
    /// basis for `decodeQuality`.
    private func extractTileDataMultiLayer(
        _ tileData: Data, metadata: CodestreamMetadata,
        tileOriginX: Int, tileOriginY: Int,
        maxQualityLayer: Int?
    ) throws -> [CodeBlockInfo] {
        let cbWidth = metadata.configuration.codeBlockSize.width
        let cbHeight = metadata.configuration.codeBlockSize.height
        let levels = metadata.configuration.decompositionLevels
        let tileWidth = metadata.tileSize.width
        let tileHeight = metadata.tileSize.height
        let totalLayers = max(1, metadata.configuration.qualityLayers)
        let lastLayer = min(maxQualityLayer ?? (totalLayers - 1), totalLayers - 1)
        let cacheKey = J2KLayeredBlockCache.Key(tileOriginX: tileOriginX, tileOriginY: tileOriginY, byteCount: tileData.count)
        if let cache = layeredBlockCache, let cached = cache.entry(for: cacheKey) {
            // Tier-2 reuse: truncate the cached full-layer blocks to the requested layer.
            partialAccounting?.recordCachedTile(packetBytesPerLayer: cached.packetBytesPerLayer, lastLayer: lastLayer)
            return cached.blocks.compactMap { $0.truncated(toLayer: lastLayer) }
        }
        // When a cache is attached every layer is retained so later refinements need no second parse.
        let retainedLayer = layeredBlockCache == nil ? lastLayer : totalLayers - 1

        var reader = J2KBitReader(data: tileData)
        reader.setByteStuffing(true)

        let precinctExps = metadata.configuration.precinctExponents
        func bandPrecinctSize(forRes res: Int) -> (w: Int, h: Int) {
            guard let exps = precinctExps, res < exps.count else {
                return (1 << 15, 1 << 15)
            }
            let pp = exps[res]
            let wExp = res == 0 ? pp.widthExp : max(0, pp.widthExp - 1)
            let hExp = res == 0 ? pp.heightExp : max(0, pp.heightExp - 1)
            return (1 << wExp, 1 << hExp)
        }

        struct PrecinctKey: Hashable {
            let res: Int, comp: Int, subband: J2KSubband, py: Int, px: Int
        }
        let segmentedByPass = metadata.configuration.terminateOnEachPass && !metadata.configuration.useHTJ2K
        let segmentedByBypass = metadata.configuration.useSelectiveArithmeticBypass && !metadata.configuration.useHTJ2K
        struct BlockAccum {
            var included = false
            var lengths = SegmentLengthState()
            var zeroBitPlanes = 0
            var passCount = 0
            var data = Data()
            var componentIndex = 0
            var decomLevel = 0
            var subband: J2KSubband = .ll
            var x = 0, y = 0, width = 0, height = 0
            var bandKb = 0
            var emitOrder = 0
            var contributions: [LayerContribution] = []
        }
        var consumedPacketBytes = 0
        var skippedPacketBytes = 0
        var packetBytesPerLayer = [Int](repeating: 0, count: totalLayers)

        var inclusionTrees: [PrecinctKey: J2KTagTree] = [:]
        var zbpTrees: [PrecinctKey: J2KTagTree] = [:]
        var blockAccums: [PrecinctKey: [BlockAccum]] = [:]
        var emitCounter = 0

        let sequence = Self.packetSequence(metadata: metadata, tileWidth: tileWidth, tileHeight: tileHeight, tileOriginX: tileOriginX, tileOriginY: tileOriginY, layers: totalLayers)

        for packet in sequence {
            try Task.checkCancellation()

            let layer = packet.layer
            do {
                let resLevel = packet.res
                do {
                    let compIdx = packet.comp
                    let subbands: [J2KSubband] = resLevel == 0 ? [.ll] : [.hl, .lh, .hh]
                    // T.800 B.6: the precinct partition is anchored at the origin of the resolution grid; a
                    // resolution with an empty band still carries its packets, and empty precincts carry none.
                    let grid = Self.resolutionPrecinctGrid(
                        tileWidth: tileWidth, tileHeight: tileHeight,
                        tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                        levels: levels, resLevel: resLevel, precinctExps: precinctExps)
                    guard grid.count.x > 0 && grid.count.y > 0 else { continue }
                    let (pw, ph) = grid.bandPrecinct

                    do {

                        let py = packet.py
                        do {
                            let px = packet.px
                            guard reader.bytesRemaining > 0 || reader.bitOffset > 0 else { break }
                            let packetStart = reader.position
                            defer {
                                let packetBytes = max(0, reader.position - packetStart)
                                if layer <= lastLayer { consumedPacketBytes += packetBytes } else { skippedPacketBytes += packetBytes }
                                if layer < packetBytesPerLayer.count { packetBytesPerLayer[layer] += packetBytes }
                            }
                            try Self.skipSOPMarker(&reader)
                            let notEmpty = try reader.readBit()
                            guard notEmpty else {
                                try reader.alignToByte()
                                Self.skipEPHMarker(&reader)
                                continue
                            }

                            // Blocks that contribute data in THIS
                            // packet, in header order — the packet
                            // body is read in the same order.
                            var layerContrib: [(pkey: PrecinctKey, leaf: Int, length: Int)] = []

                            for subband in subbands {
                                let (sbWidth, sbHeight) = Self.subbandDimensions(
                                    tileWidth: tileWidth, tileHeight: tileHeight,
                                    tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                                    levels: levels, resLevel: resLevel, subband: subband)
                                guard sbWidth > 0 && sbHeight > 0 else { continue }
                                let (tbx0, tby0) = Self.subbandCanvasOrigin(
                                    tileOriginX: tileOriginX, tileOriginY: tileOriginY,
                                    levels: levels, resLevel: resLevel, subband: subband)
                                let bpx0 = max(tbx0, (grid.first.x + px) * pw)
                                let bpy0 = max(tby0, (grid.first.y + py) * ph)
                                let bpx1 = min(tbx0 + sbWidth, (grid.first.x + px + 1) * pw)
                                let bpy1 = min(tby0 + sbHeight, (grid.first.y + py + 1) * ph)
                                guard bpx1 > bpx0, bpy1 > bpy0 else { continue }
                                // B.7: code-blocks are capped by the band precinct size and anchored at 0.
                                let cbw = min(cbWidth, pw), cbh = min(cbHeight, ph)
                                let firstCanvasX = bpx0 / cbw
                                let firstCanvasY = bpy0 / cbh
                                let lastCanvasX  = (bpx1 + cbw - 1) / cbw
                                let lastCanvasY  = (bpy1 + cbh - 1) / cbh
                                let pBlocksX = lastCanvasX - firstCanvasX
                                let pBlocksY = lastCanvasY - firstCanvasY
                                let pBlockCount = pBlocksX * pBlocksY
                                guard pBlockCount > 0 else { continue }

                                let bandKey = subband == .ll
                                    ? "LL_0" : "\(subband.rawValue)_\(resLevel)"
                                let kb = metadata.bandKbValues[bandKey]
                                    ?? (metadata.components[compIdx].bitDepth + metadata.quantizationGuardBits)
                                let decomLevel = resLevel == 0 ? 0 : (levels - resLevel + 1)

                                let pkey = PrecinctKey(
                                    res: resLevel, comp: compIdx, subband: subband, py: py, px: px)
                                var accums = blockAccums[pkey]
                                    ?? Array(repeating: BlockAccum(), count: pBlockCount)
                                var incTree = inclusionTrees[pkey]
                                    ?? J2KTagTree(width: pBlocksX, height: pBlocksY)
                                var zbpTree = zbpTrees[pkey]
                                    ?? J2KTagTree(width: pBlocksX, height: pBlocksY)

                                for leaf in 0..<pBlockCount {
                                    var accum = accums[leaf]
                                    if !accum.included {
                                        let inc = try incTree.decode(
                                            reader: &reader, leafIndex: leaf,
                                            threshold: Int32(layer + 1))
                                        if !inc {
                                            accums[leaf] = accum
                                            continue
                                        }
                                        accum.included = true
                                        var zbp: Int32 = 0
                                        while !(try zbpTree.decode(
                                            reader: &reader, leafIndex: leaf, threshold: zbp + 1)) {
                                            zbp += 1
                                            if zbp > 100 { break }
                                        }
                                        accum.zeroBitPlanes = Int(zbp)
                                        // Block geometry — computed once.
                                        let localY = leaf / pBlocksX
                                        let localX = leaf % pBlocksX
                                        let canvasStartX = (firstCanvasX + localX) * cbw
                                        let canvasStartY = (firstCanvasY + localY) * cbh
                                        let tileStartX = max(bpx0, canvasStartX) - tbx0
                                        let tileEndX   = min(bpx1, canvasStartX + cbw) - tbx0
                                        let tileStartY = max(bpy0, canvasStartY) - tby0
                                        let tileEndY   = min(bpy1, canvasStartY + cbh) - tby0
                                        accum.componentIndex = compIdx
                                        accum.decomLevel = decomLevel
                                        accum.subband = subband
                                        accum.x = tileStartX
                                        accum.y = tileStartY
                                        accum.width = tileEndX - tileStartX
                                        accum.height = tileEndY - tileStartY
                                        accum.bandKb = kb
                                        accum.emitOrder = emitCounter
                                        emitCounter += 1
                                    } else {
                                        // Already included — one bit signals
                                        // whether it contributes this layer.
                                        let contributes = try reader.readBit()
                                        if !contributes {
                                            accums[leaf] = accum
                                            continue
                                        }
                                    }
                                    let passes = try Self.decodeCodingPasses(&reader)
                                    let signalled = try accum.lengths.readLengths(
                                        &reader, passes: passes, terminateOnEachPass: segmentedByPass,
                                        bypass: segmentedByBypass)
                                    let length = signalled.pieces.reduce(0, +)
                                    // Packets above the retained layer are parsed (their headers advance the inclusion
                                    // and lblock state) but contribute no passes or data.
                                    if layer <= retainedLayer {
                                        accum.passCount += passes
                                        accum.contributions.append(LayerContribution(
                                            layer: layer, passes: passes, byteCount: length,
                                            segmentBytes: signalled.pieces, continuesSegment: signalled.continuesSegment))
                                    }
                                    accums[leaf] = accum
                                    layerContrib.append((pkey, leaf, length))
                                }

                                inclusionTrees[pkey] = incTree
                                zbpTrees[pkey] = zbpTree
                                blockAccums[pkey] = accums
                            }

                            // Packet body — code-block data bytes, header order.
                            try reader.alignToByte()
                            Self.skipEPHMarker(&reader)
                            reader.setByteStuffing(false)
                            for contrib in layerContrib {
                                let d = try reader.readBytes(contrib.length)
                                if layer <= retainedLayer, var accums = blockAccums[contrib.pkey] {
                                    accums[contrib.leaf].data.append(d)
                                    blockAccums[contrib.pkey] = accums
                                }
                            }
                            reader.setByteStuffing(true)
                        }
                    }
                }
            }
        }

        // Emit one CodeBlockInfo per included block, first-inclusion order.
        var included: [BlockAccum] = []
        for accums in blockAccums.values {
            for a in accums where a.included { included.append(a) }
        }
        included.sort { $0.emitOrder < $1.emitOrder }
        let fullBlocks = included.map { a in
            CodeBlockInfo(
                componentIndex: a.componentIndex, level: a.decomLevel, subband: a.subband,
                x: a.x, y: a.y, width: a.width, height: a.height,
                data: a.data, passCount: a.passCount,
                zeroBitPlanes: a.zeroBitPlanes, bandKb: a.bandKb, layerContributions: a.contributions)
        }
        partialAccounting?.recordParsedTile(consumedPacketBytes: consumedPacketBytes, skippedPacketBytes: skippedPacketBytes,
                                            decodedLayers: lastLayer + 1, totalLayers: totalLayers)
        if let cache = layeredBlockCache {
            cache.store(J2KLayeredBlockCache.Entry(blocks: fullBlocks, packetBytesPerLayer: packetBytesPerLayer), for: cacheKey)
            return fullBlocks.compactMap { $0.truncated(toLayer: lastLayer) }
        }
        return fullBlocks
    }

    /// Computes subband dimensions for a given resolution level and subband type.
    ///
    /// v6-alpha3 step 6B slice 4 — accepts `tileOriginX/Y` (default
    /// 0) and computes spec-correct band sizes per ISO/IEC 15444-1
    /// Eq. B-15 when origin is non-zero. For origin (0, 0) the
    /// formula reduces to the legacy recursive `(w + 1) / 2`
    /// outputs — single-tile and 32-aligned multi-tile decode are
    /// byte-identical.
    ///
    /// Eq. B-15:
    ///   tbx0 = ceil((tcx0 - x_offset_b) / 2^d)
    ///   tbx1 = ceil((tcx1 - x_offset_b) / 2^d)
    ///   bandW = tbx1 - tbx0
    /// where (x_offset_b, y_offset_b) is (0, 0) for LL, (2^(d-1), 0)
    /// for HL, (0, 2^(d-1)) for LH, (2^(d-1), 2^(d-1)) for HH; and
    /// d is the decomposition depth (= `levels` for LL, = `levels -
    /// resLevel + 1` for HL/LH/HH at resolution `resLevel`).

    /// T.800 B.6 precinct partition of one resolution level of a tile-component: precinct count and the index of
    /// the first precinct on the resolution grid (anchored at 0), plus the precinct size in band coordinates
    /// (2^PPx at r = 0, 2^(PPx−1) above). Zero counts mean the resolution has no samples and hence no packets.
    static func resolutionPrecinctGrid(
        tileWidth: Int, tileHeight: Int, tileOriginX: Int, tileOriginY: Int,
        levels: Int, resLevel: Int, precinctExps: [(widthExp: Int, heightExp: Int)]?
    ) -> (count: (x: Int, y: Int), first: (x: Int, y: Int), bandPrecinct: (w: Int, h: Int)) {
        let scale = 1 << (levels - resLevel)
        let trx0 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginX, scale)
        let try0 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginY, scale)
        let trx1 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginX + tileWidth, scale)
        let try1 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginY + tileHeight, scale)
        var ppx = 15, ppy = 15
        if let exps = precinctExps, !exps.isEmpty {
            let pp = exps[min(resLevel, exps.count - 1)]
            ppx = pp.widthExp
            ppy = pp.heightExp
        }
        let countX = trx1 > trx0 ? EncoderPipeline.ceilDivIntegerOrigin(trx1, 1 << ppx) - (trx0 >> ppx) : 0
        let countY = try1 > try0 ? EncoderPipeline.ceilDivIntegerOrigin(try1, 1 << ppy) - (try0 >> ppy) : 0
        let bandW = 1 << (resLevel == 0 ? ppx : max(0, ppx - 1))
        let bandH = 1 << (resLevel == 0 ? ppy : max(0, ppy - 1))
        return ((countX, countY), (trx0 >> ppx, try0 >> ppy), (bandW, bandH))
    }


    /// Packet sequence of one tile for the five Part 1 progression orders (T.800 B.12, no POC), with every component
    /// on the same sampling grid. Position-driven orders (RPCL, PCRL, CPRL) walk the canvas with the smallest
    /// precinct step and emit the packets of a precinct when its first sample is reached, as B.12.1.3–B.12.1.5.
    static func packetSequence(
        metadata: CodestreamMetadata, tileWidth: Int, tileHeight: Int, tileOriginX: Int, tileOriginY: Int, layers: Int
    ) -> [(layer: Int, res: Int, comp: Int, py: Int, px: Int)] {
        let levels = metadata.configuration.decompositionLevels
        let components = metadata.components.count
        let exps = metadata.configuration.precinctExponents
        var grids: [(count: (x: Int, y: Int), first: (x: Int, y: Int), bandPrecinct: (w: Int, h: Int))] = []
        var stepX: [Int] = [], stepY: [Int] = []
        for res in 0...levels {
            grids.append(resolutionPrecinctGrid(tileWidth: tileWidth, tileHeight: tileHeight, tileOriginX: tileOriginX,
                                                tileOriginY: tileOriginY, levels: levels, resLevel: res, precinctExps: exps))
            var ppx = 15, ppy = 15
            if let exps, !exps.isEmpty { let pp = exps[min(res, exps.count - 1)]; ppx = pp.widthExp; ppy = pp.heightExp }
            stepX.append(1 << min(60, ppx + levels - res))
            stepY.append(1 << min(60, ppy + levels - res))
        }
        var sequence: [(layer: Int, res: Int, comp: Int, py: Int, px: Int)] = []
        func rasterPrecincts(_ res: Int, _ body: (Int, Int) -> Void) {
            let grid = grids[res]
            for py in 0..<grid.count.y { for px in 0..<grid.count.x { body(py, px) } }
        }
        let tx1 = tileOriginX + tileWidth, ty1 = tileOriginY + tileHeight
        /// Precinct index of resolution `res` whose first sample is the canvas position (x, y), or nil when no precinct
        /// starts there (B.12.1.3 conditions).
        func precinctStarting(res: Int, x: Int, y: Int) -> (py: Int, px: Int)? {
            let grid = grids[res]
            guard grid.count.x > 0, grid.count.y > 0 else { return nil }
            let scale = 1 << (levels - res)
            let trx0 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginX, scale)
            let try0 = EncoderPipeline.ceilDivIntegerOrigin(tileOriginY, scale)
            let startsY = y % stepY[res] == 0 || (y == tileOriginY && (try0 * scale) % stepY[res] != 0)
            let startsX = x % stepX[res] == 0 || (x == tileOriginX && (trx0 * scale) % stepX[res] != 0)
            guard startsX, startsY else { return nil }
            let ppxBand = grid.bandPrecinct.w << (res == 0 ? 0 : 1), ppyBand = grid.bandPrecinct.h << (res == 0 ? 0 : 1)
            let px = EncoderPipeline.ceilDivIntegerOrigin(x, scale) / ppxBand - grid.first.x
            let py = EncoderPipeline.ceilDivIntegerOrigin(y, scale) / ppyBand - grid.first.y
            guard px >= 0, py >= 0, px < grid.count.x, py < grid.count.y else { return nil }
            return (py, px)
        }
        func positions(_ steps: [Int], from origin: Int, to end: Int) -> [Int] {
            let step = steps.min() ?? 1
            var out: [Int] = [origin]
            var value = origin - origin % step + step
            while value < end { out.append(value); value += step }
            return out
        }
        switch metadata.configuration.progressionOrder {
        case .lrcp:
            for layer in 0..<layers { for res in 0...levels { for comp in 0..<components {
                rasterPrecincts(res) { py, px in sequence.append((layer, res, comp, py, px)) }
            } } }
        case .rlcp:
            for res in 0...levels { for layer in 0..<layers { for comp in 0..<components {
                rasterPrecincts(res) { py, px in sequence.append((layer, res, comp, py, px)) }
            } } }
        case .rpcl:
            for res in 0...levels {
                for y in positions([stepY[res]], from: tileOriginY, to: ty1) { for x in positions([stepX[res]], from: tileOriginX, to: tx1) {
                    for comp in 0..<components {
                        if let p = precinctStarting(res: res, x: x, y: y) { for layer in 0..<layers { sequence.append((layer, res, comp, p.py, p.px)) } }
                    }
                } }
            }
        case .pcrl:
            for y in positions(stepY, from: tileOriginY, to: ty1) { for x in positions(stepX, from: tileOriginX, to: tx1) {
                for comp in 0..<components { for res in 0...levels {
                    if let p = precinctStarting(res: res, x: x, y: y) { for layer in 0..<layers { sequence.append((layer, res, comp, p.py, p.px)) } }
                } }
            } }
        case .cprl:
            for comp in 0..<components {
                for y in positions(stepY, from: tileOriginY, to: ty1) { for x in positions(stepX, from: tileOriginX, to: tx1) {
                    for res in 0...levels {
                        if let p = precinctStarting(res: res, x: x, y: y) { for layer in 0..<layers { sequence.append((layer, res, comp, p.py, p.px)) } }
                    }
                } }
            }
        }
        return sequence
    }

    /// Skips an SOP marker segment (FF91, length 4, Nsop) at a packet boundary when present (T.800 A.8.1).
    static func skipSOPMarker(_ reader: inout J2KBitReader) throws {
        guard reader.isByteAligned, reader.peekUInt16() == 0xFF91 else { return }
        try reader.skip(6)
    }

    /// Skips an EPH marker (FF92) after a packet header when present (T.800 A.8.2).
    static func skipEPHMarker(_ reader: inout J2KBitReader) {
        guard reader.isByteAligned, reader.peekUInt16() == 0xFF92 else { return }
        try? reader.skip(2)
    }

    private static func subbandDimensions(
        tileWidth: Int, tileHeight: Int,
        tileOriginX: Int = 0, tileOriginY: Int = 0,
        levels: Int, resLevel: Int, subband: J2KSubband
    ) -> (width: Int, height: Int) {
        let d: Int
        if resLevel == 0 {
            d = levels   // LL at deepest decomposition level
        } else {
            d = levels - resLevel + 1
        }
        let denom = 1 << d
        let half  = d >= 1 ? (1 << (d - 1)) : 0
        let xOff: Int
        let yOff: Int
        switch subband {
        case .ll: xOff = 0;    yOff = 0
        case .hl: xOff = half; yOff = 0
        case .lh: xOff = 0;    yOff = half
        case .hh: xOff = half; yOff = half
        }
        let tcx0 = tileOriginX
        let tcy0 = tileOriginY
        let tcx1 = tileOriginX + tileWidth
        let tcy1 = tileOriginY + tileHeight
        let tbx0 = EncoderPipeline.ceilDivIntegerOrigin(tcx0 - xOff, denom)
        let tby0 = EncoderPipeline.ceilDivIntegerOrigin(tcy0 - yOff, denom)
        let tbx1 = EncoderPipeline.ceilDivIntegerOrigin(tcx1 - xOff, denom)
        let tby1 = EncoderPipeline.ceilDivIntegerOrigin(tcy1 - yOff, denom)
        return (tbx1 - tbx0, tby1 - tby0)
    }

    /// v6-alpha3 step 6B slice 4 — band canvas-coord origin per
    /// ISO/IEC 15444-1 Eq. B-15. Used by `extractTileData` to
    /// canvas-anchor the code-block partition (mirror of the
    /// encoder's step-6A canvas-anchored grid).
    private static func subbandCanvasOrigin(
        tileOriginX: Int, tileOriginY: Int,
        levels: Int, resLevel: Int, subband: J2KSubband
    ) -> (x: Int, y: Int) {
        let d: Int
        if resLevel == 0 {
            d = levels
        } else {
            d = levels - resLevel + 1
        }
        let denom = 1 << d
        let half  = d >= 1 ? (1 << (d - 1)) : 0
        let xOff: Int
        let yOff: Int
        switch subband {
        case .ll: xOff = 0;    yOff = 0
        case .hl: xOff = half; yOff = 0
        case .lh: xOff = 0;    yOff = half
        case .hh: xOff = half; yOff = half
        }
        return (
            EncoderPipeline.ceilDivIntegerOrigin(tileOriginX - xOff, denom),
            EncoderPipeline.ceilDivIntegerOrigin(tileOriginY - yOff, denom)
        )
    }

    /// Decodes the number of coding passes per ISO/IEC 15444-1 Table B.4.
    private static func decodeCodingPasses(_ reader: inout J2KBitReader) throws -> Int {
        if !(try reader.readBit()) { return 1 }   // 0 → 1 pass
        if !(try reader.readBit()) { return 2 }   // 10 → 2 passes
        // 11...
        let b3 = try reader.readBit()
        let b4 = try reader.readBit()
        if !(b3 && b4) {
            return 3 + (b3 ? 2 : 0) + (b4 ? 1 : 0) // 1100→3, 1101→4, 1110→5
        }
        // 1111 → read 5-bit value per ISO 15444-1 Table B.4
        let value5 = Int(try reader.readBits(5))
        if value5 < 31 {
            return 6 + value5                         // 1111 XXXXX → 6-36
        }
        return 37 + Int(try reader.readBits(7))      // 1111 11111 XXXXXXX → 37-164
    }

    /// A code-block's tier-2 length state across packets (ISO/IEC 15444-1 B.10.7): `Lblock` and the codeword
    /// segment a previous layer left open. Mirrors the rule in `DicomJ2KPacketHeaderReader.packetLength`.
    struct SegmentLengthState {
        var lblock = 3
        /// Passes the open segment can hold; 0 before the block's first segment.
        var capacity = 0
        var used = 0

        /// Reads the lengths one packet signals for `passes` new passes: one per codeword-segment piece.
        mutating func readLengths(
            _ reader: inout J2KBitReader, passes: Int, terminateOnEachPass: Bool, bypass: Bool
        ) throws -> (pieces: [Int], continuesSegment: Bool) {
            while try reader.readBit() { lblock += 1 }
            let continuesSegment = capacity > 0 && used < capacity
            var remaining = passes
            var pieces: [Int] = []
            while remaining > 0 {
                if used == capacity {
                    capacity = DecoderPipeline.segmentCapacity(
                        previous: capacity, terminateOnEachPass: terminateOnEachPass, bypass: bypass)
                    used = 0
                }
                let contribution = min(remaining, capacity - used)
                let passLog = Int.bitWidth - 1 - contribution.leadingZeroBitCount
                pieces.append(Int(try reader.readBits(lblock + passLog)))
                remaining -= contribution
                used += contribution
            }
            return (pieces, continuesSegment)
        }
    }

    /// Passes a codeword segment holds (Annex D): one per pass under RESTART; under selective bypass the first
    /// ten passes, then alternately two raw passes and one arithmetic cleanup pass; otherwise the whole block.
    /// - Parameter previous: the previous segment's capacity, 0 for the first segment.
    static func segmentCapacity(previous: Int, terminateOnEachPass: Bool, bypass: Bool) -> Int {
        if terminateOnEachPass { return 1 }
        guard bypass else { return 109 }
        if previous == 0 { return 10 }
        return previous == 10 || previous == 1 ? 2 : 1
    }

    /// Splits a code-block's passes into codeword segments.
    static func segmentPassCounts(numPasses: Int, terminateOnEachPass: Bool, bypass: Bool) -> [Int] {
        var counts: [Int] = []
        var remaining = numPasses
        var capacity = 0
        while remaining > 0 {
            capacity = segmentCapacity(previous: capacity, terminateOnEachPass: terminateOnEachPass, bypass: bypass)
            counts.append(min(remaining, capacity))
            remaining -= capacity
        }
        return counts
    }

    /// Entropy-decoder options for a codestream's code-block style.
    static func decodeCodingOptions(for config: DecoderConfiguration, checksEntropyIntegrity: Bool) -> CodingOptions {
        CodingOptions(
            bypassEnabled: config.useSelectiveArithmeticBypass,
            resetContextOnEachPass: config.resetContextOnEachPass,
            terminateOnEachPass: config.terminateOnEachPass,
            verticallyCausalContext: config.verticallyCausalContext,
            segmentationSymbols: config.useSegmentationSymbols,
            checksEntropyIntegrity: checksEntropyIntegrity)
    }

    // MARK: - Stage 3: Entropy Decoding

    /// Decoded subband information.
    struct SubbandInfo: Sendable {
        let componentIndex: Int
        let level: Int
        let subband: J2KSubband
        let coefficients: [Int32]
        /// Double-precision dequantized coefficients for the irreversible 9/7 path.
        /// When populated, the inverse DWT uses these directly to avoid
        /// precision loss from Int32 rounding of fractional dequantized values.
        let doubleCoefficients: [Double]?
        let width: Int
        let height: Int
        /// Per-coefficient mask set to `true` where the HTJ2K block decoder
        /// applied a block-level partial-refinement midpoint. When non-empty
        /// and for the irreversible HT path, dequantization must skip the
        /// quantization bin midpoint (`+0.5 * stepSize`) for those coefficients
        /// to avoid the double-midpoint bias.
        let htPartiallyRefined: [Bool]

        init(
            componentIndex: Int,
            level: Int,
            subband: J2KSubband,
            coefficients: [Int32],
            doubleCoefficients: [Double]?,
            width: Int,
            height: Int,
            htPartiallyRefined: [Bool] = []
        ) {
            self.componentIndex = componentIndex
            self.level = level
            self.subband = subband
            self.coefficients = coefficients
            self.doubleCoefficients = doubleCoefficients
            self.width = width
            self.height = height
            self.htPartiallyRefined = htPartiallyRefined
        }
    }

    /// Applies entropy decoding to code blocks.
    ///
    /// When `metadata.configuration.useHTJ2K` is true, uses HTJ2K FBCOT block
    /// decoding (ISO/IEC 15444-15). Otherwise uses legacy EBCOT bit-plane
    /// decoding (ISO/IEC 15444-1).
    /// Internal (was private through v7.0.0); promoted to allow
    /// v7.1.0 H1.1 Defect A diagnostic test to compare per-tile
    /// `[SubbandInfo]` output between GPU-entropy and CPU-entropy
    /// paths. Not part of the public API surface.
    ///
    /// v7.1.0 H1.1 — `isMultiTilePerTile` parameter added to suppress
    /// the v5.9 zero-copy fast-lane (line ~1902) when the caller is
    /// `decodeTilePayloadGPU` and the downstream IDWT is forced to
    /// CPU per E1.2 (``). The fast-lane
    /// returns `([], batch)` assuming a downstream GPU IDWT will
    /// consume `batch` via `inverse2DInt32FullFusedFromCodeblocks`;
    /// when CPU IDWT runs instead, the empty `[SubbandInfo]`
    /// produces zero coefficients → zero spatial output → DC
    /// unshift adds +32 768 = exactly the Defect A pixel diff.
    /// Suppressing the fast-lane forces the slow-lane regroup,
    /// which populates `[SubbandInfo]` correctly for CPU IDWT.
    func applyEntropyDecoding(
        _ blocks: [CodeBlockInfo],
        metadata: CodestreamMetadata,
        // v6.2.0 D4 — `true` only when the caller is on the GPU
        // pipeline path (decodeSingleTileGPU / decodeTilePayloadGPU).
        // Constrains the `_gpuHTEntropyEnabled` static-flag-driven
        // GPU HT entropy decode so it doesn't fire on CPU pipeline
        // paths where the regroup downstream can't consume the
        // GPU-decoded output. CPU `decodeWithGPUHT(_:)` callers
        // still get GPU HT entropy via the `useGPUHT` instance var
        // independent of this parameter — the OR-with-flag at the
        // consume sites is the load-bearing gate.
        // v7.1.0 H1.1 — set true by `decodeTilePayloadGPU` for every
        // tile in a multi-tile decode. Suppresses the v5.9 zero-copy
        // fast-lane (line ~1902) which assumes a downstream GPU IDWT
        // will consume `batch` via `inverse2DInt32FullFusedFromCodeblocks`.
        // For multi-tile per-tile decode, E1.2 forces CPU IDWT
        // (`applyInverseWaveletTransformGPU` falls back when
        // ``); the fast-lane's empty
        // `[SubbandInfo]` would produce zero coefficients → DC
        // unshift adds +32 768 to all pixels = exactly the Defect A
        // observed diff. Suppressing the fast-lane forces the slow-
        // lane regroup, which populates `[SubbandInfo]` correctly
        // for CPU IDWT consumption.
        // v7.2.0 Phase E — pre-batched GPU HT entropy results.
        // When non-nil, the function skips its own per-tile GPU
        // dispatch (the `gpuEarly` block) and instead consumes the
        // supplied `[blockIdxWithinThisTile: [Int32]]` as if it had
        // performed the dispatch itself. Used by
        // `decodeMultiTileGPUBatched` to amortize the per-tile
        // MTLCommandBuffer overhead across all tiles in one CB.
        // The returned `batch: J2KGPUHTBatch?` is always nil on this
        // path — the caller is responsible for the IDWT routing
        // (multi-tile per-tile uses CPU IDWT, no batch needed).
    ) async throws -> [SubbandInfo] {
        let isIrreversible: Bool
        if case .irreversible97 = metadata.configuration.waveletFilter {
            isIrreversible = true
        } else {
            isIrreversible = false
        }
        let useHT = metadata.configuration.useHTJ2K

        // v5.9 zero-copy fast-lane.
        //
        // When the v5.8 fused-DWT path is going to be active
        // downstream (session + reversible 5/3 + conformant HT +
        // all-blocks-eligible) AND the IDWT itself will run on GPU,
        // the LH/HL/HH `[SubbandInfo]` we'd build via the CPU
        // regroup loop are dead code — the fused DWT consumes them
        // straight off the GPU codeblock buffer via the scatter
        // kernel. The fast lane skips the regroup entirely and only
        // produces the LL `[SubbandInfo]` that the outermost-level
        // DWT initialLL upload still needs.
        //
        // Memcpy budget on the fast-lane: O(LL codeblocks per
        // component) — typically 1–4 per component on 5-decomp
        // images. Down from O(all codeblocks) on the slow-lane.
        //
        // The downstream-IDWT-path precondition (`idwtWillBeGPU`)
        // mirrors `applyInverseWaveletTransformGPU`'s own gate.
        // When that gate fails, the IDWT falls back to CPU
        // `applyInverseWaveletTransform`, which expects
        // `[SubbandInfo]` for *all* subbands — and the fast lane
        // only provides LL. The mr_002 fixture (180×180 = 32400 px)
        // is the canonical case: GPU IDWT requires
        // `pixelCount >= 256*256`, so the small-image path goes to
        // CPU. Without this gate the fast lane fires anyway, the
        // CPU IDWT sees empty LH/HL/HH, and 30541/64800 output
        // bytes diverge from the sessionless reference.
        // `testCorpusSessionAndSessionlessAgreeBitExact` is the
        // regression gate.
        // v8 Phase 1 — also gate on `_gpuInverse53Enabled` BEFORE
        // calling `J2KMetalDWT.isAvailable`. When --no-gpu is set
        // via the CLI (or the env var/flag is otherwise off), GPU
        // IDWT can never run, so this whole probe is wasted —
        // worse, calling `J2KMetalDWT.isAvailable` here costs
        // ~50 ms cold the first time Metal is touched per process.
        // On small/medium CLI invocations this was the dominant
        // overhead.

        // Struct key avoids per-block string interpolation allocations.
        struct SubbandKey: Hashable {
            let componentIndex: Int; let level: Int; let subband: J2KSubband
        }

        // Track subband dimensions and use 2D placement for code blocks
        var subbandDims: [SubbandKey: (width: Int, height: Int)] = [:]
        // Store decoded code blocks with their positions for proper 2D placement
        struct DecodedBlock {
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let coefficients: [Int32]
            /// Per-coefficient mask set to `true` where the HT block decoder
            /// applied a block-level partial-refinement midpoint. Empty for
            /// EBCOT blocks (which never carry this flag).
            let htPartiallyRefined: [Bool]
        }
        var subbandBlocks: [SubbandKey: [DecodedBlock]] = [:]

        let blockCount = blocks.count
        // Each EBCOT code block is independently decodable: own MQ state, context models,
        // coefficient arrays. DecoderScratchBuffers are per-task (not shared). Thread-safe
        // for all bit depths and filter types.
        let shouldParallelDecodeBlocks = blockCount >= 4

        if shouldParallelDecodeBlocks {
            // === Parallel code block decoding ===
            // Each code block is independent (own MQ state + context models for EBCOT,
            // own MEL/VLC/MagSgn state for HTJ2K).
            let componentBitDepths = metadata.components.map { $0.bitDepth }
            let decodeOptions = Self.decodeCodingOptions(for: metadata.configuration,
                                                       checksEntropyIntegrity: maxQualityLayer == nil)

            // Parallel decode using structured concurrency.
            //
            // v10.25 — load-balanced + oversubscribed + P-core-biased entropy
            // scheduling. The previous design split blocks into exactly
            // `coreCount` *contiguous* chunks (`chunkSize = blockCount /
            // coreCount`). Code-block decode cost is highly skewed (dense LL /
            // low-frequency blocks vs near-empty HH), and blocks arrive in
            // resolution/packet order, so expensive blocks clustered into a few
            // chunks → the slowest chunk gated the whole stage while other cores
            // sat idle (~2.9 of 8 cores effective on M2, measured). And the
            // tasks ran at default priority, so they spilled onto M-series
            // E-cores (3–4× slower than P-cores).
            //
            // Fix (bit-exact — output is keyed by block index, so work
            // *distribution* is free to change): distribute blocks across
            // `2 × coreCount` buckets using LPT (longest-processing-time-first):
            // sort blocks by descending estimated cost (encoded byte length is a
            // good proxy for entropy-decode work) and greedily assign each to the
            // least-loaded bucket. Oversubscription + greedy balancing keeps the
            // tail short; child tasks inherit visible or shadow priority from the caller.
            // This is the decode-side analogue of the encoder's Tier1ChunkPlan.
            let coreCount = ProcessInfo.processInfo.processorCount
            let bucketCount = min(blockCount, max(1, coreCount * 2))
            let buckets: [[Int]] = {
                var b = [[Int]](repeating: [], count: bucketCount)
                var load = [Int](repeating: 0, count: bucketCount)
                // GPU-pre-decoded blocks cost ~nothing here (just a copy); weight
                // them at 1 so they don't distort balancing.
                let order = (0..<blockCount).sorted {
                    blocks[$0].data.count > blocks[$1].data.count
                }
                for idx in order {
                    var lo = 0
                    for k in 1..<bucketCount where load[k] < load[lo] { lo = k }
                    b[lo].append(idx)
                    load[lo] += max(1, blocks[idx].data.count)
                }
                return b
            }()

            let allResults: [([Int32], [Bool])?] = try await withThrowingTaskGroup(
                of: [(Int, [Int32], [Bool])].self
            ) { group in
                for bucket in buckets where !bucket.isEmpty {
                    group.addTask {
                        try Task.checkCancellation()
                        var chunkResults: [(Int, [Int32], [Bool])] = []
                        chunkResults.reserveCapacity(bucket.count)
                        // One scratch buffer per task — reused across all blocks in the bucket
                        let scratch = useHT ? nil : DecoderScratchBuffers()
                        for i in bucket {
                            try Task.checkCancellation()
                            // Skip blocks already decoded on GPU. The
                            // empty `htPartiallyRefined` mask matches the
                            // cleanup-only branch below
                            // (cleanup-only blocks never carry partial
                            // refinement).
                            let block = blocks[i]
                            let bitDepth = block.bandKb > 0 ? block.bandKb : componentBitDepths[block.componentIndex]

                            let coeffs: [Int32]
                            let htPartiallyRefined: [Bool]
                            if useHT {
                                let htDecoder = HTBlockDecoder(
                                    width: block.width,
                                    height: block.height,
                                    subband: block.subband
                                )
                                do {
                                    // Part-15 conformant blocks are cleanup-only; no refinement
                                    // passes, so the partial-refinement mask is empty.
                                    if block.data.isEmpty || block.passCount == 0 {
                                        coeffs = [Int32](repeating: 0, count: block.width * block.height)
                                    } else {
                                        coeffs = try htDecoder.decodeCleanupConformant(
                                            rawBytes: [UInt8](block.data),
                                            missingMSBs: block.zeroBitPlanes)
                                    }
                                    htPartiallyRefined = []
                                }
                            } else {
                                let blockDecoder = CodeBlockDecoder()
                                let codeBlock = J2KCodeBlock(
                                    index: 0,
                                    x: block.x,
                                    y: block.y,
                                    width: block.width,
                                    height: block.height,
                                    subband: block.subband,
                                    data: block.data,
                                    passeCount: block.passCount,
                                    zeroBitPlanes: block.zeroBitPlanes,
                                    passSegmentLengths: block.segmentLengths
                                )
                                coeffs = try blockDecoder.decode(
                                    codeBlock: codeBlock,
                                    bitDepth: bitDepth,
                                    options: decodeOptions,
                                    irreversible: isIrreversible,
                                    scratch: scratch
                                )
                                htPartiallyRefined = []
                            }
                            chunkResults.append((i, coeffs, htPartiallyRefined))
                        }
                        return chunkResults
                    }
                }
                // Pre-allocated array indexed by block index avoids hash-table overhead
            var resultsArray = [([Int32], [Bool])?](repeating: nil, count: blockCount)
                for try await chunk in group {
                    for (i, coeffs, mask) in chunk {
                        resultsArray[i] = (coeffs, mask)
                    }
                }
                return resultsArray
            }

            // Collect results sequentially
            for i in 0..<blockCount {
                let block = blocks[i]
                var coeffs: [Int32]
                var htMask: [Bool]
                if let entry = allResults[i] {
                    coeffs = entry.0
                    htMask = entry.1
                } else {
                    coeffs = [Int32](repeating: 0, count: block.width * block.height)
                    htMask = []
                }

                let key = SubbandKey(componentIndex: block.componentIndex, level: block.level, subband: block.subband)

                let currentWidth = subbandDims[key]?.width ?? 0
                let currentHeight = subbandDims[key]?.height ?? 0
                subbandDims[key] = (
                    width: max(currentWidth, block.x + block.width),
                    height: max(currentHeight, block.y + block.height)
                )

                if subbandBlocks[key] == nil {
                    subbandBlocks[key] = []
                }
                subbandBlocks[key]?.append(DecodedBlock(
                    x: block.x, y: block.y,
                    width: block.width, height: block.height,
                    coefficients: coeffs,
                    htPartiallyRefined: htMask
                ))
            }
        } else {
            // Sequential path for small block counts
            let decodeOptions = Self.decodeCodingOptions(for: metadata.configuration,
                                                       checksEntropyIntegrity: maxQualityLayer == nil)
            for block in blocks {
                try Task.checkCancellation()
                let compInfo = metadata.components[block.componentIndex]
                let bitDepth = block.bandKb > 0 ? block.bandKb : compInfo.bitDepth
                let coeffs: [Int32]
                let htMask: [Bool]

                if useHT {
                    // HTJ2K path: use FBCOT block decoding.
                    let htDecoder = HTBlockDecoder(
                        width: block.width,
                        height: block.height,
                        subband: block.subband
                    )
                    do {
                        if block.data.isEmpty || block.passCount == 0 {
                            coeffs = [Int32](repeating: 0, count: block.width * block.height)
                        } else {
                            coeffs = try htDecoder.decodeCleanupConformant(
                                rawBytes: [UInt8](block.data),
                                missingMSBs: block.zeroBitPlanes)
                        }
                        htMask = []
                    }
                } else {
                    // Legacy path: use EBCOT bit-plane decoding
                    let decoder = CodeBlockDecoder()
                    let codeBlock = J2KCodeBlock(
                        index: 0,
                        x: block.x,
                        y: block.y,
                        width: block.width,
                        height: block.height,
                        subband: block.subband,
                        data: block.data,
                        passeCount: block.passCount,
                        zeroBitPlanes: block.zeroBitPlanes,
                        passSegmentLengths: block.segmentLengths
                    )
                    coeffs = try decoder.decode(
                        codeBlock: codeBlock,
                        bitDepth: bitDepth,
                        options: decodeOptions,
                        irreversible: isIrreversible
                    )
                    htMask = []
                }

                let key = SubbandKey(componentIndex: block.componentIndex, level: block.level, subband: block.subband)

                let currentWidth = subbandDims[key]?.width ?? 0
                let currentHeight = subbandDims[key]?.height ?? 0
                subbandDims[key] = (
                    width: max(currentWidth, block.x + block.width),
                    height: max(currentHeight, block.y + block.height)
                )

                if subbandBlocks[key] == nil {
                    subbandBlocks[key] = []
                }
                subbandBlocks[key]?.append(DecodedBlock(
                    x: block.x, y: block.y,
                    width: block.width, height: block.height,
                    coefficients: coeffs,
                    htPartiallyRefined: htMask
                ))
            }
        }

        // Scatter code block coefficients into proper 2D subband positions
        var subbands: [SubbandInfo] = []
        for (key, decodedBlocks) in subbandBlocks {
            guard let dims = subbandDims[key] else { continue }

            let compIdx = key.componentIndex
            let level = key.level
            let subbandType = key.subband

            // Create subband buffer and place each code block at its correct position
            var subbandCoeffs = [Int32](repeating: 0, count: dims.width * dims.height)
            // Parallel per-coefficient mask for HT partial refinement. Scatter only
            // if at least one contributing block supplies a non-empty mask; keeping
            // it empty is the fast path (cleanup-only blocks, EBCOT blocks).
            let subbandPixelCount = dims.width * dims.height
            let anyHTMask = decodedBlocks.contains { !$0.htPartiallyRefined.isEmpty }
            var subbandHTMask: [Bool] = anyHTMask ? [Bool](repeating: false, count: subbandPixelCount) : []
            subbandCoeffs.withUnsafeMutableBufferPointer { dstBuf in
                for db in decodedBlocks {
                    db.coefficients.withUnsafeBufferPointer { srcBuf in
                        for row in 0..<db.height {
                            let srcStart = row * db.width
                            let dstStart = (db.y + row) * dims.width + db.x
                            let copyCount = min(db.width, srcBuf.count - srcStart)
                            guard copyCount > 0, dstStart + copyCount <= dstBuf.count else { continue }
                            dstBuf.baseAddress!.advanced(by: dstStart)
                                .update(from: srcBuf.baseAddress!.advanced(by: srcStart), count: copyCount)
                        }
                    }
                    if anyHTMask && !db.htPartiallyRefined.isEmpty {
                        for row in 0..<db.height {
                            let srcStart = row * db.width
                            let dstStart = (db.y + row) * dims.width + db.x
                            for col in 0..<db.width {
                                let srcIdx = srcStart + col
                                let dstIdx = dstStart + col
                                guard srcIdx < db.htPartiallyRefined.count,
                                      dstIdx < subbandHTMask.count else { continue }
                                if db.htPartiallyRefined[srcIdx] {
                                    subbandHTMask[dstIdx] = true
                                }
                            }
                        }
                    }
                }
            }

            subbands.append(SubbandInfo(
                componentIndex: compIdx,
                level: level,
                subband: subbandType,
                coefficients: subbandCoeffs,
                doubleCoefficients: nil,
                width: dims.width,
                height: dims.height,
                htPartiallyRefined: subbandHTMask
            ))
        }

        return subbands
    }

    // MARK: - Stage 4: Dequantization

    /// Applies dequantization to decoded subbands (parallel across subbands).
    private func applyDequantization(
        _ subbands: [SubbandInfo],
        metadata: CodestreamMetadata
    ) async throws -> [SubbandInfo] {
        let levels = metadata.configuration.decompositionLevels

        let isIrreversible: Bool
        if case .irreversible97 = metadata.configuration.waveletFilter {
            isIrreversible = true
        } else {
            isIrreversible = false
        }

        // HTJ2K (FBCOT) outputs coefficients at natural scale, while standard
        // EBCOT uses bpno_plus_one (shifted left by 1) for irreversible 9/7.
        // The dequantization scale factor must account for this difference.
        let useHTJ2K = metadata.configuration.useHTJ2K
        let quantSteps = metadata.quantizationSteps  // capture value type for task isolation

        guard !subbands.isEmpty else { return [] }
        // Each subband is independent — process all in parallel.
        var result = [SubbandInfo](repeating: subbands[0], count: subbands.count)
        try await withThrowingTaskGroup(of: (Int, SubbandInfo).self) { group in
            for (idx, info) in subbands.enumerated() {
                group.addTask {
                    // QCD keys use resolution-level numbering (1=coarsest, NL=finest),
                    // but SubbandInfo.level uses decomposition-level numbering (NL=coarsest, 1=finest).
                    // Convert: resLevel = NL - decomLevel + 1
                    let key: String
                    if info.subband == .ll {
                        key = "LL_0"
                    } else {
                        let resLevel = levels - info.level + 1
                        key = "\(info.subband.rawValue)_\(resLevel)"
                    }
                    let stepSize = quantSteps[key] ?? 1.0

                    guard isIrreversible else {
                        // For reversible 5/3, step size is always 1 (no quantization).
                        return (idx, SubbandInfo(
                            componentIndex: info.componentIndex,
                            level: info.level,
                            subband: info.subband,
                            coefficients: info.coefficients,
                            doubleCoefficients: nil,
                            width: info.width,
                            height: info.height
                        ))
                    }

                    // For irreversible 9/7, dequantize to Double to preserve fractional
                    // precision through the inverse DWT. Rounding to Int32 here would
                    // destroy sub-integer information (e.g. step=0.02, q=10 → 0.2 → 0).
                    //
                    // Standard EBCOT coefficients use bpno_plus_one scale (shifted left
                    // by 1) to match OPJ's oneplushalf approach, so dequantization
                    // applies ×0.5 to compensate. The EBCOT halfBit adds 1 at bit 0,
                    // giving effective dequantization of (2q + 1) × stepSize/2 =
                    // (q + 0.5) × stepSize — the midpoint of the quantization bin.
                    //
                    // HTJ2K (FBCOT) outputs coefficients at natural scale (no shift).
                    // For **cleanup-only** or **fully-refined** coefficients the block
                    // decoder returns the exact integer magnitude, so dequantization
                    // adds the standard `+0.5 * stepSize` quantization-bin midpoint.
                    // For **partially-refined** coefficients the block decoder has
                    // already injected a block-level midpoint `1 << uncertaintyPlane`
                    // that centers the coefficient inside its residual-uncertainty
                    // range; in that case adding another `+0.5 * stepSize` on top
                    // produces the double-midpoint bias, so we skip the offset
                    // whenever `htPartiallyRefined[i]` is set.
                    let effectiveStepSize = useHTJ2K ? stepSize : (0.5 * stepSize)
                    let midpointOffset = useHTJ2K ? (0.5 * stepSize) : 0.0
                    let htMask = info.htPartiallyRefined
                    let hasHTMask = useHTJ2K && !htMask.isEmpty && htMask.count == info.coefficients.count
                    let dequantizedDouble: [Double]
                    if hasHTMask {
                        // HTJ2K per-coefficient offset — must stay scalar (mask varies per element)
                        dequantizedDouble = info.coefficients.enumerated().map { i, coeff -> Double in
                            if coeff == 0 { return 0.0 }
                            let sign: Double = coeff > 0 ? 1.0 : -1.0
                            let magnitude = Double(abs(coeff))
                            let offset = htMask[i] ? 0.0 : midpointOffset
                            return sign * (magnitude * effectiveStepSize + offset)
                        }
                    } else {
                        // Standard EBCOT path: vectorise with vDSP.
                        // Steps: Int32→Double, abs, scale+offset, restore sign.
                        let n = info.coefficients.count
                        // Skip zero-init — both arrays are fully overwritten by vDSP before any read.
                        var absDoubles  = [Double](unsafeUninitializedCapacity: n) { _, s in s = n }
                        var signDoubles = [Double](unsafeUninitializedCapacity: n) { _, s in s = n }
                        info.coefficients.withUnsafeBufferPointer { src in
                            // 1. Convert Int32 → Double (signed originals)
                            vDSP_vflt32D(src.baseAddress!, 1, &signDoubles, 1, vDSP_Length(n))
                            // 2. |x|
                            vDSP_vabsD(signDoubles, 1, &absDoubles, 1, vDSP_Length(n))
                            // 3. magnitude * effectiveStepSize + midpointOffset
                            var scale  = effectiveStepSize
                            var offset = midpointOffset
                            vDSP_vsmsaD(absDoubles, 1, &scale, &offset, &absDoubles, 1, vDSP_Length(n))
                            // 4. Restore sign: sign(original) * scaled_magnitude.
                            //    Compute signum(x): clip to ±1 via vDSP_vclipD then multiply.
                            var posOne = 1.0, negOne = -1.0
                            vDSP_vclipD(signDoubles, 1, &negOne, &posOne, &signDoubles, 1, vDSP_Length(n))
                            vDSP_vmulD(absDoubles, 1, signDoubles, 1, &signDoubles, 1, vDSP_Length(n))
                        }
                        // 5. For standard JPEG 2000, midpointOffset == 0.0 so zeros stay zero.
                        //    For HTJ2K without htMask, vDSP_vsmsaD applied a non-zero offset to
                        //    zero-valued coefficients — fix those back to 0.0.
                        if midpointOffset != 0.0 {
                            info.coefficients.withUnsafeBufferPointer { src in
                                for i in 0..<n where src[i] == 0 { signDoubles[i] = 0.0 }
                            }
                        }
                        dequantizedDouble = signDoubles
                    }

                    return (idx, SubbandInfo(
                        componentIndex: info.componentIndex,
                        level: info.level,
                        subband: info.subband,
                        coefficients: info.coefficients,
                        doubleCoefficients: dequantizedDouble,
                        width: info.width,
                        height: info.height,
                        htPartiallyRefined: info.htPartiallyRefined
                    ))
                }
            }
            for try await (idx, subband) in group {
                result[idx] = subband
            }
        }
        return result
    }

    // MARK: - Stage 5: Inverse Wavelet Transform

    /// Applies inverse wavelet transform to reconstruct spatial domain.
    private func applyInverseWaveletTransform(
        _ subbands: [SubbandInfo],
        metadata: CodestreamMetadata,
        // v6-alpha3 step 6B slice 3 — tile-component canvas-coord
        // origin for the parity-aware inverse 5/3 DWT. Default
        // (0, 0) preserves single-tile and 32-aligned multi-tile
        // decode byte-for-byte.
        tileOriginX: Int = 0,
        tileOriginY: Int = 0
    ) async throws -> [[Double]] {
        let filter = metadata.configuration.waveletFilter
        let levels = metadata.configuration.decompositionLevels

        // v10.5.0 Stage B.2 — partial-resolution iDWT truncation.
        // When `partialResolutionLevel = r` is set (in [0, levels]),
        // only the deepest `r` iDWT steps run. The `levelSubbands53`
        // array (built later, deepest-first) is truncated to the
        // first `r` elements before being passed to the iDWT, so
        // the inverse transform stops after producing the LL at
        // decomposition level (N - r). For r = 0, no iDWT runs;
        // the function returns the deepest LL directly.
        let effectiveLevels: Int = {
            if let r = partialResolutionLevel {
                return min(max(r, 0), levels)
            }
            return levels
        }()

        // Use the component count from the SIZ marker, not from the data.
        // Some components may have all-empty packets (e.g., aggressive rate
        // control). They should still produce zero-filled output.
        let maxComponent = max(
            metadata.componentCount - 1,
            subbands.map { $0.componentIndex }.max() ?? 0
        )
        let componentCount = maxComponent + 1

        // Pre-index subbands by component — avoids O(n) .filter per component.
        var subbandsByComponentMut = [[SubbandInfo]](repeating: [], count: componentCount)
        for sb in subbands {
            if sb.componentIndex < componentCount {
                subbandsByComponentMut[sb.componentIndex].append(sb)
            }
        }
        let subbandsByComponent = subbandsByComponentMut

        // Thread-safe result storage for parallel component processing.
        // Each component's IDWT is fully independent (reads separate
        // subbands, writes to its own output array).

        let inverseTransformOneComponent: @Sendable (Int) async throws -> [Double] = { (compIdx: Int) async throws -> [Double] in
            try Task.checkCancellation()
            // Select filter for this component
            let componentFilter: J2KDWT1D.Filter
            if let kernelConfig = metadata.configuration.waveletKernelConfiguration {
                // Use arbitrary wavelet kernel if configured
                if let kernel = kernelConfig.kernel(
                    forTile: 0, component: compIdx,
                    lossless: metadata.configuration.useReversibleTransform
                ) {
                    componentFilter = kernel.toDWTFilter()
                } else {
                    componentFilter = filter
                }
            } else {
                componentFilter = filter
            }

            let compSubbands = subbandsByComponent[compIdx]

            if compSubbands.isEmpty {
                // Component has no data (e.g., all code blocks were zeroed by
                // rate control). Fill with neutral values so downstream stages
                // (color transform, reconstruction) have the expected shape.
                return [Double](repeating: 0.0, count: metadata.width * metadata.height)
            }

            // Find LL subband.  When rate control truncates aggressively the
            // LL code blocks may all be empty, so synthesise a zero-filled
            // subband with the standard dimensions for the deepest level.
            let llSubband: SubbandInfo
            let width: Int
            let height: Int
            if let found = compSubbands.first(where: { $0.subband == .ll }) {
                llSubband = found
                width = found.width
                height = found.height
            } else {
                let cW = metadata.width / metadata.components[compIdx].subsamplingX
                let cH = metadata.height / metadata.components[compIdx].subsamplingY
                var w = cW; var h = cH
                for _ in 0..<levels { w = (w + 1) / 2; h = (h + 1) / 2 }
                llSubband = SubbandInfo(
                    componentIndex: compIdx,
                    level: levels,
                    subband: .ll,
                    coefficients: [Int32](repeating: 0, count: w * h),
                    doubleCoefficients: nil,
                    width: w,
                    height: h
                )
                width = w
                height = h
            }

            // For now, if no decomposition levels, just return LL subband
            if levels == 0 {
                // No decomposition: the LL band is the image; irreversible coefficients are the dequantised doubles.
                return llSubband.doubleCoefficients ?? vDSPConvert.int32sToDoubles(llSubband.coefficients)
            }

            // Convert 1D coefficient arrays to 2D arrays for each subband
            func to2D(_ coeffs: [Int32], width: Int, height: Int) -> [[Int32]] {
                var result = [[Int32]](
                    repeating: [Int32](repeating: 0, count: width),
                    count: height
                )
                for row in 0..<height {
                    for col in 0..<width {
                        let idx = row * width + col
                        if idx < coeffs.count {
                            result[row][col] = coeffs[idx]
                        }
                    }
                }
                return result
            }

            func to2DDouble(_ coeffs: [Int32], width: Int, height: Int) -> [[Double]] {
                var result = [[Double]](
                    repeating: [Double](repeating: 0, count: width),
                    count: height
                )
                for row in 0..<height {
                    for col in 0..<width {
                        let idx = row * width + col
                        if idx < coeffs.count {
                            result[row][col] = Double(coeffs[idx])
                        }
                    }
                }
                return result
            }

            func to2DDoubleFromDoubles(_ coeffs: [Double], width: Int, height: Int) -> [[Double]] {
                var result = [[Double]](
                    repeating: [Double](repeating: 0, count: width),
                    count: height
                )
                for row in 0..<height {
                    for col in 0..<width {
                        let idx = row * width + col
                        if idx < coeffs.count {
                            result[row][col] = coeffs[idx]
                        }
                    }
                }
                return result
            }

            // Compute expected subband dimensions at each decomposition level.
            //
            // v6-alpha3 step 6B slice 3 — for non-zero tile-component
            // canvas origin, use the spec formula per ISO/IEC 15444-1
            // Eq. B-15:
            //   LL_d width  = ceil((tcx0 + compW) / 2^d) - ceil(tcx0 / 2^d)
            //   LL_d height = ceil((tcy0 + compH) / 2^d) - ceil(tcy0 / 2^d)
            // For origin (0, 0) this reduces to ceil(compW / 2^d), which
            // is what the recursive `(pw + 1) / 2` gives — single-tile
            // and 32-aligned multi-tile decode are byte-identical.
            let compW = metadata.width / metadata.components[compIdx].subsamplingX
            let compH = metadata.height / metadata.components[compIdx].subsamplingY
            let tcx0 = tileOriginX / metadata.components[compIdx].subsamplingX
            let tcy0 = tileOriginY / metadata.components[compIdx].subsamplingY
            var levelSizes: [(width: Int, height: Int)] = []
            for d in 0...levels {
                let denom = 1 << d
                let bandX0 = EncoderPipeline.ceilDivIntegerOrigin(tcx0, denom)
                let bandX1 = EncoderPipeline.ceilDivIntegerOrigin(tcx0 + compW, denom)
                let bandY0 = EncoderPipeline.ceilDivIntegerOrigin(tcy0, denom)
                let bandY1 = EncoderPipeline.ceilDivIntegerOrigin(tcy0 + compH, denom)
                levelSizes.append((bandX1 - bandX0, bandY1 - bandY0))
            }

            // Helper: convert 1D Int32 array to 2D padded to standard dimensions.
            // When rate control truncates code blocks, the actual subband data may
            // be smaller than the standard dimension. Zero-pad to the expected size.
            func paddedInt(_ coeffs: [Int32], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [[Int32]] {
                var result = [[Int32]](repeating: [Int32](repeating: 0, count: dstW), count: dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                coeffs.withUnsafeBufferPointer { srcBuf in
                    for row in 0..<copyH {
                        let srcOffset = row * srcW
                        guard srcOffset + copyW <= srcBuf.count else { return }
                        result[row].withUnsafeMutableBufferPointer { dstBuf in
                            dstBuf.baseAddress!.update(from: srcBuf.baseAddress! + srcOffset, count: copyW)
                        }
                    }
                }
                return result
            }

            func paddedDoubleFromInt(_ coeffs: [Int32], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [[Double]] {
                var result = [[Double]](repeating: [Double](repeating: 0, count: dstW), count: dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                coeffs.withUnsafeBufferPointer { srcBuf in
                    for row in 0..<copyH {
                        let srcOffset = row * srcW
                        guard srcOffset + copyW <= srcBuf.count else { return }
                        result[row].withUnsafeMutableBufferPointer { dstBuf in
                            for col in 0..<copyW {
                                dstBuf[col] = Double(srcBuf[srcOffset + col])
                            }
                        }
                    }
                }
                return result
            }

            func paddedDouble(_ coeffs: [Double], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [[Double]] {
                var result = [[Double]](repeating: [Double](repeating: 0, count: dstW), count: dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                coeffs.withUnsafeBufferPointer { srcBuf in
                    for row in 0..<copyH {
                        let srcOffset = row * srcW
                        guard srcOffset + copyW <= srcBuf.count else { return }
                        result[row].withUnsafeMutableBufferPointer { dstBuf in
                            dstBuf.baseAddress!.update(from: srcBuf.baseAddress! + srcOffset, count: copyW)
                        }
                    }
                }
                return result
            }

            // Flat-buffer helpers for 9/7 multi-level IDWT path
            func paddedFlat(_ coeffs: [Double], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Double] {
                if srcW == dstW && srcH == dstH && coeffs.count == dstW * dstH {
                    return coeffs
                }
                var result = [Double](repeating: 0, count: dstW * dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                coeffs.withUnsafeBufferPointer { srcBuf in
                    result.withUnsafeMutableBufferPointer { dstBuf in
                        let dst = dstBuf.baseAddress!
                        let src = srcBuf.baseAddress!
                        for row in 0..<copyH {
                            let srcOffset = row * srcW
                            let dstOffset = row * dstW
                            guard srcOffset + copyW <= srcBuf.count else { return }
                            (dst + dstOffset).update(from: src + srcOffset, count: copyW)
                        }
                    }
                }
                return result
            }

            func paddedFlatFromInt(_ coeffs: [Int32], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Double] {
                var result = [Double](repeating: 0, count: dstW * dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                if srcW == dstW && srcH == dstH && coeffs.count == dstW * dstH {
                    coeffs.withUnsafeBufferPointer { srcBuf in
                        result.withUnsafeMutableBufferPointer { dstBuf in
                            vDSP_vflt32D(srcBuf.baseAddress!, 1, dstBuf.baseAddress!, 1, vDSP_Length(srcBuf.count))
                        }
                    }
                    return result
                }
                coeffs.withUnsafeBufferPointer { srcBuf in
                    result.withUnsafeMutableBufferPointer { dstBuf in
                        let dst = dstBuf.baseAddress!
                        let src = srcBuf.baseAddress!
                        for row in 0..<copyH {
                            let srcOffset = row * srcW
                            let dstOffset = row * dstW
                            guard srcOffset + copyW <= srcBuf.count else { return }
                            vDSP_vflt32D(src + srcOffset, 1, dst + dstOffset, 1, vDSP_Length(copyW))
                        }
                    }
                }
                return result
            }

            /// Pads/crops flat `[Int32]` coefficients into a new flat `[Int32]` buffer.
            /// When dimensions match exactly, returns the original array (COW — no copy).
            func paddedIntFlat(_ coeffs: [Int32], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Int32] {
                if srcW == dstW && srcH == dstH && coeffs.count == dstW * dstH {
                    return coeffs
                }
                var result = [Int32](repeating: 0, count: dstW * dstH)
                let copyW = min(srcW, dstW)
                let copyH = min(srcH, dstH)
                coeffs.withUnsafeBufferPointer { srcBuf in
                    result.withUnsafeMutableBufferPointer { dstBuf in
                        let dst = dstBuf.baseAddress!
                        let src = srcBuf.baseAddress!
                        for row in 0..<copyH {
                            let srcOffset = row * srcW
                            let dstOffset = row * dstW
                            guard srcOffset + copyW <= srcBuf.count else { return }
                            (dst + dstOffset).update(from: src + srcOffset, count: copyW)
                        }
                    }
                }
                return result
            }

            // Full multi-level IDWT reconstruction
            // For 9/7 irreversible, use Double precision throughout all levels to
            // avoid accumulated rounding error from Int32 truncation at each level.
            let useDoublePrecision: Bool
            if case .irreversible97 = componentFilter {
                useDoublePrecision = true
            } else {
                useDoublePrecision = false
            }
            // High-bit-depth medical lossy workflows now use reversible 5/3
            // rate truncation, and the optimized integer IDWT path has verified
            // deterministic behavior there. Keep the conservative fallback only
            // for the more fragile high-bit-depth irreversible 9/7 path.
            // #2329: the vendored J2KDWT2DOptimizer97 float/double inverse produced wrong samples for 8-bit 9/7
            // codestreams from OpenJPEG (grey and colour, with and without ICT) while the reference double-precision
            // J2KDWT2D.inverseTransform97 is exact within one LSB of opj_decompress; every irreversible depth now takes
            // the reference path and the optimiser was removed rather than carried as dead code.
            let useConservativeHighBitDepthPath = useDoublePrecision

            if useDoublePrecision {
                // Double-precision path for 9/7 irreversible wavelet.
                // Use flat-buffer multi-level IDWT to avoid [[Double]]
                // intermediate conversions at each decomposition level.
                let expectedLLW = levelSizes[levels].width
                let expectedLLH = levelSizes[levels].height

                // Convert LL subband to flat [Double]
                let llFlat: [Double]
                if let dc = llSubband.doubleCoefficients {
                    llFlat = paddedFlat(dc, srcW: width, srcH: height, dstW: expectedLLW, dstH: expectedLLH)
                } else {
                    llFlat = paddedFlatFromInt(llSubband.coefficients, srcW: width, srcH: height, dstW: expectedLLW, dstH: expectedLLH)
                }

                // Build flat subbands for each level (deepest first)
                var levelSubbands: [(lh: [Double], lhW: Int, lhH: Int,
                                     hl: [Double], hlW: Int, hlH: Int,
                                     hh: [Double], hhW: Int, hhH: Int)] = []

                for level in (1...levels).reversed() {
                    try Task.checkCancellation()
                    let parentW = levelSizes[level - 1].width
                    let parentH = levelSizes[level - 1].height
                    let llW = levelSizes[level].width
                    let llH = levelSizes[level].height
                    let hlW = parentW - llW
                    let lhH = parentH - llH

                    // HL subband
                    let hlSub = compSubbands.first(where: { $0.level == level && $0.subband == .hl })
                    let hlFlat: [Double]
                    if let hs = hlSub, let dc = hs.doubleCoefficients {
                        hlFlat = paddedFlat(dc, srcW: hs.width, srcH: hs.height, dstW: hlW, dstH: llH)
                    } else if let hs = hlSub {
                        hlFlat = paddedFlatFromInt(hs.coefficients, srcW: hs.width, srcH: hs.height, dstW: hlW, dstH: llH)
                    } else {
                        hlFlat = [Double](repeating: 0, count: hlW * llH)
                    }

                    // LH subband
                    let lhSub = compSubbands.first(where: { $0.level == level && $0.subband == .lh })
                    let lhFlat: [Double]
                    if let ls = lhSub, let dc = ls.doubleCoefficients {
                        lhFlat = paddedFlat(dc, srcW: ls.width, srcH: ls.height, dstW: llW, dstH: lhH)
                    } else if let ls = lhSub {
                        lhFlat = paddedFlatFromInt(ls.coefficients, srcW: ls.width, srcH: ls.height, dstW: llW, dstH: lhH)
                    } else {
                        lhFlat = [Double](repeating: 0, count: llW * lhH)
                    }

                    // HH subband
                    let hhSub = compSubbands.first(where: { $0.level == level && $0.subband == .hh })
                    let hhFlat: [Double]
                    if let hs = hhSub, let dc = hs.doubleCoefficients {
                        hhFlat = paddedFlat(dc, srcW: hs.width, srcH: hs.height, dstW: hlW, dstH: lhH)
                    } else if let hs = hhSub {
                        hhFlat = paddedFlatFromInt(hs.coefficients, srcW: hs.width, srcH: hs.height, dstW: hlW, dstH: lhH)
                    } else {
                        hhFlat = [Double](repeating: 0, count: hlW * lhH)
                    }

                    levelSubbands.append((lh: lhFlat, lhW: llW, lhH: lhH,
                                          hl: hlFlat, hlW: hlW, hlH: llH,
                                          hh: hhFlat, hhW: hlW, hhH: lhH))
                }

                // v10.25 — partial-resolution truncation for the 9/7
                // path, mirroring the 5/3 path's Stage B.2 semantics.
                // Without this, partial-resolution decode of an
                // irreversible codestream ran ALL synthesis levels
                // (high-res bands zero-filled by the B.1 entropy
                // filter) and returned full-dimension data behind the
                // reduced-dimension image header — the same
                // dims/data-size corruption signature as the
                // multi-tile composite bug. For a full decode
                // effectiveLevels == levels and the prefix is the
                // identity. Note the 9/7 multi-level inverse is not
                // parity-aware (no canvas-origin handling) even for
                // full decode — truncation neither adds nor removes
                // that limitation.
                let truncatedSubbands97 = (effectiveLevels < levelSubbands.count)
                    ? Array(levelSubbands.prefix(effectiveLevels))
                    : levelSubbands

                do {
                    var currentLL = to2DDoubleFromDoubles(llFlat, width: expectedLLW, height: expectedLLH)

                    for index in 0..<truncatedSubbands97.count {
                        let levelData = truncatedSubbands97[index]
                        let lh2D = to2DDoubleFromDoubles(levelData.lh, width: levelData.lhW, height: levelData.lhH)
                        let hl2D = to2DDoubleFromDoubles(levelData.hl, width: levelData.hlW, height: levelData.hlH)
                        let hh2D = to2DDoubleFromDoubles(levelData.hh, width: levelData.hhW, height: levelData.hhH)
                        currentLL = try J2KDWT2D.inverseTransform97(
                            ll: currentLL,
                            lh: lh2D,
                            hl: hl2D,
                            hh: hh2D,
                            boundaryExtension: .symmetric
                        )
                    }

                    let rowCount = currentLL.count
                    let colCount = rowCount > 0 ? currentLL[0].count : 0
                    var flattened = [Double](repeating: 0.0, count: rowCount * colCount)
                    flattened.withUnsafeMutableBufferPointer { dst in
                        for r in 0..<rowCount {
                            let row = currentLL[r]
                            let offset = r * colCount
                            for c in 0..<min(colCount, row.count) {
                                dst[offset + c] = row[c]
                            }
                        }
                    }
                    return flattened
                }
            } else {
                // Int32 path for 5/3 reversible wavelet (exact integer arithmetic)
                // Uses flat contiguous buffers throughout to eliminate the hundreds
                // of short-lived [[Int32]] allocations and cache-miss-heavy column
                // gather in the per-level inverseTransform2DOptimized path.
                let expectedLLW = levelSizes[levels].width
                let expectedLLH = levelSizes[levels].height
                let llFlat = paddedIntFlat(
                    llSubband.coefficients,
                    srcW: width, srcH: height,
                    dstW: expectedLLW, dstH: expectedLLH
                )

                // Build flat subbands array deepest-first (mirrors the 9/7 path)
                var levelSubbands53: [(lh: [Int32], lhW: Int, lhH: Int,
                                       hl: [Int32], hlW: Int, hlH: Int,
                                       hh: [Int32], hhW: Int, hhH: Int)] = []

                for level in (1...levels).reversed() {
                    try Task.checkCancellation()
                    let parentW = levelSizes[level - 1].width
                    let parentH = levelSizes[level - 1].height
                    let llW = levelSizes[level].width
                    let llH = levelSizes[level].height
                    let hlW = parentW - llW
                    let lhH = parentH - llH

                    let hlFlat: [Int32]
                    if let hs = compSubbands.first(where: { $0.level == level && $0.subband == .hl }) {
                        hlFlat = paddedIntFlat(hs.coefficients, srcW: hs.width, srcH: hs.height, dstW: hlW, dstH: llH)
                    } else {
                        hlFlat = [Int32](repeating: 0, count: hlW * llH)
                    }

                    let lhFlat: [Int32]
                    if let ls = compSubbands.first(where: { $0.level == level && $0.subband == .lh }) {
                        lhFlat = paddedIntFlat(ls.coefficients, srcW: ls.width, srcH: ls.height, dstW: llW, dstH: lhH)
                    } else {
                        lhFlat = [Int32](repeating: 0, count: llW * lhH)
                    }

                    let hhFlat: [Int32]
                    if let hhs = compSubbands.first(where: { $0.level == level && $0.subband == .hh }) {
                        hhFlat = paddedIntFlat(hhs.coefficients, srcW: hhs.width, srcH: hhs.height, dstW: hlW, dstH: lhH)
                    } else {
                        hhFlat = [Int32](repeating: 0, count: hlW * lhH)
                    }

                    levelSubbands53.append((
                        lh: lhFlat, lhW: llW, lhH: lhH,
                        hl: hlFlat, hlW: hlW, hlH: llH,
                        hh: hhFlat, hhW: hlW, hhH: lhH
                    ))
                }

                if useConservativeHighBitDepthPath {
                    // Conservative [[Int32]] path kept for edge-case correctness
                    var currentLL = paddedInt(llSubband.coefficients, srcW: width, srcH: height, dstW: expectedLLW, dstH: expectedLLH)
                    for (index, _) in Array((1...levels).reversed()).enumerated() {
                        let lvl = levelSubbands53[index]
                        func toJagged(_ flat: [Int32], w: Int, h: Int) -> [[Int32]] {
                            (0..<h).map { r in Array(flat[(r*w)..<(r*w+w)]) }
                        }
                        let lh2D = toJagged(lvl.lh, w: lvl.lhW, h: lvl.lhH)
                        let hl2D = toJagged(lvl.hl, w: lvl.hlW, h: lvl.hlH)
                        let hh2D = toJagged(lvl.hh, w: lvl.hhW, h: lvl.hhH)
                        currentLL = try J2KDWT2D.inverseTransform(
                            ll: currentLL, lh: lh2D, hl: hl2D, hh: hh2D,
                            filter: componentFilter, boundaryExtension: .symmetric
                        )
                    }
                    let rowCount = currentLL.count
                    let colCount = rowCount > 0 ? currentLL[0].count : 0
                    var flattened = [Double](repeating: 0.0, count: rowCount * colCount)
                    flattened.withUnsafeMutableBufferPointer { dst in
                        for r in 0..<rowCount {
                            let row = currentLL[r]
                            let offset = r * colCount
                            for c in 0..<min(colCount, row.count) {
                                dst[offset + c] = Double(row[c])
                            }
                        }
                    }
                    return flattened
                } else {
                    let optimizer = J2KDWT2DOptimizer()
                    // v6-alpha3 step 6B slice 3 — pass tile-component
                    // canvas origin into the parity-aware multi-level
                    // inverse so non-32-aligned multi-tile codestreams
                    // self-decode correctly. For origin (0, 0) the
                    // overload routes to the existing optimised
                    // flat-buffer fast path — byte-identical, zero-cost.
                    //
                    // v10.5.0 Stage B.2 — when partial-resolution decode
                    // is active, truncate the subbands array to the
                    // deepest `effectiveLevels` entries. The iDWT does
                    // exactly N steps for N subband elements; passing
                    // fewer elements stops the inverse transform at the
                    // corresponding decomposition level, producing
                    // reduced-dimension LL output directly. For
                    // effectiveLevels == 0, the iDWT short-circuits and
                    // returns the deepest LL unchanged.
                    //
                    // v10.25 multi-tile partial-resolution —
                    // `outputDepthOffset` tells the parity-aware
                    // multi-level inverse that the truncated chain's
                    // output sits at depth (levels - effectiveLevels),
                    // not 0, so per-level interleave parity stays
                    // anchored to the true canvas depth for non-zero
                    // tile origins. 0 for a full reconstruction.
                    let truncatedSubbands = (effectiveLevels < levelSubbands53.count)
                        ? Array(levelSubbands53.prefix(effectiveLevels))
                        : levelSubbands53
                    let result = try await optimizer.inverseTransformMultiLevel53(
                        ll: llFlat, llW: expectedLLW, llH: expectedLLH,
                        subbands: truncatedSubbands,
                        tileOriginX: tcx0, tileOriginY: tcy0,
                        outputDepthOffset: levels - effectiveLevels
                    )
                    // Convert flat [Int32] → [Double] with vDSP (NEON-vectorised on Apple Silicon)
                    let n = result.data.count
                    var out = [Double](repeating: 0.0, count: n)
                    result.data.withUnsafeBufferPointer { src in
                        vDSP_vflt32D(src.baseAddress!, 1, &out, 1, vDSP_Length(n))
                    }
                    return out
                }
            }
        }

        // Execute component processing: parallel for multi-component images.
        let componentResults: [[Double]]
        if componentCount >= 2 {
            componentResults = try await withThrowingTaskGroup(
                of: (Int, [Double]).self
            ) { group in
                for compIdx in 0..<componentCount {
                    group.addTask {
                        let result = try await inverseTransformOneComponent(compIdx)
                        return (compIdx, result)
                    }
                }
                var results = [[Double]](repeating: [], count: componentCount)
                for try await (compIdx, data) in group {
                    results[compIdx] = data
                }
                return results
            }
        } else {
            var results = [[Double]]()
            for compIdx in 0..<componentCount {
                let data = try await inverseTransformOneComponent(compIdx)
                results.append(data)
            }
            componentResults = results
        }

        return componentResults
    }

    // MARK: - GPU Inverse Wavelet Transform

    /// Extracts a subband as an Int32 array with zero-padding to expected dimensions.
    private func getSubbandAsInt32(_ subbands: [SubbandInfo], level: Int, subband: J2KSubband,
                                     dstW: Int, dstH: Int) -> [Int32] {
        if let sb = subbands.first(where: { $0.level == level && $0.subband == subband }) {
            // Reversible 5/3 path stores integer coefficients in `coefficients`.
            // Some HTJ2K paths populate `doubleCoefficients` after dequant — in
            // that case round to nearest Int32 (lossless dequant produces values
            // exactly representable as Int32 since stepSize == 1 for reversible).
            if let dc = sb.doubleCoefficients {
                let srcData: [Int32] = dc.map { val in
                    let rounded = (val < 0) ? Int32((val - 0.5).rounded(.up)) : Int32((val + 0.5).rounded(.down))
                    return rounded
                }
                return padFlatInt32(srcData, srcW: sb.width, srcH: sb.height, dstW: dstW, dstH: dstH)
            }
            return padFlatInt32(sb.coefficients, srcW: sb.width, srcH: sb.height, dstW: dstW, dstH: dstH)
        }
        return [Int32](repeating: 0, count: dstW * dstH)
    }

    /// Zero-pads a flat Int32 array from source to destination dimensions.
    private func padFlatInt32(_ data: [Int32], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Int32] {
        if srcW == dstW && srcH == dstH && data.count == dstW * dstH { return data }
        var result = [Int32](repeating: 0, count: dstW * dstH)
        let copyW = min(srcW, dstW)
        let copyH = min(srcH, dstH)
        data.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                let src = srcBuf.baseAddress!
                for row in 0..<copyH {
                    let srcOffset = row * srcW
                    let dstOffset = row * dstW
                    guard srcOffset + copyW <= srcBuf.count else { return }
                    (dst + dstOffset).update(from: src + srcOffset, count: copyW)
                }
            }
        }
        return result
    }

    /// Extracts a subband as a Float array with zero-padding to expected dimensions.
    private func getSubbandAsFloat(_ subbands: [SubbandInfo], level: Int, subband: J2KSubband,
                                    dstW: Int, dstH: Int) -> [Float] {
        if let sb = subbands.first(where: { $0.level == level && $0.subband == subband }) {
            let srcData: [Float]
            if let dc = sb.doubleCoefficients {
                srcData = vDSPConvert.doublesToFloats(dc)
            } else {
                srcData = vDSPConvert.int32sToFloats(sb.coefficients)
            }
            return padFlatFloat(srcData, srcW: sb.width, srcH: sb.height, dstW: dstW, dstH: dstH)
        }
        return [Float](repeating: 0, count: dstW * dstH)
    }

    /// Zero-pads a flat Float array from source to destination dimensions.
    private func padFlatFloat(_ data: [Float], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [Float] {
        if srcW == dstW && srcH == dstH && data.count == dstW * dstH { return data }
        var result = [Float](repeating: 0, count: dstW * dstH)
        let copyW = min(srcW, dstW)
        let copyH = min(srcH, dstH)
        for row in 0..<copyH {
            let srcOffset = row * srcW
            let dstOffset = row * dstW
            guard srcOffset + copyW <= data.count else { break }
            for col in 0..<copyW {
                result[dstOffset + col] = data[srcOffset + col]
            }
        }
        return result
    }

    // MARK: - Stage 6: Inverse Colour Transform

    /// Applies inverse colour transform.
    private func applyInverseColorTransform(
        _ components: [[Double]],
        metadata: CodestreamMetadata
    ) throws -> [[Double]] {
        // Only apply if 3+ components
        guard components.count >= 3 else { return components }

        // Apply inverse RCT/ICT based on configuration
        // useReversibleTransform indicates MCT is enabled; waveletFilter determines RCT vs ICT
        if metadata.configuration.useReversibleTransform {
            if case .reversible53 = metadata.configuration.waveletFilter {
                // Inverse RCT (lossless) — operate directly on Doubles to avoid conversion overhead
                let transform = J2KColorTransform(configuration: J2KColorTransformConfiguration(mode: .reversible))
                let (r, g, b) = try transform.inverseRCTDouble(
                    y: components[0],
                    cb: components[1],
                    cr: components[2]
                )

                var result: [[Double]] = [r, g, b]
                if components.count > 3 {
                    result.append(contentsOf: components[3...])
                }
                return result
            } else {
                // Inverse ICT (lossy) — stays in Double precision throughout
                let transform = J2KColorTransform(configuration: J2KColorTransformConfiguration(mode: .irreversible))
                let (red, green, blue) = try transform.inverseICT(y: components[0], cb: components[1], cr: components[2])

                var result: [[Double]] = [red, green, blue]
                if components.count > 3 {
                    result.append(contentsOf: components[3...])
                }
                return result
            }
        } else {
            // No MCT
            return components
        }
    }

    /// In-place inverse colour transform: modifies `components` directly.
    /// Uses the steal pattern (drop outer reference before mutation) to guarantee
    /// refcount=1 on each inner buffer, preventing COW copies on in-place vDSP ops.
    /// ICT: allocates only 1 new [Double] (for G) — saves 2× large buffer allocations.
    /// RCT: allocates only 1 temp [Double] — saves 1× large buffer allocation.
    private func applyInverseColorTransformInPlace(
        _ components: inout [[Double]],
        metadata: CodestreamMetadata
    ) throws {
        guard components.count >= 3 else { return }
        guard metadata.configuration.useReversibleTransform else { return }

        // Steal inner arrays: zeroing components[i] drops the outer reference,
        // giving y/cb/cr exclusive ownership (refcount=1) so withUnsafeMutableBufferPointer
        // never copies the buffer.
        var y  = components[0]; components[0] = []
        var cb = components[1]; components[1] = []
        var cr = components[2]; components[2] = []

        let count = y.count
        guard count > 0, cb.count >= count, cr.count >= count else {
            components[0] = y; components[1] = cb; components[2] = cr
            return
        }
        let n = vDSP_Length(count)

        if case .reversible53 = metadata.configuration.waveletFilter {
            // Inverse RCT (ISO 15444-1 G.2):
            //   G = Y - floor((Cb + Cr) / 4)   in-place in y
            //   R = Cr + G                      in-place in cr
            //   B = Cb + G                      in-place in cb
            var temp = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            var quarter = 0.25
            cb.withUnsafeBufferPointer { cbBuf in
                cr.withUnsafeBufferPointer { crBuf in
                    temp.withUnsafeMutableBufferPointer { tBuf in
                        vDSP_vaddD(cbBuf.baseAddress!, 1, crBuf.baseAddress!, 1, tBuf.baseAddress!, 1, n)
                    }
                }
            }
            temp.withUnsafeMutableBufferPointer { tBuf in
                vDSP_vsmulD(tBuf.baseAddress!, 1, &quarter, tBuf.baseAddress!, 1, n)
                vvfloor(tBuf.baseAddress!, tBuf.baseAddress!, [Int32(count)])
            }
            y.withUnsafeMutableBufferPointer { yBuf in
                temp.withUnsafeBufferPointer { tBuf in
                    vDSP_vsubD(tBuf.baseAddress!, 1, yBuf.baseAddress!, 1, yBuf.baseAddress!, 1, n)
                }
            }
            y.withUnsafeBufferPointer { gBuf in
                cr.withUnsafeMutableBufferPointer { crBuf in
                    vDSP_vaddD(crBuf.baseAddress!, 1, gBuf.baseAddress!, 1, crBuf.baseAddress!, 1, n)
                }
                cb.withUnsafeMutableBufferPointer { cbBuf in
                    vDSP_vaddD(cbBuf.baseAddress!, 1, gBuf.baseAddress!, 1, cbBuf.baseAddress!, 1, n)
                }
            }
            // [R=cr, G=y, B=cb]
            components[0] = cr
            components[1] = y
            components[2] = cb
        } else {
            // Inverse ICT (ISO 15444-1 G.3):
            //   G = Y - 0.344136*Cb - 0.714136*Cr   1 new buffer
            //   R = Y + 1.402*Cr                     in-place in cr
            //   B = Y + 1.772*Cb                     in-place in cb
            var g = [Double](unsafeUninitializedCapacity: count) { _, s in s = count }
            var cGCb = -0.344136, cGCr = -0.714136, cRCr = 1.402, cBCb = 1.772
            y.withUnsafeBufferPointer { yBuf in
                cb.withUnsafeBufferPointer { cbBuf in
                    cr.withUnsafeBufferPointer { crBuf in
                        g.withUnsafeMutableBufferPointer { gBuf in
                            vDSP_vsmaD(cbBuf.baseAddress!, 1, &cGCb, yBuf.baseAddress!, 1, gBuf.baseAddress!, 1, n)
                            vDSP_vsmaD(crBuf.baseAddress!, 1, &cGCr, gBuf.baseAddress!, 1, gBuf.baseAddress!, 1, n)
                        }
                    }
                }
                cr.withUnsafeMutableBufferPointer { crBuf in
                    vDSP_vsmaD(crBuf.baseAddress!, 1, &cRCr, yBuf.baseAddress!, 1, crBuf.baseAddress!, 1, n)
                }
                cb.withUnsafeMutableBufferPointer { cbBuf in
                    vDSP_vsmaD(cbBuf.baseAddress!, 1, &cBCb, yBuf.baseAddress!, 1, cbBuf.baseAddress!, 1, n)
                }
            }
            // [R=cr, G=g, B=cb]
            components[0] = cr
            components[1] = g
            components[2] = cb
        }
    }

    // MARK: - Stage 7: Image Reconstruction

    /// Reconstructs the final J2KImage from component data.
    private func reconstructImage(
        _ components: [[Double]],
        metadata: CodestreamMetadata
    ) throws -> J2KImage {
        var imageComponents: [J2KComponent] = []

        // v10.5.0 Stage B.2 — substitute outputDimensions for
        // metadata.width × height when partial-resolution decode is
        // active. The truncated iDWT has already produced reduced-
        // dimension component data; the J2KImage and its components
        // must carry the reduced dimensions to stay consistent.
        let effectiveWidth = outputDimensions?.width ?? metadata.width
        let effectiveHeight = outputDimensions?.height ?? metadata.height

        func clampRoundedToInt32(_ value: Double) -> Int32 {
            let rounded = value.rounded()
            if rounded.isNaN { return 0 }
            if rounded >= Double(Int32.max) { return Int32.max }
            if rounded <= Double(Int32.min) { return Int32.min }
            return Int32(rounded)
        }

        // Shared chunk buffer — allocated once, reused across all components.
        // chunkSize keeps working set (Float chunks) in L2 cache.
        #if canImport(Accelerate)
        let chunkSize = 65536
        var floatChunk = [Float](repeating: 0, count: chunkSize)
        #endif

        for (idx, compData) in components.enumerated() {
            guard idx < metadata.components.count else { break }

            var compInfo = metadata.components[idx]
            // Annex J: the CBD depths describe the reconstructed components, the SIZ depths the coded ones.
            if let outputBitDepth = compInfo.outputBitDepth { compInfo.bitDepth = outputBitDepth }
            if let outputSigned = compInfo.outputSigned { compInfo.signed = outputSigned }
            let width = effectiveWidth / compInfo.subsamplingX
            let height = effectiveHeight / compInfo.subsamplingY
            let componentLowerBound: Int32
            let componentUpperBound: Int32
            if compInfo.signed {
                let halfRange = Int64(1) << Int64(max(compInfo.bitDepth - 1, 0))
                componentLowerBound = Int32(max(Int64(Int32.min), -halfRange))
                componentUpperBound = Int32(min(Int64(Int32.max), halfRange - 1))
            } else {
                componentLowerBound = 0
                let maxValue = (Int64(1) << Int64(max(compInfo.bitDepth, 1))) - 1
                componentUpperBound = Int32(min(Int64(Int32.max), maxValue))
            }

            // Convert Double array to Data with final rounding and clamping
            // Pre-allocate the exact size needed
            let bytesPerPixel = compInfo.bitDepth <= 8 ? 1 : 2
            let pixelCount = compData.count
            var data = Data(count: pixelCount * bytesPerPixel)

            data.withUnsafeMutableBytes { rawBuf in
                let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                // Swap only when the requested order differs from the host's.
                let swapsSamples = j2kHostIsLittleEndian() != (outputByteOrder == .littleEndian)
                let lo = Double(componentLowerBound)
                let hi = Double(componentUpperBound)

#if canImport(Accelerate)
                // Chunked vDSP pipeline: Double→Float → clip (Float, in-place) → integer bytes.
                // Clipping in Float (not Double) eliminates the 512 KB dblChunk intermediate,
                // halving the L2 working-set and reducing per-component allocation overhead.
                // Float has sufficient precision for all standard bit depths (≤24-bit).
                var floatLo = Float(lo), floatHi = Float(hi)

                compData.withUnsafeBufferPointer { src in
                    let srcBase = src.baseAddress!
                    if compInfo.bitDepth <= 8 && !compInfo.signed {
                        // 8-bit unsigned: vDSP_vdpsp → vDSP_vclip → vDSP_vfixru8
                        floatChunk.withUnsafeMutableBufferPointer { fBuf in
                            for start in stride(from: 0, to: pixelCount, by: chunkSize) {
                                let n = min(chunkSize, pixelCount - start)
                                let cnt = vDSP_Length(n)
                                vDSP_vdpsp(srcBase + start, 1, fBuf.baseAddress!, 1, cnt)
                                vDSP_vclip(fBuf.baseAddress!, 1, &floatLo, &floatHi, fBuf.baseAddress!, 1, cnt)
                                vDSP_vfixru8(fBuf.baseAddress!, 1, ptr + start, 1, cnt)
                            }
                        }
                    } else if compInfo.bitDepth > 8 && !compInfo.signed {
                        // 16-bit unsigned → big-endian bytes.
                        // Fast path: vDSP fixes to UInt16 in host byte order, then bulk byte-swap on LE hosts.
                        let u16Ptr = ptr.withMemoryRebound(to: UInt16.self, capacity: pixelCount) { $0 }
                        floatChunk.withUnsafeMutableBufferPointer { fBuf in
                            for start in stride(from: 0, to: pixelCount, by: chunkSize) {
                                let n = min(chunkSize, pixelCount - start)
                                let cnt = vDSP_Length(n)
                                vDSP_vdpsp(srcBase + start, 1, fBuf.baseAddress!, 1, cnt)
                                vDSP_vclip(fBuf.baseAddress!, 1, &floatLo, &floatHi, fBuf.baseAddress!, 1, cnt)
                                vDSP_vfixru16(fBuf.baseAddress!, 1, u16Ptr + start, 1, cnt)
                            }
                        }
                        if swapsSamples {
                            for i in 0..<pixelCount { u16Ptr[i] = u16Ptr[i].byteSwapped }
                        }
                    } else if compInfo.bitDepth > 8 && compInfo.signed {
                        // 16-bit signed (e.g. CT Hounsfield units) → big-endian bytes.
                        let i16Ptr = ptr.withMemoryRebound(to: Int16.self, capacity: pixelCount) { $0 }
                        floatChunk.withUnsafeMutableBufferPointer { fBuf in
                            for start in stride(from: 0, to: pixelCount, by: chunkSize) {
                                let n = min(chunkSize, pixelCount - start)
                                let cnt = vDSP_Length(n)
                                vDSP_vdpsp(srcBase + start, 1, fBuf.baseAddress!, 1, cnt)
                                vDSP_vclip(fBuf.baseAddress!, 1, &floatLo, &floatHi, fBuf.baseAddress!, 1, cnt)
                                vDSP_vfixr16(fBuf.baseAddress!, 1, i16Ptr + start, 1, cnt)
                            }
                        }
                        if swapsSamples {
                            for i in 0..<pixelCount { i16Ptr[i] = i16Ptr[i].byteSwapped }
                        }
                    } else {
                        // 8-bit signed: scalar fallback
                        for i in 0..<pixelCount {
                            let rounded = min(componentUpperBound, max(componentLowerBound, clampRoundedToInt32(compData[i])))
                            ptr[i] = UInt8(bitPattern: Int8(clamping: rounded))
                        }
                    }
                }
#else
                if compInfo.bitDepth <= 8 {
                    if compInfo.signed {
                        for i in 0..<pixelCount {
                            let rounded = min(componentUpperBound, max(componentLowerBound, clampRoundedToInt32(compData[i])))
                            ptr[i] = UInt8(bitPattern: Int8(clamping: rounded))
                        }
                    } else {
                        for i in 0..<pixelCount {
                            let rounded = min(componentUpperBound, max(componentLowerBound, clampRoundedToInt32(compData[i])))
                            ptr[i] = UInt8(clamping: max(0, rounded))
                        }
                    }
                } else {
                    // 16-bit output: big-endian byte order (PGM / DICOM Explicit VR BE
                    // convention). Callers expecting little-endian output (e.g. DICOM
                    // Explicit VR LE transfer syntax) must byte-swap at integration.
                    if compInfo.signed {
                        for i in 0..<pixelCount {
                            let rounded = min(componentUpperBound, max(componentLowerBound, clampRoundedToInt32(compData[i])))
                            let v = UInt16(bitPattern: Int16(clamping: rounded))
                            let bytes = outputByteOrder == .littleEndian ? v : v.byteSwapped
                            ptr[i * 2]     = UInt8(bytes & 0xFF)
                            ptr[i * 2 + 1] = UInt8(bytes >> 8)
                        }
                    } else {
                        for i in 0..<pixelCount {
                            let rounded = min(componentUpperBound, max(componentLowerBound, clampRoundedToInt32(compData[i])))
                            let v = UInt16(clamping: max(0, rounded))
                            let bytes = outputByteOrder == .littleEndian ? v : v.byteSwapped
                            ptr[i * 2]     = UInt8(bytes & 0xFF)
                            ptr[i * 2 + 1] = UInt8(bytes >> 8)
                        }
                    }
                }
#endif
            }

            // v5.14.1: tag the component byte order explicitly so
            // downstream consumers (CLI PGM/PPM writers, file-format
            // serialisers) can write spec-compliant bytes without
            // re-swapping. The decoder's `reconstructImage` step
            // produces 16-bit samples in `outputByteOrder` (the
            // `swapsSamples` branch a few lines up); 8-bit samples
            // are byte-order-agnostic.
            // Without this tag, callers that don't know the
            // convention silently corrupt 16-bit output.
            let component = J2KComponent(
                index: idx,
                bitDepth: compInfo.bitDepth,
                signed: compInfo.signed,
                width: width,
                height: height,
                subsamplingX: compInfo.subsamplingX,
                subsamplingY: compInfo.subsamplingY,
                data: data,
                sampleByteOrder: compInfo.bitDepth > 8 ? outputByteOrder : nil
            )

            imageComponents.append(component)
        }

        return J2KImage(
            width: effectiveWidth,
            height: effectiveHeight,
            components: imageComponents
        )
    }

    // MARK: - Progress Reporting

    private func reportProgress(
        _ callback: ((DecoderProgressUpdate) -> Void)?,
        stage: DecodingStage,
        stageProgress: Double
    ) {
        guard let callback = callback else { return }
        let stages = DecodingStage.allCases
        guard let stageIndex = stages.firstIndex(of: stage) else { return }
        let stageWeight = 1.0 / Double(stages.count)
        let overall = Double(stageIndex) * stageWeight + stageProgress * stageWeight
        callback(DecoderProgressUpdate(
            stage: stage,
            progress: stageProgress,
            overallProgress: min(overall, 1.0)
        ))
    }
}

// MARK: - Quality-layer accounting and tier-2 reuse (issue #2382)

/// Packet-byte accounting of one decode: bytes of packets in layers beyond the requested one are parsed but
/// never entropy-decoded, which is the measurable work a quality-limited decode avoids.
public final class J2KPartialDecodeAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var _consumedPacketBytes = 0
    private var _skippedPacketBytes = 0
    private var _decodedLayers = 0
    private var _totalLayers = 0
    private var _parsedTiles = 0
    private var _reusedTiles = 0

    public init() {}

    func recordParsedTile(consumedPacketBytes: Int, skippedPacketBytes: Int, decodedLayers: Int, totalLayers: Int) {
        lock.lock(); defer { lock.unlock() }
        _consumedPacketBytes += consumedPacketBytes
        _skippedPacketBytes += skippedPacketBytes
        _decodedLayers = max(_decodedLayers, decodedLayers)
        _totalLayers = max(_totalLayers, totalLayers)
        _parsedTiles += 1
    }

    func recordCachedTile(packetBytesPerLayer: [Int], lastLayer: Int) {
        var consumed = 0, skipped = 0
        for (layer, bytes) in packetBytesPerLayer.enumerated() {
            if layer <= lastLayer { consumed += bytes } else { skipped += bytes }
        }
        lock.lock(); defer { lock.unlock() }
        _consumedPacketBytes += consumed
        _skippedPacketBytes += skipped
        _decodedLayers = max(_decodedLayers, lastLayer + 1)
        _totalLayers = max(_totalLayers, packetBytesPerLayer.count)
        _reusedTiles += 1
    }

    public var report: J2KPartialDecodeReport {
        lock.lock(); defer { lock.unlock() }
        return J2KPartialDecodeReport(decodedLayers: _decodedLayers, totalLayers: _totalLayers, consumedPacketBytes: _consumedPacketBytes,
                                      skippedPacketBytes: _skippedPacketBytes, parsedTiles: _parsedTiles, reusedTiles: _reusedTiles)
    }
}

/// What a quality-limited decode did and avoided (issue #2382).
public struct J2KPartialDecodeReport: Sendable, Equatable {
    /// Layers whose passes were entropy-decoded (cumulative count, 1-based).
    public let decodedLayers: Int
    public let totalLayers: Int
    /// Packet bytes (headers and bodies, cached-tile bodies only) that fed the entropy decoder.
    public let consumedPacketBytes: Int
    /// Packet bytes parsed past but never entropy-decoded because they belong to higher layers.
    public let skippedPacketBytes: Int
    public let parsedTiles: Int
    /// Tiles served from the tier-2 cache of a refinement session instead of a packet parse.
    public let reusedTiles: Int

    public init(decodedLayers: Int, totalLayers: Int, consumedPacketBytes: Int, skippedPacketBytes: Int, parsedTiles: Int, reusedTiles: Int) {
        self.decodedLayers = decodedLayers; self.totalLayers = totalLayers; self.consumedPacketBytes = consumedPacketBytes
        self.skippedPacketBytes = skippedPacketBytes; self.parsedTiles = parsedTiles; self.reusedTiles = reusedTiles
    }

    public var isFinalLayer: Bool { totalLayers > 0 && decodedLayers >= totalLayers }
}

/// Per-tile multi-layer packet parse retained across refinements of one codestream (issue #2382).
public final class J2KLayeredBlockCache: @unchecked Sendable {
    struct Key: Hashable {
        let tileOriginX: Int
        let tileOriginY: Int
        let byteCount: Int
    }
    struct Entry {
        let blocks: [DecoderPipeline.CodeBlockInfo]
        /// Packet bytes (headers and bodies) of every layer of the tile.
        let packetBytesPerLayer: [Int]
    }
    private let lock = NSLock()
    private var storage: [Key: Entry] = [:]

    public init() {}

    func entry(for key: Key) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func store(_ entry: Entry, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = entry
    }

    /// Packet bytes (headers and bodies) per quality layer over every cached tile; empty until a tile was parsed.
    public var bytesPerLayer: [Int] {
        lock.lock(); defer { lock.unlock() }
        var totals: [Int] = []
        for entry in storage.values {
            for (layer, bytes) in entry.packetBytesPerLayer.enumerated() {
                while totals.count <= layer { totals.append(0) }
                totals[layer] += bytes
            }
        }
        return totals
    }

    public var cachedTileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}
