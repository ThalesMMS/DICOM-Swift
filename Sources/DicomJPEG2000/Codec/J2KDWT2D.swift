//
// J2KDWT2D.swift
// J2KSwift
//
// J2KDWT2D.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

/// Two-dimensional Discrete Wavelet Transform implementation for JPEG 2000.
///
/// This module implements the 2D DWT using separable transforms (row-then-column),
/// supporting both the reversible 5/3 filter (for lossless compression) and the
/// irreversible 9/7 filter (for lossy compression) as specified in ISO/IEC 15444-1.
///
/// The 2D DWT decomposes an image into four subbands at each level:
/// - LL (low-low): Approximation (downsampled version of the image)
/// - LH (low-high): Horizontal details
/// - HL (high-low): Vertical details
/// - HH (high-high): Diagonal details
///
/// ## Multi-Level Decomposition
///
/// For multi-level decomposition, the LL subband from level N becomes the input
/// for level N+1, creating a dyadic decomposition structure.
///
/// ## Usage
///
/// ```swift
/// let image: [[Int32]] = /* 2D image data */
/// let filter = J2KDWTFilter.reversible53
///
/// // Single-level forward transform
/// let result = try J2KDWT2D.forwardTransform(
///     image: image,
///     filter: filter
/// )
///
/// // Access subbands
/// let ll = result.ll
/// let lh = result.lh
/// let hl = result.hl
/// let hh = result.hh
///
/// // Multi-level decomposition
/// let decomposition = try J2KDWT2D.forwardDecomposition(
///     image: image,
///     levels: 3,
///     filter: filter
/// )
///
/// // Inverse transform
/// let reconstructed = try J2KDWT2D.inverseTransform(
///     ll: ll, lh: lh, hl: hl, hh: hh,
///     filter: filter
/// )
/// ```
public struct J2KDWT2D: Sendable {
    // MARK: - Types

    /// Result of a single-level 2D DWT decomposition.
    public struct DecompositionResult: Sendable {
        /// Low-low subband (approximation).
        public let ll: [[Int32]]

        /// Low-high subband (horizontal details).
        public let lh: [[Int32]]

        /// High-low subband (vertical details).
        public let hl: [[Int32]]

        /// High-high subband (diagonal details).
        public let hh: [[Int32]]

        /// Width of the LL subband.
        public var width: Int { ll[0].count }

        /// Height of the LL subband.
        public var height: Int { ll.count }

        public init(ll: [[Int32]], lh: [[Int32]], hl: [[Int32]], hh: [[Int32]]) {
            self.ll = ll
            self.lh = lh
            self.hl = hl
            self.hh = hh
        }
    }

    /// Result of a multi-level 2D DWT decomposition.
    public struct MultiLevelDecomposition: Sendable {
        /// Decomposition results for each level, from finest (index 0) to coarsest.
        public let levels: [DecompositionResult]

        /// The final LL subband (coarsest approximation).
        public var coarsestLL: [[Int32]] {
            levels.last?.ll ?? []
        }

        /// Number of decomposition levels.
        public var levelCount: Int { levels.count }

        public init(levels: [DecompositionResult]) {
            self.levels = levels
        }
    }

    /// Decomposition structure pattern for wavelet transform.
    ///
    /// Defines how the DWT should be applied across different levels and subbands.
    /// This allows for both standard dyadic decomposition and more advanced patterns.
    public enum DecompositionStructure: Sendable, Equatable {
        /// Standard dyadic decomposition (only LL subband is decomposed at each level).
        ///
        /// This is the most common pattern in JPEG 2000, where each level only decomposes
        /// the LL (low-low) subband from the previous level.
        ///
        /// Example for 3 levels:
        /// ```
        /// Level 0: Original -> LL, LH, HL, HH
        /// Level 1: LL -> LL2, LH2, HL2, HH2
        /// Level 2: LL2 -> LL3, LH3, HL3, HH3
        /// ```
        case dyadic(levels: Int)

        /// Wavelet packet decomposition (all subbands can be decomposed).
        ///
        /// Allows decomposition of not just LL, but also LH, HL, and HH subbands.
        /// This provides more flexibility but is less commonly used.
        ///
        /// - Parameter pattern: Array of level patterns, where each level specifies which
        ///   subbands to decompose. Use 4-bit pattern: bit 0=LL, 1=LH, 2=HL, 3=HH.
        ///   For example: 0b0001 = decompose only LL (standard dyadic)
        ///               0b1111 = decompose all four subbands
        case waveletPacket(pattern: [UInt8])

