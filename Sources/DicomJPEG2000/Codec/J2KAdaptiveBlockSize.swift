//
// J2KAdaptiveBlockSize.swift
// J2KSwift
//
// J2KAdaptiveBlockSize.swift
// J2KSwift
//
// Adaptive block size selection for JPEG 2000 encoding.
// Week 137-138: Content-aware block size analysis and selection.
//

import Foundation

// MARK: - Content Metrics

/// Metrics describing the content characteristics of a tile region.
///
/// These metrics are used by the adaptive block size selector to choose
/// the optimal code block size for each tile based on image content.
public struct J2KContentMetrics: Sendable, Equatable {
    /// Edge density in the range [0.0, 1.0].
    ///
    /// Higher values indicate more edges/detail in the tile region.
    /// Computed via a Sobel-like gradient magnitude estimation.
    public let edgeDensity: Double

    /// Frequency energy ratio in the range [0.0, 1.0].
    ///
    /// Higher values indicate more high-frequency content relative to
    /// low-frequency content, computed from DWT coefficient magnitudes.
    public let frequencyEnergy: Double

    /// Texture complexity score in the range [0.0, 1.0].
    ///
    /// Combined metric derived from edge density and frequency content
    /// that represents overall visual complexity of the region.
    public let textureComplexity: Double

    /// Creates content metrics with the given values.
    ///
    /// - Parameters:
    ///   - edgeDensity: Edge density (0.0-1.0).
    ///   - frequencyEnergy: Frequency energy ratio (0.0-1.0).
    ///   - textureComplexity: Texture complexity score (0.0-1.0).
    public init(edgeDensity: Double, frequencyEnergy: Double, textureComplexity: Double) {
        self.edgeDensity = max(0.0, min(1.0, edgeDensity))
        self.frequencyEnergy = max(0.0, min(1.0, frequencyEnergy))
        self.textureComplexity = max(0.0, min(1.0, textureComplexity))
    }
}

// MARK: - Aggressiveness

/// Aggressiveness level for adaptive block size selection.
///
/// Controls how aggressively the selector adapts block sizes based on
/// content metrics. More aggressive settings produce more varied block
/// sizes but may increase encoding overhead.
public enum J2KBlockSizeAggressiveness: String, Sendable, CaseIterable {
    /// Conservative: prefers larger blocks, only uses small blocks for very complex regions.
    ///
    /// Thresholds: complexity > 0.7 → 16×16, complexity > 0.4 → 32×32, else 64×64.
    case conservative

    /// Balanced: moderate adaptation based on content complexity.
    ///
    /// Thresholds: complexity > 0.5 → 16×16, complexity > 0.25 → 32×32, else 64×64.
    case balanced

    /// Aggressive: uses small blocks for most complex regions, large blocks only for smooth areas.
    ///
    /// Thresholds: complexity > 0.3 → 16×16, complexity > 0.15 → 32×32, else 64×64.
    case aggressive
}

// MARK: - Block Size Selection Mode

/// Mode for selecting code block sizes during encoding.
///
/// Determines whether block sizes are fixed (manual) or chosen adaptively
/// based on image content analysis.
public enum J2KBlockSizeMode: Sendable, Equatable {
    /// Use a fixed block size for all tiles (manual selection).
    ///
    /// This is the default backward-compatible mode where the encoder uses
    /// the `codeBlockSize` property directly.
    case fixed

    /// Automatically select block sizes per tile based on content analysis.
    ///
    /// The analyser examines each tile's edge density, frequency content,
    /// and texture complexity to choose optimal block dimensions from
    /// 16×16, 32×32, or 64×64.
    ///
    /// - Parameter aggressiveness: How aggressively to adapt block sizes.
    case adaptive(aggressiveness: J2KBlockSizeAggressiveness)

