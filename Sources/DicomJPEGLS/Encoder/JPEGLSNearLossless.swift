// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS near-lossless encoding implementation per ITU-T.87.
///
/// Near-lossless encoding introduces controlled quantization of prediction errors
/// to achieve higher compression ratios while guaranteeing a maximum reconstruction
/// error bounded by the NEAR parameter.

import Foundation

/// Near-lossless encoder for JPEG-LS compression.
///
/// The near-lossless encoder extends the regular mode with:
/// 1. Quantized prediction error calculation using NEAR parameter
/// 2. Reconstructed value computation for decoder state tracking
/// 3. Modified threshold parameters for near-lossless mode
/// 4. Error bounds compliance validation
///
/// Per ITU-T.87 Section 4.2.1, the NEAR parameter defines the maximum difference
/// between original and reconstructed sample values.
public struct JPEGLSNearLossless: Sendable {
    // MARK: - Properties

    /// Preset parameters controlling thresholds and limits
    private let parameters: JPEGLSPresetParameters

    /// Near-lossless parameter (1-255, defines maximum reconstruction error)
    private let near: Int

    /// Maximum sample value from parameters
    private let maxValue: Int

    /// Quantization divisor: qbpp = 2 * NEAR + 1
    /// Used to quantize prediction errors for near-lossless encoding.
    public let quantizationDivisor: Int

    /// Range value: RANGE = floor((MAXVAL + 2*NEAR) / (2*NEAR + 1)) + 1
    /// Defines the range of quantized prediction errors.
    public let range: Int

    /// Modified threshold T1 for near-lossless mode
    public let modifiedThreshold1: Int

    /// Modified threshold T2 for near-lossless mode
    public let modifiedThreshold2: Int

    /// Modified threshold T3 for near-lossless mode
    public let modifiedThreshold3: Int

    // MARK: - Initialization

    /// Initialize near-lossless encoder with preset parameters.
    ///
    /// - Parameters:
    ///   - parameters: Preset parameters (thresholds, MAXVAL, RESET)
    ///   - near: Near-lossless parameter (1-255)
    /// - Throws: `JPEGLSError.invalidNearParameter` if NEAR is invalid
    public init(parameters: JPEGLSPresetParameters, near: Int) throws {
        guard near >= 1 && near <= 255 else {
            throw JPEGLSError.invalidNearParameter(near: near)
        }

        self.parameters = parameters
        self.near = near
        self.maxValue = parameters.maxValue

        // Compute quantization divisor per ITU-T.87 Section 4.2.1
        // qbpp = 2 * NEAR + 1
        self.quantizationDivisor = 2 * near + 1

        // Compute RANGE per ITU-T.87 Section 4.2.1
        // RANGE = floor((MAXVAL + 2*NEAR) / (2*NEAR + 1)) + 1
        self.range = (parameters.maxValue + 2 * near) / quantizationDivisor + 1

        // Compute modified thresholds per ITU-T.87 Section 4.3.5
        // In near-lossless mode, thresholds are adjusted:
        // T'i = max(Ti / (2*NEAR + 1), 1)
        self.modifiedThreshold1 = Self.computeModifiedThreshold(
            threshold: parameters.threshold1,
            divisor: quantizationDivisor
        )
        self.modifiedThreshold2 = Self.computeModifiedThreshold(
            threshold: parameters.threshold2,
            divisor: quantizationDivisor
        )
        self.modifiedThreshold3 = Self.computeModifiedThreshold(
            threshold: parameters.threshold3,
            divisor: quantizationDivisor
        )
    }

    /// Compute a modified threshold for near-lossless mode.
    ///
    /// Per ITU-T.87 Section 4.3.5, thresholds are scaled by the quantization divisor:
    /// T'i = max(floor(Ti / (2*NEAR + 1)), 1)
    ///
    /// - Parameters:
    ///   - threshold: Original threshold value
    ///   - divisor: Quantization divisor (2*NEAR + 1)
    /// - Returns: Modified threshold (minimum 1)
    private static func computeModifiedThreshold(threshold: Int, divisor: Int) -> Int {
        return max(threshold / divisor, 1)
    }

