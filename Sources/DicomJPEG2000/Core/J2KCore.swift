//
// J2KCore.swift
// J2KSwift
//
/// # J2KCore
///
/// Core module for JPEG 2000 encoding and decoding functionality.
///
/// This module provides the foundational types, protocols, and utilities for JPEG 2000 image
/// processing. It defines the basic building blocks used by other modules in the J2KSwift framework.
///
/// ## Topics
///
/// ### Core Types
/// - ``J2KImage``
/// - ``J2KComponent``
/// - ``J2KTile``
/// - ``J2KTileComponent``
/// - ``J2KPrecinct``
/// - ``J2KCodeBlock``
///
/// ### Memory Management
/// - ``J2KBuffer``
/// - ``J2KImageBuffer``
/// - ``J2KMemoryTracker``
///
/// ### Enumerations
/// - ``J2KSubband``
/// - ``J2KColorSpace``
/// - ``J2KError``
///
/// ### Configuration
/// - ``J2KConfiguration``

import Foundation

/// Represents a JPEG 2000 image with metadata and pixel data.
///
/// A J2KImage contains all the necessary information to describe a JPEG 2000 image,
/// including dimensions, components, tiling information, and colour space metadata.
public struct J2KImage: Sendable {
    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The image components (colour channels).
    public let components: [J2KComponent]

    /// The horizontal offset of the image reference grid origin.
    public let offsetX: Int

    /// The vertical offset of the image reference grid origin.
    public let offsetY: Int

    /// The width of a tile in pixels (0 means no tiling).
    public let tileWidth: Int

    /// The height of a tile in pixels (0 means no tiling).
    public let tileHeight: Int

    /// The horizontal offset of the first tile.
    public let tileOffsetX: Int

    /// The vertical offset of the first tile.
    public let tileOffsetY: Int

    /// The colour space of the image.
    public let colorSpace: J2KColorSpace

    /// Creates a new J2KImage with the specified parameters.
    ///
    /// - Parameters:
    ///   - width: The width of the image in pixels.
    ///   - height: The height of the image in pixels.
    ///   - components: The image components (colour channels).
    ///   - offsetX: The horizontal offset of the image reference grid origin (default: 0).
    ///   - offsetY: The vertical offset of the image reference grid origin (default: 0).
    ///   - tileWidth: The width of a tile in pixels, 0 for no tiling (default: 0).
    ///   - tileHeight: The height of a tile in pixels, 0 for no tiling (default: 0).
    ///   - tileOffsetX: The horizontal offset of the first tile (default: 0).
    ///   - tileOffsetY: The vertical offset of the first tile (default: 0).
    ///   - colorSpace: The colour space of the image (default: .sRGB).
    public init(
        width: Int,
        height: Int,
        components: [J2KComponent],
        offsetX: Int = 0,
        offsetY: Int = 0,
        tileWidth: Int = 0,
        tileHeight: Int = 0,
        tileOffsetX: Int = 0,
        tileOffsetY: Int = 0,
        colorSpace: J2KColorSpace = .sRGB
    ) {
        self.width = width
        self.height = height
        self.components = components
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.tileOffsetX = tileOffsetX
        self.tileOffsetY = tileOffsetY
        self.colorSpace = colorSpace
    }

    /// Convenience initializer for simple images without tiling.
    ///
    /// - Parameters:
    ///   - width: The width of the image in pixels.
    ///   - height: The height of the image in pixels.
    ///   - components: The number of colour components (e.g., 3 for RGB, 4 for RGBA).
    ///   - bitDepth: The bit depth per component (default: 8).
    ///   - signed: Whether the components are signed (default: false).
    public init(width: Int, height: Int, components: Int, bitDepth: Int = 8, signed: Bool = false) {
        // Validate and clamp inputs
        let validWidth = max(1, width) // At least 1 pixel wide
        let validHeight = max(1, height) // At least 1 pixel high
        let validComponents = max(1, components) // At least 1 component
        let validBitDepth = max(1, min(38, bitDepth)) // Between 1 and 38 bits

        let imageComponents = (0..<validComponents).map { index in
            J2KComponent(
                index: index,
                bitDepth: validBitDepth,
                signed: signed,
                width: validWidth,
                height: validHeight
            )
        }

        self.init(
            width: validWidth,
            height: validHeight,
            components: imageComponents
        )
    }

