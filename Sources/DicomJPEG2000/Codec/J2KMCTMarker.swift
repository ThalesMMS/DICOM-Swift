//
// J2KMCTMarker.swift
// J2KSwift
//
// J2KMCTMarker.swift
// J2KSwift
//
// MCT marker segment support for ISO/IEC 15444-2 Part 2
//

import Foundation

/// MCT marker segment data structure.
///
/// The MCT (Multi-Component Transform) marker segment defines array-based
/// multi-component transforms for decorrelating image components.
///
/// ## Marker Code
///
/// - Marker: `0xFF75`
/// - Type: Functional marker segment
/// - Scope: Main header or tile-part header
///
/// ## Format
///
/// ```
/// MCT (2 bytes) - Marker code 0xFF75
/// Lmct (2 bytes) - Length of marker segment (excluding marker)
/// Zmct (2 bytes) - Index of this MCT
/// Imct (1 byte) - Type of MCT (0 = decorrelation, 1 = dependency)
/// Ymct (1 byte) - Component transform type (0 = irreversible, 1 = reversible)
/// Qmct (2 bytes) - Number of output components
/// Amct (variable) - Transform coefficients
/// ```
public struct J2KMCTMarkerSegment: Sendable {
    /// The index of this MCT (allows multiple MCT definitions).
    public let index: UInt16

    /// The type of MCT.
    public let transformType: TransformType

    /// The component transform type (reversible or irreversible).
    public let componentType: ComponentType

    /// The number of output components.
    public let outputComponentCount: UInt16

    /// The transform coefficients (interpretation depends on transformType).
    public let coefficients: Data

    /// Transform type for MCT.
    public enum TransformType: UInt8, Sendable {
        /// Decorrelation transform (array-based).
        case decorrelation = 0

        /// Dependency transform.
        case dependency = 1
    }

    /// Component transform type.
    public enum ComponentType: UInt8, Sendable {
        /// Irreversible (floating-point) transform.
        case irreversible = 0

        /// Reversible (integer) transform.
        case reversible = 1
    }

    /// Creates a new MCT marker segment.
    ///
    /// - Parameters:
    ///   - index: The MCT index.
    ///   - transformType: The type of transform.
    ///   - componentType: The component transform type.
    ///   - outputComponentCount: Number of output components.
    ///   - coefficients: Transform coefficients.
    public init(
        index: UInt16,
        transformType: TransformType,
        componentType: ComponentType,
        outputComponentCount: UInt16,
        coefficients: Data
    ) {
        self.index = index
        self.transformType = transformType
        self.componentType = componentType
        self.outputComponentCount = outputComponentCount
        self.coefficients = coefficients
    }

    /// Parses an MCT marker segment from data.
    ///
    /// - Parameter data: The marker segment data (excluding marker and length).
    /// - Returns: The parsed MCT marker segment.
    /// - Throws: ``J2KError/invalidData(_:)`` if parsing fails.
    public static func parse(from data: Data) throws -> J2KMCTMarkerSegment {
        guard data.count >= 6 else {
            throw J2KError.invalidData("MCT marker segment too short: \(data.count) bytes")
        }

        var reader = J2KBitReader(data: data)

        let index = try reader.readUInt16()
        let transformTypeRaw = try reader.readUInt8()
        let componentTypeRaw = try reader.readUInt8()
        let outputComponentCount = try reader.readUInt16()

        guard let transformType = TransformType(rawValue: transformTypeRaw) else {
            throw J2KError.invalidData("Invalid MCT transform type: \(transformTypeRaw)")
        }

        guard let componentType = ComponentType(rawValue: componentTypeRaw) else {
            throw J2KError.invalidData("Invalid MCT component type: \(componentTypeRaw)")
        }

        // Read remaining data as coefficients
        let coefficients = data.subdata(in: 6..<data.count)

        return J2KMCTMarkerSegment(
            index: index,
            transformType: transformType,
            componentType: componentType,
            outputComponentCount: outputComponentCount,
            coefficients: coefficients
        )
    }

