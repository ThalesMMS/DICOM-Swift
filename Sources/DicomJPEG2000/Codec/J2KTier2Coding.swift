//
// J2KTier2Coding.swift
// J2KSwift
//
/// # Tier-2 Coding
///
/// Implementation of JPEG 2000 Tier-2 coding (packet header encoding/decoding).
///
/// Tier-2 coding organizes the output of Tier-1 coding (code-block contributions)
/// into packets. Each packet contains data for one precinct in one quality layer.
/// The packet header describes which code-blocks contribute data and how many
/// coding passes are included from each code-block.
///
/// ## Topics
///
/// ### Progression Orders
/// - ``ProgressionOrder``
///
/// ### Packet Headers
/// - ``PacketHeader``
/// - ``PacketHeaderWriter``
/// - ``PacketHeaderReader``
///
/// ### Layer Formation
/// - ``QualityLayer``
/// - ``LayerFormation``

import Foundation

// MARK: - Progression Order

/// Defines the order in which packets are written to the codestream.
///
/// JPEG 2000 supports five progression orders that determine how image data
/// is organised for transmission. Each order provides different benefits for
/// specific use cases.
public enum ProgressionOrder: UInt8, Sendable, CaseIterable {
    /// Layer-Resolution-Component-Position (LRCP).
    ///
    /// Packets are ordered by quality layer first, then resolution level,
    /// then component, and finally spatial position. This order is optimal
    /// for progressive quality refinement.
    case lrcp = 0

    /// Resolution-Layer-Component-Position (RLCP).
    ///
    /// Packets are ordered by resolution level first, then quality layer,
    /// then component, and finally spatial position. This order is optimal
    /// for progressive resolution refinement.
    case rlcp = 1

    /// Resolution-Position-Component-Layer (RPCL).
    ///
    /// Packets are ordered by resolution level, then spatial position,
    /// then component, and finally quality layer. This order allows for
    /// efficient spatial region-of-interest decoding.
    case rpcl = 2

    /// Position-Component-Resolution-Layer (PCRL).
    ///
    /// Packets are ordered by spatial position first, then component,
    /// then resolution level, and finally quality layer. This order is
    /// optimal for random access to spatial regions.
    case pcrl = 3

    /// Component-Position-Resolution-Layer (CPRL).
    ///
    /// Packets are ordered by component first, then spatial position,
    /// then resolution level, and finally quality layer. This order is
    /// useful for component-specific processing.
    case cprl = 4

    /// Returns a human-readable name for the progression order.
    public var name: String {
        switch self {
        case .lrcp: return "LRCP (Layer-Resolution-Component-Position)"
        case .rlcp: return "RLCP (Resolution-Layer-Component-Position)"
        case .rpcl: return "RPCL (Resolution-Position-Component-Layer)"
        case .pcrl: return "PCRL (Position-Component-Resolution-Layer)"
        case .cprl: return "CPRL (Component-Position-Resolution-Layer)"
        }
    }

    /// Returns a short acronym for the progression order.
    public var acronym: String {
        switch self {
        case .lrcp: return "LRCP"
        case .rlcp: return "RLCP"
        case .rpcl: return "RPCL"
        case .pcrl: return "PCRL"
        case .cprl: return "CPRL"
        }
    }
}

// MARK: - Quality Layer

/// Represents a quality layer in JPEG 2000 encoding.
///
/// Quality layers allow for progressive quality refinement. Each layer contains
/// additional coding passes from code-blocks, progressively improving image quality.
public struct QualityLayer: Sendable {
    /// The layer index (0-based).
    public let index: Int

    /// The target bit rate for this layer (bits per pixel), or nil for lossless.
    public let targetRate: Double?

    /// Code-block contributions for this layer.
    ///
    /// Maps code-block index to the number of coding passes included from that block.
    public var codeBlockContributions: [Int: Int]

