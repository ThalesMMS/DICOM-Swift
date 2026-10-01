//
// J2KEncodingPresets.swift
// J2KSwift
//
// J2KEncodingPresets.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-07.
//

import Foundation

// # JPEG 2000 Encoding Presets
//
// Predefined encoding configurations optimised for different use cases.
//
// Encoding presets provide a simple way to choose between encoding speed,
// file size, and quality without manually configuring all parameters.
//
// ## Preset Types
//
// - **Fast**: Optimised for encoding speed with acceptable quality
// - **Balanced**: Default balanced settings for general use
// - **Quality**: Optimised for maximum quality with slower encoding
//
// ## Usage
//
// ```swift
// // Use a preset directly
// let config = J2KEncodingPreset.fast.configuration(quality: 0.8)
// let encoder = J2KEncoder(configuration: config)
//
// // Or customize a preset
// var customConfig = J2KEncodingPreset.balanced.configuration()
// customConfig.decompositionLevels = 3
// ```

// MARK: - Encoding Preset

/// Predefined encoding preset types.
public enum J2KEncodingPreset: String, Sendable, CaseIterable {
    /// Fast encoding with acceptable quality.
    ///
    /// - Fewer decomposition levels (3 levels)
    /// - Larger code blocks (64×64)
    /// - Fewer quality layers (3 layers)
    /// - No visual weighting
    /// - Single-threaded encoding
    ///
    /// **Performance:** 2-3× faster than balanced
    /// **Quality:** Good for preview/draft quality
    /// **Use cases:** Real-time encoding, thumbnails, previews
    case fast

    /// Balanced encoding for general use.
    ///
    /// - Standard decomposition levels (5 levels)
    /// - Medium code blocks (32×32)
    /// - Multiple quality layers (5 layers)
    /// - Optional visual weighting
    /// - Multi-threaded encoding
    ///
    /// **Performance:** Reference baseline
    /// **Quality:** Excellent for most use cases
    /// **Use cases:** General purpose, web delivery, storage
    case balanced

    /// Maximum quality encoding.
    ///
    /// - Maximum decomposition levels (6 levels)
    /// - Small code blocks (32×32)
    /// - Many quality layers (10 layers)
    /// - Visual weighting enabled
    /// - Multi-threaded with aggressive optimisation
    ///
    /// **Performance:** 1.5-2× slower than balanced
    /// **Quality:** Best possible quality
    /// **Use cases:** Archival, medical imaging, professional photography
    case quality

    /// Creates an encoding configuration from this preset.
    ///
    /// - Parameters:
    ///   - quality: Overall quality factor (0.0 to 1.0). Default is 0.9.
    ///   - lossless: Whether to use lossless compression. Default is false.
    /// - Returns: A fully configured ``J2KEncodingConfiguration``.
    public func configuration(
        quality: Double = 0.9,
        lossless: Bool = false
    ) -> J2KEncodingConfiguration {
        switch self {
        case .fast:
            return J2KEncodingConfiguration(
                quality: quality,
                lossless: lossless,
                decompositionLevels: 3,
                codeBlockSize: (width: 64, height: 64),
                qualityLayers: 3,
                progressionOrder: .lrcp,  // Layer-resolution-component-position (simple)
                enableVisualWeighting: false,
                tileSize: (width: 512, height: 512),
                bitrateMode: .constantQuality,
                maxThreads: 1
            )

        case .balanced:
            return J2KEncodingConfiguration(
                quality: quality,
                lossless: lossless,
                decompositionLevels: 5,
                codeBlockSize: (width: 32, height: 32),
                qualityLayers: 5,
                progressionOrder: .rpcl,  // Resolution-position-component-layer (good for streaming)
                enableVisualWeighting: quality < 1.0,  // Enable for lossy
                tileSize: (width: 1024, height: 1024),
                bitrateMode: .constantQuality,
                maxThreads: 0  // Auto-detect
            )

        case .quality:
            return J2KEncodingConfiguration(
                quality: quality,
                lossless: lossless,
                decompositionLevels: 6,
                codeBlockSize: (width: 32, height: 32),
                qualityLayers: 10,
                progressionOrder: .rpcl,
                enableVisualWeighting: quality < 1.0,
                tileSize: (width: 2048, height: 2048),
                bitrateMode: .constantQuality,
                maxThreads: 0
            )
        }
    }
}

// MARK: - Encoding Configuration

/// Comprehensive configuration for JPEG 2000 encoding.
public struct J2KEncodingConfiguration: Sendable {
    /// Overall quality factor (0.0 to 1.0).
    ///
    /// - 0.0: Maximum compression (lowest quality)
    /// - 1.0: Lossless or minimal compression (highest quality)
    public var quality: Double

