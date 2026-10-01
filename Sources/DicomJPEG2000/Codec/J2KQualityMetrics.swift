//
// J2KQualityMetrics.swift
// J2KSwift
//
// J2KQualityMetrics.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

// # JPEG 2000 Perceptual Quality Metrics
//
// Implementation of image quality metrics for evaluating JPEG 2000 compression.
//
// This module provides various quality metrics that can be used to measure the
// perceptual quality of compressed images compared to their originals. These
// metrics are essential for:
// - Evaluating compression quality
// - Rate-distortion optimisation
// - Quality-based encoding modes
// - Benchmarking and validation
//
// ## Supported Metrics
//
// - **PSNR** (Peak Signal-to-Noise Ratio): Simple MSE-based metric
// - **SSIM** (Structural Similarity Index): Perceptually motivated metric
// - **MS-SSIM** (Multi-Scale SSIM): Multi-resolution extension of SSIM
//
// ## Usage
//
// ```swift
// let metrics = J2KQualityMetrics()
//
// // Calculate PSNR between original and compressed
// let psnr = try metrics.psnr(
//     original: originalImage,
//     compressed: compressedImage
// )
// print("PSNR: \(psnr) dB")
//
// // Calculate SSIM for better perceptual correlation
// let ssim = try metrics.ssim(
//     original: originalImage,
//     compressed: compressedImage
// )
// print("SSIM: \(ssim)")
//
// // Calculate MS-SSIM for multi-scale quality assessment
// let msssim = try metrics.msssim(
//     original: originalImage,
//     compressed: compressedImage
// )
// print("MS-SSIM: \(msssim)")
// ```

// MARK: - Quality Metrics Result

/// Result of a quality metric calculation.
public struct J2KQualityMetricResult: Sendable, Equatable {
    /// The metric value (higher is better for most metrics).
    public let value: Double

    /// Per-component metric values if available.
    public let componentValues: [Double]?

    /// Creates a new quality metric result.
    ///
    /// - Parameters:
    ///   - value: The overall metric value.
    ///   - componentValues: Optional per-component values.
    public init(value: Double, componentValues: [Double]? = nil) {
        self.value = value
        self.componentValues = componentValues
    }
}

// MARK: - Quality Metrics

/// Implements perceptual quality metrics for image comparison.
/// Component geometry must match. Two-byte samples require an explicit producer-resolved byte order.
public struct J2KQualityMetrics: Sendable {
    /// Creates a new quality metrics instance.
    public init() {}

    // MARK: - PSNR (Peak Signal-to-Noise Ratio)

    /// Calculates PSNR between two images.
    ///
    /// PSNR is a simple quality metric based on mean squared error (MSE).
    /// While not perceptually accurate, it's fast and widely used for benchmarking.
    ///
    /// PSNR = 10 * log10(MAX^2 / MSE)
    ///
    /// where MAX is the maximum possible pixel value (e.g., 255 for 8-bit images).
    ///
    /// - Parameters:
    ///   - original: The original (reference) image.
    ///   - compressed: The compressed (distorted) image.
    /// - Returns: PSNR value in decibels (dB). Higher is better.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if images have different dimensions.
    public func psnr(
        original: J2KImage,
        compressed: J2KImage
    ) throws -> J2KQualityMetricResult {
        try validateImagePair(original: original, compressed: compressed)

        var componentPSNRs: [Double] = []
        var totalMSE: Double = 0.0
        var totalPixels: Int = 0

        // Calculate PSNR for each component
        for (origComp, compComp) in zip(original.components, compressed.components) {
            let originalSamples = try extractSamples(from: origComp)
            let compressedSamples = try extractSamples(from: compComp)

            let mse = try meanSquaredError(
                original: originalSamples,
                compressed: compressedSamples,
                width: origComp.width,
                height: origComp.height
            )

            if mse == 0.0 {
                // Perfect match, infinite PSNR
                componentPSNRs.append(Double.infinity)
            } else {
                // Calculate max value based on bit depth
                let maxValue = Double((1 << origComp.bitDepth) - 1)
                let psnrValue = 10.0 * log10((maxValue * maxValue) / mse)
                componentPSNRs.append(psnrValue)
            }

            totalMSE += mse
            totalPixels += original.width * original.height
        }

        // Overall PSNR
        let avgMSE = totalMSE / Double(original.components.count)
        let maxValue = Double((1 << original.components[0].bitDepth) - 1)
        let overallPSNR: Double

        if avgMSE == 0.0 {
            overallPSNR = Double.infinity
        } else {
            overallPSNR = 10.0 * log10((maxValue * maxValue) / avgMSE)
        }

        return J2KQualityMetricResult(
            value: overallPSNR,
            componentValues: componentPSNRs
        )
    }