    /// Returns the number of tiles in the horizontal direction.
    public var tilesX: Int {
        guard tileWidth > 0 else { return 1 }
        return (width + tileWidth - 1) / tileWidth
    }

    /// Returns the number of tiles in the vertical direction.
    public var tilesY: Int {
        guard tileHeight > 0 else { return 1 }
        return (height + tileHeight - 1) / tileHeight
    }

    /// Returns the total number of tiles in the image.
    public var tileCount: Int {
        tilesX * tilesY
    }

    // MARK: - Convenience Properties

    /// Returns true if the image uses tiling.
    public var isTiled: Bool {
        tileWidth > 0 && tileHeight > 0
    }

    /// Returns the total number of pixels in the image.
    public var pixelCount: Int {
        width * height
    }

    /// Returns the number of components in the image.
    public var componentCount: Int {
        components.count
    }

    /// Returns true if the image is grayscale (single component).
    public var isGrayscale: Bool {
        components.count == 1
    }

    /// Returns true if the image has an alpha channel.
    ///
    /// An alpha channel is assumed to be present if there are 2 components (grayscale + alpha)
    /// or 4 components (RGB + alpha).
    public var hasAlpha: Bool {
        components.count == 2 || components.count == 4
    }

    /// Returns the aspect ratio of the image (width / height).
    public var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    // MARK: - Validation Methods

    /// Validates that the image has valid dimensions and components.
    ///
    /// - Throws: ``J2KError/invalidDimensions(_:)`` if dimensions are invalid.
    /// - Throws: ``J2KError/invalidComponentConfiguration(_:)`` if components are invalid.
    public func validate() throws {
        guard width > 0 && height > 0 else {
            throw J2KError.invalidDimensions("Image dimensions must be positive: \(width)x\(height)")
        }

        guard !components.isEmpty else {
            throw J2KError.invalidComponentConfiguration("Image must have at least one component")
        }

        for component in components {
            guard component.bitDepth >= 1 && component.bitDepth <= 38 else {
                throw J2KError.invalidBitDepth("Component \(component.index) has invalid bit depth: \(component.bitDepth)")
            }
        }

        if isTiled {
            guard tileWidth > 0 && tileHeight > 0 else {
                throw J2KError.invalidTileConfiguration("Tile dimensions must be positive if tiling is enabled")
            }
        }
    }
}

/// Represents a single component (colour channel) of a JPEG 2000 image.
///
/// Each component has its own bit depth, sign, and dimensions. Components can be
/// subsampled relative to the full image resolution.
public struct J2KComponent: Sendable {
    /// Byte order of 16-bit sample data inside `data`. Only meaningful when
    /// `bitDepth > 8`. When nil (the default), the encoder auto-detects the
    /// byte order via a statistical heuristic — this works well for natural
    /// images but can flip at full 16-bit bit-depth (where both orderings
    /// fit UInt16 range). Set explicitly when you know the input format to
    /// guarantee a correct round-trip.
    public enum ByteOrder: Sendable {
        /// Low byte first (DICOM Explicit VR LE, native Apple Silicon).
        case littleEndian
        /// High byte first (PGM, DICOM Explicit VR BE, our decoder's output).
        case bigEndian
    }

    /// The index of this component (0-based).
    public let index: Int

    /// The bit depth of this component (1-38 bits).
    public let bitDepth: Int

    /// Whether this component uses signed values.
    public let signed: Bool

    /// The width of this component in pixels.
    public let width: Int