    // MARK: - Quantized Prediction Error

    /// Quantize a prediction error for near-lossless encoding.
    ///
    /// Per ITU-T.87 Section 4.3.2, the prediction error is quantized:
    /// - Errval' = floor((Errval + NEAR) / (2*NEAR + 1))  if Errval >= 0
    /// - Errval' = -floor((abs(Errval) + NEAR) / (2*NEAR + 1))  if Errval < 0
    ///
    /// This quantization ensures the reconstructed value differs from the original
    /// by at most NEAR.
    ///
    /// - Parameter predictionError: Raw prediction error (actual - prediction)
    /// - Returns: Quantized prediction error
    public func quantizePredictionError(_ predictionError: Int) -> Int {
        if predictionError >= 0 {
            return (predictionError + near) / quantizationDivisor
        } else {
            return -((abs(predictionError) + near) / quantizationDivisor)
        }
    }

    /// Dequantize a prediction error.
    ///
    /// This is the inverse of quantization, used to compute reconstructed values:
    /// - DerrVal = Errval' * (2*NEAR + 1)
    ///
    /// - Parameter quantizedError: Quantized prediction error
    /// - Returns: Dequantized error (multiple of 2*NEAR + 1)
    public func dequantizePredictionError(_ quantizedError: Int) -> Int {
        return quantizedError * quantizationDivisor
    }

    // MARK: - Reconstructed Value Computation

    /// Compute the reconstructed value for decoder tracking.
    ///
    /// Per ITU-T.87 Section A.4.4 (code segment A.7), the encoder must track
    /// what the decoder will reconstruct to maintain context synchronization:
    /// - Rx = Px + Errval' × (2·NEAR + 1)
    /// - If Rx < −NEAR:       Rx += RANGE × (2·NEAR + 1)
    /// - If Rx > MAXVAL+NEAR: Rx -= RANGE × (2·NEAR + 1)
    /// - Clamp Rx to [0, MAXVAL]
    ///
    /// - Parameters:
    ///   - prediction: Bias-corrected prediction value
    ///   - quantizedError: Quantized prediction error
    /// - Returns: Reconstructed value (clamped to [0, MAXVAL])
    public func computeReconstructedValue(prediction: Int, quantizedError: Int) -> Int {
        let dequantizedError = dequantizePredictionError(quantizedError)
        var reconstructed = prediction + dequantizedError

        // Per ITU-T.87 §A.4.4: wrap range is RANGE × (2·NEAR + 1)
        let wrapRange = range * quantizationDivisor
        if reconstructed < -near {
            reconstructed += wrapRange
        } else if reconstructed > maxValue + near {
            reconstructed -= wrapRange
        }

        return clampToRange(reconstructed)
    }

    /// Clamp a value to the valid sample range [0, MAXVAL].
    ///
    /// - Parameter value: Value to clamp
    /// - Returns: Value clamped to [0, MAXVAL]
    public func clampToRange(_ value: Int) -> Int {
        return max(0, min(maxValue, value))
    }

    // MARK: - Error Bounds Validation

    /// Validate that the reconstruction error is within NEAR bounds.
    ///
    /// This method checks that |original - reconstructed| <= NEAR,
    /// which is the fundamental guarantee of near-lossless encoding.
    ///
    /// - Parameters:
    ///   - original: Original sample value
    ///   - reconstructed: Reconstructed sample value
    /// - Returns: True if the error is within bounds
    public func validateErrorBounds(original: Int, reconstructed: Int) -> Bool {
        return abs(original - reconstructed) <= near
    }

    /// Compute the actual reconstruction error.
    ///
    /// - Parameters:
    ///   - original: Original sample value
    ///   - reconstructed: Reconstructed sample value
    /// - Returns: Absolute reconstruction error
    public func computeReconstructionError(original: Int, reconstructed: Int) -> Int {
        return abs(original - reconstructed)
    }

