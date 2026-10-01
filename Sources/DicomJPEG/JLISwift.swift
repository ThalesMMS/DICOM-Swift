// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

/// JLISwift — a native Swift JPEG codec with jpegli-style perceptual encoding.
///
/// JLISwift encodes and decodes standard JPEG that any conformant decoder reads,
/// while adopting the quality techniques popularized by Google's jpegli
/// (perceptual quantization, trellis, a distance parameter). It is cross-validated
/// bit-exactly against libjpeg-turbo, mozjpeg, and ImageIO, and the decoder is
/// fuzz-hardened to throw — never trap — on malformed input. Apple platforms only;
/// Swift 6 strict concurrency throughout.
///
/// ## Quick start
///
/// ```swift
/// import DicomJPEG
///
/// // Encode (baseline, quality 90, 4:2:0 — the default)
/// let jpeg = try JLIEncoder().encode(image, configuration: .default)
///
/// // Decode
/// let decoded = try JLIDecoder().decode(from: jpeg)
///
/// // Lossless (bit-exact archival)
/// var cfg = JLIEncoderConfiguration.default
/// cfg.lossless = true
/// let exact = try JLIEncoder().encode(image, configuration: cfg)
///
/// // Fast 1/8 thumbnail (DC-only) without a full decode
/// var thumb = JLIDecoderConfiguration.default; thumb.scale = 8
/// let preview = try JLIDecoder().decode(from: jpeg, configuration: thumb)
/// ```
///
/// ## Modes
///
/// - **Baseline** (SOF0) and **extended-sequential** (SOF1, 12-bit) DCT.
/// - **Progressive** (SOF2) decode and encode (spectral-selection or
///   successive-approximation scripts), with optional restart markers.
/// - **Lossless** (SOF3, predictive — no DCT) at 8/12/16-bit, grayscale or RGB,
///   plus **near-lossless** via a point transform (bounded error).
/// - **Reduced-scale decode** at 1/2, 1/4, 1/8 (exact box averages from the
///   low-frequency coefficients).
///
/// ## Encode quality controls
///
/// - ``JLIEncoderConfiguration/quality`` or ``JLIEncoderConfiguration/distance``
///   (the jpegli/JPEG-XL convention; takes precedence when set).
/// - Optimized per-image Huffman tables and **trellis** rate-distortion
///   quantization (``JLIEncoderConfiguration/adaptiveQuantization``).
/// - **jpegli perceptual quant tables**
///   (``JLIEncoderConfiguration/perceptualQuantTables``) and a spatial
///   **adaptive-quant field** (``JLIEncoderConfiguration/adaptiveQuantField``) —
///   both opt-in.
/// - **XYB** color (``JLIEncodingColorSpace/xyb``, experimental).
/// - ICC profile and Exif are preserved on ``JLIImage/iccProfile`` /
///   ``JLIImage/exif``.
///
/// ## Performance
///
/// The DCT/quantization pipeline runs on Accelerate (vDSP/vImage, an AMX/GPU-backed
/// GEMM for the batched transform), and the encoder parallelizes its trellis and
/// optimized-Huffman counting across cores (byte-identical to serial).
///
/// ## Topics
///
/// ### Encoding & decoding
/// - ``JLIEncoder``
/// - ``JLIDecoder``
/// - ``JLIImage``
/// - ``JLIEncoderConfiguration``
/// - ``JLIDecoderConfiguration``
///
/// ### Inspecting a JPEG
/// - ``JLIJPEGInfo``
///
/// ### Options
/// - ``JLIChromaSubsampling``
/// - ``JLIProgressiveMode``
/// - ``JLIEncodingColorSpace``
/// - ``JLIPixelFormat``
/// - ``JLIColorModel``
///
/// ### Errors
/// - ``JLIError``
public enum JLISwift {
    /// The current library version.
    public static let version = "0.5.0"
}
