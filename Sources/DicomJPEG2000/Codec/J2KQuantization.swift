//
// J2KQuantization.swift
// J2KSwift
//
// J2KQuantization.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

// # JPEG 2000 Quantization
//
// Implementation of quantization and dequantization for JPEG 2000 encoding.
//
// This module implements the quantization stage of the JPEG 2000 encoding pipeline,
// which converts wavelet coefficients to integer indices for entropy coding.
// Quantization is the primary source of lossy compression in JPEG 2000.
//
// ## Quantization Modes
//
// JPEG 2000 supports several quantization modes:
//
// - **Scalar Quantization**: Standard uniform quantization with a single step size
// - **Deadzone Quantization**: Scalar quantization with an enlarged zero bin
// - **Expounded Quantization**: Explicit step size for each subband
// - **No Quantization**: Used for lossless mode (reversible transform only)
//
// ## Step Size Calculation
//
// The quantization step size is derived from the base step size and subband gain:
// ```
// Δ_b = Δ_base × 2^(R-r) × G_b
// ```
// where:
// - Δ_base is the base step size derived from quality settings
// - R is the number of decomposition levels
// - r is the current resolution level
// - G_b is the subband gain (1 for LL, √2 for LH/HL, 2 for HH)
//
// ## Usage
//
// ```swift
// // Create quantizer with specific parameters
// let params = J2KQuantizationParameters(
//     mode: .deadzone,
//     baseStepSize: 0.1,
//     deadzoneWidth: 1.5
// )
// let quantizer = J2KQuantizer(parameters: params)
//
// // Quantize wavelet coefficients
// let quantized = try quantizer.quantize(
//     coefficients: coefficients,
//     subband: .hl,
//     decompositionLevel: 2,
//     totalLevels: 3
// )
//
// // Dequantize for reconstruction
// let reconstructed = try quantizer.dequantize(
//     indices: quantized,
//     subband: .hl,
//     decompositionLevel: 2,
//     totalLevels: 3
// )
// ```

// MARK: - Quantization Mode

/// Quantization mode for JPEG 2000 encoding.
///
/// Defines how wavelet coefficients are quantized to integer indices.
public enum J2KQuantizationMode: Sendable, Equatable, CaseIterable {
    /// Scalar (uniform) quantization.
    ///
    /// All coefficients are quantized using the same step size.
    /// The quantized value is computed as:
    /// ```
    /// q = sign(c) × floor(|c| / Δ)
    /// ```
    case scalar

    /// Deadzone quantization.
    ///
    /// Similar to scalar quantization but with an enlarged zero bin (deadzone).
    /// This provides better compression for sparse signals by mapping
    /// more small values to zero. The quantized value is:
    /// ```
    /// q = sign(c) × floor((|c| - t) / Δ) for |c| > t
    /// q = 0 for |c| <= t
    /// ```
    /// where t is the deadzone threshold (typically 0.5 × Δ to 1.5 × Δ).
    case deadzone

    /// Expounded quantization.
    ///
    /// Each subband has an explicitly specified step size.
    /// This allows fine-grained control over quality at different
    /// frequency bands.
    case expounded

    /// No quantization (lossless mode).
    ///
    /// Coefficients are passed through without modification.
    /// Only valid when used with the reversible (5/3) wavelet transform.
    case noQuantization

    /// Trellis coded quantization (TCQ).
    ///
    /// Uses a trellis structure and Viterbi algorithm to select
    /// quantization levels that minimise rate-distortion cost.
    /// Provides 2-8% improvement over scalar quantization.
    /// Part of ISO/IEC 15444-2 (JPEG 2000 Part 2 extensions).
    case trellis
}

// MARK: - Guard Bits

/// Represents the guard bits used in quantization.
///
/// Guard bits prevent overflow in the quantized coefficients by extending
/// the dynamic range. The number of guard bits affects the precision of
/// the quantized values.
public struct J2KGuardBits: Sendable, Equatable {
    /// The number of guard bits (0-7).
    public let count: Int

    /// Creates guard bits configuration.
    ///
    /// - Parameter count: Number of guard bits (0-7).
    /// - Throws: `J2KError.invalidParameter` if count is out of range.
    public init(count: Int) throws {
        guard (0...7).contains(count) else {
            throw J2KError.invalidParameter("Guard bits must be between 0 and 7")
        }
        self.count = count
    }

    /// Default guard bits (2 bits).
    public static let `default` = try! J2KGuardBits(count: 2)
}

// MARK: - Quantization Parameters

/// Parameters for JPEG 2000 quantization.
///
/// Configures the quantization behavior including mode, step size,
/// and deadzone width.
public struct J2KQuantizationParameters: Sendable, Equatable {
    /// The quantization mode.
    public let mode: J2KQuantizationMode

