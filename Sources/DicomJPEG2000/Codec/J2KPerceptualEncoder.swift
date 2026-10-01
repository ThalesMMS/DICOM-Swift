//
// J2KPerceptualEncoder.swift
// J2KSwift
//
// J2KPerceptualEncoder.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-19.
//

import Foundation

// # JPEG 2000 Perceptual Encoder
//
// Implementation of perceptual encoding modes for JPEG 2000.
//
// The perceptual encoder combines visual masking, frequency weighting, and
// quality metrics to optimise compression for perceptual quality rather than
// mathematical metrics like MSE or PSNR.
//
// ## Features
//
// - CSF-based frequency weighting
// - Luminance and texture-based masking
// - Motion-adaptive encoding (for video)
// - Quality-based rate-distortion optimisation
// - SSIM/MS-SSIM quality targeting
//
// ## Usage
//
// ```swift
// let config = J2KPerceptualEncodingConfiguration(
//     targetQuality: .ssim(0.95),
//     enableVisualMasking: true,
//     enableFrequencyWeighting: true
// )
//
// let encoder = J2KPerceptualEncoder(configuration: config)
// let encoded = try encoder.encode(image: image)
// ```

// MARK: - Quality Target

/// Target quality metric for perceptual encoding.
public enum J2KQualityTarget: Sendable, Equatable {
    /// Target PSNR in dB.
    case psnr(Double)

    /// Target SSIM value (0-1).
    case ssim(Double)

    /// Target MS-SSIM value (0-1).
    case msssim(Double)

    /// Target bitrate in bits per pixel.
    case bitrate(Double)
}

// MARK: - Perceptual Encoding Configuration

/// Configuration for perceptual encoding.
public struct J2KPerceptualEncodingConfiguration: Sendable, Equatable {
    /// Quality target for encoding.
    public let targetQuality: J2KQualityTarget

    /// Enable visual masking.
    public let enableVisualMasking: Bool

    /// Enable frequency weighting.
    public let enableFrequencyWeighting: Bool

    /// Visual masking configuration.
    public let maskingConfiguration: J2KVisualMaskingConfiguration

    /// Visual weighting configuration.
    public let weightingConfiguration: J2KVisualWeightingConfiguration

    /// Maximum number of encoding iterations for quality targeting.
    public let maxIterations: Int

    /// Quality tolerance for iterative encoding.
    public let qualityTolerance: Double

    /// Creates a new perceptual encoding configuration.
    ///
    /// - Parameters:
    ///   - targetQuality: The quality target for encoding.
    ///   - enableVisualMasking: Enable visual masking (default: true).
    ///   - enableFrequencyWeighting: Enable frequency weighting (default: true).
    ///   - maskingConfiguration: Visual masking configuration.
    ///   - weightingConfiguration: Visual weighting configuration.
    ///   - maxIterations: Maximum encoding iterations (default: 3).
    ///   - qualityTolerance: Quality tolerance (default: 0.01).
    public init(
        targetQuality: J2KQualityTarget,
        enableVisualMasking: Bool = true,
        enableFrequencyWeighting: Bool = true,
        maskingConfiguration: J2KVisualMaskingConfiguration = .default,
        weightingConfiguration: J2KVisualWeightingConfiguration = .default,
        maxIterations: Int = 3,
        qualityTolerance: Double = 0.01
    ) {
        self.targetQuality = targetQuality
        self.enableVisualMasking = enableVisualMasking
        self.enableFrequencyWeighting = enableFrequencyWeighting
        self.maskingConfiguration = maskingConfiguration
        self.weightingConfiguration = weightingConfiguration
        self.maxIterations = maxIterations
        self.qualityTolerance = qualityTolerance
    }

    /// Default configuration targeting SSIM 0.95.
    public static let `default` = J2KPerceptualEncodingConfiguration(
        targetQuality: .ssim(0.95)
    )

    /// High quality configuration targeting SSIM 0.98.
    public static let highQuality = J2KPerceptualEncodingConfiguration(
        targetQuality: .ssim(0.98),
        maskingConfiguration: .conservative
    )

    /// Balanced configuration targeting MS-SSIM 0.95.
    public static let balanced = J2KPerceptualEncodingConfiguration(
        targetQuality: .msssim(0.95)
    )

    /// High compression configuration targeting SSIM 0.90.
    public static let highCompression = J2KPerceptualEncodingConfiguration(
        targetQuality: .ssim(0.90),
        maskingConfiguration: .aggressive
    )
}

// MARK: - Perceptual Encoding Result

/// Result of perceptual encoding.
public struct J2KPerceptualEncodingResult: Sendable {
    /// The encoded data.
    public let data: Data

    /// Achieved quality metric.
    public let achievedQuality: J2KQualityMetricResult

    /// Number of encoding iterations performed.
    public let iterations: Int

