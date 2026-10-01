//
// J2KROI.swift
// J2KSwift
//
// J2KROI.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

// # JPEG 2000 Region of Interest (ROI)
//
// Implementation of Region of Interest coding for JPEG 2000.
//
// ROI coding allows specific areas of an image to be encoded at higher quality
// than the background. In JPEG 2000, this is achieved through the MaxShift method,
// which shifts the coefficients of ROI regions to higher bit planes, ensuring
// they are decoded before non-ROI regions.
//
// ## MaxShift Method
//
// The MaxShift method works by:
// 1. Identifying ROI regions in the spatial domain
// 2. Mapping those regions to the wavelet domain
// 3. Scaling ROI coefficients by shifting them up by `s` bit positions
// 4. During decoding, non-ROI coefficients are identified by their lower magnitude
//
// ## Usage
//
// ```swift
// // Define a rectangular ROI
// let roi = J2KROIRegion.rectangle(x: 100, y: 100, width: 200, height: 200)
//
// // Create ROI processor
// let roiProcessor = J2KROIProcessor(
//     imageWidth: 512,
//     imageHeight: 512,
//     regions: [roi],
//     shift: 5
// )
//
// // Apply ROI scaling to wavelet coefficients
// let scaledCoeffs = roiProcessor.applyROIScaling(
//     coefficients: dwtCoeffs,
//     subband: .ll,
//     decompositionLevel: 0,
//     totalLevels: 3
// )
// ```

// MARK: - ROI Shape

/// Represents the shape type for ROI regions.
public enum J2KROIShapeType: String, Sendable, CaseIterable {
    /// Rectangular ROI.
    case rectangle
    /// Elliptical ROI.
    case ellipse
    /// Polygon ROI defined by vertices.
    case polygon
    /// Custom mask-based ROI.
    case mask
}

// MARK: - ROI Region

/// Represents a Region of Interest in a JPEG 2000 image.
///
/// An ROI region defines an area of the image that should be encoded
/// at higher quality than the surrounding background.
public struct J2KROIRegion: Sendable, Equatable {
    /// The shape type of this region.
    public let shapeType: J2KROIShapeType

    /// The bounding box x-coordinate.
    public let x: Int

    /// The bounding box y-coordinate.
    public let y: Int

    /// The bounding box width.
    public let width: Int

    /// The bounding box height.
    public let height: Int

    /// Polygon vertices (only used for polygon shapes).
    /// Each point is (x, y) tuple.
    public let vertices: [(x: Int, y: Int)]

    /// Priority level for this ROI (higher = more important).
    /// Used when multiple ROIs overlap.
    public let priority: Int

    /// Creates a rectangular ROI region.
    ///
    /// - Parameters:
    ///   - x: The x-coordinate of the top-left corner.
    ///   - y: The y-coordinate of the top-left corner.
    ///   - width: The width of the rectangle.
    ///   - height: The height of the rectangle.
    ///   - priority: Priority level (default: 1).
    /// - Returns: A rectangular ROI region.
    public static func rectangle(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        priority: Int = 1
    ) -> J2KROIRegion {
        J2KROIRegion(
            shapeType: .rectangle,
            x: x,
            y: y,
            width: width,
            height: height,
            vertices: [],
            priority: priority
        )
    }

    /// Creates an elliptical ROI region.
    ///
    /// - Parameters:
    ///   - centerX: The x-coordinate of the center.
    ///   - centerY: The y-coordinate of the center.
    ///   - radiusX: The horizontal radius.
    ///   - radiusY: The vertical radius.
    ///   - priority: Priority level (default: 1).
    /// - Returns: An elliptical ROI region.
    public static func ellipse(
        centerX: Int,
        centerY: Int,
        radiusX: Int,
        radiusY: Int,
        priority: Int = 1
    ) -> J2KROIRegion {
        J2KROIRegion(
            shapeType: .ellipse,
            x: centerX - radiusX,
            y: centerY - radiusY,
            width: radiusX * 2,
            height: radiusY * 2,
            vertices: [],
            priority: priority
        )
    }

