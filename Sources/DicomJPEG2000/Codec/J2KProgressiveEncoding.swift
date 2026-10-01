//
// J2KProgressiveEncoding.swift
// J2KSwift
//
// J2KProgressiveEncoding.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-07.
//

import Foundation

// # JPEG 2000 Progressive Encoding
//
// Support for progressive encoding modes in JPEG 2000.
//
// Progressive encoding allows images to be decoded at different levels of quality,
// resolution, or detail, enabling efficient streaming and adaptive delivery.
//
// ## Progressive Modes
//
// - **SNR Progressive**: Quality layers provide increasing quality
// - **Spatial Progressive**: Resolution levels provide increasing resolution
// - **Layer Progressive**: Individual layers can be decoded independently
//
// ## Usage
//
// ```swift
// // Create a progressive encoding configuration
// let progressive = J2KProgressiveMode.snr(layers: 8)
// var config = J2KEncodingConfiguration()
// config.progressiveMode = progressive
//
// // Encode with progressive mode
// let encoder = J2KEncoder(configuration: config)
// let data = try encoder.encode(image)
//
// // The encoded data can be decoded progressively
// let decoder = J2KDecoder()
// let preview = try decoder.decodeProgressive(data, upToLayer: 2)
// let full = try decoder.decodeProgressive(data, upToLayer: 8)
// ```

// MARK: - Progressive Mode

/// Progressive encoding modes for JPEG 2000.
public enum J2KProgressiveMode: Sendable, Equatable {
    /// SNR (Signal-to-Noise Ratio) progressive encoding.
    ///
    /// Encodes multiple quality layers, allowing progressive quality improvement.
    /// The base layer provides a low-quality preview, and each successive layer
    /// refines the quality.
    ///
    /// - Parameter layers: Number of quality layers (1-20).
    ///
    /// **Use cases:**
    /// - Progressive web image delivery
    /// - Quality-adaptive streaming
    /// - Bandwidth-constrained networks
    case snr(layers: Int)

    /// Spatial (resolution) progressive encoding.
    ///
    /// Encodes multiple resolution levels through wavelet decomposition.
    /// Lower resolution levels can be decoded without processing higher resolutions.
    ///
    /// - Parameter maxLevel: Maximum decomposition level (0-10).
    ///
    /// **Use cases:**
    /// - Multi-resolution image pyramids
    /// - Zoom applications
    /// - Responsive image delivery
    case spatial(maxLevel: Int)

    /// Layer-progressive encoding for streaming.
    ///
    /// Organizes packets to enable layer-by-layer decoding with immediate display
    /// after each layer. Combines spatial and quality progression.
    ///
    /// - Parameters:
    ///   - layers: Number of quality layers.
    ///   - resolutionFirst: If true, prioritise resolution over quality.
    ///
    /// **Use cases:**
    /// - Real-time streaming
    /// - Network-adaptive delivery
    /// - Interactive applications
    case layerProgressive(layers: Int, resolutionFirst: Bool)

    /// Combined SNR and spatial progressive encoding.
    ///
    /// Provides both quality and resolution progression for maximum flexibility.
    ///
    /// - Parameters:
    ///   - qualityLayers: Number of quality layers.
    ///   - decompositionLevels: Number of wavelet decomposition levels.
    ///
    /// **Use cases:**
    /// - Advanced streaming applications
    /// - Multi-purpose image delivery
    /// - Adaptive content delivery networks
    case combined(qualityLayers: Int, decompositionLevels: Int)

    /// No progressive encoding (single quality, single resolution).
    case none

    /// Returns the number of quality layers for this progressive mode.
    public var qualityLayers: Int {
        switch self {
        case .snr(let layers), .layerProgressive(let layers, _):
            return layers
        case .spatial:
            return 1
        case .combined(let layers, _):
            return layers
        case .none:
            return 1
        }
    }

    /// Returns the number of decomposition levels for this progressive mode.
    public var decompositionLevels: Int? {
        switch self {
        case .snr:
            return nil  // Use default or configured value
        case .spatial(let levels):
            return levels
        case .layerProgressive:
            return nil  // Use default or configured value
        case .combined(_, let levels):
            return levels
        case .none:
            return nil
        }
    }

