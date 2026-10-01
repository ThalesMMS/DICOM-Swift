//
// J2KVisualMasking.swift
// J2KSwift
//
// J2KVisualMasking.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-19.
//

import Foundation

// # JPEG 2000 Visual Masking
//
// Implementation of advanced visual masking models for perceptual JPEG 2000 encoding.
//
// Visual masking describes how the visibility of distortions depends on local image
// characteristics. This module implements luminance-dependent masking, texture-based
// masking, and motion-adaptive masking to improve perceptual compression quality.
//
// ## Masking Models
//
// - **Luminance Masking**: Distortions are less visible in very dark or very bright regions
// - **Texture Masking**: Distortions are less visible in high-detail/textured regions
// - **Motion Masking**: Distortions are less visible in motion areas (for video)
//
// ## Usage
//
// ```swift
// let masking = J2KVisualMasking()
//
// // Calculate masking factor for a region
// let factor = masking.calculateMaskingFactor(
//     luminance: 128.0,
//     localVariance: 100.0,
//     motionVector: nil
// )
//
// // Apply to quantization step size
// let maskedStepSize = baseStepSize * factor
// ```

// MARK: - Visual Masking Configuration

/// Configuration parameters for visual masking.
public struct J2KVisualMaskingConfiguration: Sendable, Equatable {
    /// Enable luminance-dependent masking.
    public let enableLuminanceMasking: Bool

    /// Enable texture-based masking.
    public let enableTextureMasking: Bool

    /// Enable motion-adaptive masking (for video).
    public let enableMotionMasking: Bool

    /// Luminance masking strength (0.0 = none, 1.0 = full).
    public let luminanceStrength: Double

    /// Texture masking strength (0.0 = none, 1.0 = full).
    public let textureStrength: Double

    /// Motion masking strength (0.0 = none, 1.0 = full).
    public let motionStrength: Double

    /// Minimum masking factor to apply (prevents over-quantization).
    public let minimumFactor: Double

    /// Maximum masking factor to apply (prevents under-quantization).
    public let maximumFactor: Double

    /// Creates a new visual masking configuration.
    ///
    /// - Parameters:
    ///   - enableLuminanceMasking: Enable luminance-dependent masking (default: true).
    ///   - enableTextureMasking: Enable texture-based masking (default: true).
    ///   - enableMotionMasking: Enable motion-adaptive masking (default: false).
    ///   - luminanceStrength: Luminance masking strength (default: 0.5).
    ///   - textureStrength: Texture masking strength (default: 0.7).
    ///   - motionStrength: Motion masking strength (default: 0.6).
    ///   - minimumFactor: Minimum masking factor (default: 0.5).
    ///   - maximumFactor: Maximum masking factor (default: 3.0).
    public init(
        enableLuminanceMasking: Bool = true,
        enableTextureMasking: Bool = true,
        enableMotionMasking: Bool = false,
        luminanceStrength: Double = 0.5,
        textureStrength: Double = 0.7,
        motionStrength: Double = 0.6,
        minimumFactor: Double = 0.5,
        maximumFactor: Double = 3.0
    ) {
        self.enableLuminanceMasking = enableLuminanceMasking
        self.enableTextureMasking = enableTextureMasking
        self.enableMotionMasking = enableMotionMasking
        self.luminanceStrength = luminanceStrength
        self.textureStrength = textureStrength
        self.motionStrength = motionStrength
        self.minimumFactor = minimumFactor
        self.maximumFactor = maximumFactor
    }

    /// Default configuration with balanced settings.
    public static let `default` = J2KVisualMaskingConfiguration()

    /// Aggressive masking for high compression.
    public static let aggressive = J2KVisualMaskingConfiguration(
        luminanceStrength: 0.8,
        textureStrength: 0.9,
        minimumFactor: 0.3,
        maximumFactor: 4.0
    )

    /// Conservative masking for high quality.
    public static let conservative = J2KVisualMaskingConfiguration(
        luminanceStrength: 0.3,
        textureStrength: 0.5,
        minimumFactor: 0.7,
        maximumFactor: 2.0
    )
}

// MARK: - Motion Vector

/// Represents a motion vector for motion-adaptive masking.
public struct J2KMotionVector: Sendable, Equatable {
    /// Horizontal component of motion in pixels.
    public let dx: Double

    /// Vertical component of motion in pixels.
    public let dy: Double

    /// Creates a new motion vector.
    ///
    /// - Parameters:
    ///   - dx: Horizontal motion in pixels.
    ///   - dy: Vertical motion in pixels.
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    /// Magnitude of the motion vector.
    public var magnitude: Double {
        sqrt(dx * dx + dy * dy)
    }

    /// Zero motion vector.
    public static let zero = J2KMotionVector(dx: 0, dy: 0)
}

