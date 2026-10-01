//
// J2KDCOffset.swift
// J2KSwift
//
// J2KDCOffset.swift
// J2KSwift
//
// Implementation of ISO/IEC 15444-2 variable DC offset for JPEG 2000 Part 2.
//

import Foundation

// # JPEG 2000 Part 2 Variable DC Offset
//
// Implementation of variable DC offset as defined in ISO/IEC 15444-2.
//
// DC offset improves compression efficiency for images with non-zero mean
// component values by removing the DC bias before wavelet transform and
// quantization. This is particularly effective for medical imaging,
// satellite imagery, and scientific data where the mean pixel value
// may be significantly different from zero.
//
// ## How It Works
//
// The DC offset process consists of:
// 1. **Analysis**: Compute per-component mean values
// 2. **Removal**: Subtract the DC offset before encoding (centers data around zero)
// 3. **Signaling**: Store the offset in DCO marker segments in the codestream
// 4. **Restoration**: Add the offset back during decoding
//
// ## Usage
//
// ```swift
// // Encoder path: remove DC offset
// let dcOffset = J2KDCOffset()
// let result = try dcOffset.computeAndRemove(
//     componentData: componentData,
//     bitDepth: 8,
//     signed: false
// )
// // result.adjustedData has the offset removed
// // result.offset contains the computed offset value
//
// // Decoder path: restore DC offset
// let restored = dcOffset.apply(
//     offset: result.offset,
//     to: result.adjustedData
// )
// ```

// MARK: - DC Offset Configuration

/// Configuration for variable DC offset operations.
///
/// Controls how DC offset is computed and applied during encoding
/// and decoding.
public struct J2KDCOffsetConfiguration: Sendable, Equatable {
    /// Whether DC offset removal is enabled.
    public let enabled: Bool

    /// The method used to compute the DC offset.
    public let method: J2KDCOffsetMethod

    /// Whether to optimise the offset for natural images.
    ///
    /// When enabled, the offset computation considers image statistics
    /// and may use a weighted mean or median instead of arithmetic mean.
    public let optimizeForNaturalImages: Bool

    /// Creates a DC offset configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable DC offset removal (default: true).
    ///   - method: The offset computation method (default: .mean).
    ///   - optimizeForNaturalImages: Whether to optimise for natural images (default: false).
    public init(
        enabled: Bool = true,
        method: J2KDCOffsetMethod = .mean,
        optimizeForNaturalImages: Bool = false
    ) {
        self.enabled = enabled
        self.method = method
        self.optimizeForNaturalImages = optimizeForNaturalImages
    }

    /// Default configuration with DC offset enabled using mean computation.
    public static let `default` = J2KDCOffsetConfiguration()

    /// Configuration with DC offset disabled.
    public static let disabled = J2KDCOffsetConfiguration(enabled: false)

    /// Configuration optimised for natural images.
    public static let naturalImage = J2KDCOffsetConfiguration(
        enabled: true,
        method: .mean,
        optimizeForNaturalImages: true
    )
}

// MARK: - DC Offset Method

/// Method for computing the DC offset value.
///
/// Different methods may yield better results depending on the
/// image content and compression goals.
public enum J2KDCOffsetMethod: String, Sendable, Equatable, CaseIterable {
    /// Arithmetic mean of all sample values.
    ///
    /// Standard method that works well for most images.
    /// Offset = (1/N) × Σ x_i
    case mean

    /// Midpoint of the sample value range.
    ///
    /// Uses the midpoint between the minimum and maximum values.
    /// Offset = (min + max) / 2
    case midrange

    /// Custom offset value provided by the user.
    ///
    /// Allows explicit specification of the DC offset value.
    case custom
}

// MARK: - DC Offset Result

/// Result of DC offset computation and removal.
///
/// Contains the adjusted data with offset removed and the offset
/// values needed for restoration during decoding.
public struct J2KDCOffsetResult: Sendable {
    /// The component data with DC offset removed.
    public let adjustedData: [Int32]