    /// Base step size for quantization (Δ_base).
    ///
    /// This is the fundamental unit of quantization. Larger values
    /// result in more aggressive compression but lower quality.
    /// Range: 0.0 (lossless) to any positive value.
    public let baseStepSize: Double

    /// Deadzone width as a multiple of the step size.
    ///
    /// Only used in deadzone mode. A value of 1.0 gives a deadzone
    /// equal to the step size. Typical values are 0.5 to 2.0.
    /// Default is 1.0 (one step size on each side of zero).
    public let deadzoneWidth: Double

    /// Guard bits for overflow prevention.
    public let guardBits: J2KGuardBits

    /// Whether to use implicit (derived) step sizes.
    ///
    /// When true, step sizes for subbands are derived from the base
    /// step size using standard JPEG 2000 formulas. When false,
    /// explicit step sizes must be provided for each subband.
    public let implicitStepSizes: Bool

    /// Explicit step sizes for each subband (optional).
    ///
    /// Only used when `implicitStepSizes` is false.
    /// Keys should be subband names at specific levels (e.g., "HL1", "HH2").
    public let explicitStepSizes: [String: Double]

    /// TCQ configuration (only used when mode is .trellis).
    ///
    /// Configures the trellis coded quantization behavior.
    /// Nil value uses default TCQ configuration.
    public let tcqConfiguration: J2KTCQConfiguration?

    /// Creates quantization parameters.
    ///
    /// - Parameters:
    ///   - mode: The quantization mode.
    ///   - baseStepSize: Base step size (default: 1.0).
    ///   - deadzoneWidth: Deadzone width multiple (default: 1.0).
    ///   - guardBits: Guard bits configuration (default: 2).
    ///   - implicitStepSizes: Whether to derive step sizes (default: true).
    ///   - explicitStepSizes: Explicit step sizes for subbands (default: empty).
    ///   - tcqConfiguration: TCQ configuration (default: nil, uses default if mode is .trellis).
    public init(
        mode: J2KQuantizationMode,
        baseStepSize: Double = 1.0,
        deadzoneWidth: Double = 1.0,
        guardBits: J2KGuardBits = .default,
        implicitStepSizes: Bool = true,
        explicitStepSizes: [String: Double] = [:],
        tcqConfiguration: J2KTCQConfiguration? = nil
    ) {
        self.mode = mode
        self.baseStepSize = baseStepSize
        self.deadzoneWidth = deadzoneWidth
        self.guardBits = guardBits
        self.implicitStepSizes = implicitStepSizes
        self.explicitStepSizes = explicitStepSizes
        self.tcqConfiguration = tcqConfiguration
    }

    /// Default parameters for lossy compression.
    public static let lossy = J2KQuantizationParameters(
        mode: .deadzone,
        baseStepSize: 1.0,
        deadzoneWidth: 1.0
    )

    /// Parameters for lossless compression.
    public static let lossless = J2KQuantizationParameters(
        mode: .noQuantization,
        baseStepSize: 1.0
    )

    /// Parameters for trellis coded quantization (default TCQ settings).
    public static let trellis = J2KQuantizationParameters(
        mode: .trellis,
        baseStepSize: 1.0,
        tcqConfiguration: .default
    )

    /// Creates parameters from a quality factor.
    ///
    /// - Parameters:
    ///   - quality: Quality factor (0.0 = lowest, 1.0 = highest).
    ///   - bitDepth: Source component precision in bits. Higher-precision inputs
    ///     require proportionally larger base step sizes to avoid excessive
    ///     bit-plane counts and unstable PCRD truncation at the same byte budget.
    /// - Returns: Quantization parameters suitable for the quality level.
    public static func fromQuality(_ quality: Double, bitDepth: Int = 8) -> J2KQuantizationParameters {
        // Map quality to a moderate base quantization step for 8-bit input.
        //
        // Very small step sizes force noisy images to rely almost entirely on
        // post-compression pass truncation, which can cause severe low-bitrate
        // collapse on textured RGB and high-detail medical workloads. A more
        // realistic base step keeps the number of significant bit-planes under
        // control while still leaving PCRD room to optimize quality.
        let q = max(0.0, min(1.0, quality))
        let base8BitStep: Double
        if q >= 0.95 {
            base8BitStep = 0.5
        } else if q >= 0.80 {
            base8BitStep = 0.75
        } else if q >= 0.50 {
            base8BitStep = 1.0
        } else if q >= 0.20 {
            base8BitStep = 1.5
        } else {
            base8BitStep = 2.0
        }

        // Scale the step with input dynamic range so 12/16-bit sources are not
        // quantized as though they were 8-bit images. This keeps the number of
        // significant bit-planes in line with the target bitrate and prevents the
        // severe medical-image collapse seen in low-bpp release benchmarks.
        let adjustedStep: Double
        if bitDepth > 8 {
            adjustedStep = J2KDynamicRange.adjustStepSize(
                base8BitStep,
                forBitDepth: bitDepth,
                referenceBitDepth: 8
            )
        } else {
            adjustedStep = base8BitStep
        }

        // Use scalar mode which implements the standard JPEG 2000 quantization
        // formula: q = sign(c) × floor(|c| / Δ). This naturally creates a
        // deadzone of width 2Δ centred at zero (from the floor operation),
        // matching ISO/IEC 15444-1 Annex E and OpenJPEG behaviour.
        return J2KQuantizationParameters(
            mode: .scalar,
            baseStepSize: adjustedStep
        )
    }
}