    /// Whether to use lossless compression.
    ///
    /// When true, the encoder uses the reversible colour transform (RCT)
    /// and reversible wavelet filter (5/3), ensuring perfect reconstruction.
    public var lossless: Bool {
        didSet {
            if lossless {
                useReversibleFilter = true
            }
        }
    }

    /// Number of wavelet decomposition levels.
    ///
    /// - Valid range: 0-10
    /// - Default: 5 for balanced, 3 for fast, 6 for quality
    /// - More levels = better compression but slower encoding
    public var decompositionLevels: Int

    /// Size of code blocks for entropy coding.
    ///
    /// - Valid range: 4-1024 for each dimension
    /// - Default: 32×32 (balanced), 64×64 (fast)
    /// - Larger blocks = faster encoding, smaller blocks = better quality
    public var codeBlockSize: (width: Int, height: Int)

    /// Number of quality layers.
    ///
    /// - Valid range: 1-20
    /// - Default: 5 (balanced), 3 (fast), 10 (quality)
    /// - More layers = finer quality progression, slower encoding
    public var qualityLayers: Int

    /// Progression order for packet organization.
    ///
    /// Determines the order in which image data is encoded and streamed:
    /// - LRCP: Layer-Resolution-Component-Position (simple, good for quality)
    /// - RLCP: Resolution-Layer-Component-Position (progressive resolution)
    /// - RPCL: Resolution-Position-Component-Layer (best for streaming)
    /// - PCRL: Position-Component-Resolution-Layer (spatial locality)
    /// - CPRL: Component-Position-Resolution-Layer (component-by-component)
    public var progressionOrder: J2KProgressionOrder

    /// Whether to enable visual frequency weighting.
    ///
    /// When enabled, applies perceptual weighting to quantization based on
    /// the human visual system's contrast sensitivity function (CSF).
    public var enableVisualWeighting: Bool

    /// Tile size for tiled encoding.
    ///
    /// - (0, 0): No tiling (single tile)
    /// - Otherwise: Width and height of each tile in pixels
    /// - Tiling enables memory-efficient processing of large images
    public var tileSize: (width: Int, height: Int)

    /// Bitrate control mode.
    ///
    /// Determines how the encoder controls the output file size:
    /// - Constant quality: Target quality level
    /// - Constant bitrate: Target file size
    /// - Variable bitrate: Quality-constrained with size limit
    public var bitrateMode: J2KBitrateMode

    /// Maximum number of threads for parallel encoding.
    ///
    /// - 0: Auto-detect optimal thread count
    /// - 1: Single-threaded encoding
    /// - &gt;1: Use specified number of threads
    public var maxThreads: Int

    /// Whether to use HTJ2K (High-Throughput JPEG 2000) block coding.
    ///
    /// When enabled, uses the FBCOT (Fast Block Coder with Optimised Truncation)
    /// algorithm instead of traditional EBCOT, providing significantly faster
    /// encoding and decoding throughput as specified in ISO/IEC 15444-15.
    ///
    /// - Note: HTJ2K mode requires CAP and CPF markers to be written in the codestream.
    /// - Default: false (use legacy EBCOT block coding)
    public var useHTJ2K: Bool

    /// Whether to use the reversible (5/3) wavelet filter and RCT colour transform
    /// even in lossy mode.
    ///
    /// When `true`, the encoder uses the reversible 5/3 DWT and integer RCT, with
    /// no quantization (step size = 1.0). Quality is controlled solely through
    /// PCRD rate truncation of coding passes. This produces better quality at the
    /// same bitrate for medical/diagnostic imaging because there is no DWT or
    /// quantization noise — only truncation of least-significant bit planes.
    ///
    /// When `false`, uses the irreversible 9/7 DWT, floating-point ICT, and
    /// deadzone quantization (traditional lossy JPEG 2000).
    ///
    /// This property is forced to `true` when `lossless` is `true`.
    /// For lossy encoding, set this to `true` to match OpenJPEG's default
    /// behaviour (5/3 reversible DWT + rate truncation).
    ///
    /// - Default: `true`
    public var useReversibleFilter: Bool

    /// Whether to enable parallel code-block encoding.
    ///
    /// When enabled, independent code-blocks within a tile are encoded in parallel
    /// using Swift structured concurrency. This provides significant speedups for
    /// images with many code-blocks on multi-core systems.
    ///
    /// Each code-block in JPEG 2000 is an independent unit of entropy coding with
    /// its own MQ encoder state and context models, making them ideal for parallel
    /// processing without any synchronisation overhead.
    ///
    /// - Default: true
    public var enableParallelCodeBlocks: Bool

    /// Whether to enable fast MEL encoding optimisation for HTJ2K.
    ///
    /// When enabled, uses optimised run-length encoding in the MEL (Magnitude Exchange
    /// Length) coder with adaptive thresholding and efficient buffering strategies.
    /// This optimisation provides faster MEL encoding at the cost of slightly larger
    /// MEL segments in some cases.
    ///
    /// Only applies when `useHTJ2K` is true.
    ///
    /// - Note: This is an HTJ2K-specific optimisation.
    /// - Default: true
    public var enableFastMEL: Bool

