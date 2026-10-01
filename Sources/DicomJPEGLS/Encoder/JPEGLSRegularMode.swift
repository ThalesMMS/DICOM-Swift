// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS regular mode encoding implementation per ITU-T.87.
///
/// Regular mode is the primary encoding mode for JPEG-LS, used when the local
/// gradient indicates non-uniform pixel values. It uses context-based adaptive
/// prediction and Golomb-Rice coding to compress prediction errors efficiently.

import Foundation

/// Regular mode encoder for JPEG-LS compression.
///
/// The regular mode encoder implements the core JPEG-LS algorithm:
/// 1. Compute local gradients (D1, D2, D3) around the current pixel
/// 2. Quantize gradients to determine context
/// 3. Predict pixel value using MED (Median Edge Detector)
/// 4. Apply bias correction based on context statistics
/// 5. Compute prediction error with modular reduction
/// 6. Encode error using Golomb-Rice coding
/// 7. Update context statistics for adaptation
public struct JPEGLSRegularMode: Sendable {
    // MARK: - Properties

    /// Preset parameters controlling thresholds and limits
    private let parameters: JPEGLSPresetParameters

    /// Public accessor for preset parameters
    public var presetParameters: JPEGLSPresetParameters { parameters }

    /// Near-lossless parameter (0 for lossless mode)
    private let near: Int

    /// Range value: RANGE = (MAXVAL + 2*NEAR)/qbpp + 1
    /// Used for modular reduction of prediction errors
    private let range: Int

    /// Quantization factor: qbpp = (NEAR == 0) ? 0 : ((NEAR << 1) | 1)
    private let qbpp: Int

    /// Pre-computed gradient quantisation lookup table.
    ///
    /// The table covers the inner range [−T3, T3] (size = 2·T3 + 1).
    /// Gradient values outside this range are handled by the early-exit checks in
    /// `quantizeGradient` and always map to ±4.  Building the table once at init
    /// avoids repeated branch evaluation in the per-pixel hot path.
    private let gradientTable: [Int]

    /// Offset used to convert a gradient value in [−T3, T3] to a table index.
    /// Index = gradient + gradientTableOffset.
    private let gradientTableOffset: Int

    /// Pre-computed wrap range for `computeReconstructedValue`.
    /// For lossless: `range`. For near-lossless: `range × qbpp`.
    private let wrapRange: Int

    /// Pre-computed upper bound for modular reduction in `computePredictionError`.
    /// `= (range − 1) / 2`
    private let halfRangeHigh: Int

    /// Pre-computed lower bound for modular reduction in `computePredictionError`.
    /// `= −(range / 2)`
    private let halfRangeLow: Int

    // MARK: - Initialization

    /// Initialize regular mode encoder with preset parameters.
    ///
    /// - Parameters:
    ///   - parameters: Preset parameters (thresholds, MAXVAL, RESET)
    ///   - near: Near-lossless parameter (0 for lossless mode)
    /// - Throws: `JPEGLSError.invalidNearParameter` if NEAR is invalid
    public init(parameters: JPEGLSPresetParameters, near: Int = 0) throws {
        guard near >= 0 && near <= 255 else {
            throw JPEGLSError.invalidNearParameter(near: near)
        }

        self.parameters = parameters
        self.near = near

        // Compute quantization factor per ITU-T.87 Section 4.2.1
        self.qbpp = (near == 0) ? 0 : ((near << 1) | 1)

        // Compute RANGE per ITU-T.87 Section 4.2.1
        // RANGE = (MAXVAL + 2*NEAR)/qbpp + 1
        if near == 0 {
            self.range = parameters.maxValue + 1
        } else {
            self.range = (parameters.maxValue + 2 * near) / qbpp + 1
        }

        // Pre-compute modular-reduction bounds and wrap range to avoid per-pixel arithmetic.
        self.halfRangeHigh = (self.range - 1) / 2
        self.halfRangeLow  = -(self.range / 2)
        self.wrapRange     = near == 0 ? self.range : self.range * ((near << 1) | 1)

        // Build gradient quantisation lookup table for the inner range [-T3, T3].
        // Values outside this range always map to ±4 (handled by early-exit checks).
        let t3 = parameters.threshold3
        let tableSize = 2 * t3 + 1
        self.gradientTableOffset = t3
        var table = [Int](repeating: 0, count: tableSize)
        for i in 0..<tableSize {
            let g = i - t3  // gradient in [−T3, T3]
            if g < -near {
                if g <= -parameters.threshold2 { table[i] = -3 }
                else if g <= -parameters.threshold1 { table[i] = -2 }
                else { table[i] = -1 }
            } else if g <= near {
                table[i] = 0
            } else {
                if g < parameters.threshold1 { table[i] = 1 }
                else if g < parameters.threshold2 { table[i] = 2 }
                else { table[i] = 3 }
            }
        }
        self.gradientTable = table
    }