// MARK: - Subband Gain

/// Calculates subband gain factors for quantization.
///
/// The gain factor accounts for the energy redistribution during
/// the wavelet transform. Different subbands have different energy
/// levels and require appropriate scaling.
public struct J2KSubbandGain: Sendable {
    /// Returns the gain factor for a subband.
    ///
    /// For the 5/3 filter:
    /// - LL: 1.0
    /// - LH, HL: √2 ≈ 1.414
    /// - HH: 2.0
    ///
    /// For the 9/7 filter:
    /// - LL: 1.0
    /// - LH, HL: 2.0
    /// - HH: 4.0
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - reversible: Whether using the reversible (5/3) filter.
    /// - Returns: The gain factor.
    public static func gain(
        for subband: J2KSubband,
        reversible: Bool
    ) -> Double {
        if reversible {
            // 5/3 filter gains
            switch subband {
            case .ll: return 1.0
            case .lh, .hl: return 1.4142135623730951 // √2
            case .hh: return 2.0
            }
        } else {
            // 9/7 filter gains (squared magnitudes)
            switch subband {
            case .ll: return 1.0
            case .lh, .hl: return 2.0
            case .hh: return 4.0
            }
        }
    }

    /// Returns the base 2 logarithm of the gain (for bit shifting).
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - reversible: Whether using the reversible filter.
    /// - Returns: log2 of the gain factor.
    public static func log2Gain(
        for subband: J2KSubband,
        reversible: Bool
    ) -> Double {
        if reversible {
            switch subband {
            case .ll: return 0.0
            case .lh, .hl: return 0.5 // log2(√2)
            case .hh: return 1.0 // log2(2)
            }
        } else {
            switch subband {
            case .ll: return 0.0
            case .lh, .hl: return 1.0 // log2(2)
            case .hh: return 2.0 // log2(4)
            }
        }
    }
}

// MARK: - Step Size Calculator

// MARK: - CDF 9/7 Wavelet Norms

/// L2 norms of CDF 9/7 synthesis basis functions for step size scaling.
///
/// These norms determine the quantization step size for each subband so that
/// the reconstruction error contribution is uniform across subbands. Values
/// match OpenJPEG's `dwt_norms_real` table.
///
/// Index 0 = finest decomposition level (resolution 1), increasing toward
/// coarser levels.
struct CDF97Norms: Sendable {
    /// LL subband norms by decomposition depth (index 0 = 1 level, etc.)
    private static let ll: [Double] = [
        1.000, 1.965, 4.177, 8.403, 16.90, 33.84, 67.69, 135.3, 270.6, 540.9
    ]
    /// HL (and LH) subband norms by decomposition level index (0 = finest)
    private static let hl: [Double] = [
        2.022, 3.989, 8.355, 17.04, 34.27, 68.63, 137.3, 274.6, 549.0
    ]
    /// HH subband norms by decomposition level index (0 = finest)
    private static let hh: [Double] = [
        2.080, 3.865, 8.307, 17.18, 34.71, 69.59, 139.3, 278.6, 557.2
    ]