    /// The height of this component in pixels.
    public let height: Int

    /// The horizontal subsampling factor relative to the reference grid.
    public let subsamplingX: Int

    /// The vertical subsampling factor relative to the reference grid.
    public let subsamplingY: Int

    /// The pixel data for this component.
    public var data: Data

    /// Explicit byte-order hint for 16-bit sample data (see `ByteOrder`).
    /// Ignored for 8-bit components. When nil, the encoder infers the order
    /// from the sample distribution — reliable for ≤ 14-bit data, less so at
    /// full 16-bit where both interpretations always fit UInt16.
    public let sampleByteOrder: ByteOrder?

    public init(
        index: Int,
        bitDepth: Int,
        signed: Bool = false,
        width: Int,
        height: Int,
        subsamplingX: Int = 1,
        subsamplingY: Int = 1,
        data: Data = Data(),
        sampleByteOrder: ByteOrder? = nil
    ) {
        self.index = index
        self.bitDepth = bitDepth
        self.signed = signed
        self.width = width
        self.height = height
        self.subsamplingX = subsamplingX
        self.subsamplingY = subsamplingY
        self.data = data
        self.sampleByteOrder = sampleByteOrder
    }

    // MARK: - Convenience Properties

    /// Returns the total number of pixels in the component.
    public var pixelCount: Int {
        width * height
    }

    /// Returns true if the component is subsampled.
    public var isSubsampled: Bool {
        subsamplingX > 1 || subsamplingY > 1
    }

    /// Returns the maximum value for this component's bit depth.
    public var maxValue: Int {
        (1 << bitDepth) - 1
    }

    /// Returns the minimum value for this component (0 for unsigned, negative for signed).
    public var minValue: Int {
        signed ? -(1 << (bitDepth - 1)) : 0
    }
}

/// Represents a tile in a JPEG 2000 image.
///
/// Tiles are rectangular regions that can be encoded and decoded independently.
/// They enable parallel processing and memory-efficient streaming.
public struct J2KTile: Sendable {
    /// The index of this tile.
    public let index: Int

    /// The x-coordinate of the tile in the tile grid.
    public let x: Int

    /// The y-coordinate of the tile in the tile grid.
    public let y: Int

    /// The width of this tile in pixels.
    public let width: Int

    /// The height of this tile in pixels.
    public let height: Int

    /// The x-offset of this tile in the reference grid.
    public let offsetX: Int

    /// The y-offset of this tile in the reference grid.
    public let offsetY: Int

    /// The tile-components (one per image component).
    public var components: [J2KTileComponent]

    /// Creates a new tile with the specified parameters.
    ///
    /// - Parameters:
    ///   - index: The tile index.
    ///   - x: The x-coordinate in the tile grid.
    ///   - y: The y-coordinate in the tile grid.
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    ///   - offsetX: The x-offset in the reference grid.
    ///   - offsetY: The y-offset in the reference grid.
    ///   - components: The tile-components.
    public init(
        index: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        offsetX: Int,
        offsetY: Int,
        components: [J2KTileComponent] = []
    ) {
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.components = components
    }
}

/// Represents a component within a tile.
public struct J2KTileComponent: Sendable {
    /// The component index.
    public let componentIndex: Int

    /// The width of this tile-component in pixels.
    public let width: Int

    /// The height of this tile-component in pixels.
    public let height: Int

    /// The precincts in this tile-component (organised by resolution level).
    public var precincts: [[J2KPrecinct]]

    /// Creates a new tile-component.
    ///
    /// - Parameters:
    ///   - componentIndex: The component index.
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    ///   - precincts: The precincts organised by resolution level.
    public init(
        componentIndex: Int,
        width: Int,
        height: Int,
        precincts: [[J2KPrecinct]] = []
    ) {
        self.componentIndex = componentIndex
        self.width = width
        self.height = height
        self.precincts = precincts
    }
}

