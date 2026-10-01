// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Quantization tables, zigzag scan ordering, and quantization operations.
enum Quantization {

    // MARK: - Zigzag Scan Order

    /// Maps zigzag position (0–63) to block index (row × 8 + col).
    static let zigzagOrder: [Int] = [
         0,  1,  8, 16,  9,  2,  3, 10,
        17, 24, 32, 25, 18, 11,  4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13,  6,  7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
    ]

    /// Maps block index to zigzag position (inverse of `zigzagOrder`).
    static let inverseZigzagOrder: [Int] = {
        var inverse = [Int](repeating: 0, count: 64)
        for i in 0..<64 {
            inverse[zigzagOrder[i]] = i
        }
        return inverse
    }()

    /// Reorders a block from natural order to zigzag order.
    static func zigzagScan(_ block: [Int32]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        zigzagScan(block, into: &result)
        return result
    }

    /// In-place variant: reorders `block` into `out` in zigzag order.
    static func zigzagScan(_ block: [Int32], into out: inout [Int32]) {
        zigzagScan(block, offset: 0, into: &out)
    }

    /// Variant that reads from a contiguous multi-block buffer at the given offset,
    /// avoiding a per-block 64-element copy in the encoder's MCU walk.
    static func zigzagScan(_ source: [Int32], offset: Int, into out: inout [Int32]) {
        source.withUnsafeBufferPointer { srcBuf in
            out.withUnsafeMutableBufferPointer { dstBuf in
                let src = srcBuf.baseAddress! + offset
                let dst = dstBuf.baseAddress!
                for i in 0..<64 { dst[i] = src[zigzagOrder[i]] }
            }
        }
    }

    /// Reorders a block from zigzag order to natural order.
    static func inverseZigzagScan(_ zigzag: [Int32]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        inverseZigzagScan(zigzag, into: &result)
        return result
    }

    /// In-place variant: reorders zigzag `zigzag` into natural order in `out`.
    static func inverseZigzagScan(_ zigzag: [Int32], into out: inout [Int32]) {
        for i in 0..<64 { out[zigzagOrder[i]] = zigzag[i] }
    }

    // MARK: - Standard Quantization Tables (ITU-T T.81 Annex K)

    /// Standard JPEG luminance quantization table at quality 50.
    static let standardLuminanceTable: [Int] = [
        16, 11, 10, 16,  24,  40,  51,  61,
        12, 12, 14, 19,  26,  58,  60,  55,
        14, 13, 16, 24,  40,  57,  69,  56,
        14, 17, 22, 29,  51,  87,  80,  62,
        18, 22, 37, 56,  68, 109, 103,  77,
        24, 35, 55, 64,  81, 104, 113,  92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103,  99
    ]

    /// Standard JPEG chrominance quantization table at quality 50.
    static let standardChrominanceTable: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99
    ]

    /// Maps a jpegli/JPEG-XL **distance** to an IJG quality (1–100).
    ///
    /// Distance is jpegli's native quality knob: it targets a Butteraugli
    /// distance, where ~1.0 is visually lossless and larger values compress
    /// harder. This is the inverse of libjxl's `JpegQualityToDistance`:
    ///
    ///     q ≥ 100  → d = 0.01
    ///     q ≥ 30   → d = 0.1 + (100 − q)·0.09          (linear)
    ///     q < 30   → d = (53/3000)q² − (23/20)q + 25   (quadratic)
    ///
    /// JLISwift scales the standard IJG tables by this quality rather than
    /// jpegli's perceptually-tuned base matrices, so this is an approximation
    /// of jpegli's distance semantics — same monotonic rate/distance behavior,
    /// not byte-identical output. Returns a Double so callers can round as they
    /// see fit.
    static func qualityForDistance(_ distance: Double) -> Double {
        let d = max(0.0, distance)
        if d < 0.1 { return 100.0 }
        // Linear branch maps d ∈ [0.1, 6.4] → q ∈ [100, 30].
        if d <= 6.4 {
            return 100.0 - (d - 0.1) / 0.09
        }
        // Quadratic branch for q < 30: (53/3000)q² − (23/20)q + (25 − d) = 0.
        let a = 53.0 / 3000.0
        let b = -23.0 / 20.0
        let c = 25.0 - d
        let disc = b * b - 4 * a * c
        if disc <= 0 { return 1.0 }
        let q = (-b - disc.squareRoot()) / (2 * a)   // lower root = lower quality
        return max(1.0, min(30.0, q))
    }

    /// Scales a quantization table for a given JPEG quality (0–100).
    ///
    /// Uses the standard IJG quality scaling formula.
    static func scaleTable(_ baseTable: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale: Int
        if q < 50 {
            scale = 5000 / q
        } else {
            scale = 200 - 2 * q
        }
        return baseTable.map { entry in
            max(1, min(255, (entry * scale + 50) / 100))
        }
    }

    /// Quantizes a block of DCT coefficients using the given quantization table.
    ///
    /// - Parameters:
    ///   - dctBlock: 64 floating-point DCT coefficients in natural order.
    ///   - table: 64-element quantization table.
    /// - Returns: 64 quantized integer coefficients in natural order.
    static func quantize(_ dctBlock: [Float], table: [Int]) -> [Int32] {
        var result = [Int32](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = Int32((dctBlock[i] / Float(table[i])).rounded(.toNearestOrEven))
        }
        return result
    }

    /// Dequantizes a block of quantized coefficients.
    ///
    /// - Parameters:
    ///   - quantized: 64 quantized integer coefficients in natural order.
    ///   - table: 64-element quantization table.
    /// - Returns: 64 floating-point DCT coefficients.
    static func dequantize(_ quantized: [Int32], table: [Int]) -> [Float] {
        var result = [Float](repeating: 0, count: 64)
        for i in 0..<64 {
            result[i] = Float(quantized[i]) * Float(table[i])
        }
        return result
    }
}