    // MARK: - Modular Reduction

    /// Apply modular reduction to quantized prediction error.
    ///
    /// Per ITU-T.87 Section 4.2.2, modular arithmetic is used to keep
    /// the quantized error within bounds:
    /// - If error > (RANGE - 1) / 2: error -= RANGE
    /// - If error < -RANGE / 2: error += RANGE
    ///
    /// - Parameter quantizedError: Quantized prediction error
    /// - Returns: Reduced error within [-RANGE/2, (RANGE-1)/2]
    public func applyModularReduction(_ quantizedError: Int) -> Int {
        var error = quantizedError

        if error > (range - 1) / 2 {
            error -= range
        } else if error < -(range / 2) {
            error += range
        }

        return error
    }

    // MARK: - Error Mapping

    /// Map quantized error to non-negative value for Golomb coding.
    ///
    /// Per ITU-T.87 Section 4.4.1, the signed error is mapped to non-negative:
    /// - If Errval >= 0: MErrval = 2 × Errval
    /// - If Errval < 0: MErrval = -2 × Errval - 1
    ///
    /// - Parameter quantizedError: Signed quantized prediction error
    /// - Returns: Mapped non-negative error value
    public func mapErrorToNonNegative(_ quantizedError: Int) -> Int {
        if quantizedError >= 0 {
            return 2 * quantizedError
        } else {
            return -2 * quantizedError - 1
        }
    }

    /// Unmap a non-negative error back to signed value.
    ///
    /// This is the inverse of `mapErrorToNonNegative`:
    /// - If MErrval is even: Errval = MErrval / 2
    /// - If MErrval is odd: Errval = -(MErrval + 1) / 2
    ///
    /// - Parameter mappedError: Non-negative mapped error
    /// - Returns: Signed quantized prediction error
    public func unmapErrorToSigned(_ mappedError: Int) -> Int {
        if mappedError % 2 == 0 {
            return mappedError / 2
        } else {
            return -(mappedError + 1) / 2
        }
    }

    // MARK: - Gradient Quantization

    /// Quantize a gradient value for context determination.
    ///
    /// Per ITU-T.87 Section 4.3.1, in near-lossless mode gradients are
    /// quantized using modified thresholds and the NEAR parameter:
    /// - Q = 0 if |d| <= NEAR
    /// - Q = sign(d) × 1 if NEAR < |d| <= T'1
    /// - Q = sign(d) × 2 if T'1 < |d| <= T'2
    /// - Q = sign(d) × 3 if T'2 < |d| <= T'3
    /// - Q = sign(d) × 4 if T'3 < |d|
    ///
    /// - Parameter gradient: Raw gradient value
    /// - Returns: Quantized gradient in range [-4, 4]
    public func quantizeGradient(_ gradient: Int) -> Int {
        let absGrad = abs(gradient)
        let sign = gradient >= 0 ? 1 : -1

        if absGrad <= near {
            return 0
        } else if absGrad <= modifiedThreshold1 {
            return sign * 1
        } else if absGrad <= modifiedThreshold2 {
            return sign * 2
        } else if absGrad <= modifiedThreshold3 {
            return sign * 3
        } else {
            return sign * 4
        }
    }

    // MARK: - Complete Encoding Pipeline