    /// Creates a polygon ROI region.
    ///
    /// - Parameters:
    ///   - vertices: Array of (x, y) vertex coordinates.
    ///   - priority: Priority level (default: 1).
    /// - Returns: A polygon ROI region.
    public static func polygon(
        vertices: [(x: Int, y: Int)],
        priority: Int = 1
    ) -> J2KROIRegion {
        // Calculate bounding box
        guard !vertices.isEmpty else {
            return J2KROIRegion(
                shapeType: .polygon,
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                vertices: [],
                priority: priority
            )
        }

        let minX = vertices.map { $0.x }.min() ?? 0
        let maxX = vertices.map { $0.x }.max() ?? 0
        let minY = vertices.map { $0.y }.min() ?? 0
        let maxY = vertices.map { $0.y }.max() ?? 0

        return J2KROIRegion(
            shapeType: .polygon,
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY,
            vertices: vertices,
            priority: priority
        )
    }

    /// Private initializer.
    private init(
        shapeType: J2KROIShapeType,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        vertices: [(x: Int, y: Int)],
        priority: Int
    ) {
        self.shapeType = shapeType
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.vertices = vertices
        self.priority = priority
    }

    /// Checks if this region is valid.
    public var isValid: Bool {
        width > 0 && height > 0
    }

    /// Returns the center point of the region.
    public var center: (x: Int, y: Int) {
        (x + width / 2, y + height / 2)
    }

    /// Returns the area of the region in pixels (for bounding box).
    public var area: Int {
        width * height
    }

    // Equatable conformance
    public static func == (lhs: J2KROIRegion, rhs: J2KROIRegion) -> Bool {
        lhs.shapeType == rhs.shapeType &&
               lhs.x == rhs.x &&
               lhs.y == rhs.y &&
               lhs.width == rhs.width &&
               lhs.height == rhs.height &&
               lhs.priority == rhs.priority &&
               lhs.vertices.count == rhs.vertices.count &&
               zip(lhs.vertices, rhs.vertices).allSatisfy { $0.x == $1.x && $0.y == $1.y }
    }
}

// MARK: - ROI Mask Generator

/// Generates ROI masks for various shape types.
///
/// A mask is a 2D boolean array where `true` indicates pixels
/// that are part of the ROI.
public struct J2KROIMaskGenerator: Sendable {
    /// Generates a mask for a single ROI region.
    ///
    /// - Parameters:
    ///   - region: The ROI region.
    ///   - width: The image width.
    ///   - height: The image height.
    /// - Returns: 2D boolean array representing the mask.
    public static func generateMask(
        for region: J2KROIRegion,
        width: Int,
        height: Int
    ) -> [[Bool]] {
        var mask = Array(repeating: Array(repeating: false, count: width), count: height)

        switch region.shapeType {
        case .rectangle:
            fillRectangle(&mask, region: region)
        case .ellipse:
            fillEllipse(&mask, region: region)
        case .polygon:
            fillPolygon(&mask, region: region)
        case .mask:
            // Custom mask would be provided directly
            break
        }

        return mask
    }

    /// Generates a combined mask for multiple ROI regions.
    ///
    /// When regions overlap, the pixel is marked as ROI if it belongs
    /// to any region.
    ///
    /// - Parameters:
    ///   - regions: Array of ROI regions.
    ///   - width: The image width.
    ///   - height: The image height.
    /// - Returns: 2D boolean array representing the combined mask.
    public static func generateCombinedMask(
        for regions: [J2KROIRegion],
        width: Int,
        height: Int
    ) -> [[Bool]] {
        var mask = Array(repeating: Array(repeating: false, count: width), count: height)

        for region in regions {
            let regionMask = generateMask(for: region, width: width, height: height)
            for y in 0..<height {
                for x in 0..<width where regionMask[y][x] {
                    mask[y][x] = true
                }
            }
        }

        return mask
    }