    // MARK: - SSIM (Structural Similarity Index)

    /// Calculates SSIM between two images.
    ///
    /// SSIM is a perceptually motivated metric that considers luminance, contrast,
    /// and structure. It correlates better with human perception than PSNR.
    ///
    /// SSIM ranges from -1 to 1, where 1 indicates perfect similarity.
    ///
    /// - Parameters:
    ///   - original: The original (reference) image.
    ///   - compressed: The compressed (distorted) image.
    /// - Returns: SSIM value (0 to 1). Higher is better.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if images have different dimensions.
    public func ssim(
        original: J2KImage,
        compressed: J2KImage
    ) throws -> J2KQualityMetricResult {
        try validateImagePair(original: original, compressed: compressed)

        var componentSSIMs: [Double] = []

        // Calculate SSIM for each component
        for (origComp, compComp) in zip(original.components, compressed.components) {
            let originalSamples = try extractSamples(from: origComp)
            let compressedSamples = try extractSamples(from: compComp)

            let ssimValue = try calculateSSIM(
                original: originalSamples,
                compressed: compressedSamples,
                width: origComp.width,
                height: origComp.height,
                bitDepth: origComp.bitDepth
            )
            componentSSIMs.append(ssimValue.value)
        }

        // Average SSIM across components
        let overallSSIM = componentSSIMs.reduce(0.0, +) / Double(componentSSIMs.count)

        return J2KQualityMetricResult(
            value: overallSSIM,
            componentValues: componentSSIMs
        )
    }

    // MARK: - MS-SSIM (Multi-Scale SSIM)

    /// Calculates MS-SSIM between two images.
    ///
    /// MS-SSIM extends SSIM by evaluating quality at multiple scales through
    /// iterative low-pass filtering and downsampling. This better captures
    /// quality across different viewing distances.
    ///
    /// - Parameters:
    ///   - original: The original (reference) image.
    ///   - compressed: The compressed (distorted) image.
    ///   - scales: Number of scales to evaluate (default: 5).
    /// - Returns: MS-SSIM value (0 to 1). Higher is better.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if images have different dimensions.
    public func msssim(
        original: J2KImage,
        compressed: J2KImage,
        scales: Int = 5
    ) throws -> J2KQualityMetricResult {
        try validateImagePair(original: original, compressed: compressed)

        guard scales >= 1 && scales <= 5 else {
            throw J2KError.invalidParameter("MS-SSIM scales must be between 1 and 5")
        }

        var componentMSSSIMs: [Double] = []

        // Calculate MS-SSIM for each component
        for (origComp, compComp) in zip(original.components, compressed.components) {
            let originalSamples = try extractSamples(from: origComp)
            let compressedSamples = try extractSamples(from: compComp)

            let msssimValue = try calculateMSSSIM(
                original: originalSamples,
                compressed: compressedSamples,
                width: origComp.width,
                height: origComp.height,
                bitDepth: origComp.bitDepth,
                scales: scales
            )
            componentMSSSIMs.append(msssimValue)
        }

        // Average MS-SSIM across components
        let overallMSSSIM = componentMSSSIMs.reduce(0.0, +) / Double(componentMSSSIMs.count)

        return J2KQualityMetricResult(
            value: overallMSSSIM,
            componentValues: componentMSSSIMs
        )
    }

    // MARK: - Private Helper Methods