    // MARK: - Gradient Computation

    /// Compute local gradients for regular mode detection.
    ///
    /// Per ITU-T.87 Section 4.1.1, three gradients are computed:
    /// - D1 = d - b  (top-right minus top)
    /// - D2 = b - c  (top minus top-left)
    /// - D3 = c - a  (top-left minus left)
    ///
    /// where the pixel arrangement is:
    /// ```
    ///   c b d
    ///   a x  (x is current pixel being encoded)
    /// ```
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - d: Top-right diagonal neighbor pixel value
    /// - Returns: Tuple of (D1, D2, D3) gradients
    public func computeGradients(a: Int, b: Int, c: Int, d: Int) -> (d1: Int, d2: Int, d3: Int) {
        let d1 = d - b  // Top-right minus top
        let d2 = b - c  // Top minus top-left
        let d3 = c - a  // Top-left minus left

        return (d1, d2, d3)
    }

    /// Quantize a gradient value into the range [-4, 4].
    ///
    /// Per ITU-T.87 Section 4.3.1, gradients are quantized using the
    /// threshold parameters T1, T2, T3 to produce quantization indices
    /// in the range [-4, 4].
    ///
    /// Uses a pre-computed lookup table for the inner range [−T3, T3] to avoid
    /// repeated branch evaluation in the encoding hot path.
    ///
    /// - Parameter gradient: Raw gradient value
    /// - Returns: Quantized gradient in range [-4, 4]
    public func quantizeGradient(_ gradient: Int) -> Int {
        // Gradients outside [−T3, T3] always map to ±4.
        if gradient <= -parameters.threshold3 { return -4 }
        if gradient >= parameters.threshold3 { return 4 }
        // Inner range: use pre-computed table for zero-branch lookup.
        return gradientTable[gradient + gradientTableOffset]
    }

    // MARK: - MED Prediction

    /// Compute MED (Median Edge Detector) prediction.
    ///
    /// Per ITU-T.87 Section 4.1.1, the MED predictor selects between
    /// three neighbor pixels based on their gradient pattern:
    ///
    /// ```
    ///   c b
    ///   a x  (x is current pixel being predicted)
    /// ```
    ///
    /// The prediction logic:
    /// - If c >= max(a, b): Px = min(a, b)
    /// - If c <= min(a, b): Px = max(a, b)
    /// - Otherwise: Px = a + b - c
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    /// - Returns: Predicted pixel value
    public func computeMEDPrediction(a: Int, b: Int, c: Int) -> Int {
        // MED prediction per ITU-T.87 Section 4.1.1
        if c >= max(a, b) {
            return min(a, b)
        } else if c <= min(a, b) {
            return max(a, b)
        } else {
            return a + b - c
        }
    }

    // MARK: - Bias Correction

    /// Apply bias correction to prediction.
    ///
    /// Per ITU-T.87 Section 4.3.3, bias correction adjusts the prediction
    /// based on accumulated context statistics to reduce systematic errors.
    ///
    /// - Parameters:
    ///   - prediction: Base prediction value (from MED)
    ///   - biasC: Bias correction value from context (C array)
    ///   - sign: Context sign (+1 or -1)
    /// - Returns: Bias-corrected prediction
    public func applyBiasCorrection(prediction: Int, biasC: Int, sign: Int) -> Int {
        // Bias correction per ITU-T.87 Section 4.3.3
        // Corrected prediction = Px + sign × C[context]
        let corrected = prediction + sign * biasC

        // Clamp to valid range [0, MAXVAL]
        return max(0, min(parameters.maxValue, corrected))
    }

    // MARK: - Prediction Error

    /// Quantise a raw prediction error for near-lossless mode.
    ///
    /// Per ITU-T.87 Section 4.2.2, for NEAR > 0:
    /// - Errval' = sgn(e) × floor((|e| + NEAR) / (2·NEAR + 1))
    ///
    /// For lossless (NEAR = 0) the raw error is returned unchanged.
    ///
    /// - Parameter rawError: Raw prediction error (actual − corrected prediction)
    /// - Returns: Quantised error (equals rawError when NEAR = 0)
    private func computeQuantizedError(_ rawError: Int) -> Int {
        guard near > 0 else { return rawError }
        let sign = rawError >= 0 ? 1 : -1
        return sign * ((abs(rawError) + near) / qbpp)
    }

