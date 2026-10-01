//
// J2KPart2CodestreamExtensions.swift
// J2KSwift
//
// J2KPart2CodestreamExtensions.swift
// J2KSwift
//
// Part 2 codestream marker extensions for ISO/IEC 15444-2.
// Provides extended SIZ capabilities, COD/COC extensions, and QCD/QCC extensions.
//
// Copyright (c) 2024 J2KSwift contributors
// Licensed under the MIT License

import Foundation

// MARK: - Part 2 Rsiz Capabilities

/// Part 2 SIZ marker capability profiles defined in ISO/IEC 15444-2.
///
/// The Rsiz field in the SIZ marker segment indicates the capabilities
/// required to decode the codestream. Part 2 extensions use specific
/// bit patterns to signal required features.
///
/// ## Rsiz Values
///
/// - `0x0000`: Part 1 baseline (no extensions)
/// - `0x0001`: Profile 0 (Part 1)
/// - `0x0002`: Profile 1 (Part 1)
/// - `0x8000`: Part 2 extensions present
/// - `0x4000`: Part 15 HTJ2K extensions
///
/// Part 2 profiles combine the Part 2 flag (bit 15) with feature bits:
///
/// | Bit | Feature |
/// |-----|---------|
/// | 15  | Part 2 extensions present |
/// | 14  | HTJ2K (Part 15) |
/// | 0   | Multi-component transform |
/// | 1   | Arbitrary wavelets |
/// | 2   | Trellis coded quantization |
/// | 3   | Extended ROI |
/// | 4   | DC offset |
/// | 5   | Non-linear transform |
/// | 6   | Extended precision |
/// | 7   | Visual masking / Perceptual encoding |
///
/// Example:
/// ```swift
/// let caps = J2KPart2Capabilities(configuration: myConfig)
/// let rsiz = caps.rsizValue
/// let features = caps.requiredFeatures
/// ```
public struct J2KPart2Capabilities: Sendable, Equatable {
    /// Rsiz flag: Part 2 extensions present (bit 15).
    public static let part2Flag: UInt16 = 0x8000

    /// Rsiz flag: HTJ2K Part 15 extensions (bit 14).
    public static let htj2kFlag: UInt16 = 0x4000

    /// Part 2 feature bit: Multi-component transform (bit 0).
    public static let mctBit: UInt16 = 0x0001

    /// Part 2 feature bit: Arbitrary wavelets (bit 1).
    public static let arbitraryWaveletsBit: UInt16 = 0x0002

    /// Part 2 feature bit: Trellis coded quantization (bit 2).
    public static let trellisQuantizationBit: UInt16 = 0x0004

    /// Part 2 feature bit: Extended ROI (bit 3).
    public static let extendedROIBit: UInt16 = 0x0008

    /// Part 2 feature bit: DC offset (bit 4).
    public static let dcOffsetBit: UInt16 = 0x0010

    /// Part 2 feature bit: Non-linear transform (bit 5).
    public static let nonLinearTransformBit: UInt16 = 0x0020

    /// Part 2 feature bit: Extended precision (bit 6).
    public static let extendedPrecisionBit: UInt16 = 0x0040

    /// Part 2 feature bit: Visual masking / perceptual encoding (bit 7).
    public static let visualMaskingBit: UInt16 = 0x0080

    /// The computed Rsiz value for the SIZ marker segment.
    public let rsizValue: UInt16

    /// Whether any Part 2 extensions are required.
    public var requiresPart2: Bool {
        (rsizValue & Self.part2Flag) != 0
    }

    /// Whether HTJ2K extensions are required.
    public var requiresHTJ2K: Bool {
        (rsizValue & Self.htj2kFlag) != 0
    }

    /// Whether multi-component transform is used.
    public var usesMCT: Bool {
        (rsizValue & Self.mctBit) != 0
    }

    /// Whether arbitrary wavelets are used.
    public var usesArbitraryWavelets: Bool {
        (rsizValue & Self.arbitraryWaveletsBit) != 0
    }

    /// Whether trellis coded quantization is used.
    public var usesTrellisQuantization: Bool {
        (rsizValue & Self.trellisQuantizationBit) != 0
    }

    /// Whether extended ROI is used.
    public var usesExtendedROI: Bool {
        (rsizValue & Self.extendedROIBit) != 0
    }

    /// Whether DC offset is used.
    public var usesDCOffset: Bool {
        (rsizValue & Self.dcOffsetBit) != 0
    }

    /// Whether non-linear transform is used.
    public var usesNonLinearTransform: Bool {
        (rsizValue & Self.nonLinearTransformBit) != 0
    }

    /// Whether extended precision is used.
    public var usesExtendedPrecision: Bool {
        (rsizValue & Self.extendedPrecisionBit) != 0
    }

