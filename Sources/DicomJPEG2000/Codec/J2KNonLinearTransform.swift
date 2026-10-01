//
// J2KNonLinearTransform.swift
// J2KSwift
//
// J2KNonLinearTransform.swift
// J2KSwift
//
// Implementation of ISO/IEC 15444-2 Non-Linear Point Transforms for JPEG 2000 Part 2.
//

import Foundation

// # JPEG 2000 Part 2 Non-Linear Point Transforms (NLT)
//
// Implementation of non-linear point transforms as defined in ISO/IEC 15444-2.
//
// Non-linear point transforms improve compression efficiency for images with
// non-linear characteristics by linearizing the data before wavelet transform
// and quantization. This is particularly effective for HDR imaging, gamma-encoded
// images, logarithmically-scaled scientific data, and perceptually-encoded content.
//
// ## How It Works
//
// The NLT process consists of:
// 1. **Forward Transform**: Apply non-linear function to linearize/decorrelate data
// 2. **Encoding**: Process linearized data through standard JPEG 2000 pipeline
// 3. **Signaling**: Store transform parameters in NLT marker segments
// 4. **Inverse Transform**: Apply inverse function during decoding to restore original values
//
// ## Usage
//
// ```swift
// // Encoder path: apply forward transform
// let nlt = J2KNonLinearTransform()
// let result = try nlt.applyForward(
//     componentData: componentData,
//     transform: .gamma(2.2),  // Linearize gamma-encoded data
//     bitDepth: 10
// )
//
// // Decoder path: apply inverse transform
// let restored = try nlt.applyInverse(
//     componentData: encodedData,
//     transform: .gamma(2.2),
//     bitDepth: 10
// )
// ```

// MARK: - NLT Configuration

/// Configuration for non-linear point transform operations.
///
/// Controls how NLT is computed and applied during encoding and decoding.
public struct J2KNLTConfiguration: Sendable, Equatable {
    /// Whether non-linear point transforms are enabled.
    public let enabled: Bool

    /// Per-component transform specifications.
    ///
    /// If nil, no transforms are applied. If specified, must contain
    /// an entry for each component or be empty (no transforms).
    public let componentTransforms: [J2KNLTComponentTransform]?

    /// Whether to optimise transform parameters automatically.
    ///
    /// When enabled, the encoder analyses component statistics and
    /// may adjust transform parameters for better compression.
    public let autoOptimize: Bool

    /// Creates an NLT configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable NLT (default: true).
    ///   - componentTransforms: Per-component transforms (default: nil).
    ///   - autoOptimize: Whether to auto-optimise parameters (default: false).
    public init(
        enabled: Bool = true,
        componentTransforms: [J2KNLTComponentTransform]? = nil,
        autoOptimize: Bool = false
    ) {
        self.enabled = enabled
        self.componentTransforms = componentTransforms
        self.autoOptimize = autoOptimize
    }

    /// Default configuration with NLT disabled.
    public static let `default` = J2KNLTConfiguration(enabled: false)

    /// Configuration with NLT disabled.
    public static let disabled = J2KNLTConfiguration(enabled: false)

    /// Configuration with automatic optimisation.
    public static let autoOptimized = J2KNLTConfiguration(
        enabled: true,
        componentTransforms: nil,
        autoOptimize: true
    )
}

// MARK: - Component Transform

/// Specifies a non-linear transform for a single component.
public struct J2KNLTComponentTransform: Sendable, Equatable {
    /// The component index (0-based).
    public let componentIndex: Int

    /// The transform type to apply.
    public let transformType: J2KNLTTransformType

    /// Creates a component transform.
    ///
    /// - Parameters:
    ///   - componentIndex: The component index.
    ///   - transformType: The transform type.
    public init(componentIndex: Int, transformType: J2KNLTTransformType) {
        self.componentIndex = componentIndex
        self.transformType = transformType
    }
}

// MARK: - Transform Type

/// Type of non-linear point transform.
///
/// Each transform type has a forward and inverse operation.
/// The forward operation is applied before encoding, and the
/// inverse operation is applied during decoding.
public enum J2KNLTTransformType: Sendable, Equatable {
    /// Identity transform (no change).
    ///
    /// Forward: y = x
    /// Inverse: x = y
    case identity

    /// Gamma correction transform.
    ///
    /// Forward (linearization): y = x^gamma
    /// Inverse (delinearization): x = y^(1/gamma)
    ///
    /// - Parameter gamma: The gamma value (> 0). Common values:
    ///   - 2.2: sRGB gamma
    ///   - 2.4: Rec.709 gamma
    ///   - 2.6: DCI-P3 gamma
    case gamma(Double)