    /// Creates a new quality layer.
    ///
    /// - Parameters:
    ///   - index: The layer index.
    ///   - targetRate: The target bit rate in bits per pixel (nil for lossless).
    ///   - codeBlockContributions: The code-block contributions.
    public init(
        index: Int,
        targetRate: Double? = nil,
        codeBlockContributions: [Int: Int] = [:]
    ) {
        self.index = index
        self.targetRate = targetRate
        self.codeBlockContributions = codeBlockContributions
    }
}

// MARK: - Packet Header

/// Represents the header of a packet in the JPEG 2000 codestream.
///
/// A packet header contains information about code-block contributions
/// to the current quality layer for a specific precinct.
public struct PacketHeader: Sendable {
    /// The layer index this packet belongs to.
    public let layerIndex: Int

    /// The resolution level index.
    public let resolutionLevel: Int

    /// The component index.
    public let componentIndex: Int

    /// The precinct index.
    public let precinctIndex: Int

    /// Whether the packet is empty (no code-block data).
    public let isEmpty: Bool

    /// Code-block inclusion information.
    ///
    /// For each code-block in the precinct, indicates whether it has
    /// any contribution in this packet.
    public var codeBlockInclusions: [Bool]

    /// Number of coding passes for each included code-block.
    ///
    /// Only valid for code-blocks where `codeBlockInclusions` is true.
    public var codingPasses: [Int]

    /// Length of encoded data for each included code-block.
    ///
    /// Only valid for code-blocks where `codeBlockInclusions` is true.
    public var dataLengths: [Int]

    /// Creates a new packet header.
    ///
    /// - Parameters:
    ///   - layerIndex: The quality layer index.
    ///   - resolutionLevel: The resolution level.
    ///   - componentIndex: The component index.
    ///   - precinctIndex: The precinct index.
    ///   - isEmpty: Whether the packet is empty.
    ///   - codeBlockInclusions: Code-block inclusion flags.
    ///   - codingPasses: Number of coding passes per code-block.
    ///   - dataLengths: Data lengths per code-block.
    public init(
        layerIndex: Int,
        resolutionLevel: Int,
        componentIndex: Int,
        precinctIndex: Int,
        isEmpty: Bool = false,
        codeBlockInclusions: [Bool] = [],
        codingPasses: [Int] = [],
        dataLengths: [Int] = []
    ) {
        self.layerIndex = layerIndex
        self.resolutionLevel = resolutionLevel
        self.componentIndex = componentIndex
        self.precinctIndex = precinctIndex
        self.isEmpty = isEmpty
        self.codeBlockInclusions = codeBlockInclusions
        self.codingPasses = codingPasses
        self.dataLengths = dataLengths
    }
}

// MARK: - Packet Header Writer

/// Writes packet headers to the JPEG 2000 codestream.
///
/// The packet header writer encodes packet information using tag trees
/// and arithmetic coding for efficient compression.
///
/// ## Example
///
/// ```swift
/// let writer = PacketHeaderWriter()
/// let header = PacketHeader(layerIndex: 0, resolutionLevel: 0, ...)
/// let encodedHeader = try writer.encode(header)
/// ```
public struct PacketHeaderWriter: Sendable {
    /// Creates a new packet header writer.
    public init() {}

    /// Encodes a packet header.
    ///
    /// - Parameter header: The packet header to encode.
    /// - Returns: The encoded packet header data.
    /// - Throws: ``J2KError`` if encoding fails.
    public func encode(_ header: PacketHeader) throws -> Data {
        var writer = J2KBitWriter()

        // Write empty packet flag (1 bit)
        if header.isEmpty {
            writer.writeBit(false)
            return writer.data
        }
        writer.writeBit(true)

        // Initialise MQ encoder for tag tree and other packet header elements
        var encoder = MQEncoder()
        var context = MQContext()

        // Encode code-block inclusions
        for included in header.codeBlockInclusions {
            encoder.encode(symbol: included, context: &context)
        }

        // For included code-blocks, encode number of coding passes
        var passIndex = 0
        for included in header.codeBlockInclusions where included {
            guard passIndex < header.dataLengths.count else {
                throw J2KError.invalidData("Missing data length information")
            }
            let length = header.dataLengths[passIndex]

            // Encode length in a simple way (this is simplified)
            // In real JPEG 2000, this uses a more sophisticated encoding
            var remaining = length
            while remaining > 0 {
                encoder.encode(symbol: (remaining & 1) != 0, context: &context)
                remaining >>= 1
            }
            encoder.encode(symbol: false, context: &context) // Terminator

            passIndex += 1
        }

        // Finish MQ encoding
        let mqData = encoder.finish()

        // Write MQ encoded data
        writer.writeBytes(mqData)

        return writer.data
    }

