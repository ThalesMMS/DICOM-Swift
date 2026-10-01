// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS regular mode decoding implementation per ITU-T.87.
///
/// Regular mode decoding reverses the encoding process:
/// 1. Read Golomb-Rice encoded value from bitstream
/// 2. Unmap the non-negative value back to signed error
/// 3. Reconstruct sample value using prediction and error
/// 4. Update context statistics for adaptation

import Foundation

/// Regular mode decoder for JPEG-LS decompression.
///
/// The regular mode decoder implements the inverse of the encoding algorithm:
/// 1. Compute local gradients (D1, D2, D3) around the current pixel
/// 2. Quantize gradients to determine context
/// 3. Predict pixel value using MED (Median Edge Detector)
/// 4. Apply bias correction based on context statistics
/// 5. Decode Golomb-Rice encoded prediction error
/// 6. Unmap error from non-negative to signed
/// 7. Compute reconstructed sample value with clamping
/// 8. Update context statistics for adaptation
public struct JPEGLSRegularModeDecoder: Sendable {
    // MARK: - Properties

    /// Preset parameters controlling thresholds and limits
    private let parameters: JPEGLSPresetParameters

    /// Near-lossless parameter (0 for lossless mode)
    private let near: Int

    /// Range value: RANGE = (MAXVAL + 2*NEAR)/qbpp + 1
    /// Used for modular reconstruction of prediction errors
    private let range: Int

    /// Quantization factor: qbpp = (NEAR == 0) ? 0 : ((NEAR << 1) | 1)
    private let qbpp: Int

    /// Gradient quantisation lookup table for the inner range (−T3, T3),
    /// indexed by `gradient + gradientTableOffset`. Built in `init` by
    /// evaluating the reference branch chain, so it is bit-identical to it.
    private let gradientTable: [Int]
    private let gradientTableOffset: Int

    // MARK: - Initialization

    /// Initialize regular mode decoder with preset parameters.
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