/// Represents a precinct in the wavelet decomposition.
///
/// A precinct is a spatial region within a resolution level that groups code-blocks
/// for efficient organization and streaming.
public struct J2KPrecinct: Sendable {
    /// The precinct index within its resolution level.
    public let index: Int

    /// The x-coordinate of the precinct.
    public let x: Int

    /// The y-coordinate of the precinct.
    public let y: Int

    /// The width of this precinct in the subband coordinate system.
    public let width: Int

    /// The height of this precinct in the subband coordinate system.
    public let height: Int

    /// The resolution level this precinct belongs to.
    public let resolutionLevel: Int

    /// The code-blocks in this precinct organised by subband (LL, HL, LH, HH).
    public var codeBlocks: [J2KSubband: [J2KCodeBlock]]

    /// Creates a new precinct.
    ///
    /// - Parameters:
    ///   - index: The precinct index.
    ///   - x: The x-coordinate.
    ///   - y: The y-coordinate.
    ///   - width: The width.
    ///   - height: The height.
    ///   - resolutionLevel: The resolution level.
    ///   - codeBlocks: The code-blocks organised by subband.
    public init(
        index: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        resolutionLevel: Int,
        codeBlocks: [J2KSubband: [J2KCodeBlock]] = [:]
    ) {
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.resolutionLevel = resolutionLevel
        self.codeBlocks = codeBlocks
    }
}

/// Lightweight snapshot of the MQ encoder register state at a coding pass boundary.
///
/// Captures only the 5 scalar values needed to reconstruct the terminated
/// byte stream at a specific coding pass. Used with the shared raw MQ output
/// array to avoid O(n) full-encoder copies during EBCOT encoding.
public struct MQCheckpointData: Sendable {
    /// Number of bytes emitted to the raw output at this checkpoint.
    public let outputCount: Int
    /// MQ interval register.
    public let a: UInt32
    /// MQ code register.
    public let c: UInt32
    /// MQ bit counter.
    public let ct: Int
    /// MQ pending buffer byte (-1 if no byte pending).
    public let buffer: Int

    public init(outputCount: Int, a: UInt32, c: UInt32, ct: Int, buffer: Int) {
        self.outputCount = outputCount
        self.a = a
        self.c = c
        self.ct = ct
        self.buffer = buffer
    }
}

/// Represents a code-block, the fundamental unit for entropy coding.
///
/// Code-blocks are small rectangular regions (typically 32×32 or 64×64 samples)
/// that are independently coded using the EBCOT algorithm.
public struct J2KCodeBlock: Sendable {
    /// The code-block index within its precinct and subband.
    public let index: Int

    /// The x-coordinate of the code-block.
    public let x: Int

    /// The y-coordinate of the code-block.
    public let y: Int

    /// The width of this code-block in samples.
    public let width: Int

    /// The height of this code-block in samples.
    public let height: Int

    /// The subband this code-block belongs to.
    public let subband: J2KSubband

    /// The component index this code-block belongs to.
    public let componentIndex: Int

    /// The JPEG 2000 resolution level this code-block belongs to.
    ///
    /// Resolution 0 contains only the LL subband. Resolution r (1..NL) contains
    /// the HL, LH, HH subbands at decomposition level (NL - r + 1).
    public let resolutionLevel: Int

    /// The encoded data for this code-block.
    public var data: Data

    /// The number of coding passes applied to this code-block.
    public var passeCount: Int

    /// The number of missing most significant bit-planes.
    public var zeroBitPlanes: Int

    /// The byte lengths of each coding pass segment.
    ///
    /// When predictable termination is used, the encoder resets after each
    /// coding pass, producing separate data segments. This array stores
    /// the byte length of each segment so the decoder can reset at the
    /// correct boundaries.
    ///
    /// When empty, the data is treated as a single contiguous segment
    /// (default/non-predictable termination mode).
    public var passSegmentLengths: [Int]

