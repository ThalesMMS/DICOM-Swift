//
// J2KExtendedROI.swift
// J2KSwift
//
// J2KExtendedROI.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-19.
//

import Foundation

// # Extended JPEG 2000 ROI Methods (ISO/IEC 15444-2)
//
// Implementation of Part 2 extended ROI methods beyond the basic MaxShift approach.
//
// ## Overview
//
// While Part 1 defines the MaxShift method for ROI coding, Part 2 extends
// this with more sophisticated approaches:
// - General scaling-based ROI with custom scaling factors
// - DWT domain ROI allowing arbitrary regions after transform
// - Multiple ROI regions with different priorities
// - ROI blending and feathering for smooth transitions
// - Bitplane-dependent ROI coding
// - Quality layer-based ROI
// - Adaptive ROI based on content analysis
// - Hierarchical (nested) ROI regions
//
// ## Scaling-Based ROI
//
// Unlike MaxShift which uses a uniform shift, scaling-based ROI allows
// different scaling factors for different regions, providing fine-grained
// control over quality allocation.
//
// ```swift
// let roi = J2KExtendedROIRegion(
//     baseRegion: J2KROIRegion.rectangle(x: 100, y: 100, width: 200, height: 200),
//     scalingFactor: 2.0,
//     priority: 10
// )
//
// let processor = J2KExtendedROIProcessor(
//     imageWidth: 512,
//     imageHeight: 512,
//     regions: [roi],
//     method: .scalingBased
// )
// ```

// MARK: - Extended ROI Method

/// Extended ROI coding methods.
public enum J2KExtendedROIMethod: String, Sendable, CaseIterable {
    /// General scaling-based ROI with custom scaling factors.
    case scalingBased

    /// DWT domain ROI - arbitrary regions defined after wavelet transform.
    case dwtDomain

    /// Bitplane-dependent ROI - different scaling per bitplane.
    case bitplaneDependent

    /// Quality layer-based ROI - ROI affects layer formation.
    case qualityLayerBased

    /// Adaptive ROI based on content analysis.
    case adaptive

    /// Hierarchical ROI with nested regions.
    case hierarchical
}

// MARK: - Extended ROI Region

/// Extended ROI region with additional properties for Part 2 methods.
public struct J2KExtendedROIRegion: Sendable, Equatable {
    /// The base ROI region defining the spatial area.
    public let baseRegion: J2KROIRegion

    /// Custom scaling factor for this region (for scaling-based method).
    /// Values > 1.0 increase quality, < 1.0 decrease quality.
    public let scalingFactor: Double

    /// Priority level (higher = more important).
    public let priority: Int

    /// Feathering width in pixels (0 = no feathering).
    /// Creates smooth transition at region boundaries.
    public let featheringWidth: Int

    /// Blending mode for overlapping regions.
    public let blendingMode: J2KROIBlendingMode

    /// Bitplane-specific scaling factors (for bitplane-dependent method).
    /// If nil, uses uniform scaling.
    public let bitplaneScaling: [Int: Double]?

    /// Parent region index for hierarchical ROI (nil = root region).
    public let parentIndex: Int?

    /// Creates an extended ROI region.
    ///
    /// - Parameters:
    ///   - baseRegion: The base spatial region.
    ///   - scalingFactor: Scaling factor (default: 2.0).
    ///   - priority: Priority level (default: 1).
    ///   - featheringWidth: Feathering width in pixels (default: 0).
    ///   - blendingMode: Blending mode (default: .maximum).
    ///   - bitplaneScaling: Bitplane-specific scaling (default: nil).
    ///   - parentIndex: Parent region index (default: nil).
    public init(
        baseRegion: J2KROIRegion,
        scalingFactor: Double = 2.0,
        priority: Int = 1,
        featheringWidth: Int = 0,
        blendingMode: J2KROIBlendingMode = .maximum,
        bitplaneScaling: [Int: Double]? = nil,
        parentIndex: Int? = nil
    ) {
        self.baseRegion = baseRegion
        self.scalingFactor = max(0.1, min(100.0, scalingFactor))
        self.priority = priority
        self.featheringWidth = max(0, featheringWidth)
        self.blendingMode = blendingMode
        self.bitplaneScaling = bitplaneScaling
        self.parentIndex = parentIndex
    }