    /// Generates a priority mask for multiple ROI regions.
    ///
    /// Returns the priority level for each pixel. Pixels outside all ROIs have priority 0.
    ///
    /// - Parameters:
    ///   - regions: Array of ROI regions.
    ///   - width: The image width.
    ///   - height: The image height.
    /// - Returns: 2D integer array with priority levels.
    public static func generatePriorityMask(
        for regions: [J2KROIRegion],
        width: Int,
        height: Int
    ) -> [[Int]] {
        var priorityMask = Array(repeating: Array(repeating: 0, count: width), count: height)

        // Sort regions by priority (lower first, so higher overwrites)
        let sortedRegions = regions.sorted { $0.priority < $1.priority }

        for region in sortedRegions {
            let regionMask = generateMask(for: region, width: width, height: height)
            for y in 0..<height {
                for x in 0..<width where regionMask[y][x] {
                    priorityMask[y][x] = region.priority
                }
            }
        }

        return priorityMask
    }

    // MARK: - Private Fill Methods

    private static func fillRectangle(_ mask: inout [[Bool]], region: J2KROIRegion) {
        let height = mask.count
        guard height > 0 else { return }
        let width = mask[0].count

        let startY = max(0, region.y)
        let endY = min(height, region.y + region.height)
        let startX = max(0, region.x)
        let endX = min(width, region.x + region.width)

        for y in startY..<endY {
            for x in startX..<endX {
                mask[y][x] = true
            }
        }
    }

    private static func fillEllipse(_ mask: inout [[Bool]], region: J2KROIRegion) {
        let imageHeight = mask.count
        guard imageHeight > 0 else { return }
        let imageWidth = mask[0].count

        let centerX = Double(region.x) + Double(region.width) / 2.0
        let centerY = Double(region.y) + Double(region.height) / 2.0
        let radiusX = Double(region.width) / 2.0
        let radiusY = Double(region.height) / 2.0

        guard radiusX > 0 && radiusY > 0 else { return }

        let startY = max(0, region.y)
        let endY = min(imageHeight, region.y + region.height + 1)
        let startX = max(0, region.x)
        let endX = min(imageWidth, region.x + region.width + 1)

        for y in startY..<endY {
            for x in startX..<endX {
                // Check if point is inside ellipse: (x-cx)²/rx² + (y-cy)²/ry² <= 1
                let dx = (Double(x) - centerX) / radiusX
                let dy = (Double(y) - centerY) / radiusY
                if dx * dx + dy * dy <= 1.0 {
                    mask[y][x] = true
                }
            }
        }
    }

    private static func fillPolygon(_ mask: inout [[Bool]], region: J2KROIRegion) {
        let imageHeight = mask.count
        guard imageHeight > 0 else { return }
        let imageWidth = mask[0].count

        let vertices = region.vertices
        guard vertices.count >= 3 else { return }

        let startY = max(0, region.y)
        let endY = min(imageHeight, region.y + region.height + 1)
        let startX = max(0, region.x)
        let endX = min(imageWidth, region.x + region.width + 1)

        for y in startY..<endY {
            for x in startX..<endX where isPointInPolygon(x: x, y: y, vertices: vertices) {
                mask[y][x] = true
            }
        }
    }