    /// Compute prediction error with quantisation (near-lossless) and modular reduction.
    ///
    /// Per ITU-T.87 Section 4.2.2, the prediction error is:
    /// - For lossless (NEAR = 0): Errval = x − Px' with modular reduction
    /// - For near-lossless (NEAR > 0): Errval' = quantise(x − Px') with modular reduction
    ///
    /// Modular reduction ensures the error lies in [−(RANGE−1)/2, (RANGE−1)/2].
    ///
    /// - Parameters:
    ///   - actual: Actual pixel value
    ///   - prediction: Corrected prediction value
    /// - Returns: Quantised prediction error with modular reduction applied
    public func computePredictionError(actual: Int, prediction: Int) -> Int {
        let rawError = actual - prediction
        var error = computeQuantizedError(rawError)

        // Apply modular reduction per ITU-T.87 Section 4.2.2.
        // Use pre-computed bounds to avoid per-pixel division.
        if error > halfRangeHigh {
            error -= range
        } else if error < halfRangeLow {
            error += range
        }

        return error
    }

    /// Compute the reconstructed sample value that the decoder will produce.
    ///
    /// Per ITU-T.87 Section A.4.4 (code segment A.7), the encoder must track
    /// the reconstructed value Rx to keep its context in sync with the decoder:
    /// - Rx = Px' + Errval' × (2·NEAR + 1)
    /// - If Rx < −NEAR:       Rx += RANGE × (2·NEAR + 1)
    /// - If Rx > MAXVAL+NEAR: Rx -= RANGE × (2·NEAR + 1)
    /// - Clamp Rx to [0, MAXVAL]
    ///
    /// - Parameters:
    ///   - prediction: Bias-corrected prediction value (Px')
    ///   - quantizedError: Quantised prediction error after modular reduction
    /// - Returns: Reconstructed sample value clamped to [0, MAXVAL]
    public func computeReconstructedValue(prediction: Int, quantizedError: Int) -> Int {
        let dequantized = near > 0 ? quantizedError * qbpp : quantizedError
        var rv = prediction + dequantized
        // Apply modular correction matching the decoder's reconstructSample.
        // Per ITU-T.87 §A.4.4: wrap range is RANGE × (2·NEAR + 1), thresholds −NEAR and MAXVAL+NEAR.
        // Use the pre-computed wrapRange to avoid the ternary per call.
        if rv < -near {
            rv += wrapRange
        } else if rv > parameters.maxValue + near {
            rv -= wrapRange
        }
        return max(0, min(parameters.maxValue, rv))
    }

    /// Map prediction error to non-negative value for Golomb coding.
    ///
    /// Per ITU-T.87 Section 4.4.1, the signed prediction error is mapped
    /// to a non-negative MErrval for Golomb-Rice encoding:
    /// - If Errval >= 0: MErrval = 2 × Errval
    /// - If Errval < 0: MErrval = -2 × Errval - 1
    ///
    /// - Parameter error: Signed prediction error
    /// - Returns: Mapped non-negative error value
    public func mapErrorToNonNegative(_ error: Int) -> Int {
        if error >= 0 {
            return 2 * error
        } else {
            return -2 * error - 1
        }
    }

    // MARK: - Golomb-Rice Encoding

    /// Encode a value using Golomb-Rice coding.
    ///
    /// Per ITU-T.87 Section 4.4, Golomb-Rice coding encodes a non-negative
    /// integer n with parameter k as:
    /// - Quotient: q = n >> k (encoded in unary: q zeros followed by a 1)
    /// - Remainder: r = n & ((1 << k) - 1) (encoded in binary using k bits)
    ///
    /// - Parameters:
    ///   - value: Non-negative value to encode (MErrval)
    ///   - k: Golomb-Rice parameter (from context)
    /// - Returns: Tuple of (unaryLength, remainder) for bitstream writing
    public func golombEncode(value: Int, k: Int) -> (unaryLength: Int, remainder: Int) {
        // Golomb-Rice encoding per ITU-T.87 Section 4.4
        let quotient = value >> k
        let remainder = value & ((1 << k) - 1)

        // Unary prefix length is the number of zeros (quotient)
        // The terminating 1-bit is written separately by the bitstream writer
        let unaryLength = quotient

        return (unaryLength, remainder)
    }

    /// Compute total bit length for Golomb-Rice encoded value.
    ///
    /// - Parameters:
    ///   - value: Non-negative value to encode
    ///   - k: Golomb-Rice parameter
    /// - Returns: Total number of bits required
    public func golombBitLength(value: Int, k: Int) -> Int {
        let quotient = value >> k
        // Total bits = unary length + k bits for remainder
        return quotient + 1 + k
    }

    // MARK: - Complete Encoding Pipeline