    /// Whether visual masking or perceptual encoding is used.
    public var usesVisualMasking: Bool {
        (rsizValue & Self.visualMaskingBit) != 0
    }

    /// Creates Part 2 capabilities from an explicit Rsiz value.
    ///
    /// - Parameter rsizValue: The Rsiz field value from the SIZ marker.
    public init(rsizValue: UInt16) {
        self.rsizValue = rsizValue
    }

    /// Creates Part 2 capabilities from an encoding configuration.
    ///
    /// Examines the configuration to determine which Part 2 features are
    /// enabled and computes the appropriate Rsiz value.
    ///
    /// - Parameter configuration: The encoding configuration to examine.
    public init(configuration: J2KEncodingConfiguration) {
        var rsiz: UInt16 = 0
        var hasPart2 = false

        // Check MCT configuration
        switch configuration.mctConfiguration.mode {
        case .arrayBased, .dependency, .adaptive:
            rsiz |= Self.mctBit
            hasPart2 = true
        case .disabled:
            break
        }

        // Check arbitrary wavelets
        if configuration.waveletKernelConfiguration.usesArbitraryWavelets {
            rsiz |= Self.arbitraryWaveletsBit
            hasPart2 = true
        }

        // Check DC offset
        if configuration.dcOffsetConfiguration.enabled {
            rsiz |= Self.dcOffsetBit
            hasPart2 = true
        }

        // Check extended precision
        if configuration.extendedPrecisionConfiguration != .default {
            rsiz |= Self.extendedPrecisionBit
            hasPart2 = true
        }

        // Set Part 2 flag if any Part 2 features are used
        if hasPart2 {
            rsiz |= Self.part2Flag
        }

        // Check HTJ2K
        if configuration.useHTJ2K {
            rsiz |= Self.htj2kFlag
        }

        self.rsizValue = rsiz
    }

    /// Returns a human-readable list of required Part 2 features.
    public var featureDescriptions: [String] {
        var features: [String] = []
        if requiresPart2 { features.append("Part 2 Extensions") }
        if requiresHTJ2K { features.append("HTJ2K (Part 15)") }
        if usesMCT { features.append("Multi-Component Transform") }
        if usesArbitraryWavelets { features.append("Arbitrary Wavelets") }
        if usesTrellisQuantization { features.append("Trellis Coded Quantization") }
        if usesExtendedROI { features.append("Extended ROI") }
        if usesDCOffset { features.append("DC Offset") }
        if usesNonLinearTransform { features.append("Non-Linear Transform") }
        if usesExtendedPrecision { features.append("Extended Precision") }
        if usesVisualMasking { features.append("Visual Masking") }
        return features
    }
}

// MARK: - Part 2 COD/COC Extensions

/// Part 2 extended coding style parameters for COD/COC marker segments.
///
/// ISO/IEC 15444-2 extends the COD and COC markers with additional
/// coding style options beyond Part 1 baseline:
///
/// - Extended entropy coding modes
/// - Additional precinct size configurations
/// - Multi-component coding support
/// - Arbitrary decomposition control
///
/// Example:
/// ```swift
/// let ext = J2KPart2CodingExtensions(configuration: config)
/// print(ext.extendedScodBits)
/// ```
public struct J2KPart2CodingExtensions: Sendable, Equatable {
    /// Whether arbitrary decomposition styles are used.
    public var usesArbitraryDecomposition: Bool

    /// Whether multi-component coding is used (beyond standard RCT/ICT).
    public var usesMultiComponentCoding: Bool

    /// Extended precinct sizes for Part 2 configurations.
    public var extendedPrecinctSizes: [PrecinctSize]

    /// A precinct size at a specific decomposition level.
    public struct PrecinctSize: Sendable, Equatable {
        /// The decomposition level (0 = coarsest).
        public var level: Int

        /// Width exponent (precinct width = 2^widthExponent).
        public var widthExponent: UInt8

        /// Height exponent (precinct height = 2^heightExponent).
        public var heightExponent: UInt8

        /// Creates a precinct size.
        ///
        /// - Parameters:
        ///   - level: The decomposition level.
        ///   - widthExponent: Width exponent (log2 of width).
        ///   - heightExponent: Height exponent (log2 of height).
        public init(level: Int, widthExponent: UInt8, heightExponent: UInt8) {
            self.level = level
            self.widthExponent = widthExponent
            self.heightExponent = heightExponent
        }
    }

    /// Creates Part 2 coding extensions from an encoding configuration.
    ///
    /// - Parameter configuration: The encoding configuration.
    public init(configuration: J2KEncodingConfiguration) {
        self.usesArbitraryDecomposition = configuration.waveletKernelConfiguration.usesArbitraryWavelets
        switch configuration.mctConfiguration.mode {
        case .arrayBased, .dependency, .adaptive:
            self.usesMultiComponentCoding = true
        case .disabled:
            self.usesMultiComponentCoding = false
        }
        self.extendedPrecinctSizes = []
    }