    /// Checks if a point is inside a polygon using ray casting algorithm.
    private static func isPointInPolygon(x: Int, y: Int, vertices: [(x: Int, y: Int)]) -> Bool {
        let n = vertices.count
        guard n >= 3 else { return false }

        var inside = false
        var j = n - 1

        for i in 0..<n {
            let xi = Double(vertices[i].x)
            let yi = Double(vertices[i].y)
            let xj = Double(vertices[j].x)
            let yj = Double(vertices[j].y)
            let px = Double(x)
            let py = Double(y)

            if ((yi > py) != (yj > py)) &&
               (px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }

        return inside
    }
}

// MARK: - ROI Wavelet Mapper

/// Maps ROI regions from spatial domain to wavelet domain.
///
/// When an image is transformed using DWT, the ROI regions need to be
/// mapped to the corresponding wavelet coefficients. This mapper handles
/// the transformation of ROI masks through wavelet decomposition levels.
public struct J2KROIWaveletMapper: Sendable {
    /// Maps a spatial domain mask to wavelet domain for a specific subband.
    ///
    /// Due to the DWT structure, each wavelet coefficient corresponds to
    /// a region in the original image. For a coefficient at position (x, y)
    /// in a subband at level `l`, it corresponds to a 2^l × 2^l region
    /// in the original image.
    ///
    /// - Parameters:
    ///   - spatialMask: The ROI mask in spatial domain.
    ///   - subband: The target subband.
    ///   - decompositionLevel: The decomposition level (0 = finest).
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: ROI mask for the specified subband.
    public static func mapToWaveletDomain(
        spatialMask: [[Bool]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Bool]] {
        guard !spatialMask.isEmpty && !spatialMask[0].isEmpty else {
            return []
        }

        let imageHeight = spatialMask.count
        let imageWidth = spatialMask[0].count

        // Calculate subband dimensions
        let scale = 1 << (decompositionLevel + 1)
        let subbandWidth: Int
        let subbandHeight: Int

        if subband == .ll && decompositionLevel == totalLevels - 1 {
            // LL band at coarsest level
            subbandWidth = (imageWidth + scale - 1) / scale
            subbandHeight = (imageHeight + scale - 1) / scale
        } else {
            // Detail subbands
            subbandWidth = (imageWidth + scale - 1) / scale
            subbandHeight = (imageHeight + scale - 1) / scale
        }

        var subbandMask = Array(
            repeating: Array(repeating: false, count: subbandWidth),
            count: subbandHeight
        )

        // Map each coefficient position to spatial region
        for sy in 0..<subbandHeight {
            for sx in 0..<subbandWidth {
                // Determine the spatial region this coefficient represents
                let spatialStartX: Int
                let spatialStartY: Int

                switch subband {
                case .ll:
                    // LL subband: top-left of each 2×2 block
                    spatialStartX = sx * scale
                    spatialStartY = sy * scale
                case .hl:
                    // HL subband: top-right of each 2×2 block
                    spatialStartX = sx * scale + scale / 2
                    spatialStartY = sy * scale
                case .lh:
                    // LH subband: bottom-left of each 2×2 block
                    spatialStartX = sx * scale
                    spatialStartY = sy * scale + scale / 2
                case .hh:
                    // HH subband: bottom-right of each 2×2 block
                    spatialStartX = sx * scale + scale / 2
                    spatialStartY = sy * scale + scale / 2
                }

                // Check if any pixel in this region is part of ROI
                let spatialEndX = min(spatialStartX + scale / 2, imageWidth)
                let spatialEndY = min(spatialStartY + scale / 2, imageHeight)

                var isROI = false
                for py in max(0, spatialStartY)..<spatialEndY {
                    for px in max(0, spatialStartX)..<spatialEndX {
                        // Bounds check
                        if py < imageHeight && px < imageWidth {
                            if spatialMask[py][px] {
                                isROI = true
                                break
                            }
                        }
                    }
                    if isROI { break }
                }

                subbandMask[sy][sx] = isROI
            }
        }

        return subbandMask
    }

    /// Maps a spatial domain mask to all subbands at a specific decomposition level.
    ///
    /// - Parameters:
    ///   - spatialMask: The ROI mask in spatial domain.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Dictionary mapping subbands to their ROI masks.
    public static func mapToAllSubbands(
        spatialMask: [[Bool]],
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [J2KSubband: [[Bool]]] {
        var result: [J2KSubband: [[Bool]]] = [:]

        let subbands: [J2KSubband]
        if decompositionLevel == totalLevels - 1 {
            subbands = [.ll, .lh, .hl, .hh]
        } else {
            subbands = [.lh, .hl, .hh]
        }

        for subband in subbands {
            result[subband] = mapToWaveletDomain(
                spatialMask: spatialMask,
                subband: subband,
                decompositionLevel: decompositionLevel,
                totalLevels: totalLevels
            )
        }

        return result
    }
}

// MARK: - ROI MaxShift Method

/// Implements the MaxShift ROI scaling method.
///
/// The MaxShift method scales ROI coefficients by shifting them to higher
/// bit planes. The shift amount `s` is calculated such that:
/// - ROI coefficients are scaled by 2^s
/// - Non-ROI coefficients remain unchanged
/// - During decoding, non-ROI coefficients can be identified by magnitude < 2^s
public struct J2KROIMaxShift: Sendable {
    /// Default shift value for ROI coding.
    public static let defaultShift: Int = 5

