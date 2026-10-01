//
// J2KVisualWeighting.swift
// J2KSwift
//
// J2KVisualWeighting.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

// # JPEG 2000 Visual Frequency Weighting
//
// Implementation of perceptual visual frequency weighting for JPEG 2000 encoding.
//
// Visual frequency weighting applies frequency-dependent scaling to quantization
// step sizes based on the human visual system's contrast sensitivity function (CSF).
// This allows for perceptually optimised compression by allocating more bits to
// frequency bands that are more visible to human observers.
//
// ## Contrast Sensitivity Function (CSF)
//
// The CSF describes the human eye's sensitivity to spatial frequencies. Humans are
// most sensitive to frequencies around 4-8 cycles per degree and less sensitive to
// very low and very high frequencies. The implementation uses the Mannos-Sakrison CSF
// model, which is well-suited for JPEG 2000 wavelet subbands.
//
// ## Usage
//
// ```swift
// // Create visual weighting with default CSF parameters
// let weighting = J2KVisualWeighting()
//
// // Calculate weight for a specific subband
// let weight = weighting.weight(
//     for: .hh,
//     decompositionLevel: 2,
//     totalLevels: 5,
//     viewingDistance: 60.0  // cm
// )
//
// // Apply to quantization step size
// let perceptualStepSize = baseStepSize * weight
// ```

// MARK: - Visual Weighting Configuration

/// Configuration parameters for visual frequency weighting.
public struct J2KVisualWeightingConfiguration: Sendable, Equatable {
    /// The peak sensitivity frequency in cycles per degree.
    ///
    /// Default is 4.0 cycles/degree based on empirical studies.
    public let peakFrequency: Double

    /// The CSF sensitivity decay rate.
    ///
    /// Controls how quickly sensitivity drops off from the peak frequency.
    /// Default is 0.4 based on the Mannos-Sakrison model.
    public let decayRate: Double

    /// Viewing distance in centimeters.
    ///
    /// The distance from the viewer to the display. Affects the mapping
    /// from image frequencies to retinal frequencies. Default is 60 cm
    /// (typical computer monitor viewing distance).
    public let viewingDistance: Double

    /// Display resolution in pixels per inch (PPI).
    ///
    /// Used to convert image spatial frequencies to visual angles.
    /// Default is 96 PPI (standard screen resolution).
    public let displayPPI: Double

    /// Minimum weight to apply (prevents over-quantization).
    ///
    /// Even the least sensitive frequencies should not be completely discarded.
    /// Default is 0.1 (10% of base quantization).
    public let minimumWeight: Double

    /// Maximum weight to apply (prevents under-quantization).
    ///
    /// Even the most sensitive frequencies should not dominate excessively.
    /// Default is 4.0 (4x base quantization).
    public let maximumWeight: Double

    /// Creates a new visual weighting configuration.
    ///
    /// - Parameters:
    ///   - peakFrequency: Peak sensitivity frequency in cycles per degree (default: 4.0).
    ///   - decayRate: CSF sensitivity decay rate (default: 0.4).
    ///   - viewingDistance: Viewing distance in centimeters (default: 60.0).
    ///   - displayPPI: Display resolution in pixels per inch (default: 96.0).
    ///   - minimumWeight: Minimum weight to apply (default: 0.1).
    ///   - maximumWeight: Maximum weight to apply (default: 4.0).
    public init(
        peakFrequency: Double = 4.0,
        decayRate: Double = 0.4,
        viewingDistance: Double = 60.0,
        displayPPI: Double = 96.0,
        minimumWeight: Double = 0.1,
        maximumWeight: Double = 4.0
    ) {
        self.peakFrequency = peakFrequency
        self.decayRate = decayRate
        self.viewingDistance = viewingDistance
        self.displayPPI = displayPPI
        self.minimumWeight = minimumWeight
        self.maximumWeight = maximumWeight
    }

    /// Default configuration with standard viewing conditions.
    public static let `default` = J2KVisualWeightingConfiguration()
}