    /// Encodes this MCT marker segment to data.
    ///
    /// - Returns: The encoded marker segment data (including marker and length).
    /// - Throws: ``J2KError/encodingError(_:)`` if encoding fails.
    public func encode() throws -> Data {
        var writer = J2KBitWriter()

        // Write marker
        writer.writeUInt16(J2KMarker.mct.rawValue)

        // Calculate and write length (2 bytes for length field + 6 bytes fixed + coefficients)
        let length = UInt16(2 + 6 + coefficients.count)
        writer.writeUInt16(length)

        // Write MCT data
        writer.writeUInt16(index)
        writer.writeUInt8(transformType.rawValue)
        writer.writeUInt8(componentType.rawValue)
        writer.writeUInt16(outputComponentCount)
        writer.writeBytes(coefficients)

        return writer.data
    }

    /// Converts this MCT marker to a J2KMCTMatrix.
    ///
    /// - Parameter inputComponentCount: The number of input components.
    /// - Returns: The MCT matrix representation.
    /// - Throws: ``J2KError/invalidData(_:)`` if conversion fails.
    public func toMatrix(inputComponentCount: Int) throws -> J2KMCTMatrix {
        let size = inputComponentCount
        let expectedSize = size * Int(outputComponentCount)

        // For decorrelation transforms, coefficients should be floating-point values
        if transformType == .decorrelation {
            let bytesPerValue = componentType == .irreversible ? 4 : 2
            let expectedBytes = expectedSize * bytesPerValue

            guard coefficients.count == expectedBytes else {
                throw J2KError.invalidData(
                    "MCT coefficient size mismatch: expected \(expectedBytes), got \(coefficients.count)"
                )
            }

            var matrixCoeffs = [Double](repeating: 0.0, count: expectedSize)

            coefficients.withUnsafeBytes { ptr in
                if componentType == .irreversible {
                    // Floating-point coefficients
                    for i in 0..<expectedSize {
                        let floatVal = ptr.load(fromByteOffset: i * 4, as: Float32.self)
                        matrixCoeffs[i] = Double(floatVal)
                    }
                } else {
                    // Integer coefficients (fixed-point)
                    for i in 0..<expectedSize {
                        let intVal = ptr.load(fromByteOffset: i * 2, as: Int16.self)
                        matrixCoeffs[i] = Double(intVal) / 2048.0 // Fixed-point scale
                    }
                }
            }

            let precision: J2KMCTPrecision = componentType == .irreversible ? .floatingPoint : .integer
            return try J2KMCTMatrix(size: size, coefficients: matrixCoeffs, precision: precision)
        } else {
            throw J2KError.unsupportedFeature("Dependency transforms not yet implemented")
        }
    }

    /// Creates an MCT marker segment from a matrix.
    ///
    /// - Parameters:
    ///   - matrix: The MCT matrix.
    ///   - index: The MCT index (default: 0).
    /// - Returns: The MCT marker segment.
    /// - Throws: ``J2KError/encodingError(_:)`` if encoding fails.
    public static func from(matrix: J2KMCTMatrix, index: UInt16 = 0) throws -> J2KMCTMarkerSegment {
        let componentType: ComponentType = matrix.isReversible ? .reversible : .irreversible
        let outputComponentCount = UInt16(matrix.size)

        var coefficients = Data()

        if matrix.isReversible {
            // Integer coefficients (fixed-point with scale 2048)
            for coeff in matrix.coefficients {
                let intVal = Int16((coeff * 2048.0).rounded())
                var value = intVal
                coefficients.append(Data(bytes: &value, count: 2))
            }
        } else {
            // Floating-point coefficients
            for coeff in matrix.coefficients {
                var floatVal = Float32(coeff)
                coefficients.append(Data(bytes: &floatVal, count: 4))
            }
        }

        return J2KMCTMarkerSegment(
            index: index,
            transformType: .decorrelation,
            componentType: componentType,
            outputComponentCount: outputComponentCount,
            coefficients: coefficients
        )
    }
}

/// MCC (Multi-Component Collection) marker segment.
///
/// The MCC marker groups components for multi-component transforms.
///
/// ## Marker Code
///
/// - Marker: `0xFF77`
/// - Type: Functional marker segment
/// - Scope: Main header or tile-part header
public struct J2KMCCMarkerSegment: Sendable {
    /// The index of this MCC.
    public let index: UInt16

    /// The indices of input components.
    public let inputComponents: [UInt16]