    /// Reads packed component samples; Int64 also represents unsigned and signed 32–38-bit values.
    private func extractSamples(from component: J2KComponent) throws -> [Int64] {
        guard (1...38).contains(component.bitDepth), component.width > 0, component.height > 0,
              component.width <= Int.max / component.height else {
            throw J2KError.invalidParameter("Invalid component dimensions or bit depth")
        }
        let sampleCount = component.width * component.height
        let bytesPerSample = (component.bitDepth + 7) / 8
        guard sampleCount <= component.data.count / bytesPerSample else {
            throw J2KError.invalidParameter("Component data size mismatch")
        }
        let littleEndian: Bool
        if let order = component.sampleByteOrder {
            littleEndian = order == .littleEndian
        } else if bytesPerSample == 2 {
            throw J2KError.invalidParameter("Two-byte component samples require an explicit sampleByteOrder")
        } else {
            littleEndian = false
        }
        let modulus = Int64(1) << component.bitDepth
        let mask = modulus - 1
        return component.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var samples = [Int64](repeating: 0, count: sampleCount)
            for index in 0..<sampleCount {
                var raw: Int64 = 0
                for byte in 0..<bytesPerSample {
                    let shift = (littleEndian ? byte : bytesPerSample - byte - 1) * 8
                    raw |= Int64(buffer[index * bytesPerSample + byte]) << shift
                }
                raw &= mask
                samples[index] = component.signed && raw >= modulus / 2 ? raw - modulus : raw
            }
            return samples
        }
    }

    /// Validates that two images can be compared.
    private func validateImagePair(original: J2KImage, compressed: J2KImage) throws {
        guard original.width == compressed.width else {
            throw J2KError.invalidParameter("Images have different widths: \(original.width) vs \(compressed.width)")
        }

        guard original.height == compressed.height else {
            throw J2KError.invalidParameter("Images have different heights: \(original.height) vs \(compressed.height)")
        }

        guard original.components.count == compressed.components.count else {
            throw J2KError.invalidParameter("Images have different number of components: \(original.components.count) vs \(compressed.components.count)")
        }

        for (originalComponent, compressedComponent) in zip(original.components, compressed.components) {
            guard originalComponent.width == compressedComponent.width,
                  originalComponent.height == compressedComponent.height,
                  originalComponent.subsamplingX == compressedComponent.subsamplingX,
                  originalComponent.subsamplingY == compressedComponent.subsamplingY else {
                throw J2KError.invalidParameter("Images have different component geometry")
            }
        }
    }

    /// Calculates mean squared error between two sample arrays.
    private func meanSquaredError(
        original: [Int64],
        compressed: [Int64],
        width: Int,
        height: Int
    ) throws -> Double {
        guard original.count == compressed.count else {
            throw J2KError.invalidParameter("Sample arrays have different lengths")
        }

        var sumSquaredDiff: Double = 0.0

        for i in 0..<original.count {
            let diff = Double(original[i]) - Double(compressed[i])
            sumSquaredDiff += diff * diff
        }

        return sumSquaredDiff / Double(original.count)
    }

    /// Calculates SSIM for a single component.
    private func calculateSSIM(
        original: [Int64],
        compressed: [Int64],
        width: Int,
        height: Int,
        bitDepth: Int
    ) throws -> (value: Double, luminance: Double, contrastStructure: Double) {
        // SSIM parameters
        let C1 = 0.01 * 0.01 * Double((1 << bitDepth) - 1) * Double((1 << bitDepth) - 1)
        let C2 = 0.03 * 0.03 * Double((1 << bitDepth) - 1) * Double((1 << bitDepth) - 1)

        // Use 8x8 windows with stride 4 for efficiency
        let windowSize = min(8, width, height)
        let windowStride = 4
        let lastY = max(0, height - windowSize)
        let lastX = max(0, width - windowSize)
        var yStarts = Array(stride(from: 0, through: lastY, by: windowStride))
        var xStarts = Array(stride(from: 0, through: lastX, by: windowStride))
        if yStarts.last != lastY { yStarts.append(lastY) }
        if xStarts.last != lastX { xStarts.append(lastX) }

        var ssimSum = 0.0
        var luminanceSum = 0.0
        var contrastStructureSum = 0.0
        var windowCount = 0

        for y in yStarts {
            for x in xStarts {
                let (meanX, meanY, varX, varY, covar) = try windowStatistics(
                    original: original,
                    compressed: compressed,
                    width: width,
                    x: x,
                    y: y,
                    windowSize: windowSize
                )

                // SSIM formula - broken into parts for compiler
                let meanXX = meanX * meanX
                let meanYY = meanY * meanY
                let luminance = (2.0 * meanX * meanY + C1) / (meanXX + meanYY + C1)

                let sqrtVarX = sqrt(varX)
                let sqrtVarY = sqrt(varY)
                let contrast = (2.0 * sqrtVarX * sqrtVarY + C2) / (varX + varY + C2)

                let sqrtVarProduct = sqrt(varX * varY)
                let structure = (covar + C2 / 2.0) / (sqrtVarProduct + C2 / 2.0)

                let ssim = luminance * contrast * structure
                ssimSum += ssim
                luminanceSum += luminance
                contrastStructureSum += contrast * structure
                windowCount += 1
            }
        }

        guard windowCount > 0 else { return (0, 0, 0) }
        let count = Double(windowCount)
        return (ssimSum / count, luminanceSum / count, contrastStructureSum / count)
    }

    /// Calculates statistics for a window.
    private func windowStatistics(
        original: [Int64],
        compressed: [Int64],
        width: Int,
        x: Int,
        y: Int,
        windowSize: Int
    ) throws -> (meanX: Double, meanY: Double, varX: Double, varY: Double, covar: Double) {
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumYY = 0.0
        var sumXY = 0.0
        let n = windowSize * windowSize

        for dy in 0..<windowSize {
            for dx in 0..<windowSize {
                let idx = (y + dy) * width + (x + dx)

                // Bounds check
                guard idx < original.count && idx < compressed.count else {
                    throw J2KError.invalidParameter("Window extends beyond image bounds")
                }

                let vX = Double(original[idx])
                let vY = Double(compressed[idx])

                sumX += vX
                sumY += vY
                sumXX += vX * vX
                sumYY += vY * vY
                sumXY += vX * vY
            }
        }

        let meanX = sumX / Double(n)
        let meanY = sumY / Double(n)
        let varX = (sumXX / Double(n)) - (meanX * meanX)
        let varY = (sumYY / Double(n)) - (meanY * meanY)
        let covar = (sumXY / Double(n)) - (meanX * meanY)

        return (meanX, meanY, max(0, varX), max(0, varY), covar)
    }

    /// Calculates MS-SSIM for a single component.
    private func calculateMSSSIM(
        original: [Int64],
        compressed: [Int64],
        width: Int,
        height: Int,
        bitDepth: Int,
        scales: Int
    ) throws -> Double {
        // MS-SSIM weights for each scale (from Wang et al. 2003)
        let weights: [Double] = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]

        var currentOriginal = original
        var currentCompressed = compressed
        var currentWidth = width
        var currentHeight = height

        var contrastStructure: [Double] = []
        var luminance: Double = 0.0

        // Calculate at multiple scales
        for scale in 0..<scales {
            let ssimValue = try calculateSSIM(
                original: currentOriginal,
                compressed: currentCompressed,
                width: currentWidth,
                height: currentHeight,
                bitDepth: bitDepth
            )

            // Wang et al. (2003), Eq. 7: contrast/structure at every scale, luminance only at the last.
            contrastStructure.append(ssimValue.contrastStructure)
            if scale < scales - 1 {

                // Downsample for next scale
                let (downsampledOriginal, newWidth, newHeight) = try downsample2x(
                    samples: currentOriginal,
                    width: currentWidth,
                    height: currentHeight
                )
                currentOriginal = downsampledOriginal

                let (downsampledCompressed, _, _) = try downsample2x(
                    samples: currentCompressed,
                    width: currentWidth,
                    height: currentHeight
                )
                currentCompressed = downsampledCompressed

                // Update dimensions for next iteration
                currentWidth = newWidth
                currentHeight = newHeight
            } else {
                luminance = ssimValue.luminance
            }
        }

        // Combine scales with weights
        var msssim = pow(max(0, luminance), weights[scales - 1])

        for i in 0..<contrastStructure.count {
            msssim *= pow(max(0, contrastStructure[i]), weights[i])
        }

        return min(1, max(0, msssim))
    }

    /// Downsamples an image by 2x using averaging.
    private func downsample2x(
        samples: [Int64],
        width: Int,
        height: Int
    ) throws -> (samples: [Int64], width: Int, height: Int) {
        let newWidth = width / 2
        let newHeight = height / 2

        guard newWidth > 0 && newHeight > 0 else {
            throw J2KError.invalidParameter("Image too small to downsample")
        }

        var downsampled = [Int64](repeating: 0, count: newWidth * newHeight)

        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let srcX = x * 2
                let srcY = y * 2

                // Average 2x2 block
                let v00 = samples[srcY * width + srcX]
                let v01 = samples[srcY * width + srcX + 1]
                let v10 = samples[(srcY + 1) * width + srcX]
                let v11 = samples[(srcY + 1) * width + srcX + 1]

                let avg = (v00 + v01 + v10 + v11) / 4
                downsampled[y * newWidth + x] = avg
            }
        }

        return (downsampled, newWidth, newHeight)
    }
}

// MARK: - Quality Metric Extensions

extension J2KQualityMetricResult: CustomStringConvertible {
    public var description: String {
        if value.isInfinite {
            return "Perfect (∞)"
        } else if let components = componentValues {
            let componentStr = components.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            return String(format: "%.2f (components: [%@])", value, componentStr)
        } else {
            return String(format: "%.2f", value)
        }
    }
}