    /// Logarithmic transform (base-e).
    ///
    /// Forward: y = ln(x + 1)
    /// Inverse: x = exp(y) - 1
    ///
    /// Useful for logarithmically-scaled scientific data.
    case logarithmic

    /// Base-10 logarithmic transform.
    ///
    /// Forward: y = log10(x + 1)
    /// Inverse: x = 10^y - 1
    case logarithmic10

    /// Exponential transform (base-e).
    ///
    /// Forward: y = exp(x) - 1
    /// Inverse: x = ln(y + 1)
    case exponential

    /// Perceptual Quantizer (PQ) for HDR content (SMPTE ST 2084).
    ///
    /// Forward: Linearize PQ-encoded values
    /// Inverse: Apply PQ encoding
    ///
    /// Used for HDR10 content.
    case perceptualQuantizer

    /// Hybrid Log-Gamma (HLG) for HDR content (ITU-R BT.2100).
    ///
    /// Forward: Linearize HLG-encoded values
    /// Inverse: Apply HLG encoding
    ///
    /// Used for HDR broadcast content.
    case hybridLogGamma

    /// Lookup table (LUT) based transform.
    ///
    /// Forward and inverse: Use provided lookup tables
    ///
    /// - Parameters:
    ///   - forwardLUT: Forward transform lookup table
    ///   - inverseLUT: Inverse transform lookup table
    ///   - interpolation: Whether to use linear interpolation
    case lookupTable(forwardLUT: [Double], inverseLUT: [Double], interpolation: Bool)

    /// Piecewise linear transform.
    ///
    /// Forward and inverse: Use piecewise linear segments
    ///
    /// - Parameters:
    ///   - breakpoints: X-coordinates of breakpoints
    ///   - values: Y-coordinates at breakpoints
    case piecewiseLinear(breakpoints: [Double], values: [Double])

    /// Custom parametric transform.
    ///
    /// - Parameters:
    ///   - parameters: Transform-specific parameters
    ///   - function: Custom function type identifier
    case custom(parameters: [Double], function: String)
}

// MARK: - Transform Result

/// Result of applying a non-linear point transform.
public struct J2KNLTResult: Sendable {
    /// The transformed component data.
    public let transformedData: [Int32]

    /// The transform that was applied.
    public let transform: J2KNLTComponentTransform

    /// Statistics about the transformation.
    public let statistics: J2KNLTStatistics
}

/// Statistics about a non-linear transform operation.
public struct J2KNLTStatistics: Sendable, Equatable {
    /// Input data range (min, max).
    public let inputRange: (min: Double, max: Double)

    /// Output data range (min, max).
    public let outputRange: (min: Double, max: Double)

    /// Whether any values were clipped during transformation.
    public let clipped: Bool

    /// Number of samples processed.
    public let sampleCount: Int

    public init(
        inputRange: (min: Double, max: Double),
        outputRange: (min: Double, max: Double),
        clipped: Bool,
        sampleCount: Int
    ) {
        self.inputRange = inputRange
        self.outputRange = outputRange
        self.clipped = clipped
        self.sampleCount = sampleCount
    }
}

extension J2KNLTStatistics {
    public static func == (lhs: J2KNLTStatistics, rhs: J2KNLTStatistics) -> Bool {
        lhs.inputRange.min == rhs.inputRange.min &&
        lhs.inputRange.max == rhs.inputRange.max &&
        lhs.outputRange.min == rhs.outputRange.min &&
        lhs.outputRange.max == rhs.outputRange.max &&
        lhs.clipped == rhs.clipped &&
        lhs.sampleCount == rhs.sampleCount
    }
}

// MARK: - Non-Linear Transform Implementation

/// Non-linear point transform implementation.
///
/// Provides forward and inverse non-linear transformations for
/// JPEG 2000 Part 2 compression.
public struct J2KNonLinearTransform: Sendable {
    /// Creates a non-linear transform processor.
    public init() {}

    // MARK: - Forward Transform

