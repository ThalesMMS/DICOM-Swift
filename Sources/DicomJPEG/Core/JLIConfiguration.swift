// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

/// Chroma subsampling mode for JPEG encoding.
public enum JLIChromaSubsampling: Sendable {
    /// No subsampling — full resolution for all channels (4:4:4).
    case yuv444

    /// Horizontal subsampling — chrominance at half horizontal resolution (4:2:2).
    case yuv422

    /// Both horizontal and vertical subsampling — chrominance at quarter resolution (4:2:0).
    case yuv420

    /// Grayscale — single luminance channel, no chrominance (4:0:0).
    case yuv400
}

/// The scan script used when encoding a progressive (SOF2) JPEG.
public enum JLIProgressiveMode: Sendable {
    /// Spectral selection only: one DC scan plus one full-band AC scan per
    /// component, using end-of-band runs (EOBRUN). Best for flat / low-frequency
    /// content such as medical imaging — a run of AC-empty blocks collapses to a
    /// single EOBn symbol. This is the default.
    case spectralSelection

    /// Spectral selection **and** successive approximation: libjpeg's canonical
    /// `jpeg_simple_progression` script (band-split luma, Al=2 luma / Al=1
    /// chroma, refined to 0). Slightly smaller on textured / photographic
    /// content, but larger on flat content where the extra scans fragment EOB
    /// runs. Opt in when encoding natural photographs rather than medical plates.
    case successiveApproximation
}

/// The color space to use for encoding the JPEG.
public enum JLIEncodingColorSpace: Sendable {
    /// Standard YCbCr encoding (default, maximum compatibility).
    case yCbCr

    /// XYB perceptual color space (from JPEG XL). **Experimental; 8-bit RGB only.**
    ///
    /// Encodes the image in the XYB perceptual space (full-resolution / 4:4:4) and
    /// embeds an ICC profile (a faithful port of libjxl's XYB profile) so that
    /// ICC-aware decoders applying the embedded A2B profile reconstruct correct
    /// color — verified: the profile transforms XYB→sRGB matching our inverse to
    /// <0.3/255 (`CGColorSpace`). ``JLIDecoder`` detects the profile and inverts
    /// XYB directly.
    ///
    /// Caveats worth knowing: Apple's *image-render* color pipeline (Preview,
    /// `CGContext` drawing, `sips`) does **not** apply CLUT-based A2B profiles, so
    /// it misrenders XYB JPEGs even though the profile is correct — on Apple,
    /// decode with this library. And in current tuning the size/quality is roughly
    /// at parity with tuned 4:4:4 YCbCr rather than a clear win. Prefer ``yCbCr``
    /// unless you specifically want XYB.
    case xyb
}

/// Configuration for the jpegli encoder.
///
/// Use ``JLIEncoderConfiguration/default`` for sensible defaults or customise
/// individual parameters for fine-grained control.
public struct JLIEncoderConfiguration: Sendable {
    /// The JPEG quality level (0.0 – 100.0).
    ///
    /// Higher values produce larger files with fewer artifacts.
    /// This is translated internally to an appropriate jpegli distance parameter.
    public var quality: Double

    /// The jpegli distance parameter (analogous to JPEG XL distance).
    ///
    /// When set, this takes precedence over ``quality``. Lower values produce
    /// higher quality output. A value of `1.0` is visually lossless for most images.
    /// `nil` means the distance is computed from the ``quality`` value.
    public var distance: Double?

    /// The chroma subsampling mode.
    public var chromaSubsampling: JLIChromaSubsampling

    /// The color space used for encoding.
    public var colorSpace: JLIEncodingColorSpace

    /// Whether to produce a progressive JPEG.
    public var progressive: Bool

    /// The scan script for progressive encoding (ignored unless ``progressive``
    /// is set). Defaults to ``JLIProgressiveMode/spectralSelection``, which
    /// compresses flat / medical content best.
    public var progressiveMode: JLIProgressiveMode