    /// The indices of output components.
    public let outputComponents: [UInt16]

    /// The index of the MCT to apply.
    public let mctIndex: UInt16

    /// Creates a new MCC marker segment.
    public init(
        index: UInt16,
        inputComponents: [UInt16],
        outputComponents: [UInt16],
        mctIndex: UInt16
    ) {
        self.index = index
        self.inputComponents = inputComponents
        self.outputComponents = outputComponents
        self.mctIndex = mctIndex
    }

    /// Parses an MCC marker segment from data.
    ///
    /// - Parameter data: The marker segment data (excluding marker and length).
    /// - Returns: The parsed MCC marker segment.
    /// - Throws: ``J2KError/invalidData(_:)`` if parsing fails.
    public static func parse(from data: Data) throws -> J2KMCCMarkerSegment {
        guard data.count >= 8 else {
            throw J2KError.invalidData("MCC marker segment too short")
        }

        var reader = J2KBitReader(data: data)

        let index = try reader.readUInt16()
        let inputCount = try reader.readUInt16()
        let outputCount = try reader.readUInt16()
        let mctIndex = try reader.readUInt16()

        var inputComponents: [UInt16] = []
        for _ in 0..<inputCount {
            inputComponents.append(try reader.readUInt16())
        }

        var outputComponents: [UInt16] = []
        for _ in 0..<outputCount {
            outputComponents.append(try reader.readUInt16())
        }

        return J2KMCCMarkerSegment(
            index: index,
            inputComponents: inputComponents,
            outputComponents: outputComponents,
            mctIndex: mctIndex
        )
    }

    /// Encodes this MCC marker segment to data.
    ///
    /// - Returns: The encoded marker segment data (including marker and length).
    public func encode() throws -> Data {
        var writer = J2KBitWriter()

        writer.writeUInt16(J2KMarker.mcc.rawValue)

        let length = UInt16(2 + 8 + inputComponents.count * 2 + outputComponents.count * 2)
        writer.writeUInt16(length)

        writer.writeUInt16(index)
        writer.writeUInt16(UInt16(inputComponents.count))
        writer.writeUInt16(UInt16(outputComponents.count))
        writer.writeUInt16(mctIndex)

        for comp in inputComponents {
            writer.writeUInt16(comp)
        }

        for comp in outputComponents {
            writer.writeUInt16(comp)
        }

        return writer.data
    }
}

/// MCO (Multi-Component Transform Ordering) marker segment.
///
/// The MCO marker specifies the order in which MCTs should be applied.
///
/// ## Marker Code
///
/// - Marker: `0xFF76`
/// - Type: Functional marker segment
/// - Scope: Main header or tile-part header
public struct J2KMCOMarkerSegment: Sendable {
    /// The ordered list of MCC indices to apply.
    public let mccOrder: [UInt16]

    /// Creates a new MCO marker segment.
    public init(mccOrder: [UInt16]) {
        self.mccOrder = mccOrder
    }

    /// Parses an MCO marker segment from data.
    ///
    /// - Parameter data: The marker segment data (excluding marker and length).
    /// - Returns: The parsed MCO marker segment.
    /// - Throws: ``J2KError/invalidData(_:)`` if parsing fails.
    public static func parse(from data: Data) throws -> J2KMCOMarkerSegment {
        guard data.count >= 2 else {
            throw J2KError.invalidData("MCO marker segment too short")
        }

        var reader = J2KBitReader(data: data)
        let count = try reader.readUInt16()

        var mccOrder: [UInt16] = []
        for _ in 0..<count {
            mccOrder.append(try reader.readUInt16())
        }

        return J2KMCOMarkerSegment(mccOrder: mccOrder)
    }

    /// Encodes this MCO marker segment to data.
    ///
    /// - Returns: The encoded marker segment data (including marker and length).
    public func encode() throws -> Data {
        var writer = J2KBitWriter()

        writer.writeUInt16(J2KMarker.mco.rawValue)

        let length = UInt16(2 + 2 + mccOrder.count * 2)
        writer.writeUInt16(length)

        writer.writeUInt16(UInt16(mccOrder.count))

        for index in mccOrder {
            writer.writeUInt16(index)
        }

        return writer.data
    }
}