// MARK: - Visual Masking

/// Implements advanced visual masking for perceptual quantization.
public struct J2KVisualMasking: Sendable {
    /// Configuration parameters.
    public let configuration: J2KVisualMaskingConfiguration

    /// Creates a new visual masking instance.
    ///
    /// - Parameter configuration: The masking configuration parameters.
    public init(configuration: J2KVisualMaskingConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Main Masking Methods

    /// Calculates the overall masking factor for a region.
    ///
    /// Combines luminance, texture, and motion masking to produce a single
    /// multiplicative factor for adjusting quantization step sizes.
    ///
    /// Higher factors indicate regions where distortions are less visible
    /// (more quantization allowed).
    ///
    /// - Parameters:
    ///   - luminance: Mean luminance value in the region (0-255 scale).
    ///   - localVariance: Local variance indicating texture detail.
    ///   - motionVector: Optional motion vector for motion masking.
    /// - Returns: Masking factor multiplier (typically 0.5-3.0).
    public func calculateMaskingFactor(
        luminance: Double,
        localVariance: Double,
        motionVector: J2KMotionVector? = nil
    ) -> Double {
        var maskingFactor = 1.0

        // Apply luminance masking
        if configuration.enableLuminanceMasking {
            let lumFactor = luminanceMaskingFactor(luminance: luminance)
            maskingFactor *= (1.0 + configuration.luminanceStrength * (lumFactor - 1.0))
        }

        // Apply texture masking
        if configuration.enableTextureMasking {
            let texFactor = textureMaskingFactor(variance: localVariance)
            maskingFactor *= (1.0 + configuration.textureStrength * (texFactor - 1.0))
        }

        // Apply motion masking
        if configuration.enableMotionMasking, let motion = motionVector {
            let motFactor = motionMaskingFactor(motionVector: motion)
            maskingFactor *= (1.0 + configuration.motionStrength * (motFactor - 1.0))
        }

        // Clamp to configured bounds
        return min(
            configuration.maximumFactor,
            max(configuration.minimumFactor, maskingFactor)
        )
    }

    /// Calculates masking factors for an image region.
    ///
    /// Analyzes an image region to compute masking factors for each position.
    ///
    /// - Parameters:
    ///   - samples: Sample values for the region.
    ///   - width: Width of the region.
    ///   - height: Height of the region.
    ///   - bitDepth: Bit depth of the samples.
    ///   - motionField: Optional motion vector field for motion masking.
    /// - Returns: Array of masking factors for each position.
    public func calculateRegionMaskingFactors(
        samples: [Int32],
        width: Int,
        height: Int,
        bitDepth: Int,
        motionField: [[J2KMotionVector]]? = nil
    ) -> [Double] {
        guard samples.count == width * height else {
            return Array(repeating: 1.0, count: width * height)
        }

        var maskingFactors = [Double](repeating: 1.0, count: width * height)

        // Window size for local statistics
        let windowSize = 8

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x

                // Calculate local statistics
                let (meanLum, variance) = localStatistics(
                    samples: samples,
                    width: width,
                    height: height,
                    x: x,
                    y: y,
                    windowSize: windowSize
                )

                // Get motion vector if available
                let motion: J2KMotionVector?
                if let field = motionField, y < field.count, x < field[y].count {
                    motion = field[y][x]
                } else {
                    motion = nil
                }

                // Calculate masking factor
                maskingFactors[idx] = calculateMaskingFactor(
                    luminance: meanLum,
                    localVariance: variance,
                    motionVector: motion
                )
            }
        }