    /// Applies forward non-linear transform to component data.
    ///
    /// The forward transform linearizes or decorrelates the data
    /// before encoding.
    ///
    /// - Parameters:
    ///   - componentData: The input component data.
    ///   - transform: The component transform to apply.
    ///   - bitDepth: The bit depth of the component.
    ///   - signed: Whether the component uses signed representation.
    /// - Returns: The transformed data and statistics.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    public func applyForward(
        componentData: [Int32],
        transform: J2KNLTComponentTransform,
        bitDepth: Int,
        signed: Bool = false
    ) throws -> J2KNLTResult {
        guard bitDepth > 0 && bitDepth <= 32 else {
            throw J2KError.invalidParameter("Invalid bit depth: \(bitDepth)")
        }

        guard !componentData.isEmpty else {
            throw J2KError.invalidParameter("Component data is empty")
        }

        let maxValue = signed ? (1 << (bitDepth - 1)) - 1 : (1 << bitDepth) - 1
        let minValue = signed ? -(1 << (bitDepth - 1)) : 0

        var transformedData = [Int32]()
        transformedData.reserveCapacity(componentData.count)

        var inputMin = Double.infinity
        var inputMax = -Double.infinity
        var outputMin = Double.infinity
        var outputMax = -Double.infinity
        var clipped = false

        for value in componentData {
            let normalizedInput = Double(value)
            inputMin = min(inputMin, normalizedInput)
            inputMax = max(inputMax, normalizedInput)

            // Apply forward transform
            let transformedValue = try applyForwardTransform(
                value: normalizedInput,
                type: transform.transformType,
                minValue: Double(minValue),
                maxValue: Double(maxValue)
            )

            outputMin = min(outputMin, transformedValue)
            outputMax = max(outputMax, transformedValue)

            // Clamp to valid range
            let clampedValue = transformedValue.clamped(to: Double(minValue)...Double(maxValue))
            if abs(clampedValue - transformedValue) > 0.001 {
                clipped = true
            }

            transformedData.append(j2kClampedInt32(clampedValue))
        }

        let statistics = J2KNLTStatistics(
            inputRange: (min: inputMin, max: inputMax),
            outputRange: (min: outputMin, max: outputMax),
            clipped: clipped,
            sampleCount: componentData.count
        )

        return J2KNLTResult(
            transformedData: transformedData,
            transform: transform,
            statistics: statistics
        )
    }

    // MARK: - Inverse Transform

    /// Applies inverse non-linear transform to component data.
    ///
    /// The inverse transform restores the original non-linear
    /// representation after decoding.
    ///
    /// - Parameters:
    ///   - componentData: The decoded component data.
    ///   - transform: The component transform to invert.
    ///   - bitDepth: The bit depth of the component.
    ///   - signed: Whether the component uses signed representation.
    /// - Returns: The restored data and statistics.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    public func applyInverse(
        componentData: [Int32],
        transform: J2KNLTComponentTransform,
        bitDepth: Int,
        signed: Bool = false
    ) throws -> J2KNLTResult {
        guard bitDepth > 0 && bitDepth <= 32 else {
            throw J2KError.invalidParameter("Invalid bit depth: \(bitDepth)")
        }

        guard !componentData.isEmpty else {
            throw J2KError.invalidParameter("Component data is empty")
        }

        let maxValue = signed ? (1 << (bitDepth - 1)) - 1 : (1 << bitDepth) - 1
        let minValue = signed ? -(1 << (bitDepth - 1)) : 0

        var restoredData = [Int32]()
        restoredData.reserveCapacity(componentData.count)

        var inputMin = Double.infinity
        var inputMax = -Double.infinity
        var outputMin = Double.infinity
        var outputMax = -Double.infinity
        var clipped = false

        for value in componentData {
            let normalizedInput = Double(value)
            inputMin = min(inputMin, normalizedInput)
            inputMax = max(inputMax, normalizedInput)

            // Apply inverse transform
            let restoredValue = try applyInverseTransform(
                value: normalizedInput,
                type: transform.transformType,
                minValue: Double(minValue),
                maxValue: Double(maxValue)
            )

            outputMin = min(outputMin, restoredValue)
            outputMax = max(outputMax, restoredValue)

            // Clamp to valid range
            let clampedValue = restoredValue.clamped(to: Double(minValue)...Double(maxValue))
            if abs(clampedValue - restoredValue) > 0.001 {
                clipped = true
            }

            restoredData.append(j2kClampedInt32(clampedValue))
        }

        let statistics = J2KNLTStatistics(
            inputRange: (min: inputMin, max: inputMax),
            outputRange: (min: outputMin, max: outputMax),
            clipped: clipped,
            sampleCount: componentData.count
        )

        return J2KNLTResult(
            transformedData: restoredData,
            transform: transform,
            statistics: statistics
        )
    }

    // MARK: - Transform Implementation

    /// Applies forward transform function.
    private func applyForwardTransform(
        value: Double,
        type: J2KNLTTransformType,
        minValue: Double,
        maxValue: Double
    ) throws -> Double {
        switch type {
        case .identity:
            return value

        case .gamma(let gamma):
            guard gamma > 0 else {
                throw J2KError.invalidParameter("Gamma must be positive: \(gamma)")
            }
            // Normalise to [0, 1], apply gamma, scale back
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = pow(normalized, gamma)
            return transformed * (maxValue - minValue) + minValue

        case .logarithmic:
            // ln(x + 1) with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = log(normalized + 1.0) / log(2.0)  // Normalize to [0, 1]
            return transformed * (maxValue - minValue) + minValue

        case .logarithmic10:
            // log10(x + 1) with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = log10(normalized + 1.0) / log10(2.0)  // Normalize to [0, 1]
            return transformed * (maxValue - minValue) + minValue

        case .exponential:
            // exp(x) - 1 with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = (exp(normalized) - 1.0) / (exp(1.0) - 1.0)  // Normalize to [0, 1]
            return transformed * (maxValue - minValue) + minValue

        case .perceptualQuantizer:
            return try applyPQForward(value: value, minValue: minValue, maxValue: maxValue)

        case .hybridLogGamma:
            return try applyHLGForward(value: value, minValue: minValue, maxValue: maxValue)

        case let .lookupTable(forwardLUT, _, interpolation):
            return applyLUT(
                value: value,
                lut: forwardLUT,
                minValue: minValue,
                maxValue: maxValue,
                interpolation: interpolation
            )

        case let .piecewiseLinear(breakpoints, values):
            return applyPiecewiseLinear(
                value: value,
                breakpoints: breakpoints,
                values: values,
                minValue: minValue,
                maxValue: maxValue
            )

        case .custom:
            throw J2KError.invalidParameter("Custom transforms must be implemented by caller")
        }
    }

    /// Applies inverse transform function.
    private func applyInverseTransform(
        value: Double,
        type: J2KNLTTransformType,
        minValue: Double,
        maxValue: Double
    ) throws -> Double {
        switch type {
        case .identity:
            return value

        case .gamma(let gamma):
            guard gamma > 0 else {
                throw J2KError.invalidParameter("Gamma must be positive: \(gamma)")
            }
            // Normalise to [0, 1], apply inverse gamma, scale back
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = pow(normalized, 1.0 / gamma)
            return transformed * (maxValue - minValue) + minValue

        case .logarithmic:
            // exp(y) - 1 with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = exp(normalized * log(2.0)) - 1.0
            return transformed * (maxValue - minValue) + minValue

        case .logarithmic10:
            // 10^y - 1 with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = pow(10.0, normalized * log10(2.0)) - 1.0
            return transformed * (maxValue - minValue) + minValue

        case .exponential:
            // ln(x + 1) with normalisation
            let normalized = (value - minValue) / (maxValue - minValue)
            let transformed = log(normalized * (exp(1.0) - 1.0) + 1.0)
            return transformed * (maxValue - minValue) + minValue

        case .perceptualQuantizer:
            return try applyPQInverse(value: value, minValue: minValue, maxValue: maxValue)

        case .hybridLogGamma:
            return try applyHLGInverse(value: value, minValue: minValue, maxValue: maxValue)

        case let .lookupTable(_, inverseLUT, interpolation):
            return applyLUT(
                value: value,
                lut: inverseLUT,
                minValue: minValue,
                maxValue: maxValue,
                interpolation: interpolation
            )

        case let .piecewiseLinear(breakpoints, values):
            // For inverse, swap breakpoints and values
            return applyPiecewiseLinear(
                value: value,
                breakpoints: values,
                values: breakpoints,
                minValue: minValue,
                maxValue: maxValue
            )

        case .custom:
            throw J2KError.invalidParameter("Custom transforms must be implemented by caller")
        }
    }

    // MARK: - HDR Transform Functions

    /// Applies PQ (SMPTE ST 2084) forward transform.
    private func applyPQForward(value: Double, minValue: Double, maxValue: Double) throws -> Double {
        // Normalise to [0, 1]
        let normalized = (value - minValue) / (maxValue - minValue)

        // PQ constants
        let m1 = 0.1593017578125  // 2610/16384
        let m2 = 78.84375          // 2523/32 + 128
        let c1 = 0.8359375         // 3424/4096
        let c2 = 18.8515625        // 2413/128 + 2392/128
        let c3 = 18.6875           // 2392/128

        // Apply PQ EOTF (forward = linearize)
        let y = pow(normalized, 1.0 / m2)
        let numerator = max(y - c1, 0.0)
        let denominator = c2 - c3 * y
        let linear = pow(numerator / denominator, 1.0 / m1)

        return linear * (maxValue - minValue) + minValue
    }

    /// Applies PQ (SMPTE ST 2084) inverse transform.
    private func applyPQInverse(value: Double, minValue: Double, maxValue: Double) throws -> Double {
        // Normalise to [0, 1]
        let normalized = (value - minValue) / (maxValue - minValue)

        // PQ constants
        let m1 = 0.1593017578125
        let m2 = 78.84375
        let c1 = 0.8359375
        let c2 = 18.8515625
        let c3 = 18.6875

        // Apply PQ OETF (inverse = apply encoding)
        let y = pow(normalized, m1)
        let numerator = c1 + c2 * y
        let denominator = 1.0 + c3 * y
        let encoded = pow(numerator / denominator, m2)

        return encoded * (maxValue - minValue) + minValue
    }

    /// Applies HLG (Hybrid Log-Gamma) forward transform.
    private func applyHLGForward(value: Double, minValue: Double, maxValue: Double) throws -> Double {
        // Normalise to [0, 1]
        let normalized = (value - minValue) / (maxValue - minValue)

        // HLG constants
        let a = 0.17883277
        let b = 0.28466892
        let c = 0.55991073

        // Apply HLG OETF inverse (forward = linearize)
        let linear: Double
        if normalized <= 0.5 {
            linear = normalized * normalized / 3.0
        } else {
            linear = (exp((normalized - c) / a) + b) / 12.0
        }

        return linear * (maxValue - minValue) + minValue
    }

    /// Applies HLG (Hybrid Log-Gamma) inverse transform.
    private func applyHLGInverse(value: Double, minValue: Double, maxValue: Double) throws -> Double {
        // Normalise to [0, 1]
        let normalized = (value - minValue) / (maxValue - minValue)

        // HLG constants
        let a = 0.17883277
        let b = 0.28466892
        let c = 0.55991073

        // Apply HLG OETF (inverse = apply encoding)
        let encoded: Double
        if normalized <= 1.0 / 12.0 {
            encoded = sqrt(3.0 * normalized)
        } else {
            encoded = a * log(12.0 * normalized - b) + c
        }

        return encoded * (maxValue - minValue) + minValue
    }

    // MARK: - LUT Application

    /// Applies lookup table transform.
    private func applyLUT(
        value: Double,
        lut: [Double],
        minValue: Double,
        maxValue: Double,
        interpolation: Bool
    ) -> Double {
        guard !lut.isEmpty else {
            return value
        }

        // Normalise value to LUT index range [0, lut.count - 1]
        let normalized = (value - minValue) / (maxValue - minValue)
        let index = normalized * Double(lut.count - 1)

        if !interpolation {
            // Nearest neighbor
            let i = Int(index.rounded())
            return lut[i.clamped(to: 0...(lut.count - 1))]
        } else {
            // Linear interpolation
            let i0 = Int(floor(index))
            let i1 = min(i0 + 1, lut.count - 1)
            let fraction = index - Double(i0)

            let v0 = lut[i0.clamped(to: 0...(lut.count - 1))]
            let v1 = lut[i1]

            return v0 + fraction * (v1 - v0)
        }
    }

    /// Applies piecewise linear transform.
    private func applyPiecewiseLinear(
        value: Double,
        breakpoints: [Double],
        values: [Double],
        minValue: Double,
        maxValue: Double
    ) -> Double {
        guard breakpoints.count == values.count, !breakpoints.isEmpty else {
            return value
        }

        let normalized = (value - minValue) / (maxValue - minValue)

        // Find the segment
        if normalized <= breakpoints[0] {
            return values[0] * (maxValue - minValue) + minValue
        }

        for i in 0..<(breakpoints.count - 1) where normalized <= breakpoints[i + 1] {
            // Linear interpolation within segment
            let t = (normalized - breakpoints[i]) / (breakpoints[i + 1] - breakpoints[i])
            let interpolated = values[i] + t * (values[i + 1] - values[i])
            return interpolated * (maxValue - minValue) + minValue
        }

        // Beyond last breakpoint
        return values[breakpoints.count - 1] * (maxValue - minValue) + minValue
    }
}

// MARK: - Utility Extensions

extension Double {
    /// Clamps the value to the specified range.
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Int {
    /// Clamps the value to the specified range.
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