    /// Whether to enable VLC table optimisation for HTJ2K.
    ///
    /// When enabled, uses optimised lookup tables for VLC (Variable Length Coding)
    /// encoding and decoding, providing faster throughput at the cost of increased
    /// memory usage (approximately 4-8 KB per encoder instance).
    ///
    /// Only applies when `useHTJ2K` is true.
    ///
    /// - Note: This is an HTJ2K-specific optimisation.
    /// - Default: true
    public var enableVLCOptimization: Bool

    /// Whether to enable efficient magnitude/sign bit packing for HTJ2K.
    ///
    /// When enabled, uses optimised bit packing strategies for the MagSgn (Magnitude
    /// and Sign) coder, reducing the number of bit-level operations and improving
    /// cache efficiency during encoding and decoding.
    ///
    /// Only applies when `useHTJ2K` is true.
    ///
    /// - Note: This is an HTJ2K-specific optimisation.
    /// - Default: true
    public var enableMagSgnPacking: Bool

    /// Block size selection mode.
    ///
    /// Controls whether code block sizes are fixed (manual) or adaptively
    /// selected based on per-tile content analysis.
    ///
    /// - `.fixed`: Uses the `codeBlockSize` property for all tiles (default).
    /// - `.adaptive(aggressiveness:)`: Automatically selects 16×16, 32×32, or 64×64
    ///   block sizes per tile based on content complexity.
    ///
    /// - Default: `.fixed`
    public var blockSizeMode: J2KBlockSizeMode

    /// Per-tile block size overrides for adaptive mode.
    ///
    /// When `blockSizeMode` is `.adaptive`, these overrides bypass content
    /// analysis for specific tiles. Tile indices map to explicit block sizes.
    /// Ignored when `blockSizeMode` is `.fixed`.
    ///
    /// - Default: empty (no overrides)
    public var tileBlockSizeOverrides: [Int: (width: Int, height: Int)]

    /// Configuration for Part 2 variable DC offset.
    ///
    /// When enabled, the encoder computes and removes per-component DC offset
    /// before wavelet transform and quantization, improving compression
    /// efficiency for images with non-zero mean values.
    ///
    /// The offset values are signaled in DCO marker segments (0xFF5C) in the
    /// codestream, and restored during decoding.
    ///
    /// - Default: `.disabled` (Part 1 compatible behavior)
    public var dcOffsetConfiguration: J2KDCOffsetConfiguration

    /// Writes a TLM marker segment (ISO/IEC 15444-1 A.7.1) in the main header
    /// with one entry per tile-part. DICOM PS3.5 10.18.1 requires it for the
    /// HTJ2K Lossless RPCL transfer syntax; off by default.
    public var writeTLMMarker: Bool

    /// Configuration for Part 2 extended precision arithmetic.
    ///
    /// Controls the precision, rounding behavior, and guard bit usage
    /// for Part 2 extended precision operations. Extended precision
    /// allows higher accuracy for high bit depth and HDR images.
    ///
    /// - Default: `.default` (Part 1 compatible: 32-bit, 2 guard bits)
    public var extendedPrecisionConfiguration: J2KExtendedPrecisionConfiguration

    /// Configuration for Part 2 arbitrary wavelet kernels.
    ///
    /// Specifies the wavelet kernel to use for the transform. When set to
    /// `.standard`, uses the standard Part 1 wavelets (5/3 or 9/7 based on
    /// the `lossless` setting). When set to `.arbitrary`, allows selection
    /// of custom wavelet kernels from the kernel library or user-defined
    /// kernels.
    ///
    /// - Default: `.standard` (Part 1 compatible wavelets)
    public var waveletKernelConfiguration: J2KWaveletKernelConfiguration

    /// Configuration for Part 2 multi-component transform (MCT).
    ///
    /// Specifies the multi-component transform to use for decorrelating
    /// image components. When set to `.disabled`, uses standard Part 1
    /// RCT/ICT transforms. When enabled, allows array-based or dependency-based
    /// transforms for improved compression of multi-spectral imagery.
    ///
    /// MCT is particularly effective for:
    /// - Multi-spectral and hyperspectral imagery (>3 components)
    /// - Medical imaging with multiple modalities
    /// - Scientific data with correlated channels
    ///
    /// - Default: `.disabled` (Part 1 compatible RCT/ICT transforms)
    public var mctConfiguration: J2KMCTEncodingConfiguration