    /// The computed DC offset value for this component.
    public let offset: J2KDCOffsetValue

    /// The original data statistics.
    public let statistics: J2KComponentStatistics
}

/// Statistics about a component's sample values.
///
/// Used for DC offset computation and optimisation decisions.
public struct J2KComponentStatistics: Sendable, Equatable {
    /// The arithmetic mean of sample values.
    public let mean: Double

    /// The minimum sample value.
    public let minimum: Int32

    /// The maximum sample value.
    public let maximum: Int32

    /// The number of samples.
    public let count: Int

    /// The midpoint of the sample range.
    public var midrange: Double {
        (Double(minimum) + Double(maximum)) / 2.0
    }
}

// MARK: - DC Offset Value

/// Represents a DC offset value for a single component.
///
/// Encapsulates the offset value and metadata needed for
/// DCO marker segment encoding and decoding.
public struct J2KDCOffsetValue: Sendable, Equatable {
    /// The component index (0-based).
    public let componentIndex: Int

    /// The DC offset value as a floating-point number.
    ///
    /// This is the value that was subtracted from the original data.
    public let value: Double

    /// The DC offset value rounded to the nearest integer.
    ///
    /// Used for integer arithmetic in the reversible (lossless) path.
    public var integerValue: Int32 {
        j2kClampedInt32(value)
    }

    /// Creates a DC offset value.
    ///
    /// - Parameters:
    ///   - componentIndex: The component index.
    ///   - value: The offset value.
    public init(componentIndex: Int, value: Double) {
        self.componentIndex = componentIndex
        self.value = value
    }

    /// A zero DC offset (no adjustment).
    public static func zero(componentIndex: Int) -> J2KDCOffsetValue {
        J2KDCOffsetValue(componentIndex: componentIndex, value: 0.0)
    }
}

// MARK: - DCO Marker Segment

/// DCO (DC Offset) marker segment for JPEG 2000 Part 2 codestream.
///
/// The DCO marker segment signals per-component DC offset values
/// in the JPEG 2000 codestream. It is defined in ISO/IEC 15444-2
/// Annex A.3.
///
/// ## Marker Format
///
/// ```
/// DCO marker: 0xFF5C
/// Ldco: Marker segment length
/// Sdco: Offset type (0 = integer, 1 = floating-point)
/// SPdco_i: Offset value for component i
/// ```
public struct J2KDCOMarkerSegment: Sendable, Equatable {
    /// The DCO marker code (0xFF5C).
    public static let markerCode: UInt16 = 0xFF5C

    /// The offset type used in the marker segment.
    public let offsetType: J2KDCOOffsetType

    /// Per-component DC offset values.
    public let offsets: [J2KDCOffsetValue]

    /// Creates a DCO marker segment.
    ///
    /// - Parameters:
    ///   - offsetType: The type of offset encoding (default: .integer).
    ///   - offsets: Per-component offset values.
    public init(
        offsetType: J2KDCOOffsetType = .integer,
        offsets: [J2KDCOffsetValue]
    ) {
        self.offsetType = offsetType
        self.offsets = offsets
    }