    /// Returns the synthesis basis function L2 norm for a subband.
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - decompositionLevel: For LL pass 0. For detail subbands, 0 or 1-based
    ///     both work (0 maps to finest).
    ///   - totalLevels: Total decomposition levels.
    static func norm(
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> Double {
        switch subband {
        case .ll:
            // LL norm uses totalLevels as the index
            let idx = min(totalLevels, ll.count - 1)
            return ll[idx]
        case .hl, .lh:
            // Map to 0-based norms table index:
            // decompositionLevel 0 → index 0 (finest)
            // decompositionLevel 1 → index 0 (finest, from 1-based encoder path)
            // decompositionLevel N → index N-1 (coarsest)
            let idx: Int
            if decompositionLevel <= 0 {
                idx = 0
            } else {
                idx = min(decompositionLevel - 1, hl.count - 1)
            }
            return hl[idx]
        case .hh:
            let idx: Int
            if decompositionLevel <= 0 {
                idx = 0
            } else {
                idx = min(decompositionLevel - 1, hh.count - 1)
            }
            return hh[idx]
        }
    }
}

/// Calculates quantization step sizes for JPEG 2000 subbands.
///
/// The step size varies by subband to account for:
/// - Resolution level (coarser levels have larger steps)
/// - Subband type (detail subbands have different gains)
/// - Filter type (5/3 vs 9/7 have different energy distributions)
public struct J2KStepSizeCalculator: Sendable {
    /// Calculates the step size for a specific subband.
    ///
    /// For irreversible 9/7, step = base / K_b where K_b is the synthesis
    /// basis function L2 norm from the CDF 9/7 wavelet norm tables.
    ///
    /// - Parameters:
    ///   - baseStepSize: The base step size from configuration.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The current decomposition level (0 = LL, 1 = finest detail, N = coarsest detail).
    ///   - totalLevels: Total number of decomposition levels.
    ///   - reversible: Whether using the reversible filter.
    /// - Returns: The calculated step size for this subband.
    public static func calculateStepSize(
        baseStepSize: Double,
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int,
        reversible: Bool
    ) -> Double {
        if reversible {
            // 5/3 reversible: no quantization, step size = 1.0
            return 1.0
        } else {
            // 9/7 irreversible: norm-based step size scaling.
            //
            // The step size for each subband is derived from the L2 norm of
            // the 2D synthesis basis function for that subband position.
            // step_b = base / K_b
            //
            // K_b values come from the CDF 9/7 wavelet filter norms
            // (identical to OpenJPEG's dwt_norms_real table).
            // Larger K_b → smaller step → finer quantization (more bits
            // allocated to perceptually important subbands).
            let norm = CDF97Norms.norm(
                subband: subband,
                decompositionLevel: decompositionLevel,
                totalLevels: totalLevels
            )
            return baseStepSize / norm
        }
    }

    /// Calculates step sizes for all subbands in a multi-level decomposition.
    ///
    /// - Parameters:
    ///   - baseStepSize: The base step size.
    ///   - totalLevels: Number of decomposition levels.
    ///   - reversible: Whether using the reversible filter.
    /// - Returns: Dictionary mapping subband identifiers to step sizes.
    public static func calculateAllStepSizes(
        baseStepSize: Double,
        totalLevels: Int,
        reversible: Bool
    ) -> [String: Double] {
        var stepSizes: [String: Double] = [:]

        // For each level, calculate step sizes for LH, HL, HH
        for level in 0..<totalLevels {
            let levelName = "\(level + 1)" // 1-indexed for naming

            for subband in [J2KSubband.lh, .hl, .hh] {
                let key = "\(subband.rawValue)\(levelName)"
                stepSizes[key] = calculateStepSize(
                    baseStepSize: baseStepSize,
                    subband: subband,
                    decompositionLevel: level,
                    totalLevels: totalLevels,
                    reversible: reversible
                )
            }
        }

        // LL subband at the coarsest level
        stepSizes["LL\(totalLevels)"] = calculateStepSize(
            baseStepSize: baseStepSize,
            subband: .ll,
            decompositionLevel: totalLevels - 1,
            totalLevels: totalLevels,
            reversible: reversible
        )

        return stepSizes
    }

    /// Encodes step size as JPEG 2000 exponent/mantissa pair.
    ///
    /// In JPEG 2000, step sizes are encoded as:
    /// ```
    /// Δ = 2^(ε_b - B) × (1 + μ/2^11)
    /// ```
    /// where ε_b is the exponent (5 bits), μ is the mantissa (11 bits), and B is a bias.
    /// For simplicity, we use a normalised encoding where step sizes are stored
    /// with sufficient precision for typical use cases.
    ///
    /// - Parameter stepSize: The step size to encode.
    /// - Returns: Tuple of (exponent, mantissa).
    public static func encodeStepSize(_ stepSize: Double) -> (exponent: Int, mantissa: Int) {
        guard stepSize > 0 else {
            return (0, 0)
        }

        // Find the exponent such that stepSize is in range [1, 2) × 2^e
        // i.e., e = floor(log2(stepSize))
        let log2Step = log2(stepSize)
        let floatExponent = floor(log2Step)

        // The exponent in JPEG 2000 is stored as a 5-bit value
        // We need to encode it in a way that allows reconstruction
        // Exponent represents the power of 2 for the step size
        // We use signed representation: positive exponents for step > 1
        let exponent = Int(floatExponent) + 16 // Bias of 16 to handle both > 1 and < 1
        let clampedExponent = max(0, min(31, exponent))

        // Calculate mantissa: stepSize = 2^(e) × (1 + μ/2048)
        // So μ = (stepSize / 2^e - 1) × 2048
        let baseValue = pow(2.0, floatExponent)
        let normalizedValue = stepSize / baseValue
        let mantissa = max(0, min(2047, Int((normalizedValue - 1.0) * 2048.0)))

        return (clampedExponent, mantissa)
    }