    /// Minimum allowed shift value.
    public static let minShift: Int = 0

    /// Maximum allowed shift value.
    public static let maxShift: Int = 37

    /// Calculates the appropriate shift value based on image bit depth.
    ///
    /// - Parameters:
    ///   - bitDepth: The bit depth of the image.
    ///   - guardBits: Number of guard bits.
    /// - Returns: Recommended shift value.
    public static func calculateShift(
        bitDepth: Int,
        guardBits: Int = 2
    ) -> Int {
        // The shift should leave room for non-ROI coefficients
        // while ensuring ROI coefficients are always decoded first
        let maxBits = bitDepth + guardBits
        let recommendedShift = min(maxBits - 1, defaultShift)
        return max(minShift, min(maxShift, recommendedShift))
    }

    /// Applies MaxShift scaling to ROI coefficients.
    ///
    /// - Parameters:
    ///   - coefficient: The wavelet coefficient.
    ///   - isROI: Whether this coefficient is in the ROI.
    ///   - shift: The shift amount.
    /// - Returns: Scaled coefficient.
    public static func applyScaling(
        coefficient: Int32,
        isROI: Bool,
        shift: Int
    ) -> Int32 {
        guard isROI && shift > 0 else {
            return coefficient
        }

        // Preserve sign while scaling
        if coefficient >= 0 {
            return coefficient << shift
        } else {
            // For negative values, scale the magnitude
            return -((-coefficient) << shift)
        }
    }

    /// Removes MaxShift scaling from coefficients.
    ///
    /// This is used during decoding to reconstruct the original coefficients.
    ///
    /// - Parameters:
    ///   - coefficient: The scaled coefficient.
    ///   - shift: The shift amount used during encoding.
    /// - Returns: Original coefficient.
    public static func removeScaling(
        coefficient: Int32,
        shift: Int
    ) -> Int32 {
        guard shift > 0 else {
            return coefficient
        }

        let threshold = Int32(1 << shift)

        // Check if this was an ROI coefficient (magnitude >= threshold)
        let magnitude = abs(coefficient)

        if magnitude >= threshold {
            // ROI coefficient - remove scaling
            let sign: Int32 = coefficient >= 0 ? 1 : -1
            return sign * (magnitude >> shift)
        } else {
            // Non-ROI coefficient - no change
            return coefficient
        }
    }

    /// Determines if a coefficient is from ROI region based on its magnitude.
    ///
    /// - Parameters:
    ///   - coefficient: The coefficient to check.
    ///   - shift: The shift amount.
    /// - Returns: True if the coefficient is from ROI.
    public static func isROICoefficient(
        coefficient: Int32,
        shift: Int
    ) -> Bool {
        guard shift > 0 else {
            return false
        }

        let threshold = Int32(1 << shift)
        return abs(coefficient) >= threshold
    }
}

// MARK: - ROI Processor

/// Main processor for ROI coding operations.
///
/// Combines mask generation, wavelet mapping, and MaxShift scaling
/// into a unified interface for ROI processing.
public struct J2KROIProcessor: Sendable {
    /// The image width.
    public let imageWidth: Int

    /// The image height.
    public let imageHeight: Int

    /// The ROI regions.
    public let regions: [J2KROIRegion]

    /// The shift amount for MaxShift method.
    public let shift: Int

    /// Whether ROI is enabled.
    public let isEnabled: Bool

    /// Cached spatial domain mask.
    private let spatialMask: [[Bool]]