    /// Encodes the DCO marker segment to binary data.
    ///
    /// - Returns: The encoded marker segment data.
    /// - Throws: ``J2KError/encodingError(_:)`` if encoding fails.
    public func encode() throws -> Data {
        var data = Data()

        // Marker code (2 bytes)
        data.append(UInt8(J2KDCOMarkerSegment.markerCode >> 8))
        data.append(UInt8(J2KDCOMarkerSegment.markerCode & 0xFF))

        // Calculate segment length
        let bytesPerOffset: Int
        switch offsetType {
        case .integer:
            bytesPerOffset = 4 // 32-bit signed integer
        case .floatingPoint:
            bytesPerOffset = 4 // 32-bit IEEE 754 float
        }

        // Ldco: segment length (2 bytes) = 3 + N * bytesPerOffset
        // (2 for Ldco itself + 1 for Sdco + N * bytesPerOffset)
        let segmentLength = 3 + offsets.count * bytesPerOffset
        data.append(UInt8((segmentLength >> 8) & 0xFF))
        data.append(UInt8(segmentLength & 0xFF))

        // Sdco: offset type (1 byte)
        data.append(offsetType.rawValue)

        // SPdco_i: offset values
        for offset in offsets {
            switch offsetType {
            case .integer:
                let raw = UInt32(bitPattern: offset.integerValue)
                data.append(UInt8((raw >> 24) & 0xFF))
                data.append(UInt8((raw >> 16) & 0xFF))
                data.append(UInt8((raw >> 8) & 0xFF))
                data.append(UInt8(raw & 0xFF))
            case .floatingPoint:
                let raw = Float(offset.value).bitPattern
                data.append(UInt8((raw >> 24) & 0xFF))
                data.append(UInt8((raw >> 16) & 0xFF))
                data.append(UInt8((raw >> 8) & 0xFF))
                data.append(UInt8(raw & 0xFF))
            }
        }

        return data
    }

    /// Decodes a DCO marker segment from binary data.
    ///
    /// - Parameter data: The binary data starting after the marker code.
    /// - Returns: The decoded DCO marker segment.
    /// - Throws: ``J2KError/decodingError(_:)`` if the data is malformed.
    public static func decode(from data: Data) throws -> J2KDCOMarkerSegment {
        guard data.count >= 3 else {
            throw J2KError.decodingError("DCO marker segment too short")
        }

        // Ldco: segment length (already consumed by caller)
        let segmentLength = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])

        guard data.count >= segmentLength else {
            throw J2KError.decodingError("DCO marker segment data truncated")
        }

        // Sdco: offset type
        let offsetTypeByte = data[data.startIndex + 2]
        guard let offsetType = J2KDCOOffsetType(rawValue: offsetTypeByte) else {
            throw J2KError.decodingError("Unknown DCO offset type: \(offsetTypeByte)")
        }

        let bytesPerOffset: Int
        switch offsetType {
        case .integer:
            bytesPerOffset = 4
        case .floatingPoint:
            bytesPerOffset = 4
        }

        // Calculate number of components
        let offsetDataLength = segmentLength - 3
        guard offsetDataLength.isMultiple(of: bytesPerOffset) else {
            throw J2KError.decodingError("DCO marker segment has invalid length")
        }
        let componentCount = offsetDataLength / bytesPerOffset

        // Read offset values
        var offsets: [J2KDCOffsetValue] = []
        offsets.reserveCapacity(componentCount)

        var position = data.startIndex + 3
        for i in 0..<componentCount {
            let value: Double
            switch offsetType {
            case .integer:
                let raw = UInt32(data[position]) << 24
                    | UInt32(data[position + 1]) << 16
                    | UInt32(data[position + 2]) << 8
                    | UInt32(data[position + 3])
                value = Double(Int32(bitPattern: raw))
            case .floatingPoint:
                let raw = UInt32(data[position]) << 24
                    | UInt32(data[position + 1]) << 16
                    | UInt32(data[position + 2]) << 8
                    | UInt32(data[position + 3])
                value = Double(Float(bitPattern: raw))
            }

            offsets.append(J2KDCOffsetValue(componentIndex: i, value: value))
            position += bytesPerOffset
        }

        return J2KDCOMarkerSegment(offsetType: offsetType, offsets: offsets)
    }
}

/// Type of DC offset encoding in the DCO marker segment.
public enum J2KDCOOffsetType: UInt8, Sendable, Equatable {
    /// Integer offset values (32-bit signed).
    case integer = 0

    /// Floating-point offset values (32-bit IEEE 754).
    case floatingPoint = 1
}

// MARK: - DC Offset Processor

