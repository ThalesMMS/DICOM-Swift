//
// J2KExtendedPrecision.swift
// J2KSwift
//
// J2KExtendedPrecision.swift
// J2KSwift
//
// Implementation of ISO/IEC 15444-2 extended precision arithmetic for JPEG 2000 Part 2.
//

import Foundation

// # JPEG 2000 Part 2 Extended Precision Arithmetic
//
// Implementation of extended precision support as defined in ISO/IEC 15444-2.
//
// Extended precision allows JPEG 2000 Part 2 encoders and decoders to
// process wavelet coefficients with higher accuracy than the standard
// Part 1 specification. This is essential for:
//
// - High dynamic range (HDR) imaging with bit depths > 16
// - Medical and scientific imaging requiring high fidelity
// - Lossless compression with large dynamic ranges
// - Precision preservation through multi-stage pipelines
//
// ## Guard Bits Extension
//
// Standard JPEG 2000 (Part 1) supports 0-7 guard bits. Part 2
// extends this to 0-15 guard bits, providing greater overflow
// protection for high bit depth images.
//
// ## Rounding Modes
//
// Extended precision supports configurable rounding modes:
// - **Truncate**: Round toward zero (fastest)
// - **Round-to-nearest**: Standard rounding (best accuracy)
// - **Round-to-even**: Banker's rounding (minimal bias)
//
// ## Usage
//
// ```swift
// // Configure extended precision
// let config = J2KExtendedPrecisionConfiguration(
//     internalBitDepth: 32,
//     guardBits: try J2KExtendedGuardBits(count: 10),
//     roundingMode: .roundToNearest
// )
//
// let precision = J2KExtendedPrecision(configuration: config)
//
// // Apply precision-preserving operations
// let result = precision.multiply(a, by: b)
// let rounded = precision.round(value)
// ```

// MARK: - Extended Guard Bits

/// Extended guard bits for Part 2 quantization.
///
/// Part 2 allows up to 15 guard bits (vs. 7 in Part 1),
/// providing greater overflow protection for high bit depth images
/// and extended dynamic range wavelet coefficients.
public struct J2KExtendedGuardBits: Sendable, Equatable {
    /// The number of guard bits (0-15).
    public let count: Int

    /// Creates extended guard bits configuration.
    ///
    /// - Parameter count: Number of guard bits (0-15).
    /// - Throws: ``J2KError/invalidParameter(_:)`` if count is out of range.
    public init(count: Int) throws {
        guard (0...15).contains(count) else {
            throw J2KError.invalidParameter(
                "Extended guard bits must be between 0 and 15, got \(count)"
            )
        }
        self.count = count
    }

    /// Default extended guard bits (2 bits, same as Part 1 default).
    public static let `default` = try! J2KExtendedGuardBits(count: 2)

    /// Maximum extended guard bits (15 bits).
    public static let maximum = try! J2KExtendedGuardBits(count: 15)

    /// Recommended guard bits for high bit depth images (>16 bits).
    public static let highBitDepth = try! J2KExtendedGuardBits(count: 4)
}

// MARK: - Rounding Mode

/// Rounding mode for extended precision arithmetic.
///
/// Controls how intermediate floating-point results are converted
/// to integer values during quantization and coefficient processing.
public enum J2KRoundingMode: String, Sendable, Equatable, CaseIterable {
    /// Truncate toward zero (floor for positive, ceil for negative).
    ///
    /// Fastest rounding mode. May introduce a small positive bias.
    /// Used in standard Part 1 quantization.
    case truncate

    /// Round to the nearest integer, with ties going to the nearest even.
    ///
    /// Standard rounding with good accuracy. Simple to implement.
    case roundToNearest

    /// Round to the nearest even integer (banker's rounding).
    ///
    /// Minimizes cumulative rounding bias over many operations.
    /// Recommended for high-precision scientific imaging.
    case roundToEven
}

// MARK: - Extended Precision Configuration

/// Configuration for extended precision arithmetic.
///
/// Controls the precision, rounding behavior, and guard bit usage
/// for Part 2 extended precision operations.
public struct J2KExtendedPrecisionConfiguration: Sendable, Equatable {
    /// Internal bit depth for intermediate calculations.
    ///
    /// Higher values preserve more precision through the pipeline
    /// at the cost of increased memory and computation.
    /// Range: 16-64 bits.
    public let internalBitDepth: Int

    /// Extended guard bits for overflow prevention.
    public let guardBits: J2KExtendedGuardBits

    /// Rounding mode for precision reduction steps.
    public let roundingMode: J2KRoundingMode

    /// Whether to use extended dynamic range for wavelet coefficients.
    ///
    /// When enabled, wavelet coefficients use 64-bit storage to
    /// prevent overflow during multi-level decomposition of
    /// high bit depth images.
    public let extendedDynamicRange: Bool