    /// Checks if this is a root region (no parent).
    public var isRootRegion: Bool {
        parentIndex == nil
    }
}

// MARK: - ROI Blending Mode

/// Blending mode for overlapping ROI regions.
public enum J2KROIBlendingMode: String, Sendable, CaseIterable {
    /// Use maximum scaling factor.
    case maximum

    /// Use minimum scaling factor.
    case minimum

    /// Average the scaling factors.
    case average

    /// Weighted average by priority.
    case weightedAverage

    /// Use first region's scaling (priority-based).
    case priorityBased
}

// MARK: - Extended ROI Processor

/// Processor for extended ROI methods.
public struct J2KExtendedROIProcessor: Sendable {
    /// Image dimensions.
    public let imageWidth: Int
    public let imageHeight: Int

    /// Extended ROI regions.
    public let regions: [J2KExtendedROIRegion]

    /// ROI coding method.
    public let method: J2KExtendedROIMethod

    /// Whether ROI is enabled.
    public let enabled: Bool

    /// Creates an extended ROI processor.
    ///
    /// - Parameters:
    ///   - imageWidth: Image width.
    ///   - imageHeight: Image height.
    ///   - regions: Array of extended ROI regions.
    ///   - method: ROI coding method.
    public init(
        imageWidth: Int,
        imageHeight: Int,
        regions: [J2KExtendedROIRegion],
        method: J2KExtendedROIMethod = .scalingBased
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.regions = regions
        self.method = method
        self.enabled = !regions.isEmpty
    }

    /// Creates a disabled processor.
    public static func disabled() -> J2KExtendedROIProcessor {
        J2KExtendedROIProcessor(
            imageWidth: 0,
            imageHeight: 0,
            regions: [],
            method: .scalingBased
        )
    }

    // MARK: - Scaling-Based ROI

    /// Applies scaling-based ROI to wavelet coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: Wavelet coefficients.
    ///   - subband: Target subband.
    ///   - decompositionLevel: Decomposition level.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: Scaled coefficients.
    public func applyScalingBasedROI(
        coefficients: [[Int32]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Int32]] {
        guard enabled else { return coefficients }

        let height = coefficients.count
        guard height > 0 else { return coefficients }
        let width = coefficients[0].count

        // Generate scaling map
        let scalingMap = generateScalingMap(
            width: width,
            height: height,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        // Apply scaling
        var scaled = coefficients
        for y in 0..<height {
            for x in 0..<width {
                let scale = scalingMap[y][x]
                if scale > 1.0 {
                    scaled[y][x] = j2kClampedInt32(Double(coefficients[y][x]) * scale)
                }
            }
        }

        return scaled
    }

    /// Generates a scaling map for coefficients.
    ///
    /// - Parameters:
    ///   - width: Coefficient width.
    ///   - height: Coefficient height.
    ///   - subband: Target subband.
    ///   - decompositionLevel: Decomposition level.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: 2D array of scaling factors.
    public func generateScalingMap(
        width: Int,
        height: Int,
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Double]] {
        // Initialise with no scaling
        var scalingMap = Array(
            repeating: Array(repeating: 1.0, count: width),
            count: height
        )

        // Process each region
        for region in regions {
            // Generate spatial mask
            let spatialMask = J2KROIMaskGenerator.generateMask(
                for: region.baseRegion,
                width: imageWidth,
                height: imageHeight
            )

            // Map to wavelet domain
            let waveletMask = J2KROIWaveletMapper.mapToWaveletDomain(
                spatialMask: spatialMask,
                subband: subband,
                decompositionLevel: decompositionLevel,
                totalLevels: totalLevels
            )

            // Apply feathering if specified
            let featheredMask = region.featheringWidth > 0
                ? applyFeathering(mask: waveletMask, width: region.featheringWidth)
                : waveletMask.map { $0.map { $0 ? 1.0 : 0.0 } }

            // Update scaling map
            for y in 0..<min(height, featheredMask.count) {
                for x in 0..<min(width, featheredMask[y].count) {
                    let maskValue = featheredMask[y][x]
                    if maskValue > 0.0 {
                        let newScale = 1.0 + (region.scalingFactor - 1.0) * maskValue
                        scalingMap[y][x] = blendScaling(
                            current: scalingMap[y][x],
                            new: newScale,
                            mode: region.blendingMode,
                            priority: region.priority
                        )
                    }
                }
            }
        }

        return scalingMap
    }