/// Performs DC offset computation, removal, and restoration.
///
/// The `J2KDCOffset` processor handles per-component DC offset
/// operations for the JPEG 2000 Part 2 encoding and decoding pipeline.
///
/// ## Encoder Path
///
/// 1. Compute component statistics (mean, min, max)
/// 2. Determine optimal DC offset value
/// 3. Subtract offset from component data
/// 4. Generate DCO marker segment for codestream
///
/// ## Decoder Path
///
/// 1. Parse DCO marker segment from codestream
/// 2. Add offset back to reconstructed component data
///
/// ## Example
///
/// ```swift
/// let dcOffset = J2KDCOffset()
///
/// // Encoder: compute and remove DC offset
/// let result = try dcOffset.computeAndRemove(
///     componentData: pixelData,
///     componentIndex: 0,
///     bitDepth: 8,
///     signed: false
/// )
///
/// // Decoder: restore DC offset
/// let restored = dcOffset.apply(
///     offset: result.offset,
///     to: decodedData
/// )
/// ```
public struct J2KDCOffset: Sendable {
    /// The configuration for DC offset operations.
    public let configuration: J2KDCOffsetConfiguration

    /// Creates a DC offset processor.
    ///
    /// - Parameter configuration: The DC offset configuration (default: `.default`).
    public init(configuration: J2KDCOffsetConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Statistics Computation

    /// Computes statistics for a component's sample data.
    ///
    /// - Parameters:
    ///   - data: The sample data array.
    /// - Returns: Component statistics including mean, min, max.
    public func computeStatistics(_ data: [Int32]) -> J2KComponentStatistics {
        guard !data.isEmpty else {
            return J2KComponentStatistics(mean: 0, minimum: 0, maximum: 0, count: 0)
        }

        var sum: Int64 = 0
        var minimum = data[0]
        var maximum = data[0]

        for sample in data {
            sum += Int64(sample)
            if sample < minimum { minimum = sample }
            if sample > maximum { maximum = sample }
        }

        let mean = Double(sum) / Double(data.count)

        return J2KComponentStatistics(
            mean: mean,
            minimum: minimum,
            maximum: maximum,
            count: data.count
        )
    }

    // MARK: - DC Offset Computation

    /// Computes the optimal DC offset for a component.
    ///
    /// - Parameters:
    ///   - statistics: The component statistics.
    ///   - bitDepth: The bit depth of the component.
    ///   - signed: Whether the component data is signed.
    /// - Returns: The computed DC offset value.
    public func computeOffset(
        from statistics: J2KComponentStatistics,
        componentIndex: Int,
        bitDepth: Int,
        signed: Bool
    ) -> J2KDCOffsetValue {
        guard configuration.enabled else {
            return .zero(componentIndex: componentIndex)
        }

        let offsetValue: Double

        switch configuration.method {
        case .mean:
            if configuration.optimizeForNaturalImages {
                // For natural images, use the rounded mean to maintain
                // integer precision in the reversible path
                offsetValue = statistics.mean.rounded()
            } else {
                offsetValue = statistics.mean
            }

        case .midrange:
            offsetValue = statistics.midrange

        case .custom:
            // Custom offset should be set externally; return zero
            offsetValue = 0.0
        }

        return J2KDCOffsetValue(componentIndex: componentIndex, value: offsetValue)
    }

    // MARK: - Encoder Path: Remove DC Offset

    /// Computes and removes the DC offset from component data.
    ///
    /// This is the encoder-side operation: it computes the optimal offset
    /// and subtracts it from the data to center values around zero.
    ///
    /// - Parameters:
    ///   - componentData: The raw component sample data.
    ///   - componentIndex: The index of the component.
    ///   - bitDepth: The bit depth of the component.
    ///   - signed: Whether the component data is signed.
    /// - Returns: The result containing adjusted data and offset information.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    public func computeAndRemove(
        componentData: [Int32],
        componentIndex: Int = 0,
        bitDepth: Int = 8,
        signed: Bool = false
    ) throws -> J2KDCOffsetResult {
        guard bitDepth > 0 && bitDepth <= 38 else {
            throw J2KError.invalidParameter("Bit depth must be between 1 and 38, got \(bitDepth)")
        }

        let statistics = computeStatistics(componentData)

        let offset = computeOffset(
            from: statistics,
            componentIndex: componentIndex,
            bitDepth: bitDepth,
            signed: signed
        )

        let adjustedData: [Int32]
        if configuration.enabled && offset.value != 0.0 {
            let intOffset = offset.integerValue
            adjustedData = componentData.map { $0 - intOffset }
        } else {
            adjustedData = componentData
        }

        return J2KDCOffsetResult(
            adjustedData: adjustedData,
            offset: offset,
            statistics: statistics
        )
    }