    /// Decodes JPEG 2000 exponent/mantissa pair to step size.
    ///
    /// - Parameters:
    ///   - exponent: The exponent value (0-31).
    ///   - mantissa: The mantissa value (0-2047).
    /// - Returns: The decoded step size.
    public static func decodeStepSize(exponent: Int, mantissa: Int) -> Double {
        // Reverse the encoding: stepSize = 2^(e-bias) × (1 + μ/2048)
        let actualExponent = Double(exponent - 16) // Remove bias
        let base = pow(2.0, actualExponent)
        return base * (1.0 + Double(mantissa) / 2048.0)
    }
}

// MARK: - Dynamic Range Adjustment

/// Handles dynamic range adjustment for different bit depths.
///
/// Quantization parameters must be adjusted based on the bit depth
/// of the input data to maintain consistent quality.
public struct J2KDynamicRange: Sendable {
    /// Calculates the scaling factor for a given bit depth.
    ///
    /// - Parameters:
    ///   - bitDepth: The bit depth of the input data.
    ///   - signed: Whether the data is signed.
    /// - Returns: Scaling factor to normalise values.
    public static func scalingFactor(bitDepth: Int, signed: Bool) -> Double {
        // For 8-bit unsigned: range is 0-255, normalise to ~1.0
        // For 16-bit unsigned: range is 0-65535, normalise to ~1.0
        let maxValue = Double((1 << bitDepth) - 1)
        return 1.0 / maxValue
    }

    /// Calculates the maximum magnitude for a bit depth.
    ///
    /// - Parameters:
    ///   - bitDepth: The bit depth.
    ///   - signed: Whether values are signed.
    /// - Returns: Maximum possible magnitude.
    public static func maxMagnitude(bitDepth: Int, signed: Bool) -> Int32 {
        if signed {
            return Int32((1 << (bitDepth - 1)) - 1)
        } else {
            return Int32((1 << bitDepth) - 1)
        }
    }

    /// Adjusts base step size for bit depth.
    ///
    /// Higher bit depths have a larger dynamic range and may need
    /// larger step sizes to achieve similar compression ratios.
    ///
    /// - Parameters:
    ///   - baseStepSize: Original step size.
    ///   - bitDepth: Bit depth of the data.
    ///   - referenceBitDepth: Reference bit depth (default: 8).
    /// - Returns: Adjusted step size.
    public static func adjustStepSize(
        _ baseStepSize: Double,
        forBitDepth bitDepth: Int,
        referenceBitDepth: Int = 8
    ) -> Double {
        // Scale step size based on bit depth ratio
        let ratio = Double(1 << bitDepth) / Double(1 << referenceBitDepth)
        return baseStepSize * ratio
    }
}

// MARK: - Quantizer

/// JPEG 2000 quantizer for wavelet coefficients.
///
/// Performs forward quantization (encoding) and inverse quantization
/// (decoding/reconstruction) of wavelet transform coefficients.
public struct J2KQuantizer: Sendable {
    /// The quantization parameters.
    public let parameters: J2KQuantizationParameters

    /// Whether to use the reversible (5/3) filter.
    public let reversible: Bool

    /// Creates a new quantizer.
    ///
    /// - Parameters:
    ///   - parameters: Quantization parameters.
    ///   - reversible: Whether using the reversible filter (default: false).
    public init(
        parameters: J2KQuantizationParameters,
        reversible: Bool = false
    ) {
        self.parameters = parameters
        self.reversible = reversible
    }

    // MARK: - Forward Quantization

    /// Quantizes a single coefficient.
    ///
    /// - Parameters:
    ///   - coefficient: The wavelet coefficient.
    ///   - stepSize: The step size for this coefficient.
    /// - Returns: The quantized index.
    public func quantizeCoefficient(_ coefficient: Double, stepSize: Double) -> Int32 {
        switch parameters.mode {
        case .noQuantization:
            // No quantization - round to nearest integer
            return j2kClampedInt32(coefficient)

        case .scalar:
            // Scalar quantization: q = sign(c) × floor(|c| / Δ)
            let sign = coefficient >= 0 ? 1.0 : -1.0
            let magnitude = abs(coefficient)
            let quantizedMag = floor(magnitude / stepSize)
            return Int32(sign * quantizedMag)

        case .deadzone:
            // Deadzone quantization with enlarged zero bin
            let sign = coefficient >= 0 ? 1.0 : -1.0
            let magnitude = abs(coefficient)
            let threshold = stepSize * parameters.deadzoneWidth * 0.5

            if magnitude <= threshold {
                return 0
            }

            let quantizedMag = floor((magnitude - threshold) / stepSize) + 1
            return Int32(sign * quantizedMag)

        case .expounded:
            // Same as scalar for individual coefficient
            // (step size should be provided from explicit table)
            let sign = coefficient >= 0 ? 1.0 : -1.0
            let magnitude = abs(coefficient)
            let quantizedMag = floor(magnitude / stepSize)
            return Int32(sign * quantizedMag)

        case .trellis:
            // TCQ uses Viterbi algorithm on sequences, fall back to scalar for single coefficient
            let sign = coefficient >= 0 ? 1.0 : -1.0
            let magnitude = abs(coefficient)
            let quantizedMag = floor(magnitude / stepSize)
            return Int32(sign * quantizedMag)
        }
    }