    /// Returns the recommended progression order for this mode.
    public var recommendedProgressionOrder: J2KProgressionOrder {
        switch self {
        case .snr:
            return .lrcp  // Layer-Resolution-Component-Position for quality progression
        case .spatial:
            return .rlcp  // Resolution-Layer-Component-Position for spatial progression
        case .layerProgressive(_, let resolutionFirst):
            return resolutionFirst ? .rpcl : .lrcp
        case .combined:
            return .rpcl  // Resolution-Position-Component-Layer for combined
        case .none:
            return .lrcp
        }
    }

    /// Validates the progressive mode parameters.
    ///
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    public func validate() throws {
        switch self {
        case .snr(let layers), .layerProgressive(let layers, _):
            if layers < 1 || layers > 20 {
                throw J2KError.invalidParameter("Quality layers must be between 1 and 20, got \(layers)")
            }
        case .spatial(let level):
            if level < 0 || level > 10 {
                throw J2KError.invalidParameter("Decomposition level must be between 0 and 10, got \(level)")
            }
        case let .combined(layers, levels):
            if layers < 1 || layers > 20 {
                throw J2KError.invalidParameter("Quality layers must be between 1 and 20, got \(layers)")
            }
            if levels < 0 || levels > 10 {
                throw J2KError.invalidParameter("Decomposition levels must be between 0 and 10, got \(levels)")
            }
        case .none:
            break
        }
    }
}

// MARK: - Progressive Decoding Options

/// Options for progressive decoding.
public struct J2KProgressiveDecodingOptions: Sendable, Equatable {
    /// Maximum quality layer to decode (inclusive).
    ///
    /// If nil, decodes all available layers.
    public var maxLayer: Int?

    /// Maximum resolution level to decode (inclusive).
    ///
    /// - 0: Decode only the coarsest resolution (1/2^N of full resolution)
    /// - nil: Decode all resolution levels (full resolution)
    public var maxResolutionLevel: Int?

    /// Specific region to decode (in full-resolution coordinates).
    ///
    /// If nil, decodes the entire image.
    public var region: J2KRegion?

    /// Whether to stop decoding early once the requested quality/resolution is reached.
    ///
    /// When true, stops parsing packets after reaching the target layer/resolution,
    /// saving processing time and memory.
    public var earlyStop: Bool

    /// Creates new progressive decoding options.
    ///
    /// - Parameters:
    ///   - maxLayer: Maximum quality layer to decode (default: nil for all layers).
    ///   - maxResolutionLevel: Maximum resolution level (default: nil for full resolution).
    ///   - region: Specific region to decode (default: nil for full image).
    ///   - earlyStop: Enable early stopping optimisation (default: true).
    public init(
        maxLayer: Int? = nil,
        maxResolutionLevel: Int? = nil,
        region: J2KRegion? = nil,
        earlyStop: Bool = true
    ) {
        self.maxLayer = maxLayer
        self.maxResolutionLevel = maxResolutionLevel
        self.region = region
        self.earlyStop = earlyStop
    }
}

// MARK: - Region Definition

/// Defines a rectangular region in an image.
public struct J2KRegion: Sendable, Equatable {
    /// The x-coordinate of the top-left corner.
    public let x: Int

    /// The y-coordinate of the top-left corner.
    public let y: Int

    /// The width of the region.
    public let width: Int

    /// The height of the region.
    public let height: Int

    /// Creates a new region.
    ///
    /// - Parameters:
    ///   - x: The x-coordinate of the top-left corner.
    ///   - y: The y-coordinate of the top-left corner.
    ///   - width: The width of the region.
    ///   - height: The height of the region.
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Validates the region against image dimensions.
    ///
    /// - Parameters:
    ///   - imageWidth: The width of the full image.
    ///   - imageHeight: The height of the full image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the region is invalid.
    public func validate(imageWidth: Int, imageHeight: Int) throws {
        if x < 0 || y < 0 {
            throw J2KError.invalidParameter("Region coordinates must be non-negative")
        }

        if width <= 0 || height <= 0 {
            throw J2KError.invalidParameter("Region dimensions must be positive")
        }

        if x + width > imageWidth || y + height > imageHeight {
            throw J2KError.invalidParameter("Region extends beyond image bounds")
        }
    }
}

// MARK: - Progressive Encoding Strategy

/// Strategy for organising progressive encoding.
public struct J2KProgressiveEncodingStrategy: Sendable {
    /// The progressive mode to use.
    public let mode: J2KProgressiveMode

    /// Whether to use SNR scalability within each resolution level.
    public let snrScalable: Bool