    /// Final bitrate in bits per pixel.
    public let bitrate: Double

    /// Creates a new perceptual encoding result.
    ///
    /// - Parameters:
    ///   - data: The encoded data.
    ///   - achievedQuality: The achieved quality metric.
    ///   - iterations: Number of iterations performed.
    ///   - bitrate: Final bitrate in bits per pixel.
    public init(
        data: Data,
        achievedQuality: J2KQualityMetricResult,
        iterations: Int,
        bitrate: Double
    ) {
        self.data = data
        self.achievedQuality = achievedQuality
        self.iterations = iterations
        self.bitrate = bitrate
    }
}

// MARK: - Perceptual Encoder

/// Perceptual encoder for JPEG 2000.
public struct J2KPerceptualEncoder: Sendable {
    /// Configuration for perceptual encoding.
    public let configuration: J2KPerceptualEncodingConfiguration

    /// Visual masking instance.
    private let visualMasking: J2KVisualMasking

    /// Visual weighting instance.
    private let visualWeighting: J2KVisualWeighting

    /// Quality metrics instance.
    private let qualityMetrics: J2KQualityMetrics

    /// Creates a new perceptual encoder.
    ///
    /// - Parameter configuration: The perceptual encoding configuration.
    public init(configuration: J2KPerceptualEncodingConfiguration = .default) {
        self.configuration = configuration
        self.visualMasking = J2KVisualMasking(
            configuration: configuration.maskingConfiguration
        )
        self.visualWeighting = J2KVisualWeighting(
            configuration: configuration.weightingConfiguration
        )
        self.qualityMetrics = J2KQualityMetrics()
    }

    // MARK: - Quantization Step Calculation

    /// Calculates perceptually optimised quantization steps.
    ///
    /// Combines visual masking and frequency weighting to produce quantization
    /// steps that optimise for perceptual quality.
    ///
    /// - Parameters:
    ///   - baseQuantization: Base quantization value.
    ///   - image: The image being encoded.
    ///   - decompositionLevels: Number of wavelet decomposition levels.
    /// - Returns: Array of perceptual quantization steps per subband.
    public func calculatePerceptualQuantizationSteps(
        baseQuantization: Double,
        image: J2KImage,
        decompositionLevels: Int
    ) -> [[J2KSubband: Double]] {
        var steps: [[J2KSubband: Double]] = []

        for level in 0..<decompositionLevels {
            var levelSteps: [J2KSubband: Double] = [:]

            // Subbands for this level
            let subbands: [J2KSubband] = (level == decompositionLevels - 1) ?
                [.ll, .lh, .hl, .hh] : [.lh, .hl, .hh]

            for subband in subbands {
                // Start with base quantization
                var stepSize = baseQuantization

                // Apply frequency weighting if enabled
                if configuration.enableFrequencyWeighting {
                    let weight = visualWeighting.weight(
                        for: subband,
                        decompositionLevel: level,
                        totalLevels: decompositionLevels,
                        imageWidth: image.width,
                        imageHeight: image.height
                    )
                    stepSize *= weight
                }

                // Apply visual masking if enabled
                if configuration.enableVisualMasking {
                    // For simplicity, use average luminance
                    // In a full implementation, this would be per-codeblock
                    let avgLuminance = 128.0  // Placeholder
                    let avgVariance = 100.0   // Placeholder

                    let maskingFactor = visualMasking.calculateMaskingFactor(
                        luminance: avgLuminance,
                        localVariance: avgVariance,
                        motionVector: nil
                    )
                    stepSize *= maskingFactor
                }

                levelSteps[subband] = stepSize
            }

            steps.append(levelSteps)
        }

        return steps
    }