    /// Quantizes a single Int32 coefficient (optimised version).
    ///
    /// This overload avoids type conversion overhead by working directly with Int32 values.
    ///
    /// - Parameters:
    ///   - coefficient: The wavelet coefficient to quantize.
    ///   - stepSize: The quantization step size.
    /// - Returns: The quantized index.
    @inline(__always)
    public func quantizeCoefficient(_ coefficient: Int32, stepSize: Double) -> Int32 {
        switch parameters.mode {
        case .noQuantization:
            // No quantization - return as-is
            return coefficient

        case .scalar:
            // Scalar quantization: q = sign(c) × floor(|c| / Δ)
            let sign: Int32 = coefficient >= 0 ? 1 : -1
            let magnitude = abs(coefficient)
            let quantizedMag = j2kClampedInt32(Double(magnitude) / stepSize)
            return sign &* quantizedMag

        case .deadzone:
            // Deadzone quantization with enlarged zero bin
            let sign: Int32 = coefficient >= 0 ? 1 : -1
            let magnitude = abs(coefficient)
            let threshold = Int32(stepSize * parameters.deadzoneWidth * 0.5)

            if magnitude <= threshold {
                return 0
            }

            let quantizedMag = j2kClampedInt32((Double(magnitude) - Double(threshold)) / stepSize) &+ 1
            return sign &* quantizedMag

        case .expounded:
            // Same as scalar for individual coefficient
            let sign: Int32 = coefficient >= 0 ? 1 : -1
            let magnitude = abs(coefficient)
            let quantizedMag = j2kClampedInt32(Double(magnitude) / stepSize)
            return sign &* quantizedMag

        case .trellis:
            // TCQ uses Viterbi algorithm on sequences, fall back to scalar for single coefficient
            let sign: Int32 = coefficient >= 0 ? 1 : -1
            let magnitude = abs(coefficient)
            let quantizedMag = j2kClampedInt32(Double(magnitude) / stepSize)
            return sign &* quantizedMag
        }
    }

    // MARK: - vDSP Vectorized Quantization

    #if canImport(Accelerate)
    /// Vectorised scalar quantization: q = sign(c) × floor(|c| / Δ).
    ///
    /// Uses vDSP for bulk absolute value, division, floor, and sign restoration,
    /// replacing the per-element scalar loop with hardware-accelerated vector ops.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients to quantize.
    ///   - stepSize: The quantization step size.
    /// - Returns: Array of quantized indices as Int32.
    private func quantizeVectorized(_ coefficients: [Double], stepSize: Double) -> [Int32] {
        let count = coefficients.count
        var magnitudes = [Double](repeating: 0, count: count)
        var divided = [Double](repeating: 0, count: count)

        // |c|
        vDSP_vabsD(coefficients, 1, &magnitudes, 1, vDSP_Length(count))

        // |c| / Δ
        var step = stepSize
        vDSP_vsdivD(magnitudes, 1, &step, &divided, 1, vDSP_Length(count))

        // floor(|c| / Δ) — vDSP has no floor, but truncation toward zero for positive
        // values is equivalent to floor. Since magnitudes are >= 0, Int32 truncation works.
        // Restore sign: q = sign(c) × floor(|c| / Δ)
        var result = [Int32](repeating: 0, count: count)
        coefficients.withUnsafeBufferPointer { src in
            divided.withUnsafeBufferPointer { div in
                result.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<count {
                        let mag = Int32(div[i])
                        dst[i] = src[i] >= 0 ? mag : -mag
                    }
                }
            }
        }
        return result
    }