    /// Applies feathering to a mask.
    ///
    /// - Parameters:
    ///   - mask: Boolean mask.
    ///   - width: Feathering width in pixels.
    /// - Returns: Float mask with smooth transitions.
    private func applyFeathering(
        mask: [[Bool]],
        width: Int
    ) -> [[Double]] {
        let height = mask.count
        guard height > 0 else { return [] }
        let maskWidth = mask[0].count

        // Simple distance-based feathering
        var feathered = Array(
            repeating: Array(repeating: 0.0, count: maskWidth),
            count: height
        )

        for y in 0..<height {
            for x in 0..<maskWidth {
                if mask[y][x] {
                    feathered[y][x] = 1.0
                } else {
                    // Find distance to nearest ROI pixel
                    var minDist = Double(width + 1)
                    for dy in -width...width {
                        for dx in -width...width {
                            let ny = y + dy
                            let nx = x + dx
                            if ny >= 0 && ny < height && nx >= 0 && nx < maskWidth {
                                if mask[ny][nx] {
                                    let dist = sqrt(Double(dx * dx + dy * dy))
                                    minDist = min(minDist, dist)
                                }
                            }
                        }
                    }

                    // Linear falloff
                    if minDist <= Double(width) {
                        feathered[y][x] = 1.0 - (minDist / Double(width))
                    }
                }
            }
        }

        return feathered
    }

    /// Blends scaling factors based on blending mode.
    ///
    /// - Parameters:
    ///   - current: Current scaling factor.
    ///   - new: New scaling factor.
    ///   - mode: Blending mode.
    ///   - priority: Priority of new region.
    /// - Returns: Blended scaling factor.
    private func blendScaling(
        current: Double,
        new: Double,
        mode: J2KROIBlendingMode,
        priority: Int
    ) -> Double {
        switch mode {
        case .maximum:
            return max(current, new)
        case .minimum:
            return min(current, new)
        case .average:
            return (current + new) / 2.0
        case .weightedAverage:
            let weight = Double(priority) / 10.0
            return current * (1.0 - weight) + new * weight
        case .priorityBased:
            return priority > 1 ? new : current
        }
    }

    // MARK: - DWT Domain ROI

    /// Applies DWT domain ROI directly to coefficients.
    ///
    /// Unlike spatial domain ROI, this allows arbitrary regions to be
    /// defined directly in the wavelet domain.
    ///
    /// - Parameters:
    ///   - coefficients: Wavelet coefficients.
    ///   - dwtMask: Boolean mask in DWT domain.
    ///   - scalingFactor: Scaling factor for ROI coefficients.
    /// - Returns: Scaled coefficients.
    public func applyDWTDomainROI(
        coefficients: [[Int32]],
        dwtMask: [[Bool]],
        scalingFactor: Double
    ) -> [[Int32]] {
        guard enabled else { return coefficients }

        let height = coefficients.count
        guard height > 0 && height == dwtMask.count else { return coefficients }
        let width = coefficients[0].count
        guard width == dwtMask[0].count else { return coefficients }

        var scaled = coefficients
        for y in 0..<height {
            for x in 0..<width where dwtMask[y][x] {
                scaled[y][x] = j2kClampedInt32(Double(coefficients[y][x]) * scalingFactor)
            }
        }

        return scaled
    }

    // MARK: - Bitplane-Dependent ROI