    /// Whether to use spatial (resolution) scalability.
    public let spatialScalable: Bool

    /// Target bitrates for each quality layer (in bits per pixel).
    ///
    /// If provided, the encoder will target these bitrates for each layer.
    /// If nil, layers are distributed evenly.
    public let layerBitrates: [Double]?

    /// Creates a new progressive encoding strategy.
    ///
    /// - Parameters:
    ///   - mode: The progressive mode.
    ///   - snrScalable: Enable SNR scalability (default: true).
    ///   - spatialScalable: Enable spatial scalability (default: true).
    ///   - layerBitrates: Optional target bitrates per layer.
    public init(
        mode: J2KProgressiveMode,
        snrScalable: Bool = true,
        spatialScalable: Bool = true,
        layerBitrates: [Double]? = nil
    ) {
        self.mode = mode
        self.snrScalable = snrScalable
        self.spatialScalable = spatialScalable
        self.layerBitrates = layerBitrates
    }

    /// Creates a strategy optimised for quality progression.
    ///
    /// - Parameter layers: Number of quality layers.
    /// - Returns: A quality-progressive encoding strategy.
    public static func qualityProgressive(layers: Int) -> J2KProgressiveEncodingStrategy {
        J2KProgressiveEncodingStrategy(
            mode: .snr(layers: layers),
            snrScalable: true,
            spatialScalable: false
        )
    }

    /// Creates a strategy optimised for resolution progression.
    ///
    /// - Parameter levels: Maximum decomposition level.
    /// - Returns: A resolution-progressive encoding strategy.
    public static func resolutionProgressive(levels: Int) -> J2KProgressiveEncodingStrategy {
        J2KProgressiveEncodingStrategy(
            mode: .spatial(maxLevel: levels),
            snrScalable: false,
            spatialScalable: true
        )
    }

    /// Creates a strategy optimised for streaming.
    ///
    /// - Parameters:
    ///   - layers: Number of quality layers.
    ///   - levels: Maximum decomposition level.
    /// - Returns: A streaming-optimised encoding strategy.
    public static func streaming(layers: Int, levels: Int) -> J2KProgressiveEncodingStrategy {
        J2KProgressiveEncodingStrategy(
            mode: .combined(qualityLayers: layers, decompositionLevels: levels),
            snrScalable: true,
            spatialScalable: true
        )
    }

    /// Validates the strategy parameters.
    ///
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    public func validate() throws {
        try mode.validate()

        if let bitrates = layerBitrates {
            if bitrates.count != mode.qualityLayers {
                throw J2KError.invalidParameter("Layer bitrates count must match quality layers")
            }

            for (index, bitrate) in bitrates.enumerated() {
                if bitrate <= 0 {
                    throw J2KError.invalidParameter("Layer bitrate[\(index)] must be positive")
                }

                // Verify increasing bitrates
                if index > 0 && bitrate <= bitrates[index - 1] {
                    throw J2KError.invalidParameter("Layer bitrates must be strictly increasing")
                }
            }
        }
    }
}

// MARK: - Extensions

extension J2KEncodingConfiguration {
    /// The progressive mode for this configuration.
    ///
    /// Derived from quality layers and decomposition levels.
    public var progressiveMode: J2KProgressiveMode {
        if qualityLayers > 1 && decompositionLevels > 0 {
            return .combined(qualityLayers: qualityLayers, decompositionLevels: decompositionLevels)
        } else if qualityLayers > 1 {
            return .snr(layers: qualityLayers)
        } else if decompositionLevels > 0 {
            return .spatial(maxLevel: decompositionLevels)
        } else {
            return .none
        }
    }
}

extension J2KProgressiveMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .snr(let layers):
            return "SNR Progressive (\(layers) quality layers)"
        case .spatial(let level):
            return "Spatial Progressive (up to \(level) decomposition levels)"
        case let .layerProgressive(layers, resFirst):
            let priority = resFirst ? "resolution-first" : "quality-first"
            return "Layer Progressive (\(layers) layers, \(priority))"
        case let .combined(layers, levels):
            return "Combined Progressive (\(layers) quality layers, \(levels) decomposition levels)"
        case .none:
            return "Non-progressive"
        }
    }
}

extension J2KRegion: CustomStringConvertible {
    public var description: String {
        "(\(x), \(y), \(width)×\(height))"
    }
}