    /// Emit a restart marker (RST) every N MCUs, with a DRI marker declaring the
    /// interval. `0` (default) disables restart markers. Restart markers add
    /// resync points so a corrupt run only damages one interval rather than the
    /// rest of the scan, and enable segmented decoding — at a small size cost.
    /// Applies to the baseline / extended-sequential and progressive paths; in
    /// progressive scans the interval counts interleaved MCUs in the DC scan and
    /// data units in the (non-interleaved) AC scans, matching the decoder.
    public var restartInterval: Int

    /// Produce a lossless (SOF3) JPEG — exact reconstruction via spatial
    /// prediction, no DCT/quantization. Larger files, but bit-for-bit lossless
    /// (e.g. medical archival). Grayscale only for now; overrides `progressive`.
    public var lossless: Bool

    /// Lossless predictor selector (1–7, ITU-T T.81 Table H.1; default 1 = left).
    /// Ignored unless `lossless` is set.
    public var losslessPredictor: Int

    /// Sample precision for lossless encoding (2–16), or `0` to derive it from the
    /// pixel format (8-bit for `.uint8`, 12-bit for `.uint16`). Set to 16 for
    /// full 16-bit lossless (e.g. 16-bit medical sources); requires `.uint16`
    /// input. Ignored unless `lossless` is set; DCT modes always use 8/12-bit.
    public var losslessPrecision: Int

    /// Point transform for **near-lossless** SOF3 encoding (0–`precision-1`;
    /// default `0` = true lossless). When `> 0`, the low `Pt` bits of each sample
    /// are discarded before prediction, bounding the reconstruction error to
    /// `2^Pt − 1` while shrinking the file — a controlled-loss archival tradeoff.
    /// Ignored unless `lossless` is set.
    public var losslessPointTransform: Int

    /// Write the frame header as SOF1 (extended sequential DCT) even for 8-bit
    /// samples. DICOM's JPEG Extended syntax (`1.2.840.10008.1.2.4.51`) is
    /// Process 2 & 4, so an 8-bit frame under it must not be Process 1 (SOF0);
    /// see PS3.5 A.4.1. Ignored for progressive and lossless frames.
    public var extendedSequential: Bool = false

    /// Whether to use optimised Huffman coding.
    public var optimiseHuffman: Bool

    /// Whether to enable adaptive dead-zone quantization.
    ///
    /// When enabled, quantization thresholds vary spatially based on image
    /// content — smoother regions get finer quantization while noisy regions
    /// are quantized more aggressively. This is a core jpegli improvement.
    public var adaptiveQuantization: Bool

    /// Spatial adaptive quantization (experimental): modulate the trellis
    /// rate-distortion λ per 8×8 luma block by a visual-masking proxy (the block's
    /// AC energy), so busy/masked blocks are quantized harder and smooth blocks
    /// (where banding shows) are preserved. Requires ``adaptiveQuantization``
    /// (the trellis). Default `false`: it improves perceptual quality-per-byte on
    /// detailed / 4:4:4 content (~5–8% lower butteraugli at mid/low quality in
    /// testing) but can slightly increase 4:2:0 size at low quality, so it's
    /// opt-in rather than on by default.
    public var adaptiveQuantField: Bool

    /// Derive the quantization tables from jpegli's perceptual model instead of
    /// scaling the ITU-T Annex K tables by an IJG quality factor.
    ///
    /// jpegli builds each quantization step from perceptually-tuned base matrices
    /// and a per-coefficient non-linear function of the ``distance`` (see
    /// ``Quantization/perceptualQuantTable(distance:chroma:isYUV420:)``). When no
    /// explicit distance is set, ``quality`` is mapped to a distance first.
    /// Applies to the YCbCr DCT path (baseline/progressive, 8-bit); ignored for
    /// lossless and 12-bit. **Default `true`** since 0.2.0 — a butteraugli RD
    /// sweep over the DICOM corpus (CT/MR/XA) showed perceptual tables clearly
    /// beat Annex K at matched bytes on the default 4:2:0 (e.g. CT q90: ba 1.20
    /// vs 1.82 at equal size; XA q90: smaller *and* better). Set `false` for the
    /// legacy Annex-K rate allocation.
    public var perceptualQuantTables: Bool