    /// Optional qstep cache for batch workflows using
    /// `.constantBitrateViaQstep` (v5.19.0+). When non-nil, the
    /// encoder consults the cache for an initial qstep guess based on
    /// (bitDepth, componentCount, targetBpp), and stores the converged
    /// qstep back after each successful search. Subsequent encodes of
    /// similar images converge in 1–2 iterations instead of 4–6.
    ///
    /// Useful for DICOMKit-style workflows that encode many similar
    /// medical images (same modality + bit-depth + target rate). Has
    /// no effect on `.constantBitrate` / `.fixedQstep` / lossless modes.
    ///
    /// - Default: `nil` (cache disabled).
    public var qstepCache: J2KQstepCache?

    /// Creates a new encoding configuration.
    ///
    /// - Parameters:
    ///   - quality: Overall quality factor (default: 0.9).
    ///   - lossless: Whether to use lossless compression (default: false).
    ///   - decompositionLevels: Number of wavelet decomposition levels (default: 5).
    ///   - codeBlockSize: Code block dimensions (default: 64×64).
    ///   - qualityLayers: Number of quality layers (default: 5).
    ///   - progressionOrder: Packet progression order (default: .rpcl).
    ///   - enableVisualWeighting: Enable perceptual weighting (default: false).
    ///   - tileSize: Tile dimensions, (0,0) for no tiling (default: no tiling).
    ///   - bitrateMode: Bitrate control mode (default: .constantQuality).
    ///   - maxThreads: Maximum encoding threads, 0 for auto (default: 0).
    ///   - useHTJ2K: Use HTJ2K block coding (default: false).
    ///   - useReversibleFilter: Use 5/3 reversible filter (default: true for lossless, false for lossy).
    ///   - enableParallelCodeBlocks: Enable parallel code-block encoding (default: true).
    ///   - enableFastMEL: Enable fast MEL encoding for HTJ2K (default: true).
    ///   - enableVLCOptimization: Enable VLC table optimisation for HTJ2K (default: true).
    ///   - enableMagSgnPacking: Enable efficient magnitude/sign packing for HTJ2K (default: true).
    ///   - blockSizeMode: Block size selection mode (default: .fixed).
    ///   - tileBlockSizeOverrides: Per-tile block size overrides for adaptive mode (default: empty).
    ///   - dcOffsetConfiguration: Part 2 DC offset configuration (default: .disabled).
    ///   - extendedPrecisionConfiguration: Part 2 extended precision configuration (default: .default).
    ///   - waveletKernelConfiguration: Part 2 wavelet kernel configuration (default: .standard).
    ///   - mctConfiguration: Part 2 multi-component transform configuration (default: .disabled).
    public init(
        quality: Double = 0.9,
        lossless: Bool = false,
        decompositionLevels: Int = 5,
        codeBlockSize: (width: Int, height: Int) = (64, 64),
        qualityLayers: Int = 5,
        progressionOrder: J2KProgressionOrder = .rpcl,
        enableVisualWeighting: Bool = false,
        tileSize: (width: Int, height: Int) = (0, 0),
        bitrateMode: J2KBitrateMode = .constantQuality,
        maxThreads: Int = 0,
        useHTJ2K: Bool = false,
        useReversibleFilter: Bool = false,
        enableParallelCodeBlocks: Bool = true,
        enableFastMEL: Bool = true,
        enableVLCOptimization: Bool = true,
        enableMagSgnPacking: Bool = true,
        blockSizeMode: J2KBlockSizeMode = .fixed,
        tileBlockSizeOverrides: [Int: (width: Int, height: Int)] = [:],
        dcOffsetConfiguration: J2KDCOffsetConfiguration = .disabled,
        extendedPrecisionConfiguration: J2KExtendedPrecisionConfiguration = .default,
        waveletKernelConfiguration: J2KWaveletKernelConfiguration = .standard,
        mctConfiguration: J2KMCTEncodingConfiguration = .disabled,
        writeTLMMarker: Bool = false,
        qstepCache: J2KQstepCache? = nil
    ) {
        self.quality = max(0.0, min(1.0, quality))
        self.lossless = lossless
        self.decompositionLevels = max(0, min(10, decompositionLevels))
        self.codeBlockSize = (
            width: max(4, min(1024, codeBlockSize.width)),
            height: max(4, min(1024, codeBlockSize.height))
        )
        self.qualityLayers = max(1, min(20, qualityLayers))
        self.progressionOrder = progressionOrder
        self.enableVisualWeighting = enableVisualWeighting
        self.tileSize = (
            width: max(0, tileSize.width),
            height: max(0, tileSize.height)
        )
        self.bitrateMode = bitrateMode
        self.maxThreads = max(0, maxThreads)
        self.useHTJ2K = useHTJ2K
        self.useReversibleFilter = lossless ? true : useReversibleFilter
        self.enableParallelCodeBlocks = enableParallelCodeBlocks
        self.enableFastMEL = enableFastMEL
        self.enableVLCOptimization = enableVLCOptimization
        self.enableMagSgnPacking = enableMagSgnPacking
        self.blockSizeMode = blockSizeMode
        self.tileBlockSizeOverrides = tileBlockSizeOverrides
        self.dcOffsetConfiguration = dcOffsetConfiguration
        self.extendedPrecisionConfiguration = extendedPrecisionConfiguration
        self.waveletKernelConfiguration = waveletKernelConfiguration
        self.mctConfiguration = mctConfiguration
        self.writeTLMMarker = writeTLMMarker
        self.qstepCache = qstepCache
    }

