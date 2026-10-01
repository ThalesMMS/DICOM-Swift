//
// J2KMCT.swift
// J2KSwift
//
// J2KMCT.swift
// J2KSwift
//
// Array-based Multi-Component Transform (MCT) implementation for ISO/IEC 15444-2 Part 2
//

import Foundation

/// Multi-component transform types supported by JPEG 2000 Part 2.
///
/// MCT extends the basic colour transforms (RCT/ICT) with arbitrary linear transforms
/// that can decorrelate any number of components.
public enum J2KMCTType: String, Sendable, CaseIterable {
    /// Array-based transform using explicit matrix coefficients
    case arrayBased = "Array-Based"

    /// Dependency transform using component relationships
    case dependency = "Dependency"
}

/// Transform precision for MCT operations.
public enum J2KMCTPrecision: Sendable {
    /// Integer transform (reversible)
    case integer

    /// Floating-point transform (irreversible)
    case floatingPoint
}

/// Represents a multi-component transform matrix.
///
/// The matrix defines a linear transformation that can be applied to image components
/// to decorrelate them, improving compression efficiency.
///
/// ## Mathematical Representation
///
/// For N components, the MCT applies a linear transformation:
/// ```
/// Y = M × X
/// ```
/// where:
/// - X is the input vector (N components)
/// - M is the N×N transform matrix
/// - Y is the output vector (N transformed components)
///
/// ## Example Usage
///
/// ```swift
/// // Create a 3×3 decorrelation matrix
/// let matrix = J2KMCTMatrix(
///     size: 3,
///     coefficients: [
///         0.299,  0.587,  0.114,   // Y
///         -0.169, -0.331,  0.500,   // Cb
///         0.500, -0.419, -0.081    // Cr
///     ],
///     precision: .floatingPoint
/// )
/// ```
public struct J2KMCTMatrix: Sendable, Equatable {
    /// The size of the matrix (N×N for N components).
    public let size: Int

    /// The matrix coefficients in row-major order.
    ///
    /// For a 3×3 matrix: [m00, m01, m02, m10, m11, m12, m20, m21, m22]
    public let coefficients: [Double]

    /// The precision of the transform.
    public let precision: J2KMCTPrecision

    /// Whether this is a reversible integer transform.
    public var isReversible: Bool {
        precision == .integer
    }

    /// Creates a new MCT matrix.
    ///
    /// - Parameters:
    ///   - size: The matrix size (N×N).
    ///   - coefficients: The matrix coefficients in row-major order (must contain size² elements).
    ///   - precision: The transform precision (default: .floatingPoint).
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the coefficient count is incorrect.
    public init(size: Int, coefficients: [Double], precision: J2KMCTPrecision = .floatingPoint) throws {
        guard size > 0 else {
            throw J2KError.invalidParameter("Matrix size must be positive")
        }

        guard coefficients.count == size * size else {
            throw J2KError.invalidParameter(
                "Coefficient count (\(coefficients.count)) must equal size² (\(size * size))"
            )
        }

        self.size = size
        self.coefficients = coefficients
        self.precision = precision
    }

    /// Creates an identity matrix of the specified size.
    ///
    /// - Parameter size: The matrix size.
    /// - Returns: An identity matrix where diagonal elements are 1.0 and others are 0.0.
    public static func identity(size: Int) -> J2KMCTMatrix {
        var coefficients = [Double](repeating: 0.0, count: size * size)
        for i in 0..<size {
            coefficients[i * size + i] = 1.0
        }
        return try! J2KMCTMatrix(size: size, coefficients: coefficients, precision: .floatingPoint)
    }