    /// **Experimental (0.3.0, opt-in).** Use jpegli's adaptive-quantization path:
    /// a per-8×8-block visual-masking field drives a per-coefficient zero-bias
    /// (dead-zone), quantizing busy/masked blocks harder and preserving smooth
    /// ones. Replaces trellis for the 8-bit YCbCr DCT components when set; decode
    /// is unaffected (standard single quant table). Default `false` while it's
    /// RD-validated against the trellis default and jpegli.
    public var jpegliAdaptiveQuant: Bool

    /// A sensible default configuration: quality 90, YCbCr, 4:2:0 subsampling,
    /// baseline (non-progressive) with optimized Huffman, trellis quantization,
    /// and jpegli perceptual quant tables. Progressive is opt-in — it's a
    /// multi-pass encode and most callers want the faster baseline path.
    public static let `default` = JLIEncoderConfiguration(
        quality: 90.0,
        distance: nil,
        chromaSubsampling: .yuv420,
        colorSpace: .yCbCr,
        progressive: false,
        progressiveMode: .spectralSelection,
        restartInterval: 0,
        lossless: false,
        losslessPredictor: 1,
        losslessPrecision: 0,
        losslessPointTransform: 0,
        optimiseHuffman: true,
        adaptiveQuantization: true,
        adaptiveQuantField: false,
        perceptualQuantTables: true,
        jpegliAdaptiveQuant: false
    )

    /// A configuration guaranteed to be mathematically lossless for diagnostic
    /// use: SOF3 predictive coding, point transform 0 (no near-lossless error),
    /// no chroma subsampling, and every lossy/perceptual path explicitly off.
    /// Use this — not ``default`` — when encoding images that may be used for
    /// diagnosis; ``default`` is a *lossy* perceptual configuration.
    public static let diagnosticLossless: JLIEncoderConfiguration = {
        var cfg = JLIEncoderConfiguration.default
        cfg.lossless = true
        cfg.losslessPredictor = 1
        cfg.losslessPointTransform = 0
        cfg.chromaSubsampling = .yuv444
        cfg.colorSpace = .yCbCr
        cfg.progressive = false
        cfg.adaptiveQuantization = false
        cfg.adaptiveQuantField = false
        cfg.perceptualQuantTables = false
        cfg.jpegliAdaptiveQuant = false
        cfg.optimiseHuffman = true
        return cfg
    }()

    /// True only when this configuration reconstructs the source pixels exactly
    /// (lossless SOF3 with point transform 0). Provenance signal: callers and UIs
    /// MUST NOT present the output of a configuration where this is `false` as
    /// diagnostic-lossless — that includes the default perceptual path and any
    /// near-lossless (point transform > 0) configuration.
    public var isNumericallyLossless: Bool {
        lossless && losslessPointTransform == 0
    }

    /// True when encoding discards information (any non-lossless, or near-lossless
    /// with point transform > 0). The inverse of ``isNumericallyLossless``.
    public var isLossy: Bool { !isNumericallyLossless }