    // MARK: - Decoder Path: Apply DC Offset

    /// Applies (restores) the DC offset to decoded component data.
    ///
    /// This is the decoder-side operation: it adds the offset back
    /// to the reconstructed data.
    ///
    /// - Parameters:
    ///   - offset: The DC offset value from the DCO marker segment.
    ///   - data: The decoded component data.
    /// - Returns: The data with DC offset restored.
    public func apply(
        offset: J2KDCOffsetValue,
        to data: [Int32]
    ) -> [Int32] {
        guard offset.value != 0.0 else {
            return data
        }

        let intOffset = offset.integerValue
        return data.map { $0 + intOffset }
    }

    // MARK: - Multi-Component Operations

    /// Computes and removes DC offset for all components.
    ///
    /// Processes multiple component data arrays and returns per-component
    /// results. This is used in the encoder pipeline.
    ///
    /// - Parameters:
    ///   - components: Array of component data arrays.
    ///   - bitDepths: Per-component bit depths.
    ///   - signed: Per-component signed flags.
    /// - Returns: Array of per-component DC offset results.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component counts don't match.
    public func computeAndRemoveAll(
        components: [[Int32]],
        bitDepths: [Int],
        signed: [Bool]
    ) throws -> [J2KDCOffsetResult] {
        guard components.count == bitDepths.count,
              components.count == signed.count else {
            throw J2KError.invalidParameter(
                "Component count mismatch: data=\(components.count), "
                + "bitDepths=\(bitDepths.count), signed=\(signed.count)"
            )
        }

        var results: [J2KDCOffsetResult] = []
        results.reserveCapacity(components.count)

        for i in 0..<components.count {
            let result = try computeAndRemove(
                componentData: components[i],
                componentIndex: i,
                bitDepth: bitDepths[i],
                signed: signed[i]
            )
            results.append(result)
        }

        return results
    }

    /// Applies DC offsets to all components during decoding.
    ///
    /// - Parameters:
    ///   - offsets: Per-component DC offset values.
    ///   - components: Array of decoded component data arrays.
    /// - Returns: Array of component data with offsets restored.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if component counts don't match.
    public func applyAll(
        offsets: [J2KDCOffsetValue],
        to components: [[Int32]]
    ) throws -> [[Int32]] {
        guard offsets.count == components.count else {
            throw J2KError.invalidParameter(
                "Offset count (\(offsets.count)) doesn't match component count (\(components.count))"
            )
        }

        return zip(offsets, components).map { offset, data in
            apply(offset: offset, to: data)
        }
    }

    // MARK: - DCO Marker Generation

    /// Creates a DCO marker segment from offset results.
    ///
    /// - Parameters:
    ///   - results: Per-component DC offset results.
    ///   - offsetType: The encoding type for offset values (default: .integer).
    /// - Returns: The DCO marker segment for inclusion in the codestream.
    public func createMarkerSegment(
        from results: [J2KDCOffsetResult],
        offsetType: J2KDCOOffsetType = .integer
    ) -> J2KDCOMarkerSegment {
        let offsets = results.map { $0.offset }
        return J2KDCOMarkerSegment(offsetType: offsetType, offsets: offsets)
    }
}