        return maskingFactors
    }

    // MARK: - Individual Masking Components

    /// Calculates luminance-dependent masking factor.
    ///
    /// Based on the Weber-Fechner law: distortions are less visible in very dark
    /// or very bright regions. The masking effect follows a U-shaped curve.
    ///
    /// - Parameter luminance: Mean luminance value (0-255 scale).
    /// - Returns: Masking factor (>1.0 = more masking, <1.0 = less masking).
    public func luminanceMaskingFactor(luminance: Double) -> Double {
        // Normalise to 0-1 range
        let normLum = luminance / 255.0

        // U-shaped curve: masking is strongest at extremes
        // Minimum masking around mid-gray (0.5)
        let deviation = abs(normLum - 0.5)

        // Luminance masking increases in dark and bright regions
        // Using a quadratic function for smooth behavior
        let maskingEffect = 1.0 + 2.0 * deviation * deviation

        return maskingEffect
    }

    /// Calculates texture-based masking factor.
    ///
    /// Distortions are less visible in highly textured regions with high variance.
    /// This is based on the principle that the human visual system has reduced
    /// sensitivity in regions with high spatial activity.
    ///
    /// - Parameter variance: Local variance of the region.
    /// - Returns: Masking factor (>1.0 = more masking, <1.0 = less masking).
    public func textureMaskingFactor(variance: Double) -> Double {
        // Normalise variance to a reasonable range
        // Typical variance in natural images: 0-5000
        let normVariance = min(variance / 5000.0, 1.0)

        // Texture masking increases with variance
        // Using logarithmic curve for natural behavior
        let maskingEffect = 1.0 + 1.5 * log1p(normVariance * 10.0) / log1p(10.0)

        return maskingEffect
    }

    /// Calculates motion-adaptive masking factor.
    ///
    /// Distortions are less visible in regions with motion due to temporal masking.
    /// This is particularly useful for video encoding.
    ///
    /// - Parameter motionVector: The motion vector for the region.
    /// - Returns: Masking factor (>1.0 = more masking, <1.0 = less masking).
    public func motionMaskingFactor(motionVector: J2KMotionVector) -> Double {
        let motionMagnitude = motionVector.magnitude

        // Motion masking increases with motion magnitude
        // Saturates at high motion to prevent excessive masking
        let normMotion = min(motionMagnitude / 20.0, 1.0)

        // Using tanh for smooth saturation
        let maskingEffect = 1.0 + 1.0 * tanh(normMotion * 2.0)

        return maskingEffect
    }

    // MARK: - Private Helper Methods

    /// Calculates local statistics for a region.
    private func localStatistics(
        samples: [Int32],
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        windowSize: Int
    ) -> (mean: Double, variance: Double) {
        let halfWindow = windowSize / 2
        var sum = 0.0
        var sumSquared = 0.0
        var count = 0

        for dy in -halfWindow..<halfWindow {
            for dx in -halfWindow..<halfWindow {
                let nx = x + dx
                let ny = y + dy

                // Check bounds
                guard nx >= 0 && nx < width && ny >= 0 && ny < height else {
                    continue
                }

                let idx = ny * width + nx
                guard idx < samples.count else { continue }

                let value = Double(samples[idx])
                sum += value
                sumSquared += value * value
                count += 1
            }
        }

        guard count > 0 else {
            return (0.0, 0.0)
        }

        let mean = sum / Double(count)
        let variance = (sumSquared / Double(count)) - (mean * mean)

        return (mean, max(0.0, variance))
    }
}

// MARK: - Just-Noticeable Difference (JND)

/// Just-noticeable difference model for perceptual quantization.
public struct J2KJNDModel: Sendable {
    /// Calculates the JND threshold for a given region.
    ///
    /// The JND represents the minimum distortion that is perceptible to the human eye.
    /// It depends on local luminance, texture, and viewing conditions.
    ///
    /// - Parameters:
    ///   - luminance: Mean luminance value (0-255 scale).
    ///   - localVariance: Local variance indicating texture.
    ///   - viewingDistance: Viewing distance in centimeters.
    /// - Returns: JND threshold value.
    public func jndThreshold(
        luminance: Double,
        localVariance: Double,
        viewingDistance: Double = 60.0
    ) -> Double {
        // Base JND from luminance adaptation
        let lumJND = luminanceJND(luminance: luminance)

        // Texture masking component
        let textureFactor = 1.0 + sqrt(localVariance / 100.0)

        // Viewing distance factor (closer viewing = lower JND threshold)
        let distanceFactor = sqrt(viewingDistance / 60.0)

        return lumJND * textureFactor * distanceFactor
    }

    /// Calculates luminance-dependent JND.
    private func luminanceJND(luminance: Double) -> Double {
        // Weber-Fechner law approximation
        // JND increases with luminance but with decreasing sensitivity
        let normLum = max(1.0, luminance)

        // Base threshold plus luminance-dependent component
        let baseThreshold = 2.0
        let lumComponent = 0.05 * sqrt(normLum)

        return baseThreshold + lumComponent
    }
}

// MARK: - Perceptual Quantization Integration

extension J2KVisualMasking {
    /// Calculates perceptually masked quantization step size.
    ///
    /// Combines visual masking with frequency weighting to produce an
    /// optimised quantization step size for perceptual quality.
    ///
    /// - Parameters:
    ///   - baseStepSize: The base quantization step size.
    ///   - luminance: Mean luminance of the region.
    ///   - localVariance: Local variance of the region.
    ///   - motionVector: Optional motion vector.
    /// - Returns: Perceptually masked quantization step size.
    public func perceptualStepSize(
        baseStepSize: Double,
        luminance: Double,
        localVariance: Double,
        motionVector: J2KMotionVector? = nil
    ) -> Double {
        let maskingFactor = calculateMaskingFactor(
            luminance: luminance,
            localVariance: localVariance,
            motionVector: motionVector
        )

        return baseStepSize * maskingFactor
    }
}