    /// Encode a single pixel in near-lossless mode.
    ///
    /// This is the complete near-lossless encoding pipeline:
    /// 1. Compute local gradients using reconstructed neighbors
    /// 2. Quantize gradients
    /// 3. Compute context index
    /// 4. Compute MED prediction using reconstructed neighbors
    /// 5. Apply bias correction
    /// 6. Compute raw prediction error
    /// 7. Quantize prediction error
    /// 8. Apply modular reduction
    /// 9. Map to non-negative
    /// 10. Compute reconstructed value for decoder tracking
    ///
    /// - Parameters:
    ///   - actual: Actual pixel value to encode
    ///   - a: Reconstructed left neighbor (Ra)
    ///   - b: Reconstructed top neighbor (Rb)
    ///   - c: Reconstructed top-left diagonal neighbor (Rc)
    ///   - context: Context model (for accessing statistics)
    /// - Returns: Encoded result with reconstructed value for decoder tracking
    public func encodePixel(
        actual: Int,
        a: Int,
        b: Int,
        c: Int,
        context: JPEGLSContextModel
    ) -> NearLosslessEncodedPixel {
        // Step 1: Compute local gradients
        let d1 = b - a  // Horizontal gradient
        let d2 = c - b  // Vertical gradient
        let d3 = c - a  // Diagonal gradient

        // Step 2: Quantize gradients using modified thresholds
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)

        // Step 3: Compute context index and sign
        let contextIndex = context.computeContextIndex(q1: q1, q2: q2, q3: q3)
        let sign = context.computeContextSign(q1: q1, q2: q2, q3: q3)

        // Step 4: Compute MED prediction
        let basePrediction = computeMEDPrediction(a: a, b: b, c: c)

        // Step 5: Apply bias correction
        let biasC = context.getC(contextIndex: contextIndex)
        let correctedPrediction = applyBiasCorrection(
            prediction: basePrediction,
            biasC: biasC,
            sign: sign
        )

        // Step 6: Compute raw prediction error
        let rawError = actual - correctedPrediction

        // Step 7: Quantize prediction error
        let quantizedError = quantizePredictionError(rawError)

        // Step 8: Apply modular reduction
        let reducedError = applyModularReduction(quantizedError)

        // Step 9: Map to non-negative for Golomb coding
        let mappedError = mapErrorToNonNegative(reducedError)

        // Step 10: Compute reconstructed value
        let reconstructed = computeReconstructedValue(
            prediction: correctedPrediction,
            quantizedError: reducedError
        )

        // Get Golomb parameter from context
        let golombK = context.computeGolombParameter(contextIndex: contextIndex)

        return NearLosslessEncodedPixel(
            contextIndex: contextIndex,
            sign: sign,
            prediction: correctedPrediction,
            rawError: rawError,
            quantizedError: reducedError,
            mappedError: mappedError,
            reconstructed: reconstructed,
            golombK: golombK,
            errorWithinBounds: validateErrorBounds(original: actual, reconstructed: reconstructed)
        )
    }

    // MARK: - Helper Methods

    /// Compute MED (Median Edge Detector) prediction.
    ///
    /// Per ITU-T.87 Section 4.1.1:
    /// - If c >= max(a, b): Px = min(a, b)
    /// - If c <= min(a, b): Px = max(a, b)
    /// - Otherwise: Px = a + b - c
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    /// - Returns: Predicted pixel value
    private func computeMEDPrediction(a: Int, b: Int, c: Int) -> Int {
        if c >= max(a, b) {
            return min(a, b)
        } else if c <= min(a, b) {
            return max(a, b)
        } else {
            return a + b - c
        }
    }

    /// Apply bias correction to prediction.
    ///
    /// - Parameters:
    ///   - prediction: Base prediction value (from MED)
    ///   - biasC: Bias correction value from context
    ///   - sign: Context sign (+1 or -1)
    /// - Returns: Bias-corrected prediction clamped to [0, MAXVAL]
    private func applyBiasCorrection(prediction: Int, biasC: Int, sign: Int) -> Int {
        let corrected = prediction + sign * biasC
        return clampToRange(corrected)
    }
}

// MARK: - Near-Lossless Encoded Pixel Result

/// Result of encoding a single pixel in near-lossless mode.
///
/// Contains all intermediate values, the reconstructed value for decoder tracking,
/// and encoded bits for bitstream writing.
public struct NearLosslessEncodedPixel: Sendable {
    /// Context index used (0 to 364)
    public let contextIndex: Int

    /// Context sign (+1 or -1)
    public let sign: Int

    /// Bias-corrected prediction value
    public let prediction: Int

    /// Raw prediction error before quantization
    public let rawError: Int