    /// Creates Part 2 coding extensions with explicit parameters.
    ///
    /// - Parameters:
    ///   - usesArbitraryDecomposition: Whether arbitrary decomposition is used.
    ///   - usesMultiComponentCoding: Whether multi-component coding is used.
    ///   - extendedPrecinctSizes: Extended precinct sizes per level.
    public init(
        usesArbitraryDecomposition: Bool = false,
        usesMultiComponentCoding: Bool = false,
        extendedPrecinctSizes: [PrecinctSize] = []
    ) {
        self.usesArbitraryDecomposition = usesArbitraryDecomposition
        self.usesMultiComponentCoding = usesMultiComponentCoding
        self.extendedPrecinctSizes = extendedPrecinctSizes
    }

    /// Whether any Part 2 coding extensions are active.
    public var hasPart2Extensions: Bool {
        usesArbitraryDecomposition || usesMultiComponentCoding || !extendedPrecinctSizes.isEmpty
    }

    /// Encodes the extended Scod byte bits for Part 2 features.
    ///
    /// Returns the additional Scod bit flags for Part 2 coding extensions.
    /// These bits are OR'd with the standard Part 1 Scod value.
    public var extendedScodBits: UInt8 {
        var bits: UInt8 = 0
        if !extendedPrecinctSizes.isEmpty {
            bits |= 0x01  // Bit 0: User-defined precinct sizes
        }
        return bits
    }
}

// MARK: - Part 2 QCD/QCC Extensions

/// Part 2 extended quantization parameters for QCD/QCC marker segments.
///
/// ISO/IEC 15444-2 extends quantization with:
///
/// - Trellis coded quantization (TCQ) support
/// - Extended guard bits (up to 15 instead of 7)
/// - Additional quantization styles for Part 2 features
///
/// Example:
/// ```swift
/// let ext = J2KPart2QuantizationExtensions(configuration: config)
/// print(ext.extendedGuardBits)
/// print(ext.usesTrellisQuantization)
/// ```
public struct J2KPart2QuantizationExtensions: Sendable, Equatable {
    /// Extended guard bits for higher precision (Part 2 allows 0-15).
    public var extendedGuardBits: UInt8

    /// Whether trellis coded quantization is active.
    public var usesTrellisQuantization: Bool

    /// Whether deadzone quantization adjustments are applied.
    public var usesDeadzoneAdjustment: Bool

    /// Creates Part 2 quantization extensions from an encoding configuration.
    ///
    /// - Parameter configuration: The encoding configuration.
    public init(configuration: J2KEncodingConfiguration) {
        // Extended precision may require additional guard bits
        if configuration.extendedPrecisionConfiguration != .default {
            self.extendedGuardBits = UInt8(min(15, configuration.extendedPrecisionConfiguration.guardBits.count))
        } else if !configuration.lossless {
            // For lossy (9-7 irreversible) encoding, use 2 guard bits
            // matching the standard convention (ISO 15444-1) and OpenJPEG.
            self.extendedGuardBits = 2
        } else {
            self.extendedGuardBits = 2
        }
        self.usesTrellisQuantization = false
        self.usesDeadzoneAdjustment = false
    }

    /// Creates Part 2 quantization extensions with explicit parameters.
    ///
    /// - Parameters:
    ///   - extendedGuardBits: Guard bits (0-15, default 2).
    ///   - usesTrellisQuantization: Whether TCQ is used.
    ///   - usesDeadzoneAdjustment: Whether deadzone adjustments are applied.
    public init(
        extendedGuardBits: UInt8 = 2,
        usesTrellisQuantization: Bool = false,
        usesDeadzoneAdjustment: Bool = false
    ) {
        self.extendedGuardBits = min(15, extendedGuardBits)
        self.usesTrellisQuantization = usesTrellisQuantization
        self.usesDeadzoneAdjustment = usesDeadzoneAdjustment
    }

    /// Whether any Part 2 quantization extensions are active.
    public var hasPart2Extensions: Bool {
        extendedGuardBits > 7 || usesTrellisQuantization || usesDeadzoneAdjustment
    }

    /// Encodes the Sqcd byte with extended guard bits for Part 2.
    ///
    /// The Sqcd byte layout: guard bits (bits 5-7 for Part 1, bits 4-7 for Part 2)
    /// | quantization style (bits 0-4).
    ///
    /// - Parameter quantizationStyle: The quantization style (0 = none, 1 = implicit, 2 = expounded).
    /// - Returns: The encoded Sqcd byte value.
    public func encodeSqcd(quantizationStyle: UInt8) -> UInt8 {
        let guardBitsClamped = min(7, extendedGuardBits) // Part 1 Sqcd uses bits 5-7 (3 bits)
        return (guardBitsClamped << 5) | (quantizationStyle & 0x1F)
    }
}