    /// Validates the configuration parameters.
    ///
    /// - Throws: ``J2KError/invalidParameter(_:)`` if any parameters are invalid.
    public func validate() throws {
        if quality < 0.0 || quality > 1.0 {
            throw J2KError.invalidParameter("Quality must be between 0.0 and 1.0, got \(quality)")
        }

        if decompositionLevels < 0 || decompositionLevels > 10 {
            throw J2KError.invalidParameter("Decomposition levels must be between 0 and 10, got \(decompositionLevels)")
        }

        if codeBlockSize.width < 4 || codeBlockSize.width > 1024 {
            throw J2KError.invalidParameter("Code block width must be between 4 and 1024, got \(codeBlockSize.width)")
        }

        if codeBlockSize.height < 4 || codeBlockSize.height > 1024 {
            throw J2KError.invalidParameter("Code block height must be between 4 and 1024, got \(codeBlockSize.height)")
        }

        if qualityLayers < 1 || qualityLayers > 20 {
            throw J2KError.invalidParameter("Quality layers must be between 1 and 20, got \(qualityLayers)")
        }

        if tileSize.width < 0 || tileSize.height < 0 {
            throw J2KError.invalidParameter("Tile size must be non-negative")
        }

        if maxThreads < 0 {
            throw J2KError.invalidParameter("Max threads must be non-negative, got \(maxThreads)")
        }
    }
}

// MARK: - Progression Order

/// Progression order for JPEG 2000 packet organization.
public enum J2KProgressionOrder: String, Sendable, CaseIterable {
    /// Layer-Resolution-Component-Position progression.
    ///
    /// Encodes by quality layer first, then resolution, then component, then spatial position.
    /// Good for quality-progressive applications.
    case lrcp = "LRCP"

    /// Resolution-Layer-Component-Position progression.
    ///
    /// Encodes by resolution first, then quality layer, then component, then spatial position.
    /// Good for resolution-progressive applications.
    case rlcp = "RLCP"

    /// Resolution-Position-Component-Layer progression.
    ///
    /// Encodes by resolution first, then spatial position, then component, then quality layer.
    /// Best for streaming and progressive download.
    case rpcl = "RPCL"

    /// Position-Component-Resolution-Layer progression.
    ///
    /// Encodes by spatial position first, then component, then resolution, then quality layer.
    /// Good for spatial locality and region-of-interest applications.
    case pcrl = "PCRL"

    /// Component-Position-Resolution-Layer progression.
    ///
    /// Encodes by component first, then spatial position, then resolution, then quality layer.
    /// Good for applications that process components separately.
    case cprl = "CPRL"
}

// MARK: - Bitrate Mode

/// Bitrate control modes for encoding.
public enum J2KBitrateMode: Sendable, Equatable {
    /// Constant quality mode.
    ///
    /// Maintains consistent quality across the image.
    /// File size varies based on image complexity.
    case constantQuality

    /// Constant bitrate mode.
    ///
    /// Targets a specific file size or bitrate.
    /// Quality varies to achieve the target size.
    ///
    /// - Parameter bitsPerPixel: Target bits per pixel (e.g., 0.5 for 2:1 compression).
    case constantBitrate(bitsPerPixel: Double)

    /// Variable bitrate mode.
    ///
    /// Maintains quality above a threshold while respecting a maximum file size.
    ///
    /// - Parameters:
    ///   - minQuality: Minimum quality to maintain (0.0-1.0).
    ///   - maxBitsPerPixel: Maximum bits per pixel allowed.
    case variableBitrate(minQuality: Double, maxBitsPerPixel: Double)

    /// Lossless mode.
    ///
    /// Perfect reconstruction, no quality loss.
    /// File size varies significantly based on image content.
    case lossless

    /// Fixed quantization-step mode (OpenJPH-style).
    ///
    /// Bypasses PCRD-opt rate control entirely. Coefficients are
    /// quantized using the user-supplied step size, and every
    /// codeblock is included in the output unchanged. Achieved bpp
    /// varies per image — there is no target bitrate.
    ///
    /// Useful for HT conformant lossy workflows where PCRD-opt's
    /// all-or-nothing block selection (HT cleanup pass has only one
    /// truncation point per block) produces ~7 dB worse R-D than
    /// either J2KSwift's legacy EBCOT path or OpenJPH's encoder.
    /// Picking a calibrated qstep directly matches OpenJPH's R-D
    /// operating point without the intra-block truncation work
    /// captured in V5_18_0_DESIGN.md.
    ///
    /// - Parameter qstep: Quantization step size (e.g., 0.024 for
    ///   ~2 bpp on 8-bit natural images). For irreversible 9/7 only.
    ///   Reversible 5/3 always uses step = 1; this mode is rejected
    ///   when `useReversibleFilter` is true.
    case fixedQstep(qstep: Double)