    /// Encodes multiple packet headers in sequence.
    ///
    /// - Parameter headers: The packet headers to encode.
    /// - Returns: The encoded packet headers data.
    /// - Throws: ``J2KError`` if encoding fails.
    public func encodeMultiple(_ headers: [PacketHeader]) throws -> Data {
        var allData = Data()
        for header in headers {
            let headerData = try encode(header)
            allData.append(headerData)
        }
        return allData
    }
}

// MARK: - Packet Header Reader

/// Reads packet headers from the JPEG 2000 codestream.
///
/// The packet header reader decodes packet information that was encoded
/// using tag trees and arithmetic coding.
///
/// ## Example
///
/// ```swift
/// let reader = PacketHeaderReader(data: codestreamData)
/// let header = try reader.decode(
///     layerIndex: 0,
///     resolutionLevel: 0,
///     componentIndex: 0,
///     precinctIndex: 0,
///     codeBlockCount: 16
/// )
/// ```
public struct PacketHeaderReader: Sendable {
    /// The codestream data.
    private let data: Data

    /// The current read position.
    private var position: Int

    /// Creates a new packet header reader.
    ///
    /// - Parameters:
    ///   - data: The codestream data.
    ///   - position: The initial read position (default: 0).
    public init(data: Data, position: Int = 0) {
        self.data = data
        self.position = position
    }

    /// Decodes a packet header.
    ///
    /// - Parameters:
    ///   - layerIndex: The expected layer index.
    ///   - resolutionLevel: The expected resolution level.
    ///   - componentIndex: The expected component index.
    ///   - precinctIndex: The expected precinct index.
    ///   - codeBlockCount: The number of code-blocks in the precinct.
    /// - Returns: The decoded packet header.
    /// - Throws: ``J2KError`` if decoding fails.
    public mutating func decode(
        layerIndex: Int,
        resolutionLevel: Int,
        componentIndex: Int,
        precinctIndex: Int,
        codeBlockCount: Int
    ) throws -> PacketHeader {
        var reader = J2KBitReader(data: data)
        try reader.seek(to: position)

        // Read empty packet flag
        let notEmpty = try reader.readBit()
        if !notEmpty {
            position = reader.position
            return PacketHeader(
                layerIndex: layerIndex,
                resolutionLevel: resolutionLevel,
                componentIndex: componentIndex,
                precinctIndex: precinctIndex,
                isEmpty: true
            )
        }

        // Initialise MQ decoder
        let mqData = data.suffix(from: reader.position)
        var decoder = MQDecoder(data: mqData)
        var context = MQContext()

        // Decode code-block inclusions
        var inclusions = [Bool]()
        for _ in 0..<codeBlockCount {
            let included = decoder.decode(context: &context)
            inclusions.append(included)
        }

        // Decode coding passes for included code-blocks
        var codingPasses = [Int]()
        for included in inclusions where included {
            // Decode number of passes
            let firstBit = decoder.decode(context: &context)
            if firstBit {
                // Single pass
                codingPasses.append(1)
            } else {
                let secondBit = decoder.decode(context: &context)
                if secondBit {
                    // 2 or 3 passes
                    let thirdBit = decoder.decode(context: &context)
                    codingPasses.append(thirdBit ? 3 : 2)
                } else {
                    // More than 3 passes
                    var passes = 4
                    var bit = decoder.decode(context: &context)
                    var shift = 0
                    while bit {
                        passes += (1 << shift)
                        shift += 1
                        bit = decoder.decode(context: &context)
                    }
                    codingPasses.append(passes)
                }
            }
        }

        // Decode data lengths for included code-blocks
        var dataLengths = [Int]()
        for included in inclusions where included {
            var length = 0
            var shift = 0
            var bit = decoder.decode(context: &context)
            while bit {
                length += (1 << shift)
                shift += 1
                bit = decoder.decode(context: &context)
            }
            dataLengths.append(length)
        }

        // Update position (approximate - we advance by the data we've processed)
        // In practice, packet headers are followed by packet body, so position
        // management is handled by the higher-level packet parser
        position = reader.position

        return PacketHeader(
            layerIndex: layerIndex,
            resolutionLevel: resolutionLevel,
            componentIndex: componentIndex,
            precinctIndex: precinctIndex,
            isEmpty: false,
            codeBlockInclusions: inclusions,
            codingPasses: codingPasses,
            dataLengths: dataLengths
        )
    }
}