    /// Cumulative byte counts after each coding pass.
    ///
    /// Used by rate control for per-pass truncation. Each element represents
    /// the total encoded bytes after `i+1` coding passes. When empty, rate
    /// control falls back to proportional estimation.
    public var cumulativePassBytes: [Int]

    /// Sum of squared magnitudes of the quantized coefficients in this code block.
    ///
    /// Used by rate control for accurate distortion estimation. The initial
    /// distortion (all coefficients zeroed) equals this value times the
    /// quantization step size squared.
    public var coefficientSquaredSum: Double

    /// Per-bit-plane population counts.
    ///
    /// Element `i` is the number of coefficients whose most significant bit
    /// is at bit-plane `i` (0-indexed from the MSB of the maximum magnitude).
    /// Used by rate control for accurate per-pass distortion reduction.
    public var bitPlanePopulation: [Int]

    /// Cumulative actual distortion reduction after each coding pass.
    ///
    /// Element `i` is the total squared-error reduction (vs. zero reconstruction)
    /// achieved by including coding passes 0 through `i`. Computed during EBCOT
    /// encoding from the actual coefficient values and reconstruction state.
    /// Used by rate control for accurate PCRD slope computation.
    public var cumulativePassDistortion: [Double]

    /// Properly terminated MQ data for each prefix of coding passes.
    ///
    /// Element `i` contains a correctly terminated MQ byte stream encoding
    /// passes 0 through `i`. Used during PCRD truncation to avoid using a
    /// prefix of the final encoded stream which may contain carry-corrupted
    /// bytes from later passes.
    public var perPassSnapshotData: [Data]

    /// Lightweight MQ encoder checkpoints for deferred truncation.
    ///
    /// Each checkpoint stores only the MQ register state (5 scalars) at a
    /// coding pass boundary. Combined with ``rawMQOutput``, this is sufficient
    /// to reconstruct the exact terminated byte stream at any pass boundary
    /// on-demand, avoiding the O(n²) cost of full encoder snapshots during
    /// encoding. When non-empty, ``perPassSnapshotData`` is empty and
    /// truncation uses these checkpoints instead.
    public var mqCheckpoints: [MQCheckpointData]

    /// Raw MQ encoder output bytes (before termination).
    ///
    /// Shared across all checkpoints for a code block. Bytes already
    /// emitted to this array are never modified by subsequent MQ encoding
    /// (carries only propagate into the buffer register). Used with
    /// ``mqCheckpoints`` to reconstruct terminated data on-demand.
    public var rawMQOutput: [UInt8]

    /// The quantizer step size used for this code-block's coefficients.
    ///
    /// Nil for lossless (5/3) encoding where coefficients are integers. Non-nil
    /// for lossy (9/7) encoding, where it supplies the stepsize² factor PCRD
    /// needs to convert quantized-coefficient MSE to dequantized-subband MSE
    /// (matching OpenJPEG / ISO 15444-1 Annex E).
    public var quantizationStep: Double?

    public init(
        index: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        subband: J2KSubband,
        componentIndex: Int = 0,
        resolutionLevel: Int = 0,
        data: Data = Data(),
        passeCount: Int = 0,
        zeroBitPlanes: Int = 0,
        passSegmentLengths: [Int] = [],
        cumulativePassBytes: [Int] = [],
        coefficientSquaredSum: Double = 0,
        bitPlanePopulation: [Int] = [],
        cumulativePassDistortion: [Double] = [],
        perPassSnapshotData: [Data] = [],
        mqCheckpoints: [MQCheckpointData] = [],
        rawMQOutput: [UInt8] = [],
        quantizationStep: Double? = nil
    ) {
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.subband = subband
        self.componentIndex = componentIndex
        self.resolutionLevel = resolutionLevel
        self.data = data
        self.passeCount = passeCount
        self.zeroBitPlanes = zeroBitPlanes
        self.passSegmentLengths = passSegmentLengths
        self.cumulativePassBytes = cumulativePassBytes
        self.coefficientSquaredSum = coefficientSquaredSum
        self.bitPlanePopulation = bitPlanePopulation
        self.cumulativePassDistortion = cumulativePassDistortion
        self.perPassSnapshotData = perPassSnapshotData
        self.mqCheckpoints = mqCheckpoints
        self.rawMQOutput = rawMQOutput
        self.quantizationStep = quantizationStep
    }
}