    /// Encode a single pixel in regular mode.
    ///
    /// This is the complete encoding pipeline combining all steps:
    /// 1. Compute gradients
    /// 2. Quantize gradients
    /// 3. Compute context index
    /// 4. Compute MED prediction
    /// 5. Apply bias correction
    /// 6. Compute prediction error
    /// 7. Map to non-negative
    /// 8. Determine Golomb parameter k
    /// 9. Encode using Golomb-Rice
    ///
    /// - Parameters:
    ///   - actual: Actual pixel value to encode
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model (for accessing statistics)
    /// - Returns: Encoded result with context info and encoded bits
    public func encodePixel(
        actual: Int,
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel
    ) -> EncodedPixel {
        // Step 1: Compute local gradients
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)

        // Step 2: Quantize gradients
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)

        // Step 3: Compute context index and sign
        let (contextIndex, sign) = context.computeContextIndexAndSign(q1: q1, q2: q2, q3: q3)

        return encodePixel(
            actual: actual, a: a, b: b, c: c,
            contextIndex: contextIndex, sign: sign, context: context
        )
    }

    /// Encode a single pixel in regular mode with a precomputed context.
    ///
    /// Identical to `encodePixel(actual:a:b:c:d:context:)` from step 4
    /// onward; the caller supplies the context index and sign it already
    /// derived from the quantized gradients (the scan loop computes them
    /// for the run-mode test, so recomputing here would quantize every
    /// gradient twice per pixel).
    public func encodePixel(
        actual: Int,
        a: Int,
        b: Int,
        c: Int,
        contextIndex: Int,
        sign: Int,
        context: JPEGLSContextModel
    ) -> EncodedPixel {
        // Steps 5/7/7a inputs: bias C[Q], Golomb k, and the k=0 error
        // correction from a single context-record load.
        let (biasC, k, errorCorrection) = context.pixelCodingState(contextIndex: contextIndex)

        // Step 4: Compute MED prediction
        let basePrediction = computeMEDPrediction(a: a, b: b, c: c)

        // Step 5: Apply bias correction
        let correctedPrediction = applyBiasCorrection(
            prediction: basePrediction,
            biasC: biasC,
            sign: sign
        )

        // Step 6: Compute quantised (near-lossless) or exact (lossless) prediction error
        let quantisedError = computePredictionError(actual: actual, prediction: correctedPrediction)

        // Step 6a: Apply sign to normalise the error per ITU-T.87 Section 4.3.3.
        // When the context sign is negative the error is negated so that the encoded
        // error is always relative to the normalised (positive-sign) context.
        let error = sign * quantisedError

        // Step 7a: Apply error correction XOR per ITU-T.87 §A.4.1
        let correctedError = error ^ errorCorrection

        // Step 8: Map to non-negative for Golomb coding
        let mappedError = mapErrorToNonNegative(correctedError)

        // Step 9: Encode using Golomb-Rice
        let (unaryLength, remainder) = golombEncode(value: mappedError, k: k)

        // Compute reconstructed value for near-lossless neighbour tracking.
        // For lossless (NEAR=0) the reconstructed value is always equal to the
        // actual pixel, so we skip the modular-arithmetic computation entirely.
        let reconstructedValue: Int
        if near == 0 {
            reconstructedValue = actual
        } else {
            reconstructedValue = computeReconstructedValue(
                prediction: correctedPrediction,
                quantizedError: quantisedError
            )
        }

        // Store quantisedError (uncorrected, sign-denormalised) per ITU-T.87 §A.6.2.
        // The XOR correction is only for mapping; context update uses the original
        // error.  The caller's updateContext computes errval = sign × quantisedError
        // = sign-normalised uncorrected error, matching ITU-T.87 behaviour.
        return EncodedPixel(
            contextIndex: contextIndex,
            sign: sign,
            prediction: correctedPrediction,
            error: quantisedError,
            mappedError: mappedError,
            golombK: k,
            unaryLength: unaryLength,
            remainder: remainder,
            reconstructedValue: reconstructedValue
        )
    }
}

// MARK: - Encoded Pixel Result

/// Result of encoding a single pixel in regular mode.
///
/// Contains all intermediate values and final encoded bits for testing
/// and bitstream writing.
public struct EncodedPixel: Sendable {
    /// Context index used (0 to 364)
    public let contextIndex: Int

    /// Context sign (+1 or -1)
    public let sign: Int

    /// Bias-corrected prediction value
    public let prediction: Int

    /// Quantised prediction error (equals raw error for lossless mode)
    public let error: Int

    /// Mapped non-negative error (MErrval)
    public let mappedError: Int

    /// Golomb-Rice parameter k
    public let golombK: Int

    /// Unary code length (quotient + 1)
    public let unaryLength: Int

    /// Binary remainder (k bits)
    public let remainder: Int

    /// Reconstructed sample value (what the decoder will produce).
    /// For lossless mode this equals the actual pixel value; for
    /// near-lossless it is the dequantised approximation.
    public let reconstructedValue: Int

    /// Total encoded bit length
    public var totalBitLength: Int {
        return unaryLength + 1 + golombK
    }
}