// MARK: - Visual Weighting

/// Implements visual frequency weighting for perceptual quantization.
public struct J2KVisualWeighting: Sendable {
    /// Configuration parameters for the CSF model.
    public let configuration: J2KVisualWeightingConfiguration

    /// Creates a new visual weighting instance.
    ///
    /// - Parameter configuration: The CSF configuration parameters.
    public init(configuration: J2KVisualWeightingConfiguration = .default) {
        self.configuration = configuration
    }

    /// Calculates the visual weight for a specific wavelet subband.
    ///
    /// The weight is derived from the CSF based on the subband's spatial frequency.
    /// Higher weights indicate lower visual sensitivity (more quantization allowed),
    /// lower weights indicate higher sensitivity (less quantization).
    ///
    /// - Parameters:
    ///   - subband: The wavelet subband type (LL, LH, HL, HH).
    ///   - decompositionLevel: The current decomposition level (0 = finest).
    ///   - totalLevels: The total number of decomposition levels.
    ///   - imageWidth: The width of the image in pixels.
    ///   - imageHeight: The height of the image in pixels.
    /// - Returns: The visual weight multiplier for quantization step size.
    public func weight(
        for subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> Double {
        // Calculate the spatial frequency of this subband in cycles per pixel
        let spatialFrequency = subbandSpatialFrequency(
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        // Convert to cycles per degree using viewing geometry
        let frequencyCPD = pixelFrequencyToCyclesPerDegree(
            pixelFrequency: spatialFrequency,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        // Apply CSF model to get sensitivity
        let sensitivity = contrastSensitivity(frequency: frequencyCPD)

        // Convert sensitivity to weight (inverse relationship)
        // Higher sensitivity = LOWER weight (preserve detail, less quantization)
        // Lower sensitivity = HIGHER weight (can quantize more)
        // Normalise sensitivity to a reference value around peak
        let peakSensitivity = contrastSensitivity(frequency: configuration.peakFrequency)
        let normalizedSensitivity = sensitivity / peakSensitivity

        // Weight is inverse of normalised sensitivity
        let rawWeight = 1.0 / max(0.1, normalizedSensitivity)

        // Clamp to configured bounds
        return min(
            configuration.maximumWeight,
            max(configuration.minimumWeight, rawWeight)
        )
    }

    /// Calculates weights for all subbands in a wavelet decomposition.
    ///
    /// - Parameters:
    ///   - totalLevels: The total number of decomposition levels.
    ///   - imageWidth: The width of the image in pixels.
    ///   - imageHeight: The height of the image in pixels.
    /// - Returns: Array of weights indexed by [level][subband], where level 0 is finest.
    public func weightsForAllSubbands(
        totalLevels: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> [[J2KSubband: Double]] {
        var weights: [[J2KSubband: Double]] = []

        for level in 0..<totalLevels {
            var levelWeights: [J2KSubband: Double] = [:]

            // For the coarsest level, include LL subband
            if level == totalLevels - 1 {
                levelWeights[.ll] = weight(
                    for: .ll,
                    decompositionLevel: level,
                    totalLevels: totalLevels,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
            }

            // All levels have HL, LH, HH subbands
            for subband in [J2KSubband.lh, .hl, .hh] {
                levelWeights[subband] = weight(
                    for: subband,
                    decompositionLevel: level,
                    totalLevels: totalLevels,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
            }

            weights.append(levelWeights)
        }

        return weights
    }

    // MARK: - Private Methods

    /// Calculates the spatial frequency of a subband in cycles per pixel.
    ///
    /// Wavelet decomposition creates subbands with different frequency ranges.
    /// The decomposition level determines the frequency band, with higher levels
    /// corresponding to lower frequencies.
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - decompositionLevel: Current decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Representative spatial frequency in cycles per pixel.
    private func subbandSpatialFrequency(
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> Double {
        // Each decomposition level halves the frequency range
        // Level 0 (finest) represents frequencies near Nyquist (0.5 cycles/pixel)
        // Level N (coarsest) represents lowest frequencies

        let levelFromFinest = totalLevels - decompositionLevel - 1

        // Base frequency for this level (center of the band)
        let baseFrequency = 0.25 / pow(2.0, Double(levelFromFinest))

        // Different subbands have different frequency characteristics
        switch subband {
        case .ll:
            // LL is the low-pass band, lowest frequency
            return baseFrequency * 0.5
        case .lh, .hl:
            // LH and HL are single-directional high-pass, medium frequency
            return baseFrequency
        case .hh:
            // HH is high-pass in both directions, highest frequency
            return baseFrequency * 1.414  // sqrt(2)
        }
    }

    /// Converts pixel-based frequency to cycles per degree of visual angle.
    ///
    /// This requires knowledge of the viewing geometry (distance and display size).
    ///
    /// - Parameters:
    ///   - pixelFrequency: Frequency in cycles per pixel.
    ///   - imageWidth: Image width in pixels.
    ///   - imageHeight: Image height in pixels.
    /// - Returns: Frequency in cycles per degree of visual angle.
    private func pixelFrequencyToCyclesPerDegree(
        pixelFrequency: Double,
        imageWidth: Int,
        imageHeight: Int
    ) -> Double {
        // Convert pixels to inches
        let pixelsPerInch = configuration.displayPPI

        // Average image dimension for typical viewing
        let averageDimension = sqrt(Double(imageWidth * imageHeight))
        let imageSizeInches = averageDimension / pixelsPerInch

        // Convert to centimeters
        let imageSizeCm = imageSizeInches * 2.54

        // Calculate visual angle in degrees
        let visualAngleDegrees = 2.0 * atan(imageSizeCm / (2.0 * configuration.viewingDistance)) * 180.0 / .pi

        // Cycles per pixel * pixels per degree = cycles per degree
        let pixelsPerDegree = averageDimension / visualAngleDegrees
        return pixelFrequency * pixelsPerDegree
    }

    /// Calculates contrast sensitivity for a given spatial frequency.
    ///
    /// Uses the Mannos-Sakrison CSF model, which is suitable for wavelet-based
    /// image coding. The model has a peak sensitivity around 4-8 cycles per degree
    /// and drops off at higher and lower frequencies.
    ///
    /// - Parameter frequency: Spatial frequency in cycles per degree.
    /// - Returns: Contrast sensitivity value (higher = more sensitive).
    private func contrastSensitivity(frequency: Double) -> Double {
        // Mannos-Sakrison CSF model
        // CSF(f) = A * f * exp(-B * f)
        // where A controls the peak height and B controls the decay rate

        let f = abs(frequency)
        let peak = configuration.peakFrequency
        let decay = configuration.decayRate

        // Normalise frequency relative to peak
        let normalizedFreq = f / peak

        // CSF with peak at configuration.peakFrequency
        let sensitivity = normalizedFreq * exp(1.0 - normalizedFreq / decay)

        // Ensure sensitivity is at least a small positive value
        return max(0.01, sensitivity)
    }
}

// MARK: - Perceptual Quantization

/// Extension to integrate visual weighting with quantization.
extension J2KVisualWeighting {
    /// Calculates perceptually weighted quantization step size.
    ///
    /// Applies visual frequency weighting to adjust the base quantization step size
    /// according to the human visual system's sensitivity.
    ///
    /// - Parameters:
    ///   - baseStepSize: The base quantization step size.
    ///   - subband: The wavelet subband.
    ///   - decompositionLevel: The current decomposition level.
    ///   - totalLevels: The total number of decomposition levels.
    ///   - imageWidth: The image width in pixels.
    ///   - imageHeight: The image height in pixels.
    /// - Returns: The perceptually weighted quantization step size.
    public func perceptualStepSize(
        baseStepSize: Double,
        for subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> Double {
        let visualWeight = weight(
            for: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

        return baseStepSize * visualWeight
    }
}