    /// Computes the inverse of this matrix.
    ///
    /// - Returns: The inverse matrix.
    /// - Throws: ``J2KError/invalidOperation(_:)`` if the matrix is singular (non-invertible).
    public func inverse() throws -> J2KMCTMatrix {
        // Create augmented matrix [M | I]
        var augmented = [[Double]](repeating: [Double](repeating: 0.0, count: size * 2), count: size)

        for i in 0..<size {
            for j in 0..<size {
                augmented[i][j] = coefficients[i * size + j]
            }
            augmented[i][size + i] = 1.0
        }

        // Gaussian elimination with partial pivoting
        for pivot in 0..<size {
            // Find pivot row
            var maxRow = pivot
            var maxVal = abs(augmented[pivot][pivot])
            for i in (pivot + 1)..<size {
                let val = abs(augmented[i][pivot])
                if val > maxVal {
                    maxVal = val
                    maxRow = i
                }
            }

            guard maxVal > 1e-10 else {
                throw J2KError.invalidParameter("Matrix is singular (non-invertible)")
            }

            // Swap rows if needed
            if maxRow != pivot {
                augmented.swapAt(pivot, maxRow)
            }

            // Scale pivot row
            let pivotVal = augmented[pivot][pivot]
            for j in 0..<(size * 2) {
                augmented[pivot][j] /= pivotVal
            }

            // Eliminate column
            for i in 0..<size where i != pivot {
                let factor = augmented[i][pivot]
                for j in 0..<(size * 2) {
                    augmented[i][j] -= factor * augmented[pivot][j]
                }
            }
        }

        // Extract inverse from right half
        var inverseCoeffs = [Double](repeating: 0.0, count: size * size)
        for i in 0..<size {
            for j in 0..<size {
                inverseCoeffs[i * size + j] = augmented[i][size + j]
            }
        }

        return try J2KMCTMatrix(size: size, coefficients: inverseCoeffs, precision: precision)
    }

    /// Returns the transpose of this matrix.
    public func transpose() -> J2KMCTMatrix {
        var transposed = [Double](repeating: 0.0, count: size * size)
        for i in 0..<size {
            for j in 0..<size {
                transposed[j * size + i] = coefficients[i * size + j]
            }
        }
        return try! J2KMCTMatrix(size: size, coefficients: transposed, precision: precision)
    }

    /// Validates that this matrix can be used for perfect reconstruction.
    ///
    /// - Returns: True if the matrix is invertible with reasonable precision.
    public func validateReconstructibility() -> Bool {
        guard let inv = try? inverse() else {
            return false
        }

        // Check that M × M⁻¹ ≈ I
        let product = Self.matrixMultiply(self, inv)
        let identity = Self.identity(size: size)

        for i in 0..<(size * size) {
            let diff = abs(product.coefficients[i] - identity.coefficients[i])
            if diff > 1e-6 {
                return false
            }
        }

        return true
    }

    /// Multiplies two matrices.
    private static func matrixMultiply(_ a: J2KMCTMatrix, _ b: J2KMCTMatrix) -> J2KMCTMatrix {
        assert(a.size == b.size, "Matrix sizes must match")
        let n = a.size
        var result = [Double](repeating: 0.0, count: n * n)

        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for k in 0..<n {
                    sum += a.coefficients[i * n + k] * b.coefficients[k * n + j]
                }
                result[i * n + j] = sum
            }
        }

        return try! J2KMCTMatrix(size: n, coefficients: result, precision: a.precision)
    }
}

/// Configuration for multi-component transform operations.
public struct J2KMCTConfiguration: Sendable {
    /// The transform type.
    public let type: J2KMCTType

    /// The transform matrix (for array-based transforms).
    public let matrix: J2KMCTMatrix?

    /// Whether to validate perfect reconstruction.
    public let validateReconstruction: Bool

    /// Creates a new MCT configuration.
    ///
    /// - Parameters:
    ///   - type: The transform type (default: .arrayBased).
    ///   - matrix: The transform matrix (required for array-based transforms).
    ///   - validateReconstruction: Whether to validate perfect reconstruction (default: true in debug).
    public init(
        type: J2KMCTType = .arrayBased,
        matrix: J2KMCTMatrix? = nil,
        validateReconstruction: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }()
    ) {
        self.type = type
        self.matrix = matrix
        self.validateReconstruction = validateReconstruction
    }

    /// No transform configuration.
    public static let none = J2KMCTConfiguration(type: .arrayBased, matrix: nil)
}

/// Configuration for MCT in the encoding pipeline.
///
/// This configuration controls how multi-component transforms are applied
/// during encoding, including adaptive selection, per-tile configuration,
/// and integration with other Part 2 features.
public struct J2KMCTEncodingConfiguration: Sendable, Equatable {
    /// MCT mode
    public enum Mode: Sendable, Equatable {
        /// MCT disabled (use Part 1 RCT/ICT)
        case disabled

        /// Array-based MCT with fixed matrix
        case arrayBased(J2KMCTMatrix)

        /// Dependency-based MCT
        case dependency(J2KMCTDependencyConfiguration)

        /// Adaptive MCT selection per tile
        case adaptive(candidates: [J2KMCTMatrix], selectionCriteria: AdaptiveSelectionCriteria)
    }