    /// Target-bitrate mode that hits the budget via a qstep search
    /// (v5.19.0). Combines `.constantBitrate`'s convenience (user
    /// specifies bpp, encoder hits the target) with `.fixedQstep`'s
    /// R-D quality (no PCRD-opt all-or-nothing block selection).
    ///
    /// Encoder behavior: outer loop binary-searches `qstep` over
    /// log space until the encoded size lands within `tolerance` of
    /// the target. Each iteration is a full encode at a candidate
    /// qstep — typically converges in 4–7 iterations.
    ///
    /// Use this when:
    /// - You need a target bpp (compliance / archival).
    /// - You're doing HT conformant lossy where the v5.16.0 R-D gap
    ///   in `.constantBitrate` matters.
    /// - You can spend ~5× the single-encode time on each input.
    ///
    /// - Parameters:
    ///   - bitsPerPixel: Target bpp (encoded bytes × 8 / pixel count).
    ///   - tolerance: Acceptable relative error vs target (default
    ///     0.05 = within 5%). Tighter values may need more iterations.
    ///   - maxIterations: Hard cap on encode iterations. Default 8;
    ///     real-world content typically converges in 4–6.
    case constantBitrateViaQstep(
        bitsPerPixel: Double,
        tolerance: Double = 0.05,
        maxIterations: Int = 8)

    /// **Quality-first** bounded-rate mode (v5.33.0). Best-effort
    /// byte cap, predictable latency, prioritises quality.
    ///
    /// Pick this mode for **diagnostic-grade lossy archive workflows**
    /// (DICOM PACS, clinical reads on full-bit-depth medical) where:
    ///   - quality must be clinical-grade (60+ dB on real medical
    ///     fixtures at typical bpp targets);
    ///   - the byte target is a budgeting hint, not a hard contract
    ///     (the achieved size may exceed `bitsPerPixel × pixels / 8`
    ///     by up to `maxOvershootRatio` on flat-curve high-bit-depth
    ///     content, and may exceed even `maxOvershootRatio` on
    ///     extreme cases);
    ///   - encode latency must be predictable (3-pass hard cap by
    ///     default — no flat-curve worst case).
    ///
    /// Pick `.constantBitrateStrict(bpp)` instead when the byte cap
    /// must be a hard guarantee, even if quality drops to
    /// preview/thumbnail tier on flat-curve content. Pick `.fixedQstep`
    /// when latency is the dominant constraint (1 pass, no rate
    /// guarantees). Pick `.constantBitrateViaQstep` for v5.31's
    /// 8-pass unbounded-rate behaviour.
    ///
    /// **Algorithm**: log-binary-search over qstep with adaptive
    /// bracket extension, capped at `maxPasses` total encodes. Pass 1
    /// uses a calibration prior (or cached qstep). Pass 2 scales by
    /// observed ratio. Pass 3+ does log-binary-search; if achievement
    /// is still over cap and the upper bound is hit, the bracket
    /// extends ×4. The closest-to-target result wins, with overshoot
    /// preferred over undershoot when both are valid.
    ///
    /// **Cap is best-effort** — `maxOvershootRatio` is the search's
    /// stopping criterion, not a hard ceiling. On flat-curve content
    /// (large fixtures at very low bpp), the search budget may run
    /// out before the cap is reached; the closest-achieved encoding
    /// is returned. The `J2KEncodeQstepStats.convergedWithinTolerance`
    /// flag reports whether the cap was met. For HARD byte cap, use
    /// `.constantBitrateStrict(bpp)` instead.
    ///
    /// **Latency**: at most `maxPasses × single-encode-time`. For
    /// batch workflows pass a `J2KQstepCache` via
    /// `encodingConfiguration.qstepCache` so subsequent encodes hit
    /// cache and converge in 1 pass.
    ///
    /// - Parameters:
    ///   - bitsPerPixel: target bitrate in bits per pixel.
    ///   - maxOvershootRatio: best-effort upper bound on achieved /
    ///     target byte ratio (default 2.0×). Smaller = stricter rate
    ///     target (but may still be exceeded on flat-curve content).
    ///     Larger = looser rate target (more headroom, higher quality
    ///     when the bound matters).
    ///   - maxPasses: maximum encode iterations (default 3). 1 =
    ///     fastest, takes whatever the calibration prior produces.
    ///     3+ = approaches the accuracy of `.constantBitrateViaQstep`
    ///     at the cost of latency predictability.
    case constantBitrateBounded(
        bitsPerPixel: Double,
        maxOvershootRatio: Double = 2.0,
        maxPasses: Int = 3)