    /// Applies bitplane-dependent ROI scaling.
    ///
    /// Different bitplanes can have different scaling factors,
    /// allowing fine control over quality vs. bitrate tradeoff.
    ///
    /// - Parameters:
    ///   - coefficients: Wavelet coefficients.
    ///   - bitplane: Current bitplane being coded.
    ///   - subband: Target subband.
    ///   - decompositionLevel: Decomposition level.
    ///   - totalLevels: Total decomposition levels.
    /// - Returns: Scaled coefficients.
    public func applyBitplaneROI(
        coefficients: [[Int32]],
        bitplane: Int,
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Int32]] {
        guard enabled else { return coefficients }

        let height = coefficients.count
        guard height > 0 else { return coefficients }
        let width = coefficients[0].count

        var scaled = coefficients

        for region in regions {
            // Get bitplane-specific scaling or use default
            let scale = region.bitplaneScaling?[bitplane] ?? region.scalingFactor

            // Generate spatial mask
            let spatialMask = J2KROIMaskGenerator.generateMask(
                for: region.baseRegion,
                width: imageWidth,
                height: imageHeight
            )

            // Map to wavelet domain
            let waveletMask = J2KROIWaveletMapper.mapToWaveletDomain(
                spatialMask: spatialMask,
                subband: subband,
                decompositionLevel: decompositionLevel,
                totalLevels: totalLevels
            )

            // Apply scaling
            for y in 0..<min(height, waveletMask.count) {
                for x in 0..<min(width, waveletMask[y].count) where waveletMask[y][x] {
                    scaled[y][x] = j2kClampedInt32(Double(coefficients[y][x]) * scale)
                }
            }
        }

        return scaled
    }

    // MARK: - Hierarchical ROI

    /// Gets hierarchical structure of ROI regions.
    ///
    /// - Returns: Dictionary mapping parent index to child regions.
    public func getHierarchy() -> [Int?: [J2KExtendedROIRegion]] {
        var hierarchy: [Int?: [J2KExtendedROIRegion]] = [:]

        for region in regions {
            if hierarchy[region.parentIndex] == nil {
                hierarchy[region.parentIndex] = []
            }
            hierarchy[region.parentIndex]?.append(region)
        }

        return hierarchy
    }

    /// Gets root regions (no parent).
    public func getRootRegions() -> [J2KExtendedROIRegion] {
        regions.filter { $0.isRootRegion }
    }

    /// Gets child regions for a parent index.
    ///
    /// - Parameter parentIndex: Parent region index.
    /// - Returns: Array of child regions.
    public func getChildRegions(parentIndex: Int) -> [J2KExtendedROIRegion] {
        regions.filter { $0.parentIndex == parentIndex }
    }

    // MARK: - Adaptive ROI

    /// Generates adaptive ROI based on content analysis.
    ///
    /// This analyses image content (e.g., edge strength, texture complexity)
    /// to automatically determine ROI regions.
    ///
    /// - Parameters:
    ///   - imageData: Image pixel data.
    ///   - threshold: Threshold for ROI detection (0.0-1.0).
    ///   - minRegionSize: Minimum region size in pixels.
    /// - Returns: Array of detected ROI regions.
    public static func detectAdaptiveROI(
        imageData: [[Int32]],
        threshold: Double = 0.5,
        minRegionSize: Int = 100
    ) -> [J2KExtendedROIRegion] {
        let height = imageData.count
        guard height > 0 else { return [] }
        let width = imageData[0].count

        // Simple edge-based detection (placeholder for more sophisticated methods)
        var edgeMap = Array(
            repeating: Array(repeating: 0.0, count: width),
            count: height
        )

        // Compute gradients
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let gx = abs(Int(imageData[y][x + 1]) - Int(imageData[y][x - 1]))
                let gy = abs(Int(imageData[y + 1][x]) - Int(imageData[y - 1][x]))
                edgeMap[y][x] = sqrt(Double(gx * gx + gy * gy))
            }
        }

        // Find regions with high edge strength
        var regions: [J2KExtendedROIRegion] = []

        // Simple grid-based approach
        let blockSize = 32
        for by in stride(from: 0, to: height, by: blockSize) {
            for bx in stride(from: 0, to: width, by: blockSize) {
                let endY = min(by + blockSize, height)
                let endX = min(bx + blockSize, width)

                var avgEdge = 0.0
                var count = 0
                for y in by..<endY {
                    for x in bx..<endX {
                        avgEdge += edgeMap[y][x]
                        count += 1
                    }
                }
                avgEdge /= Double(count)

                // Normalise to 0-1 range (assuming max edge ~255)
                let normalizedEdge = avgEdge / 255.0

                if normalizedEdge > threshold && count >= minRegionSize {
                    let baseRegion = J2KROIRegion.rectangle(
                        x: bx,
                        y: by,
                        width: endX - bx,
                        height: endY - by
                    )
                    let region = J2KExtendedROIRegion(
                        baseRegion: baseRegion,
                        scalingFactor: 1.0 + normalizedEdge,
                        priority: Int(normalizedEdge * 10)
                    )
                    regions.append(region)
                }
            }
        }

        return regions
    }

    // MARK: - ROI Statistics

    /// Gets statistics about ROI regions.
    ///
    /// - Returns: ROI statistics.
    public func getStatistics() -> J2KExtendedROIStatistics {
        let totalPixels = imageWidth * imageHeight

        var roiPixels = 0
        var totalScaling = 0.0
        var maxScaling = 0.0

        // Generate combined mask
        let mask = generateCombinedMask()

        for y in 0..<imageHeight {
            for x in 0..<imageWidth where mask[y][x] > 0.0 {
                roiPixels += 1
                totalScaling += mask[y][x]
                maxScaling = max(maxScaling, mask[y][x])
            }
        }

        let coverage = totalPixels > 0 ? Double(roiPixels) / Double(totalPixels) * 100.0 : 0.0
        let avgScaling = roiPixels > 0 ? totalScaling / Double(roiPixels) : 1.0

        return J2KExtendedROIStatistics(
            totalPixels: totalPixels,
            roiPixels: roiPixels,
            coveragePercentage: coverage,
            regionCount: regions.count,
            averageScaling: avgScaling,
            maximumScaling: maxScaling
        )
    }

    /// Generates a combined mask for all regions.
    ///
    /// - Returns: 2D array of scaling factors.
    private func generateCombinedMask() -> [[Double]] {
        var mask = Array(
            repeating: Array(repeating: 0.0, count: imageWidth),
            count: imageHeight
        )

        for region in regions {
            let spatialMask = J2KROIMaskGenerator.generateMask(
                for: region.baseRegion,
                width: imageWidth,
                height: imageHeight
            )

            for y in 0..<imageHeight {
                for x in 0..<imageWidth where spatialMask[y][x] {
                    mask[y][x] = max(mask[y][x], region.scalingFactor)
                }
            }
        }

        return mask
    }
}