        /// Arbitrary decomposition with different levels for horizontal and vertical.
        ///
        /// Allows independent control of horizontal and vertical decomposition levels.
        /// This can be useful for images with directional features.
        ///
        /// - Parameters:
        ///   - horizontalLevels: Number of horizontal decomposition levels
        ///   - verticalLevels: Number of vertical decomposition levels
        case arbitrary(horizontalLevels: Int, verticalLevels: Int)
    }

    // MARK: - Forward Transform

    /// Performs 2D forward discrete wavelet transform (single level).
    ///
    /// Applies 1D DWT to rows, then to columns of the result, producing four subbands.
    ///
    /// - Parameters:
    ///   - image: Input 2D image. Must be non-empty with consistent row lengths.
    ///   - filter: Wavelet filter to use (5/3 or 9/7).
    ///   - boundaryExtension: How to handle signal boundaries (default: symmetric).
    /// - Returns: Decomposition result with LL, LH, HL, HH subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if image is invalid.
    ///
    /// Example:
    /// ```swift
    /// let image: [[Int32]] = /* 8x8 image */
    /// let result = try J2KDWT2D.forwardTransform(image: image, filter: .reversible53)
    /// // result.ll is 4x4, result.lh/hl/hh are also appropriate sizes
    /// ```
    public static func forwardTransform(
        image: [[Int32]],
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> DecompositionResult {
        // Validate input
        guard !image.isEmpty else {
            throw J2KError.invalidParameter("Image cannot be empty")
        }

        let height = image.count
        let width = image[0].count

        guard width >= 2 && height >= 2 else {
            throw J2KError.invalidParameter("Image dimensions must be at least 2x2, got \(width)x\(height)")
        }

        // Validate all rows have the same length
        guard image.allSatisfy({ $0.count == width }) else {
            throw J2KError.invalidParameter("All rows must have the same length")
        }

        // Per JPEG 2000 standard (ISO 15444-1 Annex F): apply columns (vertical) first, then rows (horizontal)

        // Step 1: Apply 1D DWT to each column (vertical pass)
        // Transpose → row-wise DWT → un-transpose for cache-friendly access
        var colLowHeight = 0
        var colHighHeight = 0
        var colTransformed = Array(repeating: [Int32](repeating: 0, count: width), count: height)

        // Transpose: columns become rows for cache-friendly sequential access
        var transposed = Array(repeating: [Int32](repeating: 0, count: height), count: width)
        for row in 0..<height {
            for col in 0..<width {
                transposed[col][row] = image[row][col]
            }
        }

        // Apply 1D DWT to each transposed row (= original column)
        for col in 0..<width {
            let (low, high) = try J2KDWT1D.forwardTransform(
                signal: transposed[col],
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            colLowHeight = low.count
            colHighHeight = high.count

            for i in 0..<low.count {
                colTransformed[i][col] = low[i]
            }
            for i in 0..<high.count {
                colTransformed[colLowHeight + i][col] = high[i]
            }
        }

        // Step 2: Apply 1D DWT to each row of the column-transformed data (horizontal pass)
        var ll = [[Int32]]()
        var lh = [[Int32]]()
        var hl = [[Int32]]()
        var hh = [[Int32]]()

        // Process column-low rows → LL and HL subbands
        for row in 0..<colLowHeight {
            let (low, high) = try J2KDWT1D.forwardTransform(
                signal: colTransformed[row],
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            // low → LL (row-low, col-low), high → HL (row-high, col-low)
            ll.append(low)
            hl.append(high)
        }

        // Process column-high rows → LH and HH subbands
        for row in colLowHeight..<(colLowHeight + colHighHeight) {
            let (low, high) = try J2KDWT1D.forwardTransform(
                signal: colTransformed[row],
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            // low → LH (row-low, col-high), high → HH (row-high, col-high)
            lh.append(low)
            hh.append(high)
        }

        return DecompositionResult(ll: ll, lh: lh, hl: hl, hh: hh)
    }

    /// Performs multi-level 2D forward DWT.
    ///
    /// Recursively applies the 2D DWT to the LL subband from each level.
    ///
    /// - Parameters:
    ///   - image: Input 2D image.
    ///   - levels: Number of decomposition levels (must be >= 1).
    ///   - filter: Wavelet filter to use.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Multi-level decomposition with results for each level.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if parameters are invalid.
    ///
    /// Example:
    /// ```swift
    /// let decomposition = try J2KDWT2D.forwardDecomposition(
    ///     image: image,
    ///     levels: 3,
    ///     filter: .reversible53
    /// )
    /// // decomposition.levels[0] is finest level, decomposition.coarsestLL is final LL
    /// ```
    public static func forwardDecomposition(
        image: [[Int32]],
        levels: Int,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> MultiLevelDecomposition {
        guard levels >= 1 else {
            throw J2KError.invalidParameter("Number of levels must be at least 1, got \(levels)")
        }

        var results = [DecompositionResult]()
        var currentImage = image

        for level in 0..<levels {
            // Check if image is large enough for another level
            let height = currentImage.count
            let width = currentImage[0].count

            guard width >= 2 && height >= 2 else {
                throw J2KError.invalidParameter(
                    "Cannot decompose level \(level + 1): image size \(width)x\(height) is too small"
                )
            }

            // Perform single-level decomposition
            let result = try forwardTransform(
                image: currentImage,
                filter: filter,
                boundaryExtension: boundaryExtension
            )

            results.append(result)

            // Use LL subband as input for next level
            currentImage = result.ll
        }

        return MultiLevelDecomposition(levels: results)
    }

    // MARK: - Double-Precision Forward Transform

    /// Result of a single-level 2D DWT decomposition in Double precision.
    ///
    /// Used by the irreversible 9-7 path to avoid accumulated rounding error
    /// from intermediate Int32 truncation between column and row passes.
    public struct DoubleDecompositionResult: Sendable {
        public let ll: [[Double]]
        public let lh: [[Double]]
        public let hl: [[Double]]
        public let hh: [[Double]]
    }

    /// Result of a multi-level 2D DWT decomposition in Double precision.
    public struct DoubleMultiLevelDecomposition: Sendable {
        public let levels: [DoubleDecompositionResult]

        public var coarsestLL: [[Double]] {
            levels.last?.ll ?? []
        }

        public var levelCount: Int { levels.count }
    }

    /// Performs 2D forward DWT on Double-precision data (no intermediate rounding).
    public static func forwardTransformDouble(
        image: [[Double]],
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> DoubleDecompositionResult {
        guard !image.isEmpty else {
            throw J2KError.invalidParameter("Image cannot be empty")
        }

        let height = image.count
        let width = image[0].count

        guard width >= 2 && height >= 2 else {
            throw J2KError.invalidParameter("Image dimensions must be at least 2x2, got \(width)x\(height)")
        }

        // Per JPEG 2000 standard: columns (vertical) first, then rows (horizontal)

        // Step 1: Apply 1D DWT to each column
        // Transpose → row-wise DWT → un-transpose for cache-friendly access
        var colLowHeight = 0
        var colHighHeight = 0
        var colTransformed = Array(repeating: [Double](repeating: 0, count: width), count: height)

        // Transpose for cache-friendly column access
        var transposed = Array(repeating: [Double](repeating: 0, count: height), count: width)
        for row in 0..<height {
            for col in 0..<width {
                transposed[col][row] = image[row][col]
            }
        }

        for col in 0..<width {
            let (low, high) = try J2KDWT1D.forwardTransformDouble(
                signal: transposed[col], filter: filter, boundaryExtension: boundaryExtension
            )
            colLowHeight = low.count
            colHighHeight = high.count

            for i in 0..<low.count {
                colTransformed[i][col] = low[i]
            }
            for i in 0..<high.count {
                colTransformed[colLowHeight + i][col] = high[i]
            }
        }

        // Step 2: Apply 1D DWT to each row of the column-transformed data
        var ll = [[Double]]()
        var lh = [[Double]]()
        var hl = [[Double]]()
        var hh = [[Double]]()

        for row in 0..<colLowHeight {
            let (low, high) = try J2KDWT1D.forwardTransformDouble(
                signal: colTransformed[row], filter: filter, boundaryExtension: boundaryExtension
            )
            ll.append(low)
            hl.append(high)
        }

        for row in colLowHeight..<(colLowHeight + colHighHeight) {
            let (low, high) = try J2KDWT1D.forwardTransformDouble(
                signal: colTransformed[row], filter: filter, boundaryExtension: boundaryExtension
            )
            lh.append(low)
            hh.append(high)
        }

        return DoubleDecompositionResult(ll: ll, lh: lh, hl: hl, hh: hh)
    }

    /// Performs multi-level 2D forward DWT in Double precision.
    public static func forwardDecompositionDouble(
        image: [[Double]],
        levels: Int,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> DoubleMultiLevelDecomposition {
        guard levels >= 1 else {
            throw J2KError.invalidParameter("Number of levels must be at least 1, got \(levels)")
        }

        var results = [DoubleDecompositionResult]()
        var currentImage = image

        for level in 0..<levels {
            let height = currentImage.count
            let width = currentImage[0].count

            guard width >= 2 && height >= 2 else {
                throw J2KError.invalidParameter(
                    "Cannot decompose level \(level + 1): image size \(width)x\(height) is too small"
                )
            }

            let result = try forwardTransformDouble(
                image: currentImage, filter: filter, boundaryExtension: boundaryExtension
            )
            results.append(result)
            currentImage = result.ll
        }

        return DoubleMultiLevelDecomposition(levels: results)
    }

    // MARK: - Inverse Transform

    /// Performs 2D inverse discrete wavelet transform (single level).
    ///
    /// Reconstructs the image from the four subbands.
    ///
    /// - Parameters:
    ///   - ll: Low-low subband.
    ///   - lh: Low-high subband.
    ///   - hl: High-low subband.
    ///   - hh: High-high subband.
    ///   - filter: Wavelet filter to use (must match forward transform).
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Reconstructed 2D image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands have incompatible sizes.
    ///
    /// Example:
    /// ```swift
    /// let reconstructed = try J2KDWT2D.inverseTransform(
    ///     ll: result.ll, lh: result.lh, hl: result.hl, hh: result.hh,
    ///     filter: .reversible53
    /// )
    /// ```
    public static func inverseTransform(
        ll: [[Int32]],
        lh: [[Int32]],
        hl: [[Int32]],
        hh: [[Int32]],
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [[Int32]] {
        // Validate inputs
        guard !ll.isEmpty else {
            throw J2KError.invalidParameter("LL subband cannot be empty")
        }
        // Handle edge tiles where subbands may be empty (tile dimension=1 in some direction)
        if lh.isEmpty && hl.isEmpty && hh.isEmpty {
            return ll
        }

        let llHeight = ll.count
        let llWidth = ll[0].count
        let lhHeight = lh.count
        let lhWidth = lh.isEmpty ? 0 : lh[0].count
        let hlHeight = hl.count
        let hlWidth = hl.isEmpty ? 0 : hl[0].count
        let hhHeight = hh.count
        let hhWidth = hh.isEmpty ? 0 : hh[0].count

        // Validate subband dimensions - allow for off-by-one due to odd dimensions
        // Skip width checks if high-frequency subbands are empty (edge tile)
        if !hl.isEmpty && !hh.isEmpty {
            guard abs(llWidth - lhWidth) <= 1 && abs(hlWidth - hhWidth) <= 1 && abs(llWidth - hlWidth) <= 1 else {
                throw J2KError.invalidParameter(
                    "Incompatible subband widths: LL=\(llWidth), LH=\(lhWidth), HL=\(hlWidth), HH=\(hhWidth)"
                )
            }
        }

        if !lh.isEmpty && !hh.isEmpty {
            guard abs(llHeight - hlHeight) <= 1 && abs(lhHeight - hhHeight) <= 1 && abs(llHeight - lhHeight) <= 1 else {
                throw J2KError.invalidParameter(
                    "Incompatible subband heights: LL=\(llHeight), LH=\(lhHeight), HL=\(hlHeight), HH=\(hhHeight)"
                )
            }
        }

        // Validate all rows have consistent lengths
        guard ll.allSatisfy({ $0.count == llWidth }) &&
              (lh.isEmpty || lh.allSatisfy({ $0.count == lhWidth })) &&
              (hl.isEmpty || hl.allSatisfy({ $0.count == hlWidth })) &&
              (hh.isEmpty || hh.allSatisfy({ $0.count == hhWidth })) else {
            throw J2KError.invalidParameter("All subband rows must have consistent lengths")
        }

        // Per JPEG 2000 standard: inverse applies rows (horizontal) first, then columns (vertical)
        // This is the reverse of the forward transform (columns first, then rows)

        // Step 1: Apply inverse 1D DWT to rows (horizontal pass)
        // Undo the horizontal DWT that was applied second in the forward transform
        // LL + HL → col-low rows, LH + HH → col-high rows

        var colLow = [[Int32]]()
        colLow.reserveCapacity(llHeight)
        for row in 0..<llHeight {
            let reconstructedRow = try J2KDWT1D.inverseTransform(
                lowpass: ll[row],
                highpass: hl[row],
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            colLow.append(reconstructedRow)
        }

        var colHigh = [[Int32]]()
        colHigh.reserveCapacity(lhHeight)
        for row in 0..<lhHeight {
            let reconstructedRow = try J2KDWT1D.inverseTransform(
                lowpass: lh[row],
                highpass: hh[row],
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            colHigh.append(reconstructedRow)
        }

        // Step 2: Apply inverse 1D DWT to columns (vertical pass)
        // Undo the vertical DWT that was applied first in the forward transform
        let outputWidth = colLow[0].count
        let colLowHeight = colLow.count
        let colHighHeight = colHigh.count
        let outputHeight = colLowHeight + colHighHeight

        var result = Array(repeating: [Int32](repeating: 0, count: outputWidth), count: outputHeight)

        // Transpose colLow and colHigh for cache-friendly column access
        var transposedLow = Array(repeating: [Int32](repeating: 0, count: colLowHeight), count: outputWidth)
        for row in 0..<colLowHeight {
            for col in 0..<outputWidth {
                transposedLow[col][row] = colLow[row][col]
            }
        }
        var transposedHigh = Array(repeating: [Int32](repeating: 0, count: colHighHeight), count: outputWidth)
        for row in 0..<colHighHeight {
            for col in 0..<outputWidth {
                transposedHigh[col][row] = colHigh[row][col]
            }
        }

        for col in 0..<outputWidth {
            let reconstructedColumn = try J2KDWT1D.inverseTransform(
                lowpass: transposedLow[col],
                highpass: transposedHigh[col],
                filter: filter,
                boundaryExtension: boundaryExtension
            )

            for i in 0..<reconstructedColumn.count {
                result[i][col] = reconstructedColumn[i]
            }
        }

        return result
    }

    /// Performs multi-level 2D inverse DWT.
    ///
    /// Reconstructs the image from a multi-level decomposition by applying
    /// inverse transforms from coarsest to finest level.
    ///
    /// - Parameters:
    ///   - decomposition: Multi-level decomposition result.
    ///   - filter: Wavelet filter to use (must match forward transform).
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Reconstructed 2D image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if decomposition is invalid.
    ///
    /// Example:
    /// ```swift
    /// let reconstructed = try J2KDWT2D.inverseDecomposition(
    ///     decomposition: decomposition,
    ///     filter: .reversible53
    /// )
    /// ```
    public static func inverseDecomposition(
        decomposition: MultiLevelDecomposition,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [[Int32]] {
        guard !decomposition.levels.isEmpty else {
            throw J2KError.invalidParameter("Decomposition must have at least one level")
        }

        var currentImage = decomposition.coarsestLL

        // Reconstruct from coarsest to finest
        for level in (0..<decomposition.levelCount).reversed() {
            let result = decomposition.levels[level]

            currentImage = try inverseTransform(
                ll: currentImage,
                lh: result.lh,
                hl: result.hl,
                hh: result.hh,
                filter: filter,
                boundaryExtension: boundaryExtension
            )
        }

        return currentImage
    }

    // MARK: - Arbitrary Decomposition Structures

    /// Performs 2D forward DWT with a custom decomposition structure.
    ///
    /// This method allows for flexible decomposition patterns beyond standard dyadic,
    /// including wavelet packet decomposition and arbitrary horizontal/vertical levels.
    ///
    /// - Parameters:
    ///   - image: Input 2D image. Must be non-empty with consistent row lengths.
    ///   - structure: Decomposition structure pattern to apply.
    ///   - filter: Wavelet filter to use (5/3 or 9/7).
    ///   - boundaryExtension: How to handle signal boundaries (default: symmetric).
    /// - Returns: Multi-level decomposition with the specified structure.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if image or structure is invalid.
    ///
    /// Example:
    /// ```swift
    /// // Standard dyadic decomposition (equivalent to forwardDecomposition)
    /// let standard = try J2KDWT2D.forwardDecompositionWithStructure(
    ///     image: image,
    ///     structure: .dyadic(levels: 3),
    ///     filter: .reversible53
    /// )
    ///
    /// // Arbitrary decomposition with different H/V levels
    /// let arbitrary = try J2KDWT2D.forwardDecompositionWithStructure(
    ///     image: image,
    ///     structure: .arbitrary(horizontalLevels: 3, verticalLevels: 2),
    ///     filter: .reversible53
    /// )
    /// ```
    public static func forwardDecompositionWithStructure(
        image: [[Int32]],
        structure: DecompositionStructure,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> MultiLevelDecomposition {
        guard !image.isEmpty else {
            throw J2KError.invalidParameter("Image cannot be empty")
        }

        switch structure {
        case .dyadic(let levels):
            // Standard dyadic decomposition - just call existing method
            return try forwardDecomposition(
                image: image,
                levels: levels,
                filter: filter,
                boundaryExtension: boundaryExtension
            )

        case .waveletPacket(let pattern):
            // Wavelet packet decomposition - decompose specified subbands
            guard !pattern.isEmpty else {
                throw J2KError.invalidParameter("Wavelet packet pattern cannot be empty")
            }

            // For now, implement basic packet decomposition (LL only)
            // Full packet decomposition would require tracking all subband trees
            var levels: [DecompositionResult] = []
            var currentImage = image

            for (levelIdx, levelPattern) in pattern.enumerated() {
                // Decompose LL subband if bit 0 is set
                if levelPattern & 0b0001 != 0 {
                    let result = try forwardTransform(
                        image: currentImage,
                        filter: filter,
                        boundaryExtension: boundaryExtension
                    )
                    levels.append(result)
                    currentImage = result.ll

                    // Note: Full wavelet packet would also decompose LH/HL/HH if their bits are set
                    // This is left as a future enhancement
                } else {
                    throw J2KError.invalidParameter(
                        "Wavelet packet pattern at level \(levelIdx) must decompose at least LL subband"
                    )
                }
            }

            return MultiLevelDecomposition(levels: levels)

        case let .arbitrary(hLevels, vLevels):
            // Arbitrary decomposition with independent H/V levels
            guard hLevels >= 0 && vLevels >= 0 else {
                throw J2KError.invalidParameter(
                    "Horizontal and vertical levels must be non-negative, got h=\(hLevels), v=\(vLevels)"
                )
            }

            guard hLevels > 0 || vLevels > 0 else {
                throw J2KError.invalidParameter("At least one decomposition level is required")
            }

            // Apply separable transforms with different levels
            var currentImage = image
            var levels: [DecompositionResult] = []

            let maxLevels = max(hLevels, vLevels)

            for level in 0..<maxLevels {
                let height = currentImage.count
                let width = currentImage[0].count

                // Check if we can decompose further
                guard width >= 2 && height >= 2 else {
                    throw J2KError.invalidParameter(
                        "Image too small for \(level + 1) levels of decomposition"
                    )
                }

                var llRows = [[Int32]]()
                var lhRows = [[Int32]]()

                // Apply horizontal transform if within horizontal levels
                if level < hLevels {
                    // Standard row transform
                    for row in currentImage {
                        let (low, high) = try J2KDWT1D.forwardTransform(
                            signal: row,
                            filter: filter,
                            boundaryExtension: boundaryExtension
                        )
                        llRows.append(low)
                        lhRows.append(high)
                    }
                } else {
                    // No horizontal decomposition - keep as is
                    for row in currentImage {
                        llRows.append(row)
                        lhRows.append([])  // Empty highpass
                    }
                }

                // Apply vertical transform if within vertical levels
                var ll: [[Int32]] = []
                var lh: [[Int32]] = []
                var hl: [[Int32]] = []
                var hh: [[Int32]] = []

                if level < vLevels && level < hLevels {
                    // Standard 2D decomposition
                    let result = try forwardTransform(
                        image: currentImage,
                        filter: filter,
                        boundaryExtension: boundaryExtension
                    )
                    ll = result.ll
                    lh = result.lh
                    hl = result.hl
                    hh = result.hh
                } else if level < hLevels {
                    // Only horizontal decomposition
                    ll = llRows
                    lh = lhRows
                    hl = []
                    hh = []
                } else if level < vLevels {
                    // Only vertical decomposition
                    let transposed = transpose(currentImage)
                    var llCols = [[Int32]]()
                    var hlCols = [[Int32]]()

                    for col in transposed {
                        let (low, high) = try J2KDWT1D.forwardTransform(
                            signal: col,
                            filter: filter,
                            boundaryExtension: boundaryExtension
                        )
                        llCols.append(low)
                        hlCols.append(high)
                    }

                    ll = transpose(llCols)
                    lh = []
                    hl = transpose(hlCols)
                    hh = []
                } else {
                    // No decomposition
                    break
                }

                levels.append(DecompositionResult(ll: ll, lh: lh, hl: hl, hh: hh))
                currentImage = ll
            }

            return MultiLevelDecomposition(levels: levels)
        }
    }

    /// Helper method to transpose a 2D array.
    private static func transpose(_ matrix: [[Int32]]) -> [[Int32]] {
        guard !matrix.isEmpty else { return [] }
        let rows = matrix.count
        let cols = matrix[0].count

        var result = [[Int32]](repeating: [Int32](repeating: 0, count: rows), count: cols)
        for i in 0..<rows {
            for j in 0..<cols {
                result[j][i] = matrix[i][j]
            }
        }
        return result
    }
}

// MARK: - Floating-Point Transform for 9/7 Filter

extension J2KDWT2D {
    /// Result of a single-level 2D DWT decomposition (floating-point).
    public struct DecompositionResult97: Sendable {
        /// Low-low subband (approximation).
        public let ll: [[Double]]

        /// Low-high subband (horizontal details).
        public let lh: [[Double]]

        /// High-low subband (vertical details).
        public let hl: [[Double]]

        /// High-high subband (diagonal details).
        public let hh: [[Double]]

        /// Width of the LL subband.
        public var width: Int { ll[0].count }

        /// Height of the LL subband.
        public var height: Int { ll.count }

        public init(ll: [[Double]], lh: [[Double]], hl: [[Double]], hh: [[Double]]) {
            self.ll = ll
            self.lh = lh
            self.hl = hl
            self.hh = hh
        }
    }

    /// Performs 2D forward DWT using 9/7 irreversible filter.
    ///
    /// - Parameters:
    ///   - image: Input 2D image as floating-point values.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Decomposition result with LL, LH, HL, HH subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if image is invalid.
    public static func forwardTransform97(
        image: [[Double]],
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> DecompositionResult97 {
        guard !image.isEmpty else {
            throw J2KError.invalidParameter("Image cannot be empty")
        }

        let height = image.count
        let width = image[0].count

        guard width >= 2 && height >= 2 else {
            throw J2KError.invalidParameter("Image dimensions must be at least 2x2, got \(width)x\(height)")
        }

        guard image.allSatisfy({ $0.count == width }) else {
            throw J2KError.invalidParameter("All rows must have the same length")
        }

        // Step 1: Apply 1D DWT to each row
        var rowTransformed = [[Double]]()
        var rowLowCount = 0
        var rowHighCount = 0

        for row in image {
            let (low, high) = try J2KDWT1D.forwardTransform97(
                signal: row,
                boundaryExtension: boundaryExtension
            )
            rowLowCount = low.count
            rowHighCount = high.count

            var transformedRow = [Double]()
            transformedRow.reserveCapacity(width)
            transformedRow.append(contentsOf: low)
            transformedRow.append(contentsOf: high)
            rowTransformed.append(transformedRow)
        }

        // Step 2: Apply 1D DWT to each column
        var ll = [[Double]]()
        var lh = [[Double]]()
        var hl = [[Double]]()
        var hh = [[Double]]()

        // Process low-frequency columns
        for col in 0..<rowLowCount {
            var column = [Double]()
            column.reserveCapacity(height)
            for row in 0..<height {
                column.append(rowTransformed[row][col])
            }

            let (low, high) = try J2KDWT1D.forwardTransform97(
                signal: column,
                boundaryExtension: boundaryExtension
            )

            if ll.isEmpty {
                ll = Array(repeating: [Double](), count: low.count)
                lh = Array(repeating: [Double](), count: high.count)
            }
            for i in 0..<low.count {
                ll[i].append(low[i])
            }
            for i in 0..<high.count {
                lh[i].append(high[i])
            }
        }

        // Process high-frequency columns
        for col in rowLowCount..<(rowLowCount + rowHighCount) {
            var column = [Double]()
            column.reserveCapacity(height)
            for row in 0..<height {
                column.append(rowTransformed[row][col])
            }

            let (low, high) = try J2KDWT1D.forwardTransform97(
                signal: column,
                boundaryExtension: boundaryExtension
            )

            if hl.isEmpty {
                hl = Array(repeating: [Double](), count: low.count)
                hh = Array(repeating: [Double](), count: high.count)
            }
            for i in 0..<low.count {
                hl[i].append(low[i])
            }
            for i in 0..<high.count {
                hh[i].append(high[i])
            }
        }

        return DecompositionResult97(ll: ll, lh: lh, hl: hl, hh: hh)
    }

    /// Performs 2D inverse DWT using 9/7 irreversible filter.
    ///
    /// - Parameters:
    ///   - ll: Low-low subband.
    ///   - lh: Low-high subband.
    ///   - hl: High-low subband.
    ///   - hh: High-high subband.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Reconstructed 2D image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands have incompatible sizes.
    public static func inverseTransform97(
        ll: [[Double]],
        lh: [[Double]],
        hl: [[Double]],
        hh: [[Double]],
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [[Double]] {
        // Validate inputs (same validation as integer version)
        guard !ll.isEmpty else {
            throw J2KError.invalidParameter("LL subband cannot be empty")
        }
        // Handle edge tiles where subbands may be empty (tile dimension=1 in some direction)
        if lh.isEmpty && hl.isEmpty && hh.isEmpty {
            return ll
        }

        let llHeight = ll.count
        let llWidth = ll[0].count
        let lhHeight = lh.count
        let lhWidth = lh.isEmpty ? 0 : lh[0].count
        let hlHeight = hl.count
        let hlWidth = hl.isEmpty ? 0 : hl[0].count
        let hhHeight = hh.count
        let hhWidth = hh.isEmpty ? 0 : hh[0].count

        if !hl.isEmpty && !hh.isEmpty {
            guard abs(llWidth - lhWidth) <= 1 && abs(hlWidth - hhWidth) <= 1 && abs(llWidth - hlWidth) <= 1 else {
                throw J2KError.invalidParameter(
                    "Incompatible subband widths: LL=\(llWidth), LH=\(lhWidth), HL=\(hlWidth), HH=\(hhWidth)"
                )
            }
        }

        if !lh.isEmpty && !hh.isEmpty {
            guard abs(llHeight - hlHeight) <= 1 && abs(lhHeight - hhHeight) <= 1 && abs(llHeight - lhHeight) <= 1 else {
                throw J2KError.invalidParameter(
                    "Incompatible subband heights: LL=\(llHeight), LH=\(lhHeight), HL=\(hlHeight), HH=\(hhHeight)"
                )
            }
        }

        guard ll.allSatisfy({ $0.count == llWidth }) &&
              (lh.isEmpty || lh.allSatisfy({ $0.count == lhWidth })) &&
              (hl.isEmpty || hl.allSatisfy({ $0.count == hlWidth })) &&
              (hh.isEmpty || hh.allSatisfy({ $0.count == hhWidth })) else {
            throw J2KError.invalidParameter("All subband rows must have consistent lengths")
        }

        // Step 1: Apply inverse 1D DWT to columns
        // Transpose subbands for cache-friendly column access
        var transposedLL = Array(repeating: [Double](repeating: 0, count: llHeight), count: llWidth)
        for row in 0..<llHeight {
            for col in 0..<llWidth {
                transposedLL[col][row] = ll[row][col]
            }
        }
        var transposedLH = Array(repeating: [Double](repeating: 0, count: lhHeight), count: lhWidth)
        for row in 0..<lhHeight {
            for col in 0..<lhWidth {
                transposedLH[col][row] = lh[row][col]
            }
        }
        var transposedHL = Array(repeating: [Double](repeating: 0, count: hlHeight), count: hlWidth)
        for row in 0..<hlHeight {
            for col in 0..<hlWidth {
                transposedHL[col][row] = hl[row][col]
            }
        }
        var transposedHH = Array(repeating: [Double](repeating: 0, count: hhHeight), count: hhWidth)
        for row in 0..<hhHeight {
            for col in 0..<hhWidth {
                transposedHH[col][row] = hh[row][col]
            }
        }

        // Reconstruct low-frequency columns (LL + LH → vertical IDWT)
        var columnInversed = [[Double]]()
        for col in 0..<llWidth {
            let highpassCol: [Double] = col < transposedLH.count ? transposedLH[col] : []
            let reconstructedColumn = try J2KDWT1D.inverseTransform97(
                lowpass: transposedLL[col],
                highpass: highpassCol,
                boundaryExtension: boundaryExtension
            )

            if columnInversed.isEmpty {
                columnInversed = Array(repeating: [Double](), count: reconstructedColumn.count)
                for i in 0..<columnInversed.count {
                    columnInversed[i].reserveCapacity(llWidth + hlWidth)
                }
            }
            for i in 0..<reconstructedColumn.count {
                columnInversed[i].append(reconstructedColumn[i])
            }
        }

        // Reconstruct high-frequency columns (HL + HH → vertical IDWT)
        let highFreqStartCol = columnInversed.isEmpty ? 0 : columnInversed[0].count
        for col in 0..<hlWidth {
            let highpassCol: [Double] = col < transposedHH.count ? transposedHH[col] : []
            let reconstructedColumn = try J2KDWT1D.inverseTransform97(
                lowpass: transposedHL[col],
                highpass: highpassCol,
                boundaryExtension: boundaryExtension
            )

            for i in 0..<reconstructedColumn.count {
                columnInversed[i].append(reconstructedColumn[i])
            }
        }

        // Step 2: Apply inverse 1D DWT to rows
        var result = [[Double]]()
        result.reserveCapacity(columnInversed.count)

        for row in columnInversed {
            let midPoint = highFreqStartCol
            let lowpass = Array(row[0..<midPoint])
            let highpass = Array(row[midPoint..<row.count])

            let reconstructedRow = try J2KDWT1D.inverseTransform97(
                lowpass: lowpass,
                highpass: highpass,
                boundaryExtension: boundaryExtension
            )

            result.append(reconstructedRow)
        }

        return result
    }
}
