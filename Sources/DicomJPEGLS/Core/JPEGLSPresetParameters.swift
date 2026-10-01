// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// JPEG-LS preset coding parameters per ITU-T.87
///
/// These parameters control the encoding/decoding behaviour and can be customized
/// via the JPEG-LS Extension (LSE) marker for optimal compression or compatibility.

import Foundation

/// Preset coding parameters for JPEG-LS
///
/// The JPEG-LS standard defines default parameters that work well for most images,
/// but allows customization through preset parameters for specific use cases.
public struct JPEGLSPresetParameters: Sendable, Equatable {
    /// Maximum sample value (default: 2^bitsPerSample - 1)
    public let maxValue: Int

    /// Threshold 1 for gradient quantization (default: computed from MAXVAL)
    public let threshold1: Int

    /// Threshold 2 for gradient quantization (default: computed from MAXVAL)
    public let threshold2: Int

    /// Threshold 3 for gradient quantization (default: computed from MAXVAL)
    public let threshold3: Int

    /// Reset value for context counters (default: 64)
    public let reset: Int

    /// Initialize with custom parameters
    ///
    /// - Parameters:
    ///   - maxValue: Maximum sample value (MAXVAL)
    ///   - threshold1: Gradient quantization threshold T1
    ///   - threshold2: Gradient quantization threshold T2
    ///   - threshold3: Gradient quantization threshold T3
    ///   - reset: Context counter reset value
    /// - Throws: `JPEGLSError.invalidPresetParameters` if parameters are invalid
    public init(
        maxValue: Int,
        threshold1: Int,
        threshold2: Int,
        threshold3: Int,
        reset: Int
    ) throws {
        // Validate parameters according to ITU-T.87 Section 4.2
        guard maxValue >= 1 && maxValue <= 65535 else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "MAXVAL must be in range [1, 65535], got \(maxValue)"
            )
        }

        guard threshold1 >= 1 && threshold1 <= maxValue else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "T1 must be in range [1, MAXVAL], got \(threshold1)"
            )
        }

        guard threshold2 >= threshold1 && threshold2 <= maxValue else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "T2 must be in range [T1, MAXVAL], got \(threshold2)"
            )
        }

        guard threshold3 >= threshold2 && threshold3 <= maxValue else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "T3 must be in range [T2, MAXVAL], got \(threshold3)"
            )
        }

        guard reset >= 3 && reset <= 255 else {
            throw JPEGLSError.invalidPresetParameters(
                reason: "RESET must be in range [3, 255], got \(reset)"
            )
        }

        self.maxValue = maxValue
        self.threshold1 = threshold1
        self.threshold2 = threshold2
        self.threshold3 = threshold3
        self.reset = reset
    }

    /// Compute default preset parameters for given bits per sample
    ///
    /// These defaults are defined in ITU-T.87 Table C.2 (§C.2.4.1.1) and provide
    /// good compression performance for most natural images.
    ///
    /// The thresholds depend on NEAR (the near-lossless error bound) as well as
    /// MAXVAL.  When NEAR = 0 (lossless), the standard formulas reduce to the
    /// traditional defaults.
    ///
    /// ```swift
    /// // Default parameters for 8-bit lossless
    /// let p8 = try JPEGLSPresetParameters.defaultParameters(bitsPerSample: 8)
    /// // p8: T1=3, T2=7, T3=21, RESET=64
    ///
    /// // Default parameters for 12-bit near-lossless with NEAR=3
    /// let p12 = try JPEGLSPresetParameters.defaultParameters(bitsPerSample: 12, near: 3)
    ///
    /// // Embed explicit preset parameters in the encoded bitstream
    /// let config = try JPEGLSEncoder.Configuration(
    ///     near: 3,
    ///     presetParameters: try JPEGLSPresetParameters.defaultParameters(bitsPerSample: 8, near: 3)
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - bitsPerSample: Number of bits per sample (2-16)
    ///   - near: Near-lossless parameter (0 for lossless, default: 0)
    /// - Returns: Default preset parameters
    /// - Throws: `JPEGLSError.invalidBitsPerSample` if bits per sample is invalid
    public static func defaultParameters(bitsPerSample: Int, near: Int = 0) throws -> JPEGLSPresetParameters {
        guard bitsPerSample >= 2 && bitsPerSample <= 16 else {
            throw JPEGLSError.invalidBitsPerSample(bits: bitsPerSample)
        }

        let maxValue = (1 << bitsPerSample) - 1

        // FACTOR computation per ITU-T.87 Table C.2
        let factor: Int
        if maxValue >= 128 {
            factor = (min(maxValue, 4095) + 128) / 256
        } else {
            factor = (256 + maxValue / 2) / (maxValue + 1)
        }

        // BASIC_T values from Table C.2
        let basicT1 = 3
        let basicT2 = 7
        let basicT3 = 21

        // Threshold computation per ITU-T.87 Table C.2
        // T1 = CLAMP(FACTOR*(BASIC_T1-2) + 2 + 3*NEAR, NEAR+1, MAXVAL)
        // T2 = CLAMP(FACTOR*(BASIC_T2-3) + 3 + 5*NEAR, T1,     MAXVAL)
        // T3 = CLAMP(FACTOR*(BASIC_T3-4) + 4 + 7*NEAR, T2,     MAXVAL)
        var threshold1 = factor * (basicT1 - 2) + 2 + 3 * near
        threshold1 = min(max(threshold1, near + 1), maxValue)

        var threshold2 = factor * (basicT2 - 3) + 3 + 5 * near
        threshold2 = min(max(threshold2, threshold1), maxValue)

        var threshold3 = factor * (basicT3 - 4) + 4 + 7 * near
        threshold3 = min(max(threshold3, threshold2), maxValue)

        // Default reset value
        let reset = 64

        return try JPEGLSPresetParameters(
            maxValue: maxValue,
            threshold1: threshold1,
            threshold2: threshold2,
            threshold3: threshold3,
            reset: reset
        )
    }

    /// Returns true if these are the default parameters for the given bits per sample
    public func isDefault(forBitsPerSample bitsPerSample: Int) -> Bool {
        guard let defaultParams = try? Self.defaultParameters(bitsPerSample: bitsPerSample) else {
            return false
        }
        return self == defaultParams
    }
}

extension JPEGLSPresetParameters: CustomStringConvertible {
    /// Human-readable summary of preset parameters
    public var description: String {
        return "JPEGLSPresetParameters(MAXVAL=\(maxValue), T1=\(threshold1), T2=\(threshold2), T3=\(threshold3), RESET=\(reset))"
    }
}