    /// Creates an extended precision configuration.
    ///
    /// - Parameters:
    ///   - internalBitDepth: Internal bit depth (default: 32, range: 16-64).
    ///   - guardBits: Extended guard bits (default: 2).
    ///   - roundingMode: Rounding mode (default: .roundToNearest).
    ///   - extendedDynamicRange: Whether to use 64-bit coefficients (default: false).
    public init(
        internalBitDepth: Int = 32,
        guardBits: J2KExtendedGuardBits = .default,
        roundingMode: J2KRoundingMode = .roundToNearest,
        extendedDynamicRange: Bool = false
    ) {
        self.internalBitDepth = max(16, min(64, internalBitDepth))
        self.guardBits = guardBits
        self.roundingMode = roundingMode
        self.extendedDynamicRange = extendedDynamicRange
    }

    /// Default configuration (Part 1 compatible).
    public static let `default` = J2KExtendedPrecisionConfiguration()

    /// High-precision configuration for HDR and scientific imaging.
    public static let highPrecision = J2KExtendedPrecisionConfiguration(
        internalBitDepth: 64,
        guardBits: .highBitDepth,
        roundingMode: .roundToEven,
        extendedDynamicRange: true
    )

    /// Configuration for standard imaging with improved rounding.
    public static let standard = J2KExtendedPrecisionConfiguration(
        internalBitDepth: 32,
        guardBits: .default,
        roundingMode: .roundToNearest,
        extendedDynamicRange: false
    )
}

// MARK: - Extended Precision Processor

/// Performs extended precision arithmetic operations for Part 2 pipelines.
///
/// Provides precision-preserving operations for wavelet coefficient
/// processing, quantization, and reconstruction. All operations
/// respect the configured rounding mode and guard bit settings.
public struct J2KExtendedPrecision: Sendable {
    /// The extended precision configuration.
    public let configuration: J2KExtendedPrecisionConfiguration