    /// Vectorised scalar quantization from Float: q = sign(c) × floor(|c| / Δ).
    ///
    /// Uses vDSP single-precision operations for 2× throughput vs Double path.
    /// Ideal for GPU DWT output which is already in Float.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients as Float.
    ///   - stepSize: The quantization step size.
    /// - Returns: Array of quantized indices as Int32.
    private func quantizeVectorizedFloat(_ coefficients: [Float], stepSize: Double) -> [Int32] {
        let count = coefficients.count
        var magnitudes = [Float](repeating: 0, count: count)
        var divided = [Float](repeating: 0, count: count)

        // |c|
        vDSP_vabs(coefficients, 1, &magnitudes, 1, vDSP_Length(count))

        // |c| / Δ
        var step = Float(stepSize)
        vDSP_vsdiv(magnitudes, 1, &step, &divided, 1, vDSP_Length(count))

        // Truncate and restore sign
        var result = [Int32](repeating: 0, count: count)
        coefficients.withUnsafeBufferPointer { src in
            divided.withUnsafeBufferPointer { div in
                result.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<count {
                        let mag = Int32(div[i])
                        dst[i] = src[i] >= 0 ? mag : -mag
                    }
                }
            }
        }
        return result
    }
    #endif

    /// Quantizes an array of coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: Array of wavelet coefficients.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Array of quantized indices.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize(
        coefficients: [Double],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [Int32] {
        // Get step size for this subband
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        // Use vDSP-accelerated path for scalar/expounded modes (sign × floor(|c| / Δ))
        #if canImport(Accelerate)
        if (parameters.mode == .scalar || parameters.mode == .expounded
                || parameters.mode == .trellis) && coefficients.count >= 64 {
            return quantizeVectorized(coefficients, stepSize: stepSize)
        }
        #endif

        return coefficients.map { coefficient in
            quantizeCoefficient(coefficient, stepSize: stepSize)
        }
    }

    /// Quantizes an array of Float coefficients.
    ///
    /// Optimised for the GPU DWT path where subbands are already Float.
    /// Uses vDSP single-precision vector operations for 2× throughput
    /// over the Double path by avoiding Float→Double conversion.
    ///
    /// - Parameters:
    ///   - coefficients: Array of Float wavelet coefficients from GPU DWT.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Array of quantized indices.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize(
        coefficients: [Float],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [Int32] {
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        #if canImport(Accelerate)
        if (parameters.mode == .scalar || parameters.mode == .expounded
                || parameters.mode == .trellis) && coefficients.count >= 64 {
            return quantizeVectorizedFloat(coefficients, stepSize: stepSize)
        }
        #endif

        return coefficients.map { coefficient in
            quantizeCoefficient(Double(coefficient), stepSize: stepSize)
        }
    }

    /// Quantizes an array of Int32 coefficients.
    ///
    /// This overload handles integer input from the DWT directly, avoiding
    /// unnecessary type conversions for better performance.
    ///
    /// - Parameters:
    ///   - coefficients: Array of integer wavelet coefficients.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Array of quantized indices.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize(
        coefficients: [Int32],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [Int32] {
        // Get step size for this subband
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        // Directly quantize Int32 values using specialized Int32 method
        return coefficients.map { coefficient in
            quantizeCoefficient(coefficient, stepSize: stepSize)
        }
    }

    /// Quantizes a 2D array of coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: 2D array of wavelet coefficients.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: 2D array of quantized indices.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize2D(
        coefficients: [[Double]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [[Int32]] {
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        return coefficients.map { row in
            row.map { coefficient in
                quantizeCoefficient(coefficient, stepSize: stepSize)
            }
        }
    }

    /// Quantizes a 2D array of Int32 coefficients.
    ///
    /// This overload handles integer input from the DWT directly.
    ///
    /// - Parameters:
    ///   - coefficients: 2D array of integer wavelet coefficients.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: 2D array of quantized indices.
    /// - Throws: `J2KError` if quantization fails.
    public func quantize2D(
        coefficients: [[Int32]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [[Int32]] {
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        guard stepSize > 0 else {
            throw J2KError.invalidParameter("Step size must be positive")
        }

        return coefficients.map { row in
            row.map { coefficient in
                quantizeCoefficient(Double(coefficient), stepSize: stepSize)
            }
        }
    }

    // MARK: - Inverse Quantization (Dequantization)

    /// Dequantizes a single index.
    ///
    /// - Parameters:
    ///   - index: The quantized index.
    ///   - stepSize: The step size used during quantization.
    /// - Returns: The reconstructed coefficient.
    public func dequantizeIndex(_ index: Int32, stepSize: Double) -> Double {
        switch parameters.mode {
        case .noQuantization:
            // No quantization - return as-is
            return Double(index)

        case .scalar:
            // Scalar dequantization: c' = (q + 0.5 × sign(q)) × Δ
            // This reconstructs to the center of the quantization bin
            if index == 0 {
                return 0.0
            }
            let sign = index >= 0 ? 1.0 : -1.0
            let magnitude = Double(abs(index)) + 0.5
            return sign * magnitude * stepSize

        case .deadzone:
            // Deadzone dequantization
            if index == 0 {
                return 0.0
            }
            let sign = index >= 0 ? 1.0 : -1.0
            let threshold = stepSize * parameters.deadzoneWidth * 0.5
            let magnitude = (Double(abs(index)) - 0.5) * stepSize + threshold
            return sign * magnitude

        case .expounded:
            // Same as scalar
            if index == 0 {
                return 0.0
            }
            let sign = index >= 0 ? 1.0 : -1.0
            let magnitude = Double(abs(index)) + 0.5
            return sign * magnitude * stepSize

        case .trellis:
            // TCQ dequantization (midpoint reconstruction)
            if index == 0 {
                return 0.0
            }
            let sign = index >= 0 ? 1.0 : -1.0
            let magnitude = Double(abs(index)) + 0.5
            return sign * magnitude * stepSize
        }
    }

    /// Dequantizes an array of indices.
    ///
    /// - Parameters:
    ///   - indices: Array of quantized indices.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Array of reconstructed coefficients.
    /// - Throws: `J2KError` if dequantization fails.
    public func dequantize(
        indices: [Int32],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [Double] {
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return indices.map { index in
            dequantizeIndex(index, stepSize: stepSize)
        }
    }

    /// Dequantizes a 2D array of indices.
    ///
    /// - Parameters:
    ///   - indices: 2D array of quantized indices.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: 2D array of reconstructed coefficients.
    /// - Throws: `J2KError` if dequantization fails.
    public func dequantize2D(
        indices: [[Int32]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [[Double]] {
        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return indices.map { row in
            row.map { index in
                dequantizeIndex(index, stepSize: stepSize)
            }
        }
    }

    /// Dequantizes to integer values (for reversible transform).
    ///
    /// - Parameters:
    ///   - indices: 2D array of quantized indices.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: 2D array of reconstructed integer coefficients.
    /// - Throws: `J2KError` if dequantization fails.
    public func dequantize2DToInt(
        indices: [[Int32]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> [[Int32]] {
        // For lossless mode, indices are the coefficients
        if parameters.mode == .noQuantization {
            return indices
        }

        let stepSize = getStepSize(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return indices.map { row in
            row.map { index in
                j2kClampedInt32(dequantizeIndex(index, stepSize: stepSize))
            }
        }
    }

    // MARK: - Helper Methods

    /// Gets the step size for a specific subband.
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: The step size.
    public func getStepSize(
        for subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> Double {
        if !parameters.implicitStepSizes {
            // Look up explicit step size
            let key = "\(subband.rawValue)\(decompositionLevel + 1)"
            if let explicit = parameters.explicitStepSizes[key] {
                return explicit
            }
        }

        // Calculate implicit step size
        return J2KStepSizeCalculator.calculateStepSize(
            baseStepSize: parameters.baseStepSize,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels,
            reversible: reversible
        )
    }
}

// MARK: - Convenience Extensions

extension J2KQuantizer {
    /// Quantizes a complete DWT decomposition result.
    ///
    /// - Parameters:
    ///   - decomposition: The 2D DWT decomposition result.
    ///   - decompositionLevel: The level of this decomposition.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: Quantized subbands.
    /// - Throws: `J2KError` if quantization fails.
    public func quantizeDecomposition(
        ll: [[Int32]],
        lh: [[Int32]],
        hl: [[Int32]],
        hh: [[Int32]],
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> (ll: [[Int32]], lh: [[Int32]], hl: [[Int32]], hh: [[Int32]]) {
        let quantizedLL = try quantize2D(
            coefficients: ll,
            subband: .ll,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let quantizedLH = try quantize2D(
            coefficients: lh,
            subband: .lh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let quantizedHL = try quantize2D(
            coefficients: hl,
            subband: .hl,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let quantizedHH = try quantize2D(
            coefficients: hh,
            subband: .hh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return (quantizedLL, quantizedLH, quantizedHL, quantizedHH)
    }

    /// Dequantizes a complete set of subbands.
    ///
    /// - Parameters:
    ///   - ll: Quantized LL subband.
    ///   - lh: Quantized LH subband.
    ///   - hl: Quantized HL subband.
    ///   - hh: Quantized HH subband.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: Dequantized subbands as integers.
    /// - Throws: `J2KError` if dequantization fails.
    public func dequantizeDecomposition(
        ll: [[Int32]],
        lh: [[Int32]],
        hl: [[Int32]],
        hh: [[Int32]],
        decompositionLevel: Int,
        totalLevels: Int
    ) throws -> (ll: [[Int32]], lh: [[Int32]], hl: [[Int32]], hh: [[Int32]]) {
        let dequantizedLL = try dequantize2DToInt(
            indices: ll,
            subband: .ll,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let dequantizedLH = try dequantize2DToInt(
            indices: lh,
            subband: .lh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let dequantizedHL = try dequantize2DToInt(
            indices: hl,
            subband: .hl,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let dequantizedHH = try dequantize2DToInt(
            indices: hh,
            subband: .hh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return (dequantizedLL, dequantizedLH, dequantizedHL, dequantizedHH)
    }
}