    /// v5.34.0 — strict bounded-rate mode with a **hard byte cap**.
    ///
    /// Combines the v5.33.0 quality-first 3-pass Qstep search with
    /// post-encode codestream truncation at packet boundaries. The
    /// JPEG 2000 codestream is structurally truncatable — packets are
    /// independently decodable in LRCP order, so dropping tail packets
    /// produces a smaller-but-valid codestream that decodes to a
    /// progressively-degraded image.
    ///
    /// Algorithm:
    ///   1. Run the bounded Qstep search (≤3 passes, quality-first).
    ///   2. If the result is ≤ `maxOvershootRatio × target`, return it
    ///      unmodified.
    ///   3. Otherwise, truncate the codestream at the largest packet
    ///      boundary that still fits the cap. Update the SOT marker's
    ///      `Psot` field, append the EOC marker.
    ///
    /// **Quality** within the retained packets matches the bounded
    /// mode (same quantisation step). The truncation point determines
    /// where the LL approximation runs out of detail — typically this
    /// drops the highest-frequency sub-bands first (since LRCP visits
    /// LL → HL/LH/HH per resolution and high-frequency packets are
    /// last). Diagnostic-grade quality on the retained image area
    /// degrades gracefully rather than collapsing.
    ///
    /// **Rate** is hard-capped: output ≤ `maxOvershootRatio × target ×
    /// pixelCount / 8`. Default `maxOvershootRatio: 1.0` means an exact
    /// byte target. This is the right mode for storage-budgeted
    /// archive workflows (DICOM PACS), compliance-driven file-size
    /// caps, or fixed-rate streaming.
    ///
    /// **Latency** is at most `maxPasses + 1` operations: the bounded
    /// Qstep search (≤3 encodes) plus an O(packets) truncation pass
    /// (~µs cost). Predictable.
    ///
    /// - Parameters:
    ///   - bitsPerPixel: target bitrate in bits per pixel.
    ///   - maxOvershootRatio: hard cap on achieved/target byte ratio
    ///     (default 1.0 = exact target). Smaller is invalid (use 1.0
    ///     for "never exceed target"). Larger relaxes the cap.
    ///   - maxPasses: maximum encode iterations for the inner Qstep
    ///     search (default 3). 1 = fastest (post-truncate the first
    ///     calibration-prior result). 3+ = approaches the bounded
    ///     mode's quality before the truncation step.
    case constantBitrateStrict(
        bitsPerPixel: Double,
        maxOvershootRatio: Double = 1.0,
        maxPasses: Int = 3)
}

// MARK: - Wavelet Kernel Configuration

/// Configuration for Part 2 arbitrary wavelet kernels.
///
/// Controls which wavelet kernel is used for the discrete wavelet transform.
/// Supports both standard Part 1 wavelets and arbitrary Part 2 kernels.
public enum J2KWaveletKernelConfiguration: Sendable, Equatable {
    /// Use standard Part 1 wavelets (5/3 or 9/7).
    ///
    /// The encoder automatically selects:
    /// - 5/3 reversible filter for lossless encoding
    /// - 9/7 irreversible filter for lossy encoding
    ///
    /// This is the default and ensures maximum compatibility with Part 1 decoders.
    case standard

    /// Use an arbitrary wavelet kernel from the kernel library.
    ///
    /// Allows selection of custom wavelet kernels such as Haar, Daubechies,
    /// or user-defined kernels. Requires Part 2 decoder support.
    ///
    /// - Parameter kernel: The wavelet kernel to use for all components.
    case arbitrary(kernel: J2KWaveletKernel)

    /// Use per-tile-component kernel selection.
    ///
    /// Allows different wavelet kernels for different tile-components,
    /// providing fine-grained control over the transform. Requires Part 2
    /// decoder support and ADS marker segments in the codestream.
    ///
    /// - Parameter kernelMap: Dictionary mapping (tileIndex, componentIndex) to kernel.
    case perTileComponent(kernelMap: [TileComponentKey: J2KWaveletKernel])

    /// Key for per-tile-component kernel selection.
    public struct TileComponentKey: Sendable, Equatable, Hashable {
        /// Tile index in the image.
        public let tileIndex: Int

        /// Component index within the tile.
        public let componentIndex: Int

        /// Creates a tile-component key.
        ///
        /// - Parameters:
        ///   - tileIndex: Tile index in the image.
        ///   - componentIndex: Component index within the tile.
        public init(tileIndex: Int, componentIndex: Int) {
            self.tileIndex = tileIndex
            self.componentIndex = componentIndex
        }
    }