// MARK: - Extended ROI Statistics

/// Statistics for extended ROI.
public struct J2KExtendedROIStatistics: Sendable {
    /// Total number of pixels in the image.
    public let totalPixels: Int

    /// Number of pixels in ROI regions.
    public let roiPixels: Int

    /// Percentage of image covered by ROI.
    public let coveragePercentage: Double

    /// Number of ROI regions.
    public let regionCount: Int

    /// Average scaling factor across ROI pixels.
    public let averageScaling: Double

    /// Maximum scaling factor used.
    public let maximumScaling: Double
}

// MARK: - Extended ROI Configuration

/// Configuration for extended ROI coding.
public struct J2KExtendedROIConfiguration: Sendable, Equatable {
    /// Whether extended ROI is enabled.
    public let enabled: Bool

    /// Extended ROI regions.
    public let regions: [J2KExtendedROIRegion]

    /// ROI coding method.
    public let method: J2KExtendedROIMethod

    /// Creates extended ROI configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether ROI is enabled.
    ///   - regions: Array of extended ROI regions.
    ///   - method: ROI coding method.
    public init(
        enabled: Bool? = nil,
        regions: [J2KExtendedROIRegion] = [],
        method: J2KExtendedROIMethod = .scalingBased
    ) {
        self.regions = regions
        self.method = method
        self.enabled = enabled ?? !regions.isEmpty
    }

    /// Default configuration (no extended ROI).
    public static let disabled = J2KExtendedROIConfiguration(
        enabled: false,
        regions: [],
        method: .scalingBased
    )

    /// Creates configuration with a single scaling-based ROI.
    ///
    /// - Parameters:
    ///   - x: X coordinate.
    ///   - y: Y coordinate.
    ///   - width: Width.
    ///   - height: Height.
    ///   - scalingFactor: Scaling factor.
    /// - Returns: Extended ROI configuration.
    public static func scalingBased(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        scalingFactor: Double = 2.0
    ) -> J2KExtendedROIConfiguration {
        let baseRegion = J2KROIRegion.rectangle(x: x, y: y, width: width, height: height)
        let region = J2KExtendedROIRegion(
            baseRegion: baseRegion,
            scalingFactor: scalingFactor
        )
        return J2KExtendedROIConfiguration(
            regions: [region],
            method: .scalingBased
        )
    }
}