    /// Criteria for adaptive MCT matrix selection
    public enum AdaptiveSelectionCriteria: Sendable {
        /// Select based on component correlation
        case correlation

        /// Select based on rate-distortion optimisation
        case rateDistortion

        /// Select based on compression efficiency
        case compressionEfficiency
    }

    /// The MCT mode
    public let mode: Mode

    /// Whether to use extended precision for MCT operations
    public let useExtendedPrecision: Bool

    /// Whether to use reversible integer MCT (when possible)
    public let preferReversible: Bool

    /// Per-tile MCT overrides (tile index -> MCT matrix)
    ///
    /// When non-empty, overrides the global MCT configuration for specific tiles.
    /// Useful for spatially varying content with different decorrelation needs.
    public let perTileMCT: [Int: J2KMCTMatrix]

    /// Creates a new MCT encoding configuration.
    ///
    /// - Parameters:
    ///   - mode: The MCT mode (default: .disabled).
    ///   - useExtendedPrecision: Use extended precision arithmetic (default: false).
    ///   - preferReversible: Prefer reversible integer transforms (default: false).
    ///   - perTileMCT: Per-tile MCT overrides (default: empty).
    public init(
        mode: Mode = .disabled,
        useExtendedPrecision: Bool = false,
        preferReversible: Bool = false,
        perTileMCT: [Int: J2KMCTMatrix] = [:]
    ) {
        self.mode = mode
        self.useExtendedPrecision = useExtendedPrecision
        self.preferReversible = preferReversible
        self.perTileMCT = perTileMCT
    }

    /// Disabled MCT configuration (Part 1 compatible).
    public static let disabled = J2KMCTEncodingConfiguration(mode: .disabled)
}

/// Performs multi-component transforms for JPEG 2000 Part 2 encoding and decoding.
///
/// The `J2KMCT` class provides array-based multi-component transforms that can decorrelate
/// arbitrary numbers of image components using custom transformation matrices.
///
/// ## Features
///
/// - **Arbitrary Component Count**: Transform any number of components (not limited to 3)
/// - **Custom Matrices**: Use application-specific decorrelation matrices
/// - **Integer and Floating-Point**: Support both reversible and irreversible transforms
/// - **Perfect Reconstruction**: Validate invertibility for lossless encoding
///
/// ## Example Usage
///
/// ```swift
/// let mct = J2KMCT()
///
/// // Define a 3×3 decorrelation matrix
/// let matrix = try J2KMCTMatrix(
///     size: 3,
///     coefficients: [
///         1.0,  0.0,  0.0,
///         -0.5, 1.0,  0.0,
///         -0.5, -0.5, 1.0
///     ]
/// )
///
/// // Apply forward transform
/// let transformed = try mct.forwardTransform(
///     components: inputComponents,
///     matrix: matrix
/// )
///
/// // Apply inverse transform
/// let reconstructed = try mct.inverseTransform(
///     components: transformed,
///     matrix: try matrix.inverse()
/// )
/// ```
public struct J2KMCT: Sendable {
    /// Configuration for the MCT.
    public let configuration: J2KMCTConfiguration

    /// Creates a new MCT with the specified configuration.
    ///
    /// - Parameter configuration: The MCT configuration (default: .none).
    public init(configuration: J2KMCTConfiguration = .none) {
        self.configuration = configuration
    }

    // MARK: - Forward Transform