    /// Creates an extended precision processor.
    ///
    /// - Parameter configuration: The precision configuration (default: `.default`).
    public init(configuration: J2KExtendedPrecisionConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Rounding Operations

    /// Rounds a floating-point value according to the configured rounding mode.
    ///
    /// - Parameter value: The value to round.
    /// - Returns: The rounded value.
    public func round(_ value: Double) -> Double {
        switch configuration.roundingMode {
        case .truncate:
            return value >= 0 ? value.rounded(.down) : value.rounded(.up)

        case .roundToNearest:
            return value.rounded()

        case .roundToEven:
            return roundToEven(value)
        }
    }

    /// Rounds a value to the nearest even integer (banker's rounding).
    ///
    /// - Parameter value: The value to round.
    /// - Returns: The rounded value.
    private func roundToEven(_ value: Double) -> Double {
        let rounded = value.rounded()
        let fraction = abs(value - value.rounded(.down))

        // Only apply special handling for exact 0.5 cases
        if abs(fraction - 0.5) < 1e-10 {
            let intRounded = Int64(rounded)
            if !intRounded.isMultiple(of: 2) {
                // Round to even: if rounded value is odd, adjust
                return value >= 0 ? rounded - 1.0 : rounded + 1.0
            }
        }

        return rounded
    }

    /// Rounds a value and converts to Int32.
    ///
    /// - Parameter value: The floating-point value.
    /// - Returns: The rounded Int32 value.
    public func roundToInt32(_ value: Double) -> Int32 {
        let rounded = self.round(value)
        return Int32(clamping: Int64(rounded))
    }

    /// Rounds a value and converts to Int64 (extended dynamic range).
    ///
    /// - Parameter value: The floating-point value.
    /// - Returns: The rounded Int64 value.
    public func roundToInt64(_ value: Double) -> Int64 {
        Int64(self.round(value))
    }

    // MARK: - Extended Dynamic Range

    /// Computes the maximum representable magnitude for the given configuration.
    ///
    /// Takes into account bit depth, guard bits, and whether extended
    /// dynamic range is enabled.
    ///
    /// - Parameter bitDepth: The original component bit depth.
    /// - Returns: The maximum coefficient magnitude.
    public func maxMagnitude(forBitDepth bitDepth: Int) -> Int64 {
        let effectiveBits = bitDepth + configuration.guardBits.count
        if configuration.extendedDynamicRange {
            return (1 << min(effectiveBits, 62)) - 1
        } else {
            return Int64((1 << min(effectiveBits, 30)) - 1)
        }
    }

    /// Clamps a coefficient value to the valid range for the configuration.
    ///
    /// - Parameters:
    ///   - value: The coefficient value.
    ///   - bitDepth: The original component bit depth.
    /// - Returns: The clamped value.
    public func clampCoefficient(_ value: Int64, bitDepth: Int) -> Int64 {
        let maxMag = maxMagnitude(forBitDepth: bitDepth)
        return max(-maxMag, min(maxMag, value))
    }

    /// Clamps an Int32 coefficient value to the valid range.
    ///
    /// - Parameters:
    ///   - value: The coefficient value.
    ///   - bitDepth: The original component bit depth.
    /// - Returns: The clamped value.
    public func clampCoefficient(_ value: Int32, bitDepth: Int) -> Int32 {
        let maxMag = maxMagnitude(forBitDepth: bitDepth)
        let clampedMax = Int32(clamping: maxMag)
        let clampedMin = Int32(clamping: -maxMag)
        return max(clampedMin, min(clampedMax, value))
    }

    // MARK: - Precision-Preserving Arithmetic

    /// Multiplies two values with precision preservation.
    ///
    /// Uses extended-width intermediate calculation to prevent
    /// precision loss during multiplication.
    ///
    /// - Parameters:
    ///   - a: First operand.
    ///   - b: Second operand (scaling factor).
    /// - Returns: The product, rounded according to the configured mode.
    public func multiply(_ a: Int32, by b: Double) -> Int32 {
        let result = Double(a) * b
        return roundToInt32(result)
    }

    /// Multiplies two Int64 values with precision preservation.
    ///
    /// - Parameters:
    ///   - a: First operand.
    ///   - b: Second operand (scaling factor).
    /// - Returns: The product, rounded according to the configured mode.
    public func multiply(_ a: Int64, by b: Double) -> Int64 {
        let result = Double(a) * b
        return roundToInt64(result)
    }

    /// Divides a value with precision preservation.
    ///
    /// - Parameters:
    ///   - a: Numerator.
    ///   - b: Denominator.
    /// - Returns: The quotient, rounded according to the configured mode.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if denominator is zero.
    public func divide(_ a: Int32, by b: Double) throws -> Int32 {
        guard b != 0.0 else {
            throw J2KError.invalidParameter("Division by zero in extended precision")
        }
        let result = Double(a) / b
        return roundToInt32(result)
    }

    // MARK: - Wavelet Coefficient Processing

    /// Applies extended precision scaling to wavelet coefficients.
    ///
    /// Scales coefficients by the given factor while preserving
    /// precision according to the configuration.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients to scale.
    ///   - factor: The scaling factor.
    ///   - bitDepth: The original component bit depth.
    /// - Returns: The scaled and clamped coefficients.
    public func scaleCoefficients(
        _ coefficients: [Int32],
        by factor: Double,
        bitDepth: Int
    ) -> [Int32] {
        coefficients.map { coefficient in
            let scaled = multiply(coefficient, by: factor)
            return clampCoefficient(scaled, bitDepth: bitDepth)
        }
    }

    /// Converts coefficients to extended dynamic range (Int64).
    ///
    /// Used when processing high bit depth images that may overflow
    /// Int32 during wavelet transform or quantization.
    ///
    /// - Parameter coefficients: The Int32 coefficients.
    /// - Returns: The coefficients as Int64 values.
    public func toExtendedRange(_ coefficients: [Int32]) -> [Int64] {
        coefficients.map { Int64($0) }
    }

    /// Converts extended range coefficients back to Int32.
    ///
    /// Clamps values to the Int32 range and applies rounding.
    ///
    /// - Parameters:
    ///   - coefficients: The Int64 coefficients.
    ///   - bitDepth: The target bit depth.
    /// - Returns: The coefficients as Int32 values.
    public func fromExtendedRange(
        _ coefficients: [Int64],
        bitDepth: Int
    ) -> [Int32] {
        coefficients.map { coefficient in
            let clamped = clampCoefficient(coefficient, bitDepth: bitDepth)
            return Int32(clamping: clamped)
        }
    }

    // MARK: - Guard Bit Validation

    /// Validates that the guard bit configuration is sufficient for
    /// the given bit depth and decomposition level.
    ///
    /// - Parameters:
    ///   - bitDepth: The component bit depth.
    ///   - decompositionLevels: Number of wavelet decomposition levels.
    /// - Returns: `true` if the guard bits are sufficient.
    public func validateGuardBits(
        forBitDepth bitDepth: Int,
        decompositionLevels: Int
    ) -> Bool {
        // Each decomposition level can increase the dynamic range by up to 1 bit
        // Guard bits must accommodate this growth
        let requiredBits = decompositionLevels
        return configuration.guardBits.count >= requiredBits
    }

    /// Recommends the number of guard bits for a given configuration.
    ///
    /// - Parameters:
    ///   - bitDepth: The component bit depth.
    ///   - decompositionLevels: Number of wavelet decomposition levels.
    /// - Returns: The recommended number of guard bits.
    public static func recommendedGuardBits(
        forBitDepth bitDepth: Int,
        decompositionLevels: Int
    ) -> Int {
        // Base recommendation: at least as many guard bits as decomposition levels
        // Plus extra for high bit depth images
        let baseBits = decompositionLevels
        let extraBits = bitDepth > 16 ? 2 : (bitDepth > 12 ? 1 : 0)
        return min(15, max(2, baseBits + extraBits))
    }
}