/// Represents a subband in the wavelet decomposition.
public enum J2KSubband: String, Sendable, Hashable {
    /// Low-low subband (approximation).
    case ll = "LL"

    /// High-low subband (horizontal detail).
    case hl = "HL"

    /// Low-high subband (vertical detail).
    case lh = "LH"

    /// High-high subband (diagonal detail).
    case hh = "HH"
}

/// Represents the colour space of a JPEG 2000 image.
public enum J2KColorSpace: Sendable, Equatable {
    /// sRGB colour space (standard dynamic range).
    case sRGB

    /// Grayscale (single component).
    case grayscale

    /// YCbCr colour space.
    case yCbCr

    /// HDR colour space with extended dynamic range (e.g., Rec. 2020, Rec. 2100).
    ///
    /// HDR images typically use higher bit depths (10, 12, or 16 bits) and represent
    /// luminance values that exceed the standard 0-1 range of SDR content.
    ///
    /// Common HDR standards:
    /// - Rec. 2020: Wide colour gamut for UHDTV
    /// - Rec. 2100 (HLG/PQ): HDR transfer functions
    /// - SMPTE ST 2084 (PQ): Perceptual quantization
    /// - ARIB STD-B67 (HLG): Hybrid log-gamma
    case hdr

    /// HDR colour space with linear light encoding.
    ///
    /// Linear HDR represents light intensity directly without gamma correction,
    /// suitable for physically-based rendering and compositing operations.
    case hdrLinear

    /// ICC profile-based colour space.
    case iccProfile(Data)

    /// Unknown or unspecified colour space.
    case unknown

    /// Equatable conformance for J2KColorSpace.
    public static func == (lhs: J2KColorSpace, rhs: J2KColorSpace) -> Bool {
        switch (lhs, rhs) {
        case (.sRGB, .sRGB),
             (.grayscale, .grayscale),
             (.yCbCr, .yCbCr),
             (.hdr, .hdr),
             (.hdrLinear, .hdrLinear),
             (.unknown, .unknown):
            return true
        case let (.iccProfile(lhsData), .iccProfile(rhsData)):
            return lhsData == rhsData
        default:
            return false
        }
    }
}

/// Errors that can occur during JPEG 2000 operations.
public enum J2KError: Error, Sendable {
    /// An invalid parameter was provided.
    case invalidParameter(String)

    /// The operation is not yet implemented.
    case notImplemented(String)

    /// An internal error occurred.
    case internalError(String)

    /// Invalid image dimensions.
    case invalidDimensions(String)

    /// Invalid bit depth.
    case invalidBitDepth(String)

    /// Invalid tile configuration.
    case invalidTileConfiguration(String)

    /// Invalid component configuration.
    case invalidComponentConfiguration(String)

    /// Corrupted or invalid data.
    case invalidData(String)

    /// File format error.
    case fileFormatError(String)

    /// Unsupported feature.
    case unsupportedFeature(String)

    /// Decoding error.
    case decodingError(String)

    /// The entropy data of a code-block does not match its packet header: corrupted or truncated bytes that the
    /// arithmetic decoder would otherwise decode silently (#2899).
    case corruptedEntropyData(String)

    /// Encoding error.
    case encodingError(String)

    /// I/O error.
    case ioError(String)
}

// MARK: - J2KError Extensions