    /// Quantized prediction error after modular reduction
    public let quantizedError: Int

    /// Mapped non-negative error (MErrval) for Golomb coding
    public let mappedError: Int

    /// Reconstructed value (what decoder will produce)
    public let reconstructed: Int

    /// Golomb-Rice parameter k
    public let golombK: Int

    /// Whether the reconstruction error is within NEAR bounds
    public let errorWithinBounds: Bool

    /// Total encoded bit length (unary + k)
    public var totalBitLength: Int {
        // Golomb coding: quotient (unary) + remainder (k bits)
        let quotient = mappedError >> golombK
        return quotient + 1 + golombK
    }
}

// MARK: - Near-Lossless Configuration

/// Configuration for near-lossless encoding.
///
/// This struct provides convenient factory methods for creating
/// near-lossless configurations with common parameters.
public struct NearLosslessConfiguration: Sendable, Equatable {
    /// The NEAR parameter (maximum reconstruction error)
    public let near: Int

    /// Bits per sample for the image
    public let bitsPerSample: Int

    /// Initialize with NEAR parameter and bits per sample.
    ///
    /// - Parameters:
    ///   - near: Near-lossless parameter (1-255)
    ///   - bitsPerSample: Number of bits per sample (2-16)
    /// - Throws: `JPEGLSError.invalidNearParameter` or `JPEGLSError.invalidBitsPerSample`
    public init(near: Int, bitsPerSample: Int) throws {
        guard near >= 1 && near <= 255 else {
            throw JPEGLSError.invalidNearParameter(near: near)
        }
        guard bitsPerSample >= 2 && bitsPerSample <= 16 else {
            throw JPEGLSError.invalidBitsPerSample(bits: bitsPerSample)
        }

        self.near = near
        self.bitsPerSample = bitsPerSample
    }

    /// Computed maximum sample value
    public var maxValue: Int {
        return (1 << bitsPerSample) - 1
    }

    /// Compute the maximum achievable compression ratio improvement.
    ///
    /// Near-lossless encoding can achieve higher compression by quantizing errors.
    /// This returns an estimate of the theoretical improvement over lossless.
    ///
    /// - Returns: Estimated compression improvement factor
    public var estimatedCompressionImprovement: Double {
        let quantizationDivisor = 2 * near + 1
        return log2(Double(quantizationDivisor)) + 1.0
    }

    /// Create preset parameters for this configuration.
    ///
    /// - Returns: Default preset parameters for the configured bits per sample
    /// - Throws: `JPEGLSError.invalidBitsPerSample` if bits per sample is invalid
    public func createPresetParameters() throws -> JPEGLSPresetParameters {
        return try JPEGLSPresetParameters.defaultParameters(bitsPerSample: bitsPerSample, near: near)
    }

    /// Create a near-lossless encoder with this configuration.
    ///
    /// - Returns: Configured near-lossless encoder
    /// - Throws: If parameters are invalid
    public func createEncoder() throws -> JPEGLSNearLossless {
        let parameters = try createPresetParameters()
        return try JPEGLSNearLossless(parameters: parameters, near: near)
    }
}

// MARK: - Extension for Preset Parameters

extension JPEGLSPresetParameters {
    /// Compute modified thresholds for near-lossless mode.
    ///
    /// Per ITU-T.87 Section 4.3.5, thresholds should be adjusted when
    /// using near-lossless encoding:
    /// - T'i = max(floor(Ti / (2*NEAR + 1)), 1)
    ///
    /// - Parameter near: Near-lossless parameter
    /// - Returns: Tuple of modified thresholds (T'1, T'2, T'3)
    public func computeModifiedThresholds(near: Int) -> (t1: Int, t2: Int, t3: Int) {
        let divisor = 2 * near + 1
        let t1 = max(threshold1 / divisor, 1)
        let t2 = max(threshold2 / divisor, 1)
        let t3 = max(threshold3 / divisor, 1)
        return (t1, t2, t3)
    }
}