    /// Creates a new ROI processor.
    ///
    /// - Parameters:
    ///   - imageWidth: The image width.
    ///   - imageHeight: The image height.
    ///   - regions: Array of ROI regions.
    ///   - shift: The shift amount (default: 5).
    public init(
        imageWidth: Int,
        imageHeight: Int,
        regions: [J2KROIRegion],
        shift: Int = J2KROIMaxShift.defaultShift
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.regions = regions
        self.shift = max(J2KROIMaxShift.minShift, min(J2KROIMaxShift.maxShift, shift))
        self.isEnabled = !regions.isEmpty && shift > 0

        // Generate spatial mask once
        if isEnabled {
            self.spatialMask = J2KROIMaskGenerator.generateCombinedMask(
                for: regions,
                width: imageWidth,
                height: imageHeight
            )
        } else {
            self.spatialMask = []
        }
    }

    /// Creates a disabled ROI processor.
    public static func disabled() -> J2KROIProcessor {
        J2KROIProcessor(imageWidth: 0, imageHeight: 0, regions: [], shift: 0)
    }

    /// Applies ROI scaling to a 2D array of coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: The wavelet coefficients.
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Scaled coefficients.
    public func applyROIScaling(
        coefficients: [[Int32]],
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Int32]] {
        guard isEnabled else {
            return coefficients
        }

        guard !coefficients.isEmpty && !coefficients[0].isEmpty else {
            return coefficients
        }

        // Get the ROI mask for this subband
        let subbandMask = J2KROIWaveletMapper.mapToWaveletDomain(
            spatialMask: spatialMask,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        // Apply scaling
        var result = coefficients
        let height = min(coefficients.count, subbandMask.count)

        for y in 0..<height {
            let width = min(coefficients[y].count, subbandMask[y].count)
            for x in 0..<width where subbandMask[y][x] {
                result[y][x] = J2KROIMaxShift.applyScaling(
                    coefficient: coefficients[y][x],
                    isROI: true,
                    shift: shift
                )
            }
        }

        return result
    }

    /// Removes ROI scaling from a 2D array of coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: The scaled coefficients.
    /// - Returns: Original coefficients with scaling removed.
    public func removeROIScaling(
        coefficients: [[Int32]]
    ) -> [[Int32]] {
        guard isEnabled else {
            return coefficients
        }

        return coefficients.map { row in
            row.map { coefficient in
                J2KROIMaxShift.removeScaling(coefficient: coefficient, shift: shift)
            }
        }
    }

    /// Applies ROI scaling to a complete decomposition.
    ///
    /// - Parameters:
    ///   - ll: LL subband coefficients.
    ///   - lh: LH subband coefficients.
    ///   - hl: HL subband coefficients.
    ///   - hh: HH subband coefficients.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: Scaled decomposition subbands.
    public func applyROIScalingToDecomposition(
        ll: [[Int32]],
        lh: [[Int32]],
        hl: [[Int32]],
        hh: [[Int32]],
        decompositionLevel: Int,
        totalLevels: Int
    ) -> (ll: [[Int32]], lh: [[Int32]], hl: [[Int32]], hh: [[Int32]]) {
        let scaledLL = applyROIScaling(
            coefficients: ll,
            subband: .ll,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let scaledLH = applyROIScaling(
            coefficients: lh,
            subband: .lh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let scaledHL = applyROIScaling(
            coefficients: hl,
            subband: .hl,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
        let scaledHH = applyROIScaling(
            coefficients: hh,
            subband: .hh,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )

        return (scaledLL, scaledLH, scaledHL, scaledHH)
    }

    /// Returns the spatial domain ROI mask.
    public func getSpatialMask() -> [[Bool]] {
        spatialMask
    }

    /// Returns the ROI mask for a specific subband.
    ///
    /// - Parameters:
    ///   - subband: The subband type.
    ///   - decompositionLevel: The decomposition level.
    ///   - totalLevels: Total number of decomposition levels.
    /// - Returns: The ROI mask for the subband.
    public func getSubbandMask(
        subband: J2KSubband,
        decompositionLevel: Int,
        totalLevels: Int
    ) -> [[Bool]] {
        guard isEnabled else {
            return []
        }

        return J2KROIWaveletMapper.mapToWaveletDomain(
            spatialMask: spatialMask,
            subband: subband,
            decompositionLevel: decompositionLevel,
            totalLevels: totalLevels
        )
    }

    /// Returns statistics about the ROI coverage.
    public func getStatistics() -> J2KROIStatistics {
        guard isEnabled else {
            return J2KROIStatistics(
                totalPixels: imageWidth * imageHeight,
                roiPixels: 0,
                coveragePercentage: 0.0,
                regionCount: 0
            )
        }

        var roiPixels = 0
        for row in spatialMask {
            roiPixels += row.filter { $0 }.count
        }

        let totalPixels = imageWidth * imageHeight
        let coverage = totalPixels > 0 ? Double(roiPixels) / Double(totalPixels) * 100.0 : 0.0

        return J2KROIStatistics(
            totalPixels: totalPixels,
            roiPixels: roiPixels,
            coveragePercentage: coverage,
            regionCount: regions.count
        )
    }
}

// MARK: - ROI Statistics

/// Statistics about ROI coverage.
public struct J2KROIStatistics: Sendable {
    /// Total number of pixels in the image.
    public let totalPixels: Int

    /// Number of pixels in ROI regions.
    public let roiPixels: Int

    /// Percentage of image covered by ROI.
    public let coveragePercentage: Double

    /// Number of ROI regions.
    public let regionCount: Int
}

// MARK: - ROI Configuration

/// Configuration for ROI coding.
public struct J2KROIConfiguration: Sendable, Equatable {
    /// Whether ROI coding is enabled.
    public let enabled: Bool

    /// The ROI regions.
    public let regions: [J2KROIRegion]

    /// The shift amount for MaxShift method.
    public let shift: Int

    /// Whether to use implicit ROI (derived from image content).
    public let implicitROI: Bool

    /// Creates ROI configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether ROI is enabled (default: true if regions exist).
    ///   - regions: Array of ROI regions.
    ///   - shift: The shift amount (default: 5).
    ///   - implicitROI: Whether to use implicit ROI (default: false).
    public init(
        enabled: Bool? = nil,
        regions: [J2KROIRegion] = [],
        shift: Int = J2KROIMaxShift.defaultShift,
        implicitROI: Bool = false
    ) {
        self.regions = regions
        self.shift = max(J2KROIMaxShift.minShift, min(J2KROIMaxShift.maxShift, shift))
        self.implicitROI = implicitROI
        self.enabled = enabled ?? (!regions.isEmpty || implicitROI)
    }

    /// Default configuration (no ROI).
    public static let disabled = J2KROIConfiguration(enabled: false, regions: [])

    /// Creates configuration with a single rectangular ROI.
    ///
    /// - Parameters:
    ///   - x: X coordinate.
    ///   - y: Y coordinate.
    ///   - width: Width.
    ///   - height: Height.
    ///   - shift: Shift amount.
    /// - Returns: ROI configuration.
    public static func rectangle(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        shift: Int = J2KROIMaxShift.defaultShift
    ) -> J2KROIConfiguration {
        let region = J2KROIRegion.rectangle(x: x, y: y, width: width, height: height)
        return J2KROIConfiguration(regions: [region], shift: shift)
    }

    /// Creates configuration with a single elliptical ROI.
    ///
    /// - Parameters:
    ///   - centerX: Center X coordinate.
    ///   - centerY: Center Y coordinate.
    ///   - radiusX: Horizontal radius.
    ///   - radiusY: Vertical radius.
    ///   - shift: Shift amount.
    /// - Returns: ROI configuration.
    public static func ellipse(
        centerX: Int,
        centerY: Int,
        radiusX: Int,
        radiusY: Int,
        shift: Int = J2KROIMaxShift.defaultShift
    ) -> J2KROIConfiguration {
        let region = J2KROIRegion.ellipse(
            centerX: centerX,
            centerY: centerY,
            radiusX: radiusX,
            radiusY: radiusY
        )
        return J2KROIConfiguration(regions: [region], shift: shift)
    }
}