extension J2KError: LocalizedError {
    /// A localized description of the error.
    public var errorDescription: String? {
        switch self {
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        case .invalidDimensions(let message):
            return "Invalid dimensions: \(message)"
        case .invalidBitDepth(let message):
            return "Invalid bit depth: \(message)"
        case .invalidTileConfiguration(let message):
            return "Invalid tile configuration: \(message)"
        case .invalidComponentConfiguration(let message):
            return "Invalid component configuration: \(message)"
        case .invalidData(let message):
            return "Invalid data: \(message)"
        case .fileFormatError(let message):
            return "File format error: \(message)"
        case .unsupportedFeature(let message):
            return "Unsupported feature: \(message)"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        case .corruptedEntropyData(let message):
            return "Corrupted entropy data: \(message)"
        case .encodingError(let message):
            return "Encoding error: \(message)"
        case .ioError(let message):
            return "I/O error: \(message)"
        }
    }
}

extension J2KError: CustomStringConvertible {
    /// A textual representation of the error.
    public var description: String {
        errorDescription ?? "Unknown J2K error"
    }
}

/// Configuration options for JPEG 2000 operations.
public struct J2KConfiguration: Sendable {
    /// The quality factor for encoding (0.0 to 1.0).
    public let quality: Double

    /// Whether to use lossless compression.
    public let lossless: Bool

    /// Creates a new configuration with the specified options.
    ///
    /// - Parameters:
    ///   - quality: The quality factor (default: 0.9).
    ///   - lossless: Whether to use lossless compression (default: false).
    public init(quality: Double = 0.9, lossless: Bool = false) {
        self.quality = quality
        self.lossless = lossless
    }

    // MARK: - Convenience Factory Methods

    /// Creates a configuration for lossless compression.
    ///
    /// Use this preset when you need perfect reconstruction of the original image
    /// without any quality loss. Results in larger file sizes but maintains all
    /// original image data.
    ///
    /// - Returns: A configuration for lossless compression.
    public static var lossless: J2KConfiguration {
        J2KConfiguration(quality: 1.0, lossless: true)
    }

    /// Creates a configuration for high-quality lossy compression.
    ///
    /// Use this preset when you want excellent visual quality with moderate compression.
    /// Suitable for archival purposes and professional photography.
    ///
    /// - Returns: A configuration for high-quality compression (quality: 0.95).
    public static var highQuality: J2KConfiguration {
        J2KConfiguration(quality: 0.95, lossless: false)
    }

    /// Creates a configuration for balanced compression.
    ///
    /// Use this preset for a good balance between file size and visual quality.
    /// This is the recommended default for most use cases.
    ///
    /// - Returns: A configuration for balanced compression (quality: 0.85).
    public static var balanced: J2KConfiguration {
        J2KConfiguration(quality: 0.85, lossless: false)
    }

    /// Creates a configuration for fast compression with smaller file sizes.
    ///
    /// Use this preset when file size is more important than visual quality,
    /// such as for web delivery or bandwidth-constrained scenarios.
    ///
    /// - Returns: A configuration for fast compression (quality: 0.70).
    public static var fast: J2KConfiguration {
        J2KConfiguration(quality: 0.70, lossless: false)
    }

    /// Creates a configuration for maximum compression.
    ///
    /// Use this preset when you need the smallest possible file size and can
    /// tolerate visible compression artifacts.
    ///
    /// - Returns: A configuration for maximum compression (quality: 0.50).
    public static var maxCompression: J2KConfiguration {
        J2KConfiguration(quality: 0.50, lossless: false)
    }
}

/// Returns the version of the J2KSwift framework.
///
/// This function returns the semantic version string for the current release of J2KSwift.
/// The version follows semantic versioning (semver) format: MAJOR.MINOR.PATCH.
///
/// Example:
/// ```swift
/// let version = getVersion()
/// print("J2KSwift version: \(version)")
/// ```
///
/// - Returns: A string representing the current version in semver format.
public func getVersion() -> String {
    "11.0.2"
}