    /// Returns the kernel to use for a specific tile-component.
    ///
    /// - Parameters:
    ///   - tileIndex: The tile index.
    ///   - componentIndex: The component index.
    ///   - lossless: Whether encoding is lossless (for standard mode).
    /// - Returns: The wavelet kernel to use, or nil if standard mode is used.
    public func kernel(forTile tileIndex: Int, component componentIndex: Int, lossless: Bool) -> J2KWaveletKernel? {
        switch self {
        case .standard:
            // Standard mode - use built-in 5/3 or 9/7
            return nil
        case .arbitrary(let kernel):
            // Same kernel for all tile-components
            return kernel
        case .perTileComponent(let kernelMap):
            // Look up kernel for this specific tile-component
            let key = TileComponentKey(tileIndex: tileIndex, componentIndex: componentIndex)
            return kernelMap[key]
        }
    }

    /// Returns whether this configuration uses Part 2 arbitrary wavelets.
    public var usesArbitraryWavelets: Bool {
        switch self {
        case .standard:
            return false
        case .arbitrary, .perTileComponent:
            return true
        }
    }
}

// MARK: - Preset Extensions

extension J2KEncodingPreset: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fast:
            return "Fast (2-3× faster, good quality)"
        case .balanced:
            return "Balanced (optimal quality/speed)"
        case .quality:
            return "Quality (best quality, slower)"
        }
    }
}

extension J2KBitrateMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .constantQuality:
            return "Constant Quality"
        case .constantBitrate(let bpp):
            return "Constant Bitrate (\(String(format: "%.2f", bpp)) bpp)"
        case let .variableBitrate(minQuality, maxBpp):
            return "Variable Bitrate (min quality: \(String(format: "%.2f", minQuality)), max: \(String(format: "%.2f", maxBpp)) bpp)"
        case .lossless:
            return "Lossless"
        case .fixedQstep(let qstep):
            return "Fixed Qstep (\(String(format: "%.5f", qstep)))"
        case .constantBitrateViaQstep(let bpp, let tol, let maxIter):
            return "Constant Bitrate via Qstep (\(String(format: "%.2f", bpp)) bpp ±\(String(format: "%.0f", tol * 100))%, max \(maxIter) iters)"
        case .constantBitrateBounded(let bpp, let maxOver, let maxPasses):
            return "Constant Bitrate Bounded (\(String(format: "%.2f", bpp)) bpp, ≤\(String(format: "%.1f", maxOver))× target, max \(maxPasses) passes)"
        case .constantBitrateStrict(let bpp, let maxOver, let maxPasses):
            return "Constant Bitrate Strict (\(String(format: "%.2f", bpp)) bpp, hard cap \(String(format: "%.2f", maxOver))× target, max \(maxPasses) passes)"
        }
    }
}

// MARK: - Configuration Equatable Conformance

extension J2KEncodingConfiguration: Equatable {
    public static func == (lhs: J2KEncodingConfiguration, rhs: J2KEncodingConfiguration) -> Bool {
        lhs.quality == rhs.quality &&
            lhs.lossless == rhs.lossless &&
            lhs.decompositionLevels == rhs.decompositionLevels &&
            lhs.codeBlockSize.width == rhs.codeBlockSize.width &&
            lhs.codeBlockSize.height == rhs.codeBlockSize.height &&
            lhs.qualityLayers == rhs.qualityLayers &&
            lhs.progressionOrder == rhs.progressionOrder &&
            lhs.enableVisualWeighting == rhs.enableVisualWeighting &&
            lhs.tileSize.width == rhs.tileSize.width &&
            lhs.tileSize.height == rhs.tileSize.height &&
            lhs.bitrateMode == rhs.bitrateMode &&
            lhs.maxThreads == rhs.maxThreads &&
            lhs.dcOffsetConfiguration == rhs.dcOffsetConfiguration &&
            lhs.extendedPrecisionConfiguration == rhs.extendedPrecisionConfiguration &&
            lhs.waveletKernelConfiguration == rhs.waveletKernelConfiguration &&
            lhs.useHTJ2K == rhs.useHTJ2K &&
            lhs.useReversibleFilter == rhs.useReversibleFilter &&
            lhs.enableParallelCodeBlocks == rhs.enableParallelCodeBlocks &&
            lhs.enableFastMEL == rhs.enableFastMEL &&
            lhs.enableVLCOptimization == rhs.enableVLCOptimization &&
            lhs.enableMagSgnPacking == rhs.enableMagSgnPacking &&
            lhs.mctConfiguration == rhs.mctConfiguration &&
            lhs.writeTLMMarker == rhs.writeTLMMarker &&
            lhs.blockSizeMode == rhs.blockSizeMode &&
            lhs.tileBlockSizeOverrides.count == rhs.tileBlockSizeOverrides.count &&
            lhs.tileBlockSizeOverrides.allSatisfy { key, value in
                guard let other = rhs.tileBlockSizeOverrides[key] else { return false }
                return value.width == other.width && value.height == other.height
            }
    }
}