        // Build the gradient quantisation table for the inner range from the
        // reference branch chain (values at/beyond ±T3 are handled by the
        // early exits in `quantizeGradient`).
        let t3 = parameters.threshold3
        self.gradientTableOffset = t3
        var table = [Int](repeating: 0, count: 2 * t3 + 1)
        for i in 0..<table.count {
            table[i] = Self.quantizeGradientReference(
                i - t3,
                t1: parameters.threshold1, t2: parameters.threshold2,
                t3: t3, near: near
            )
        }
        self.gradientTable = table
    }

    /// Reference gradient quantisation using the strict upper interval
    /// boundaries in ITU-T.87 Table A.7.
    /// Used to build `gradientTable`; kept as the single source of truth
    /// for the boundary semantics.
    private static func quantizeGradientReference(
        _ gradient: Int, t1: Int, t2: Int, t3: Int, near: Int
    ) -> Int {
        if gradient <= -t3 { return -4 }
        if gradient <= -t2 { return -3 }
        if gradient <= -t1 { return -2 }
        if gradient < -near { return -1 }
        if gradient <= near { return 0 }
        if gradient < t1 { return 1 }
        if gradient < t2 { return 2 }
        if gradient < t3 { return 3 }
        return 4
    }

    // MARK: - Gradient Computation

    /// Compute local gradients for context determination.
    ///
    /// Per ITU-T.87 Section 4.1.1, three gradients are computed:
    /// - D1 = d - b  (top-right minus top)
    /// - D2 = b - c  (top minus top-left)
    /// - D3 = c - a  (top-left minus left)
    ///
    /// where the pixel arrangement is:
    /// ```
    ///   c b d
    ///   a x  (x is current pixel being decoded)
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
    /// - Parameter gradient: Raw gradient value
    /// - Returns: Quantized gradient in range [-4, 4]
    public func quantizeGradient(_ gradient: Int) -> Int {
        // Gradients at/beyond ±T3 always map to ±4; the inner range uses the
        // pre-computed table (built from the reference branch chain).
        if gradient <= -parameters.threshold3 { return -4 }
        if gradient >= parameters.threshold3 { return 4 }
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

    // MARK: - Golomb-Rice Decoding

    /// Decode a Golomb-Rice encoded value.
    ///
    /// Per ITU-T.87 Section 4.4, Golomb-Rice decoding reverses the encoding:
    /// - Read unary code (count zeros until a 1)
    /// - Read k bits for the remainder
    /// - Reconstruct value: (quotient << k) | remainder
    ///
    /// - Parameters:
    ///   - unaryCount: Number of zeros in unary prefix (quotient)
    ///   - remainder: Binary remainder (k bits)
    ///   - k: Golomb-Rice parameter
    /// - Returns: Decoded non-negative value (MErrval)
    public func golombDecode(unaryCount: Int, remainder: Int, k: Int) -> Int {
        // Reconstruct value from unary count and remainder
        // value = (quotient << k) | remainder
        return (unaryCount << k) | remainder
    }

    /// Compute total bit length for a Golomb-Rice encoded value.
    ///
    /// - Parameters:
    ///   - value: Non-negative value to decode
    ///   - k: Golomb-Rice parameter
    /// - Returns: Total number of bits required
    public func golombBitLength(value: Int, k: Int) -> Int {
        let quotient = value >> k
        // Total bits = unary length (quotient + 1) + k bits for remainder
        return quotient + 1 + k
    }

    // MARK: - Error Unmapping

    /// Unmap a non-negative error back to signed error.
    ///
    /// Per ITU-T.87 Section 4.4.1, this reverses the mapping:
    /// - If MErrval is even: Errval = MErrval / 2
    /// - If MErrval is odd: Errval = -(MErrval + 1) / 2
    ///
    /// - Parameter mappedError: Non-negative mapped error (MErrval)
    /// - Returns: Signed prediction error
    public func unmapError(_ mappedError: Int) -> Int {
        if mappedError % 2 == 0 {
            // Even: positive error
            return mappedError / 2
        } else {
            // Odd: negative error
            return -((mappedError + 1) / 2)
        }
    }

    // MARK: - Sample Reconstruction

    /// Dequantise a signed prediction error for near-lossless reconstruction.
    ///
    /// Per ITU-T.87 Section 4.2.2, for NEAR > 0 the decoded Errval is a
    /// quantised approximation; the raw (dequantised) error is:
    /// - deq = Errval × (2·NEAR + 1)
    ///
    /// For lossless (NEAR = 0), the error is returned unchanged.
    ///
    /// - Parameter error: Signed quantised prediction error (after unmapping)
    /// - Returns: Dequantised error suitable for sample reconstruction
    private func dequantizeError(_ error: Int) -> Int {
        guard near > 0 else { return error }
        return error * qbpp
    }

    /// Reconstruct the sample value from prediction and error.
    ///
    /// Per ITU-T.87 Section A.4.4 (code segment A.7):
    /// - Rx = Px' + Errval × (2·NEAR + 1)
    /// - If Rx < −NEAR:       Rx += RANGE × (2·NEAR + 1)
    /// - If Rx > MAXVAL+NEAR: Rx -= RANGE × (2·NEAR + 1)
    /// - Clamp Rx to [0, MAXVAL]
    ///
    /// For lossless (NEAR=0) this simplifies to:
    /// - Rx = Px' + Errval
    /// - Modular wrap with RANGE = MAXVAL + 1
    ///
    /// - Parameters:
    ///   - prediction: Bias-corrected prediction value
    ///   - error: Signed (quantised) prediction error after unmapping
    /// - Returns: Reconstructed sample value clamped to [0, MAXVAL]
    public func reconstructSample(prediction: Int, error: Int) -> Int {
        let dequantized = dequantizeError(error)
        var sample = prediction + dequantized

        // Per ITU-T.87 §A.4.4 fix_reconstructed_value:
        // wrap range is RANGE × (2·NEAR + 1); thresholds are −NEAR and MAXVAL+NEAR.
        let wrapRange = near == 0 ? range : range * qbpp
        if sample < -near {
            sample += wrapRange
        } else if sample > parameters.maxValue + near {
            sample -= wrapRange
        }

        // Clamp to valid range [0, MAXVAL]
        return max(0, min(parameters.maxValue, sample))
    }

    // MARK: - Complete Decoding Pipeline

    /// Decode a single pixel in regular mode.
    ///
    /// This is the complete decoding pipeline combining all steps:
    /// 1. Compute gradients
    /// 2. Quantize gradients
    /// 3. Compute context index
    /// 4. Compute MED prediction
    /// 5. Apply bias correction
    /// 6. Decode Golomb-Rice encoded error
    /// 7. Unmap error from non-negative to signed
    /// 8. Reconstruct sample value
    ///
    /// - Parameters:
    ///   - mappedError: The Golomb-Rice decoded non-negative error (MErrval)
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model (for accessing statistics)
    /// - Returns: Decoded result with context info and reconstructed sample
    public func decodePixel(
        mappedError: Int,
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel,
        errorCorrection: Int = 0
    ) -> DecodedPixel {
        // Step 1: Compute local gradients
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)

        // Step 2: Quantize gradients
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)

        // Step 3: Compute context index and sign
        let (contextIndex, sign) = context.computeContextIndexAndSign(q1: q1, q2: q2, q3: q3)

        return decodePixel(
            mappedError: mappedError, a: a, b: b, c: c,
            contextIndex: contextIndex, sign: sign,
            biasC: context.getC(contextIndex: contextIndex),
            errorCorrection: errorCorrection
        )
    }

    /// Decode a single pixel in regular mode with a precomputed context.
    ///
    /// Identical to `decodePixel(mappedError:a:b:c:d:context:errorCorrection:)`
    /// from step 4 onward; the caller supplies the context index, sign, and
    /// bias correction it already derived (the scan loop fetches the full
    /// per-pixel coding state in one context-record load).
    public func decodePixel(
        mappedError: Int,
        a: Int,
        b: Int,
        c: Int,
        contextIndex: Int,
        sign: Int,
        biasC: Int,
        errorCorrection: Int = 0
    ) -> DecodedPixel {
        // Step 4: Compute MED prediction
        let basePrediction = computeMEDPrediction(a: a, b: b, c: c)

        // Step 5: Apply bias correction
        let correctedPrediction = applyBiasCorrection(
            prediction: basePrediction,
            biasC: biasC,
            sign: sign
        )

        // Step 6: Unmap error from non-negative to signed (sign-adjusted Errval)
        var signAdjustedError = unmapError(mappedError)

        // Step 6b: Apply error correction XOR per ITU-T.87 §A.4.1.
        // When k=0 and lossless, the map swap flips the error sign for biased contexts.
        signAdjustedError = signAdjustedError ^ errorCorrection

        // Step 6a: Undo sign normalisation to recover the raw prediction error.
        // The encoder negated the error when the context sign was -1, so to
        // reconstruct the correct sample we must apply the inverse: rawError = sign × Errval.
        let rawError = sign * signAdjustedError

        // Step 7: Reconstruct sample value
        let sample = reconstructSample(prediction: correctedPrediction, error: rawError)

        return DecodedPixel(
            contextIndex: contextIndex,
            sign: sign,
            prediction: correctedPrediction,
            mappedError: mappedError,
            error: rawError,
            sample: sample
        )
    }

    /// Decode a pixel using raw Golomb parameters from bitstream.
    ///
    /// This method computes the Golomb parameter k from context and
    /// expects the unary count and remainder from the bitstream.
    ///
    /// - Parameters:
    ///   - unaryCount: Number of zeros in unary prefix (quotient)
    ///   - remainder: Binary remainder (k bits)
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model (for accessing statistics)
    /// - Returns: Decoded result with context info and reconstructed sample
    public func decodePixelFromBits(
        unaryCount: Int,
        remainder: Int,
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel
    ) -> DecodedPixel {
        // Compute gradients and context to get k
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)
        let contextIndex = context.computeContextIndex(q1: q1, q2: q2, q3: q3)

        // Get Golomb parameter k
        let k = context.computeGolombParameter(contextIndex: contextIndex)

        // Decode the mapped error
        let mappedError = golombDecode(unaryCount: unaryCount, remainder: remainder, k: k)

        // Use the main decode method
        return decodePixel(mappedError: mappedError, a: a, b: b, c: c, d: d, context: context)
    }

    /// Get the Golomb parameter k for a given context.
    ///
    /// This is useful for external code that needs to know k before
    /// reading bits from the stream.
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model
    /// - Returns: Golomb parameter k
    public func getGolombParameter(
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel
    ) -> Int {
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)
        let contextIndex = context.computeContextIndex(q1: q1, q2: q2, q3: q3)
        return context.computeGolombParameter(contextIndex: contextIndex)
    }

    /// Get the context index for a given set of neighbors.
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model
    /// - Returns: Context index (0 to 364)
    public func getContextIndex(
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel
    ) -> Int {
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)
        return context.computeContextIndex(q1: q1, q2: q2, q3: q3)
    }

    /// Get the context sign for a given set of neighbors.
    ///
    /// - Parameters:
    ///   - a: Left neighbor pixel value
    ///   - b: Top neighbor pixel value
    ///   - c: Top-left diagonal neighbor pixel value
    ///   - context: Context model
    /// - Returns: Context sign (+1 or -1)
    public func getContextSign(
        a: Int,
        b: Int,
        c: Int,
        d: Int,
        context: JPEGLSContextModel
    ) -> Int {
        let (d1, d2, d3) = computeGradients(a: a, b: b, c: c, d: d)
        let q1 = quantizeGradient(d1)
        let q2 = quantizeGradient(d2)
        let q3 = quantizeGradient(d3)
        return context.computeContextSign(q1: q1, q2: q2, q3: q3)
    }
}