    public static func == (lhs: J2KBlockSizeMode, rhs: J2KBlockSizeMode) -> Bool {
        switch (lhs, rhs) {
        case (.fixed, .fixed):
            return true
        case let (.adaptive(a), .adaptive(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Content Analyser

/// Analyzes image tile content to determine optimal block sizes.
///
/// The analyser computes content metrics (edge density, frequency energy,
/// texture complexity) for each tile region. These metrics drive the
/// adaptive block size selection to balance quality and throughput.
///
/// ## Usage
///
/// ```swift
/// let analyser = J2KContentAnalyzer()
/// let metrics = analyser.analyzeRegion(samples: tileData, width: 256, height: 256)
/// let blockSize = analyser.selectBlockSize(for: metrics, aggressiveness: .balanced)
/// ```
public struct J2KContentAnalyzer: Sendable {
    /// Creates a new content analyser.
    public init() {}

    // MARK: - Edge Density Estimation

    /// Estimates edge density for a region of image samples.
    ///
    /// Uses a simplified Sobel gradient approximation to detect edges.
    /// The result is normalised to [0.0, 1.0] where 1.0 indicates maximum edge density.
    ///
    /// - Parameters:
    ///   - samples: Flattened array of pixel values (row-major).
    ///   - width: Width of the region in pixels.
    ///   - height: Height of the region in pixels.
    /// - Returns: Edge density in range [0.0, 1.0].
    public func estimateEdgeDensity(samples: [Int32], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, samples.count >= width * height else {
            return 0.0
        }

        var gradientSum: Double = 0.0
        let count = (width - 2) * (height - 2)
        guard count > 0 else { return 0.0 }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                // Simplified Sobel: horizontal and vertical gradients
                let gx = Int64(samples[(y - 1) * width + (x + 1)]) - Int64(samples[(y - 1) * width + (x - 1)])
                    + 2 * (Int64(samples[y * width + (x + 1)]) - Int64(samples[y * width + (x - 1)]))
                    + Int64(samples[(y + 1) * width + (x + 1)]) - Int64(samples[(y + 1) * width + (x - 1)])
                let gy = Int64(samples[(y + 1) * width + (x - 1)]) - Int64(samples[(y - 1) * width + (x - 1)])
                    + 2 * (Int64(samples[(y + 1) * width + x]) - Int64(samples[(y - 1) * width + x]))
                    + Int64(samples[(y + 1) * width + (x + 1)]) - Int64(samples[(y - 1) * width + (x + 1)])

                let magnitude = sqrt(Double(gx * gx + gy * gy))
                gradientSum += magnitude
            }
        }

        let averageGradient = gradientSum / Double(count)
        // Normalise: typical max gradient for 8-bit is ~1443 (255*4*sqrt(2))
        // Use 500.0 as practical normalisation factor for reasonable range
        return min(1.0, averageGradient / 500.0)
    }

    // MARK: - Frequency Content Analysis

    /// Analyzes frequency content of a region via DWT coefficient energy.
    ///
    /// Performs a single-level DWT decomposition and computes the ratio of
    /// high-frequency subband energy (LH + HL + HH) to total energy.
    /// Higher ratios indicate more high-frequency content.
    ///
    /// - Parameters:
    ///   - samples: Flattened array of pixel values (row-major).
    ///   - width: Width of the region in pixels.
    ///   - height: Height of the region in pixels.
    /// - Returns: Frequency energy ratio in range [0.0, 1.0].
    public func analyzeFrequencyContent(samples: [Int32], width: Int, height: Int) -> Double {
        guard width >= 4, height >= 4, samples.count >= width * height else {
            return 0.0
        }

        // Convert to 2D array for DWT
        var image: [[Int32]] = []
        for y in 0..<height {
            let row = Array(samples[(y * width)..<((y + 1) * width)])
            image.append(row)
        }

        // Perform single-level 2D DWT using Haar-like approximation
        let halfW = width / 2
        let halfH = height / 2
        guard halfW > 0, halfH > 0 else { return 0.0 }

        var llEnergy: Double = 0.0
        var detailEnergy: Double = 0.0

        for y in 0..<halfH {
            for x in 0..<halfW {
                let y2 = y * 2
                let x2 = x * 2

                let a = Double(image[y2][x2])
                let b = Double(image[y2][min(x2 + 1, width - 1)])
                let c = Double(image[min(y2 + 1, height - 1)][x2])
                let d = Double(image[min(y2 + 1, height - 1)][min(x2 + 1, width - 1)])

                let ll = (a + b + c + d) / 4.0
                let lh = (a + b - c - d) / 4.0
                let hl = (a - b + c - d) / 4.0
                let hh = (a - b - c + d) / 4.0

                llEnergy += ll * ll
                detailEnergy += lh * lh + hl * hl + hh * hh
            }
        }

        let totalEnergy = llEnergy + detailEnergy
        guard totalEnergy > 0 else { return 0.0 }

        return min(1.0, detailEnergy / totalEnergy)
    }

    // MARK: - Texture Complexity Scoring

    /// Computes a combined texture complexity score from content metrics.
    ///
    /// The score is a weighted combination of edge density and frequency energy:
    /// - Edge density weight: 0.4
    /// - Frequency energy weight: 0.6
    ///
    /// - Parameters:
    ///   - edgeDensity: Edge density metric (0.0-1.0).
    ///   - frequencyEnergy: Frequency energy metric (0.0-1.0).
    /// - Returns: Texture complexity score in range [0.0, 1.0].
    public func computeTextureComplexity(edgeDensity: Double, frequencyEnergy: Double) -> Double {
        min(1.0, 0.4 * edgeDensity + 0.6 * frequencyEnergy)
    }

    // MARK: - Full Region Analysis

    /// Analyzes a tile region and returns comprehensive content metrics.
    ///
    /// Computes edge density, frequency content, and texture complexity
    /// for the given region of image samples.
    ///
    /// - Parameters:
    ///   - samples: Flattened array of pixel values (row-major).
    ///   - width: Width of the region in pixels.
    ///   - height: Height of the region in pixels.
    /// - Returns: Content metrics for the region.
    public func analyzeRegion(samples: [Int32], width: Int, height: Int) -> J2KContentMetrics {
        let edgeDensity = estimateEdgeDensity(samples: samples, width: width, height: height)
        let frequencyEnergy = analyzeFrequencyContent(samples: samples, width: width, height: height)
        let textureComplexity = computeTextureComplexity(
            edgeDensity: edgeDensity,
            frequencyEnergy: frequencyEnergy
        )
        return J2KContentMetrics(
            edgeDensity: edgeDensity,
            frequencyEnergy: frequencyEnergy,
            textureComplexity: textureComplexity
        )
    }

    // MARK: - Block Size Selection

    /// Selects the optimal block size for a tile based on its content metrics.
    ///
    /// Maps content complexity to block sizes using the given aggressiveness level:
    /// - **High complexity** → smaller blocks (16×16) for better quality
    /// - **Medium complexity** → medium blocks (32×32) for balanced performance
    /// - **Low complexity** → larger blocks (64×64) for faster encoding
    ///
    /// - Parameters:
    ///   - metrics: Content metrics for the tile region.
    ///   - aggressiveness: How aggressively to adapt block sizes.
    /// - Returns: Recommended block size as (width, height).
    public func selectBlockSize(
        for metrics: J2KContentMetrics,
        aggressiveness: J2KBlockSizeAggressiveness
    ) -> (width: Int, height: Int) {
        let complexity = metrics.textureComplexity

        let (highThreshold, mediumThreshold): (Double, Double) = {
            switch aggressiveness {
            case .conservative:
                return (0.7, 0.4)
            case .balanced:
                return (0.5, 0.25)
            case .aggressive:
                return (0.3, 0.15)
            }
        }()

        if complexity > highThreshold {
            return (width: 16, height: 16)
        } else if complexity > mediumThreshold {
            return (width: 32, height: 32)
        } else {
            return (width: 64, height: 64)
        }
    }
}

// MARK: - Adaptive Block Size Selector

/// Selects block sizes for all tiles in an image using content analysis.
///
/// The selector processes each tile region, analyses its content, and
/// determines the optimal code block size. Per-tile overrides can be
/// provided to bypass automatic selection for specific tiles.
///
/// ## Usage
///
/// ```swift
/// let selector = J2KAdaptiveBlockSizeSelector(
///     aggressiveness: .balanced,
///     overrides: [0: (32, 32)]  // Force tile 0 to 32×32
/// )
/// let sizes = selector.selectBlockSizes(for: image)
/// ```
public struct J2KAdaptiveBlockSizeSelector: Sendable {
    /// The aggressiveness level for block size adaptation.
    public let aggressiveness: J2KBlockSizeAggressiveness

    /// Per-tile block size overrides (tile index → block size).
    ///
    /// When a tile index has an override, the adaptive analysis is skipped
    /// and the override value is used directly.
    public let overrides: [Int: (width: Int, height: Int)]

    /// The content analyser used for tile analysis.
    private let analyzer: J2KContentAnalyzer

    /// Creates an adaptive block size selector.
    ///
    /// - Parameters:
    ///   - aggressiveness: Aggressiveness level (default: .balanced).
    ///   - overrides: Per-tile block size overrides (default: empty).
    public init(
        aggressiveness: J2KBlockSizeAggressiveness = .balanced,
        overrides: [Int: (width: Int, height: Int)] = [:]
    ) {
        self.aggressiveness = aggressiveness
        self.overrides = overrides
        self.analyzer = J2KContentAnalyzer()
    }

    /// Selects block sizes for all tiles in an image.
    ///
    /// For each tile, either uses the per-tile override or analyses
    /// the tile content to select the optimal block size.
    ///
    /// - Parameter image: The image to analyse.
    /// - Returns: Array of block sizes, one per tile. For non-tiled images,
    ///   returns a single-element array.
    public func selectBlockSizes(for image: J2KImage) -> [(width: Int, height: Int)] {
        let tileCount = max(1, image.tileCount)
        var result: [(width: Int, height: Int)] = []
        result.reserveCapacity(tileCount)

        for tileIndex in 0..<tileCount {
            if let override = overrides[tileIndex] {
                result.append(override)
                continue
            }

            let samples = extractTileSamples(from: image, tileIndex: tileIndex)
            let tileWidth: Int
            let tileHeight: Int

            if image.isTiled {
                let tilesX = image.tilesX
                let tileCol = tileIndex % tilesX
                let tileRow = tileIndex / tilesX
                tileWidth = min(image.tileWidth, image.width - tileCol * image.tileWidth)
                tileHeight = min(image.tileHeight, image.height - tileRow * image.tileHeight)
            } else {
                tileWidth = image.width
                tileHeight = image.height
            }

            let metrics = analyzer.analyzeRegion(
                samples: samples,
                width: tileWidth,
                height: tileHeight
            )
            let blockSize = analyzer.selectBlockSize(
                for: metrics,
                aggressiveness: aggressiveness
            )
            result.append(blockSize)
        }

        return result
    }

    /// Analyzes a single tile and returns its content metrics.
    ///
    /// - Parameters:
    ///   - image: The image containing the tile.
    ///   - tileIndex: Index of the tile to analyse.
    /// - Returns: Content metrics for the tile.
    public func analyzeTile(from image: J2KImage, tileIndex: Int) -> J2KContentMetrics {
        let samples = extractTileSamples(from: image, tileIndex: tileIndex)
        let tileWidth: Int
        let tileHeight: Int

        if image.isTiled {
            let tilesX = image.tilesX
            let tileCol = tileIndex % tilesX
            let tileRow = tileIndex / tilesX
            tileWidth = min(image.tileWidth, image.width - tileCol * image.tileWidth)
            tileHeight = min(image.tileHeight, image.height - tileRow * image.tileHeight)
        } else {
            tileWidth = image.width
            tileHeight = image.height
        }

        return analyzer.analyzeRegion(
            samples: samples,
            width: tileWidth,
            height: tileHeight
        )
    }

    // MARK: - Sample Extraction

    /// Extracts pixel samples for a tile from the first component of the image.
    ///
    /// - Parameters:
    ///   - image: The source image.
    ///   - tileIndex: Index of the tile to extract.
    /// - Returns: Flattened array of Int32 pixel values (row-major).
    private func extractTileSamples(from image: J2KImage, tileIndex: Int) -> [Int32] {
        guard !image.components.isEmpty else { return [] }

        let component = image.components[0]
        let bitDepth = component.bitDepth
        let lowByteOffset = component.sampleByteOrder == .bigEndian ? 1 : 0

        if !image.isTiled {
            return component.data.withUnsafeBytes { buffer -> [Int32] in
                let bytesPerSample = bitDepth <= 8 ? 1 : 2
                let sampleCount = min(image.width * image.height, buffer.count / bytesPerSample)
                var samples = [Int32]()
                samples.reserveCapacity(sampleCount)
                for i in 0..<sampleCount {
                    if bytesPerSample == 1 {
                        samples.append(Int32(buffer[i]))
                    } else {
                        let lo = Int32(buffer[i * 2 + lowByteOffset])
                        let hi = Int32(buffer[i * 2 + 1 - lowByteOffset])
                        samples.append(lo | (hi << 8))
                    }
                }
                return samples
            }
        }

        let tilesX = image.tilesX
        let tileCol = tileIndex % tilesX
        let tileRow = tileIndex / tilesX
        let startX = tileCol * image.tileWidth
        let startY = tileRow * image.tileHeight
        let tw = min(image.tileWidth, image.width - startX)
        let th = min(image.tileHeight, image.height - startY)

        let bytesPerSample = bitDepth <= 8 ? 1 : 2

        return component.data.withUnsafeBytes { buffer -> [Int32] in
            var samples = [Int32]()
            samples.reserveCapacity(tw * th)
            for y in startY..<(startY + th) {
                for x in startX..<(startX + tw) {
                    let idx = y * image.width + x
                    if bytesPerSample == 1 {
                        if idx < buffer.count {
                            samples.append(Int32(buffer[idx]))
                        }
                    } else {
                        let byteIdx = idx * 2
                        if byteIdx + 1 < buffer.count {
                            let lo = Int32(buffer[byteIdx + lowByteOffset])
                            let hi = Int32(buffer[byteIdx + 1 - lowByteOffset])
                            samples.append(lo | (hi << 8))
                        }
                    }
                }
            }
            return samples
        }
    }
}