    /// Calculates spatially-varying perceptual quantization for a region.
    ///
    /// Produces per-codeblock quantization steps based on local image characteristics.
    ///
    /// - Parameters:
    ///   - samples: Sample values for the region.
    ///   - width: Width of the region.
    ///   - height: Height of the region.
    ///   - bitDepth: Bit depth of the samples.
    ///   - baseQuantization: Base quantization value.
    ///   - subband: The wavelet subband.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Array of perceptual quantization steps per position.
    public func calculateSpatiallyVaryingQuantization(
        samples: [Int32],
        width: Int,
        height: Int,
        bitDepth: Int,
        baseQuantization: Double,
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [Double] {
        // Calculate frequency weight for this subband
        var steps = [Double](repeating: baseQuantization, count: width * height)

        if configuration.enableFrequencyWeighting {
            let weight = visualWeighting.weight(
                for: subband,
                decompositionLevel: decompositionLevel,
                totalLevels: totalLevels,
                imageWidth: width,
                imageHeight: height
            )

            for i in 0..<steps.count {
                steps[i] *= weight
            }
        }

        if configuration.enableVisualMasking {
            // Calculate masking factors for the region
            let maskingFactors = visualMasking.calculateRegionMaskingFactors(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                motionField: nil
            )

            // Apply masking factors
            for i in 0..<steps.count {
                steps[i] *= maskingFactors[i]
            }
        }

        return steps
    }

    // MARK: - Quality Evaluation

    /// Evaluates if the current quality meets the target.
    ///
    /// - Parameters:
    ///   - original: The original image.
    ///   - encoded: The encoded image.
    /// - Returns: True if quality target is met, false otherwise.
    /// - Throws: ``J2KError`` if quality evaluation fails.
    public func meetsQualityTarget(
        original: J2KImage,
        encoded: J2KImage
    ) throws -> Bool {
        let result: J2KQualityMetricResult

        switch configuration.targetQuality {
        case .psnr(let target):
            result = try qualityMetrics.psnr(original: original, compressed: encoded)
            return result.value >= target - configuration.qualityTolerance

        case .ssim(let target):
            result = try qualityMetrics.ssim(original: original, compressed: encoded)
            return result.value >= target - configuration.qualityTolerance

        case .msssim(let target):
            result = try qualityMetrics.msssim(original: original, compressed: encoded)
            return result.value >= target - configuration.qualityTolerance

        case .bitrate:
            // Bitrate target is handled differently (not a quality metric)
            return true
        }
    }

    /// Evaluates the quality of an encoded image.
    ///
    /// - Parameters:
    ///   - original: The original image.
    ///   - encoded: The encoded image.
    /// - Returns: The quality metric result.
    /// - Throws: ``J2KError`` if quality evaluation fails.
    public func evaluateQuality(
        original: J2KImage,
        encoded: J2KImage
    ) throws -> J2KQualityMetricResult {
        switch configuration.targetQuality {
        case .psnr, .bitrate:
            return try qualityMetrics.psnr(original: original, compressed: encoded)

        case .ssim:
            return try qualityMetrics.ssim(original: original, compressed: encoded)

        case .msssim:
            return try qualityMetrics.msssim(original: original, compressed: encoded)
        }
    }
}

// MARK: - Rate-Distortion Optimisation

extension J2KPerceptualEncoder {
    /// Estimates optimal base quantization for a target bitrate.
    ///
    /// Uses a simple heuristic to estimate the base quantization value
    /// that will achieve approximately the target bitrate.
    ///
    /// - Parameters:
    ///   - targetBitrate: Target bitrate in bits per pixel.
    ///   - imageSize: Total number of pixels.
    /// - Returns: Estimated base quantization value.
    public func estimateBaseQuantization(
        targetBitrate: Double,
        imageSize: Int
    ) -> Double {
        // Simple heuristic: higher bitrate = lower quantization
        // This is a placeholder for a more sophisticated model

        if targetBitrate >= 4.0 {
            return 0.01  // Very high quality
        } else if targetBitrate >= 2.0 {
            return 0.05  // High quality
        } else if targetBitrate >= 1.0 {
            return 0.1   // Medium quality
        } else if targetBitrate >= 0.5 {
            return 0.2   // Low quality
        } else {
            return 0.5   // Very low quality
        }
    }

    /// Adjusts quantization based on quality feedback.
    ///
    /// - Parameters:
    ///   - currentQuantization: Current base quantization.
    ///   - targetQuality: Target quality value.
    ///   - achievedQuality: Achieved quality value.
    /// - Returns: Adjusted base quantization.
    public func adjustQuantization(
        currentQuantization: Double,
        targetQuality: Double,
        achievedQuality: Double
    ) -> Double {
        let error = targetQuality - achievedQuality

        // Simple proportional adjustment
        // If achieved quality is too low, decrease quantization (improve quality)
        // If achieved quality is too high, increase quantization (reduce bitrate)
        let adjustment = -error * 0.3  // Damping factor

        let newQuantization = currentQuantization * (1.0 + adjustment)

        // Clamp to reasonable range
        return min(1.0, max(0.001, newQuantization))
    }
}

// MARK: - Quality Metric Extensions

extension J2KPerceptualEncoder {
    /// Calculates multiple quality metrics for comprehensive evaluation.
    ///
    /// - Parameters:
    ///   - original: The original image.
    ///   - encoded: The encoded image.
    /// - Returns: Dictionary of quality metric results.
    /// - Throws: ``J2KError`` if quality evaluation fails.
    public func calculateAllQualityMetrics(
        original: J2KImage,
        encoded: J2KImage
    ) throws -> [String: J2KQualityMetricResult] {
        var results: [String: J2KQualityMetricResult] = [:]

        results["PSNR"] = try qualityMetrics.psnr(original: original, compressed: encoded)
        results["SSIM"] = try qualityMetrics.ssim(original: original, compressed: encoded)
        results["MS-SSIM"] = try qualityMetrics.msssim(original: original, compressed: encoded)

        return results
    }
}