    /// Creates an encoder configuration.
    ///
    /// - Parameters:
    /// All parameters default to the same values as ``default``; see each
    /// property for the full description and trade-offs.
    ///
    /// - Parameters:
    ///   - quality: JPEG quality level (0.0 – 100.0). Default is 90.
    ///   - distance: Optional jpegli distance parameter. Overrides quality when set.
    ///   - chromaSubsampling: Chroma subsampling mode. Default is `.yuv420`.
    ///   - colorSpace: Encoding color space. Default is `.yCbCr`.
    ///   - progressive: Whether to produce a progressive JPEG. Default is `false` (opt-in).
    ///   - optimiseHuffman: Whether to use optimised Huffman tables. Default is `true`.
    ///   - adaptiveQuantization: Whether to enable trellis quantization. Default is `true`.
    public init(
        quality: Double = 90.0,
        distance: Double? = nil,
        chromaSubsampling: JLIChromaSubsampling = .yuv420,
        colorSpace: JLIEncodingColorSpace = .yCbCr,
        progressive: Bool = false,
        progressiveMode: JLIProgressiveMode = .spectralSelection,
        restartInterval: Int = 0,
        lossless: Bool = false,
        losslessPredictor: Int = 1,
        losslessPrecision: Int = 0,
        losslessPointTransform: Int = 0,
        optimiseHuffman: Bool = true,
        adaptiveQuantization: Bool = true,
        adaptiveQuantField: Bool = false,
        perceptualQuantTables: Bool = true,
        jpegliAdaptiveQuant: Bool = false
    ) {
        self.quality = quality
        self.distance = distance
        self.chromaSubsampling = chromaSubsampling
        self.colorSpace = colorSpace
        self.progressive = progressive
        self.progressiveMode = progressiveMode
        self.restartInterval = restartInterval
        self.lossless = lossless
        self.losslessPredictor = losslessPredictor
        self.losslessPrecision = losslessPrecision
        self.losslessPointTransform = losslessPointTransform
        self.optimiseHuffman = optimiseHuffman
        self.adaptiveQuantization = adaptiveQuantization
        self.adaptiveQuantField = adaptiveQuantField
        self.perceptualQuantTables = perceptualQuantTables
        self.jpegliAdaptiveQuant = jpegliAdaptiveQuant
    }
}

/// Configuration for the jpegli decoder.
public struct JLIDecoderConfiguration: Sendable {
    /// The desired output pixel format.
    ///
    /// When `nil`, the decoder selects the most appropriate format based on the
    /// JPEG's internal precision (8-bit input → `.uint8`, 10+ bit → `.uint16`).
    ///
    /// **`.float32` (decode):** the buffer holds 32-bit little-endian floats that
    /// are the **raw reconstructed sample values** — e.g. `0…4095` for 12-bit data,
    /// not normalized to `[0, 1]`. This is intentionally *asymmetric* to the
    /// encoder's float32 *input* (which is normalized `[0, 1]`); decode float32 is
    /// a zero-rounding passthrough of the reconstructed samples, so 12-bit values
    /// are exact. Supported for **grayscale** and **XYB** output; the YCbCr→RGB
    /// path and the lossless (SOF3) path reject `.float32` (use `.uint8`/`.uint16`,
    /// which are already exact for lossless).
    public var outputPixelFormat: JLIPixelFormat?

    /// The desired output color model.
    ///
    /// When `nil`, the decoder outputs in the JPEG's native color model (typically RGB).
    public var outputColorModel: JLIColorModel?

    /// Decode at a reduced scale of `1/scale` for fast previews/thumbnails of
    /// large images. Supported: `1` (full, default), `2`, `4`, and `8`. Each
    /// output sample is the exact average of its `scale × scale` source-pixel box,
    /// reconstructed directly from the low-frequency DCT coefficients (no full
    /// IDCT) — so the result is exact and faster than decoding then downsampling.
    /// `8` is the DC-only special case. Output dimensions are
    /// `ceil(width/scale) × ceil(height/scale)`.
    public var scale: Int

    /// A sensible default configuration that auto-detects precision and color model.
    public static let `default` = JLIDecoderConfiguration(
        outputPixelFormat: nil,
        outputColorModel: nil
    )

    /// Creates a decoder configuration.
    ///
    /// - Parameters:
    ///   - outputPixelFormat: Desired output pixel format, or `nil` for auto-detection.
    ///   - outputColorModel: Desired output color model, or `nil` for auto-detection.
    ///   - scale: Decode at `1/scale` resolution — `1` (full), `2`, `4`, or `8`.
    public init(
        outputPixelFormat: JLIPixelFormat? = nil,
        outputColorModel: JLIColorModel? = nil,
        scale: Int = 1
    ) {
        self.outputPixelFormat = outputPixelFormat
        self.outputColorModel = outputColorModel
        self.scale = scale
    }
}