    /// Applies a forward multi-component transform using the specified matrix.
    ///
    /// Transforms input components using matrix multiplication: Y = M × X
    ///
    /// - Parameters:
    ///   - components: The input component data arrays. Must have the same length.
    ///   - matrix: The transformation matrix (N×N for N components).
    /// - Returns: The transformed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func forwardTransform(
        components: [[Double]],
        matrix: J2KMCTMatrix
    ) throws -> [[Double]] {
        // Validate inputs
        guard !components.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        guard components.count == matrix.size else {
            throw J2KError.invalidParameter(
                "Component count (\(components.count)) must match matrix size (\(matrix.size))"
            )
        }

        let sampleCount = components[0].count
        guard components.allSatisfy({ $0.count == sampleCount }) else {
            throw J2KError.invalidParameter("All components must have the same sample count")
        }

        // Validate matrix if requested
        if configuration.validateReconstruction {
            guard matrix.validateReconstructibility() else {
                throw J2KError.invalidParameter("Transform matrix is not invertible")
            }
        }

        let n = matrix.size
        var output = [[Double]](repeating: [Double](repeating: 0.0, count: sampleCount), count: n)

        // Apply transform to each sample: Y[i] = M × X[i]
        for sample in 0..<sampleCount {
            for i in 0..<n {
                var sum = 0.0
                for j in 0..<n {
                    sum += matrix.coefficients[i * n + j] * components[j][sample]
                }
                output[i][sample] = sum
            }
        }

        return output
    }

    /// Applies a forward multi-component transform to integer components.
    ///
    /// For integer precision, performs fixed-point arithmetic with proper rounding.
    ///
    /// - Parameters:
    ///   - components: The input component data arrays (signed integers).
    ///   - matrix: The transformation matrix with integer precision.
    /// - Returns: The transformed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func forwardTransformInteger(
        components: [[Int32]],
        matrix: J2KMCTMatrix
    ) throws -> [[Int32]] {
        guard matrix.isReversible else {
            throw J2KError.invalidParameter("Matrix must have integer precision for integer transform")
        }

        // Convert to double, apply transform, round back to integer
        let doubleComponents = components.map { $0.map(Double.init) }
        let transformed = try forwardTransform(components: doubleComponents, matrix: matrix)

        return transformed.map { component in
            component.map { value in
                j2kClampedInt32(value)
            }
        }
    }

    // MARK: - Inverse Transform

    /// Applies an inverse multi-component transform using the specified matrix.
    ///
    /// Transforms components back to the original space: X = M⁻¹ × Y
    ///
    /// - Parameters:
    ///   - components: The transformed component data arrays.
    ///   - matrix: The inverse transformation matrix.
    /// - Returns: The reconstructed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func inverseTransform(
        components: [[Double]],
        matrix: J2KMCTMatrix
    ) throws -> [[Double]] {
        // Inverse transform uses the same logic as forward transform
        try forwardTransform(components: components, matrix: matrix)
    }

    /// Applies an inverse multi-component transform to integer components.
    ///
    /// - Parameters:
    ///   - components: The transformed component data arrays (signed integers).
    ///   - matrix: The inverse transformation matrix with integer precision.
    /// - Returns: The reconstructed component data arrays.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if inputs are invalid.
    public func inverseTransformInteger(
        components: [[Int32]],
        matrix: J2KMCTMatrix
    ) throws -> [[Int32]] {
        guard matrix.isReversible else {
            throw J2KError.invalidParameter("Matrix must have integer precision for integer transform")
        }

        // Convert to double, apply transform, round back to integer
        let doubleComponents = components.map { $0.map(Double.init) }
        let transformed = try inverseTransform(components: doubleComponents, matrix: matrix)

        return transformed.map { component in
            component.map { value in
                j2kClampedInt32(value)
            }
        }
    }

    // MARK: - Component-Based Transform

    /// Applies forward MCT to J2KComponent objects.
    ///
    /// - Parameters:
    ///   - components: The input components.
    ///   - matrix: The transformation matrix.
    /// - Returns: The transformed components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func forwardTransform(
        components: [J2KComponent],
        matrix: J2KMCTMatrix
    ) throws -> [J2KComponent] {
        // Validate components
        guard !components.isEmpty else {
            throw J2KError.invalidParameter("Components cannot be empty")
        }

        let width = components[0].width
        let height = components[0].height

        guard components.allSatisfy({ $0.width == width && $0.height == height }) else {
            throw J2KError.invalidComponentConfiguration("All components must have the same dimensions")
        }

        // Convert components to arrays
        let arrays = try components.map { component in
            try convertComponentToDoubleArray(component)
        }

        // Apply transform
        let transformed = try forwardTransform(components: arrays, matrix: matrix)

        // Convert back to components
        return try transformed.enumerated().map { index, data in
            try createComponentFromDoubleArray(
                data: data,
                template: components[index],
                newIndex: index
            )
        }
    }

    /// Applies inverse MCT to J2KComponent objects.
    ///
    /// - Parameters:
    ///   - components: The transformed components.
    ///   - matrix: The inverse transformation matrix.
    /// - Returns: The reconstructed components.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if components are invalid or mismatched.
    public func inverseTransform(
        components: [J2KComponent],
        matrix: J2KMCTMatrix
    ) throws -> [J2KComponent] {
        // Use the same logic as forward transform
        try forwardTransform(components: components, matrix: matrix)
    }

    // MARK: - Helper Methods

    /// Converts a J2KComponent to a double array.
    private func convertComponentToDoubleArray(_ component: J2KComponent) throws -> [Double] {
        let pixelCount = component.width * component.height
        var result = [Double](repeating: 0.0, count: pixelCount)

        let bytesPerSample = (component.bitDepth + 7) / 8

        guard component.data.count >= pixelCount * bytesPerSample else {
            throw J2KError.invalidParameter("Component data is too small")
        }

        component.data.withUnsafeBytes { ptr in
            if bytesPerSample == 1 {
                if component.signed {
                    for i in 0..<pixelCount {
                        result[i] = Double(ptr.load(fromByteOffset: i, as: Int8.self))
                    }
                } else {
                    for i in 0..<pixelCount {
                        result[i] = Double(ptr.load(fromByteOffset: i, as: UInt8.self))
                    }
                }
            } else if bytesPerSample == 2 {
                if component.signed {
                    for i in 0..<pixelCount {
                        result[i] = Double(ptr.load(fromByteOffset: i * 2, as: Int16.self))
                    }
                } else {
                    for i in 0..<pixelCount {
                        result[i] = Double(ptr.load(fromByteOffset: i * 2, as: UInt16.self))
                    }
                }
            } else {
                // For larger bit depths, use Int32
                for i in 0..<pixelCount {
                    result[i] = Double(ptr.load(fromByteOffset: i * 4, as: Int32.self))
                }
            }
        }

        return result
    }

    /// Creates a J2KComponent from a double array.
    private func createComponentFromDoubleArray(
        data: [Double],
        template: J2KComponent,
        newIndex: Int
    ) throws -> J2KComponent {
        let bytesPerSample = (template.bitDepth + 7) / 8
        var componentData = Data(count: data.count * bytesPerSample)

        componentData.withUnsafeMutableBytes { ptr in
            if bytesPerSample == 1 {
                if template.signed {
                    for i in 0..<data.count {
                        ptr.storeBytes(of: Int8(data[i].rounded()), toByteOffset: i, as: Int8.self)
                    }
                } else {
                    for i in 0..<data.count {
                        ptr.storeBytes(of: UInt8(data[i].rounded()), toByteOffset: i, as: UInt8.self)
                    }
                }
            } else if bytesPerSample == 2 {
                if template.signed {
                    for i in 0..<data.count {
                        ptr.storeBytes(of: Int16(data[i].rounded()), toByteOffset: i * 2, as: Int16.self)
                    }
                } else {
                    for i in 0..<data.count {
                        ptr.storeBytes(of: UInt16(data[i].rounded()), toByteOffset: i * 2, as: UInt16.self)
                    }
                }
            } else {
                // For larger bit depths, use Int32
                for i in 0..<data.count {
                    ptr.storeBytes(of: j2kClampedInt32(data[i]), toByteOffset: i * 4, as: Int32.self)
                }
            }
        }

        return J2KComponent(
            index: newIndex,
            bitDepth: template.bitDepth,
            signed: template.signed,
            width: template.width,
            height: template.height,
            subsamplingX: template.subsamplingX,
            subsamplingY: template.subsamplingY,
            data: componentData
        )
    }
}

// MARK: - Predefined Transform Matrices

extension J2KMCTMatrix {
    /// Standard RGB to YCbCr decorrelation matrix (floating-point).
    ///
    /// This is similar to the ICT transform but defined as an explicit matrix.
    public static let rgbToYCbCr = try! J2KMCTMatrix(
        size: 3,
        coefficients: [
            0.299, 0.587, 0.114,   // Y
            -0.169, -0.331, 0.500,   // Cb
            0.500, -0.419, -0.081    // Cr
        ],
        precision: .floatingPoint
    )

    /// Inverse of RGB to YCbCr matrix.
    public static let yCbCrToRGB = try! rgbToYCbCr.inverse()

    /// Simple averaging transform for decorrelation (3 components).
    public static let averaging3 = try! J2KMCTMatrix(
        size: 3,
        coefficients: [
            1.0, 0.0, 0.0,
            -0.5, 1.0, 0.0,
            -0.5, -0.5, 1.0
        ],
        precision: .floatingPoint
    )

    /// Identity transform for 3 components (no transformation).
    public static let identity3 = identity(size: 3)

    /// Identity transform for 4 components (no transformation).
    public static let identity4 = identity(size: 4)
}