// MARK: - Decoded Pixel Result

/// Result of decoding a single pixel in regular mode.
///
/// Contains all intermediate values and final decoded sample for testing
/// and verification.
public struct DecodedPixel: Sendable, Equatable {
    /// Context index used (0 to 364)
    public let contextIndex: Int

    /// Context sign (+1 or -1)
    public let sign: Int

    /// Bias-corrected prediction value
    public let prediction: Int

    /// Mapped non-negative error (MErrval)
    public let mappedError: Int

    /// Signed prediction error
    public let error: Int

    /// Reconstructed sample value
    public let sample: Int

    /// Initialize a decoded pixel result.
    ///
    /// - Parameters:
    ///   - contextIndex: Context index used (0 to 364)
    ///   - sign: Context sign (+1 or -1)
    ///   - prediction: Bias-corrected prediction value
    ///   - mappedError: Mapped non-negative error (MErrval)
    ///   - error: Signed prediction error
    ///   - sample: Reconstructed sample value
    public init(
        contextIndex: Int,
        sign: Int,
        prediction: Int,
        mappedError: Int,
        error: Int,
        sample: Int
    ) {
        self.contextIndex = contextIndex
        self.sign = sign
        self.prediction = prediction
        self.mappedError = mappedError
        self.error = error
        self.sample = sample
    }
}