// MARK: - Layer Formation

/// Manages the formation of quality layers from code-block contributions.
///
/// The layer formation algorithm determines which coding passes from each
/// code-block should be included in each quality layer to achieve target
/// bit rates while maximising image quality.
public struct LayerFormation: Sendable {
    /// The target bit rates for each layer (bits per pixel).
    public let targetRates: [Double]

    /// Whether to use rate-distortion optimisation.
    public let useRDOptimization: Bool

    /// Creates a new layer formation configuration.
    ///
    /// - Parameters:
    ///   - targetRates: Target bit rates for each layer in bits per pixel.
    ///   - useRDOptimization: Whether to use rate-distortion optimisation (default: false).
    public init(targetRates: [Double], useRDOptimization: Bool = false) {
        self.targetRates = targetRates
        self.useRDOptimization = useRDOptimization
    }

    /// Forms quality layers from code-block data.
    ///
    /// - Parameters:
    ///   - codeBlocks: The code-blocks to organize into layers.
    ///   - totalPixels: The total number of pixels in the image.
    /// - Returns: An array of quality layers.
    /// - Throws: ``J2KError`` if layer formation fails.
    public func formLayers(
        codeBlocks: [J2KCodeBlock],
        totalPixels: Int
    ) throws -> [QualityLayer] {
        // Use rate-distortion optimisation if enabled
        if useRDOptimization {
            let rateControl = J2KRateControl(targetRates: targetRates)
            return try rateControl.optimizeLayers(
                codeBlocks: codeBlocks,
                totalPixels: totalPixels
            )
        }

        // Otherwise use simple proportional allocation
        var layers = [QualityLayer]()

        for (index, targetRate) in targetRates.enumerated() {
            var contributions = [Int: Int]()

            // Calculate target bytes for this layer
            let targetBytes = Int(targetRate * Double(totalPixels) / 8.0)
            var currentBytes = 0

            // Distribute coding passes to code-blocks
            for codeBlock in codeBlocks {
                // Simple strategy: include passes proportionally
                let maxPasses = min(codeBlock.passeCount, 3 * (index + 1))

                if maxPasses > 0 && currentBytes < targetBytes {
                    contributions[codeBlock.index] = maxPasses
                    currentBytes += codeBlock.data.count
                }
            }

            layers.append(QualityLayer(
                index: index,
                targetRate: targetRate,
                codeBlockContributions: contributions
            ))
        }

        return layers
    }

    /// Forms layers with lossless encoding (all passes in final layer).
    ///
    /// - Parameter codeBlocks: The code-blocks to organize.
    /// - Returns: A single quality layer containing all code-block data.
    public func formLosslessLayer(codeBlocks: [J2KCodeBlock]) -> QualityLayer {
        var contributions = [Int: Int]()

        for codeBlock in codeBlocks where codeBlock.passeCount > 0 {
            contributions[codeBlock.index] = codeBlock.passeCount
        }

        return QualityLayer(
            index: 0,
            targetRate: nil,
            codeBlockContributions: contributions
        )
    }
}
