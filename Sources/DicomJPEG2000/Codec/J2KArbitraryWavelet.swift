//
// J2KArbitraryWavelet.swift
// J2KSwift
//
// J2KArbitraryWavelet.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-19.
//

import Foundation

// MARK: - ADS Marker Segment

/// ADS (Arbitrary Decomposition Styles) marker segment for JPEG 2000 Part 2.
///
/// Represents the ADS marker defined in ISO/IEC 15444-2, which specifies
/// arbitrary decomposition structures for wavelet transforms beyond the
/// standard Mallat decomposition used in Part 1.
///
/// The ADS marker allows:
/// - Independent horizontal and vertical decomposition control per node
/// - Packet wavelet decomposition in addition to standard Mallat
/// - Per-node kernel selection from a kernel table
///
/// ## Usage
///
/// ```swift
/// let marker = J2KADSMarker(
///     index: 0,
///     decompositionOrder: .mallat,
///     nodes: [
///         J2KADSMarker.DecompositionNode(
///             horizontalDecompose: true,
///             verticalDecompose: true,
///             kernelIndex: 0
///         )
///     ],
///     maxLevels: 5
/// )
/// let data = marker.encode()
/// ```
public struct J2KADSMarker: Sendable, Equatable {
    // MARK: - Nested Types

    /// Decomposition order for the wavelet transform.
    ///
    /// Determines how subbands are further decomposed at each level.
    public enum DecompositionOrder: UInt8, Sendable, Equatable {
        /// Standard Mallat decomposition: only the LL subband is further decomposed.
        case mallat = 0

        /// Packet wavelet decomposition: any subband may be further decomposed.
        case packetWavelet = 1
    }

    /// A single node in the decomposition tree.
    ///
    /// Each node specifies whether horizontal and/or vertical decomposition
    /// is applied, and which wavelet kernel to use for that decomposition step.
    public struct DecompositionNode: Sendable, Equatable {
        /// Whether to decompose horizontally at this node.
        public let horizontalDecompose: Bool

        /// Whether to decompose vertically at this node.
        public let verticalDecompose: Bool

        /// Index into the kernel table for this decomposition node.
        public let kernelIndex: UInt8

        /// Creates a decomposition node.
        ///
        /// - Parameters:
        ///   - horizontalDecompose: Whether to decompose horizontally.
        ///   - verticalDecompose: Whether to decompose vertically.
        ///   - kernelIndex: Index into the kernel table.
        public init(
            horizontalDecompose: Bool,
            verticalDecompose: Bool,
            kernelIndex: UInt8
        ) {
            self.horizontalDecompose = horizontalDecompose
            self.verticalDecompose = verticalDecompose
            self.kernelIndex = kernelIndex
        }
    }

    // MARK: - Properties

    /// ADS marker index (Sads), identifying this decomposition style.
    public let index: UInt8

    /// The decomposition order for the wavelet transform.
    public let decompositionOrder: DecompositionOrder

    /// Decomposition tree nodes describing the transform structure.
    public let nodes: [DecompositionNode]

    /// Maximum decomposition levels.
    public let maxLevels: Int

    // MARK: - Initialisation

    /// Creates an ADS marker segment.
    ///
    /// - Parameters:
    ///   - index: ADS marker index (Sads).
    ///   - decompositionOrder: The decomposition order (.mallat or .packetWavelet).
    ///   - nodes: Array of decomposition tree nodes.
    ///   - maxLevels: Maximum decomposition levels.
    public init(
        index: UInt8,
        decompositionOrder: DecompositionOrder,
        nodes: [DecompositionNode],
        maxLevels: Int
    ) {
        self.index = index
        self.decompositionOrder = decompositionOrder
        self.nodes = nodes
        self.maxLevels = maxLevels
    }

    // MARK: - Validation

    /// Validates the ADS marker contents for correctness.
    ///
    /// Checks that the marker has at least one node, the maximum levels value
    /// is within the allowed range, and all kernel indices are valid.
    ///
    /// - Throws: ``J2KError/invalidParameter(_:)`` if any validation check fails.
    public func validate() throws {
        guard maxLevels > 0 else {
            throw J2KError.invalidParameter("Maximum decomposition levels must be greater than 0")
        }
        guard maxLevels <= 32 else {
            throw J2KError.invalidParameter("Maximum decomposition levels must not exceed 32, got \(maxLevels)")
        }
        guard !nodes.isEmpty else {
            throw J2KError.invalidParameter("ADS marker must contain at least one decomposition node")
        }
        for (i, node) in nodes.enumerated() {
            if !node.horizontalDecompose && !node.verticalDecompose {
                throw J2KError.invalidParameter(
                    "Node \(i) must decompose in at least one direction"
                )
            }
        }
    }

    // MARK: - Serialisation

    /// Encodes the ADS marker segment to binary codestream format.
    ///
    /// The binary layout follows ISO/IEC 15444-2 ADS marker format:
    /// - 2 bytes: marker code (0xFF74)
    /// - 2 bytes: marker segment length (Lads)
    /// - 1 byte: ADS marker index (Sads)
    /// - 1 byte: decomposition order
    /// - 1 byte: max levels
    /// - For each node: 1 byte flags (horizontal | vertical << 1) + 1 byte kernel index
    ///
    /// - Returns: Binary representation of the ADS marker segment.
    public func encode() -> Data {
        var data = Data()

        // Marker code 0xFF74
        data.append(0xFF)
        data.append(0x74)

        // Calculate segment length (everything after the marker code, including length field)
        let segmentLength = UInt16(2 + 1 + 1 + 1 + nodes.count * 2)
        data.append(UInt8(segmentLength >> 8))
        data.append(UInt8(segmentLength & 0xFF))

        // Sads - marker index
        data.append(index)

        // Decomposition order
        data.append(decompositionOrder.rawValue)

        // Max levels
        data.append(UInt8(min(maxLevels, 255)))

        // Nodes
        for node in nodes {
            var flags: UInt8 = 0
            if node.horizontalDecompose { flags |= 0x01 }
            if node.verticalDecompose { flags |= 0x02 }
            data.append(flags)
            data.append(node.kernelIndex)
        }

        return data
    }

    /// Decodes an ADS marker segment from binary data.
    ///
    /// Parses the ADS marker segment according to the ISO/IEC 15444-2 format.
    /// The input data should begin at the marker code (0xFF74).
    ///
    /// - Parameter data: Binary data containing the ADS marker segment.
    /// - Returns: The decoded ADS marker.
    /// - Throws: ``J2KError/invalidData(_:)`` if the data is malformed or truncated.
    public static func decode(from data: Data) throws -> J2KADSMarker {
        var offset = data.startIndex

        // Verify marker code
        guard data.count >= 2 else {
            throw J2KError.invalidData("Insufficient data for ADS marker code")
        }
        guard data[offset] == 0xFF && data[offset + 1] == 0x74 else {
            throw J2KError.invalidData(
                "Invalid ADS marker code: expected 0xFF74, got 0x\(String(format: "%02X%02X", data[offset], data[offset + 1]))"
            )
        }
        offset += 2

        // Read segment length
        guard offset + 2 <= data.endIndex else {
            throw J2KError.invalidData("Insufficient data for ADS segment length")
        }
        let segmentLength = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2

        guard offset + segmentLength - 2 <= data.endIndex else {
            throw J2KError.invalidData("ADS segment length exceeds available data")
        }

        // Read Sads
        guard offset + 1 <= data.endIndex else {
            throw J2KError.invalidData("Insufficient data for ADS index")
        }
        let adsIndex = data[offset]
        offset += 1

        // Read decomposition order
        guard offset + 1 <= data.endIndex else {
            throw J2KError.invalidData("Insufficient data for decomposition order")
        }
        guard let order = DecompositionOrder(rawValue: data[offset]) else {
            throw J2KError.invalidData("Unknown decomposition order: \(data[offset])")
        }
        offset += 1

        // Read max levels
        guard offset + 1 <= data.endIndex else {
            throw J2KError.invalidData("Insufficient data for max levels")
        }
        let levels = Int(data[offset])
        offset += 1

        // Read nodes (remaining bytes in the segment, 2 bytes per node)
        let remainingBytes = segmentLength - 2 - 3 // subtract length field size and header fields
        guard remainingBytes >= 0 && remainingBytes.isMultiple(of: 2) else {
            throw J2KError.invalidData("Invalid ADS node data length: \(remainingBytes)")
        }
        let nodeCount = remainingBytes / 2

        var nodes: [DecompositionNode] = []
        nodes.reserveCapacity(nodeCount)

        for _ in 0..<nodeCount {
            guard offset + 2 <= data.endIndex else {
                throw J2KError.invalidData("Insufficient data for decomposition node")
            }
            let flags = data[offset]
            let kernelIndex = data[offset + 1]
            offset += 2

            nodes.append(DecompositionNode(
                horizontalDecompose: (flags & 0x01) != 0,
                verticalDecompose: (flags & 0x02) != 0,
                kernelIndex: kernelIndex
            ))
        }

        return J2KADSMarker(
            index: adsIndex,
            decompositionOrder: order,
            nodes: nodes,
            maxLevels: levels
        )
    }
}

// MARK: - Arbitrary Decomposition Level

/// A single level of an arbitrary wavelet decomposition.
///
/// Contains the three detail subbands produced by a single level of
/// 2D separable wavelet transform: LH (horizontal detail),
/// HL (vertical detail), and HH (diagonal detail).
public struct J2KArbitraryDecompositionLevel: Sendable, Equatable {
    /// Horizontal detail subband (LH): lowpass rows, highpass columns.
    public let lh: [[Double]]

    /// Vertical detail subband (HL): highpass rows, lowpass columns.
    public let hl: [[Double]]

    /// Diagonal detail subband (HH): highpass rows, highpass columns.
    public let hh: [[Double]]

    /// Creates a decomposition level with the specified subbands.
    ///
    /// - Parameters:
    ///   - lh: Horizontal detail subband.
    ///   - hl: Vertical detail subband.
    ///   - hh: Diagonal detail subband.
    public init(lh: [[Double]], hl: [[Double]], hh: [[Double]]) {
        self.lh = lh
        self.hl = hl
        self.hh = hh
    }
}

// MARK: - Arbitrary Decomposition Result

/// Result of a multi-level arbitrary wavelet decomposition.
///
/// Contains all decomposition levels produced by the forward transform,
/// plus the coarsest approximation (final LL subband) and the kernel used.
///
/// ## Usage
///
/// ```swift
/// let transform = J2KArbitraryWaveletTransform(kernel: kernel)
/// let decomposition = try transform.forwardTransform2D(image: image, levels: 3)
/// let reconstructed = try transform.inverseTransform2D(decomposition: decomposition)
/// ```
public struct J2KArbitraryDecomposition: Sendable, Equatable {
    /// Decomposition levels, ordered from finest (level 0) to coarsest.
    public let levels: [J2KArbitraryDecompositionLevel]

    /// The coarsest approximation subband (final LL).
    public let coarsestApproximation: [[Double]]

    /// The wavelet kernel used for this decomposition.
    public let kernel: J2KWaveletKernel

    /// Creates a decomposition result.
    ///
    /// - Parameters:
    ///   - levels: Array of decomposition levels.
    ///   - coarsestApproximation: The final LL subband.
    ///   - kernel: The wavelet kernel used.
    public init(
        levels: [J2KArbitraryDecompositionLevel],
        coarsestApproximation: [[Double]],
        kernel: J2KWaveletKernel
    ) {
        self.levels = levels
        self.coarsestApproximation = coarsestApproximation
        self.kernel = kernel
    }
}

// MARK: - Arbitrary Wavelet Transform

/// Generic convolution engine for arbitrary wavelet filters.
///
/// Implements forward and inverse wavelet transforms using direct convolution
/// with arbitrary filter kernels, as specified in JPEG 2000 Part 2 (ISO/IEC 15444-2).
/// Unlike the lifting-based transforms in ``J2KDWT1D``, this engine uses the
/// analysis and synthesis filter coefficients directly.
///
/// The engine supports:
/// - 1D forward and inverse transforms via direct convolution
/// - 2D separable transforms using row-column decomposition
/// - Multi-level decomposition with configurable depth
/// - Multiple boundary extension modes
///
/// ## Usage
///
/// ```swift
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// let transform = J2KArbitraryWaveletTransform(kernel: kernel)
///
/// // 1D transform
/// let signal: [Double] = [1, 2, 3, 4, 5, 6, 7, 8]
/// let (low, high) = try transform.forwardTransform1D(signal: signal)
/// let reconstructed = try transform.inverseTransform1D(lowpass: low, highpass: high)
/// ```
public struct J2KArbitraryWaveletTransform: Sendable {
    // MARK: - Properties

    /// The wavelet kernel providing analysis and synthesis filter coefficients.
    public let kernel: J2KWaveletKernel

    /// Boundary extension mode for handling signal edges during convolution.
    public let boundaryExtension: J2KDWT1D.BoundaryExtension

    // MARK: - Initialisation

    /// Creates an arbitrary wavelet transform engine.
    ///
    /// - Parameters:
    ///   - kernel: The wavelet kernel to use for transforms.
    ///   - boundaryExtension: Boundary handling mode (default: symmetric).
    public init(
        kernel: J2KWaveletKernel,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) {
        self.kernel = kernel
        self.boundaryExtension = boundaryExtension
    }

    // MARK: - 1D Forward Transform

    /// Performs a 1D forward wavelet transform using direct convolution.
    ///
    /// Convolves the input signal with the analysis lowpass and highpass filters,
    /// then downsamples by 2 to produce the lowpass (approximation) and highpass
    /// (detail) subbands.
    ///
    /// The convolution formula is:
    /// ```
    /// output[n] = Σ_k filter[k] * extendedSignal[2n + k - filterCenter]
    /// ```
    ///
    /// - Parameter signal: Input signal to transform. Must have at least 2 elements.
    /// - Returns: A tuple containing (lowpass, highpass) subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if signal is too short.
    ///
    /// Example:
    /// ```swift
    /// let transform = J2KArbitraryWaveletTransform(kernel: kernel)
    /// let (low, high) = try transform.forwardTransform1D(signal: [1, 2, 3, 4, 5, 6, 7, 8])
    /// ```
    public func forwardTransform1D(
        signal: [Double]
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter(
                "Signal must have at least 2 elements, got \(signal.count)"
            )
        }

        let n = signal.count
        let lowpassSize = (n + 1) / 2
        let highpassSize = n / 2

        let lpFilter = kernel.analysisLowpass
        let hpFilter = kernel.analysisHighpass
        let lpCenter = lpFilter.count / 2
        let hpCenter = hpFilter.count / 2

        var lowpass = [Double](repeating: 0, count: lowpassSize)
        var highpass = [Double](repeating: 0, count: highpassSize)

        // Convolve with analysis lowpass, downsample by 2
        for i in 0..<lowpassSize {
            var sum = 0.0
            for k in 0..<lpFilter.count {
                let signalIndex = 2 * i + k - lpCenter
                sum += lpFilter[k] * extendedValue(signal, index: signalIndex)
            }
            lowpass[i] = sum
        }

        // Convolve with analysis highpass, downsample by 2
        for i in 0..<highpassSize {
            var sum = 0.0
            for k in 0..<hpFilter.count {
                let signalIndex = 2 * i + 1 + k - hpCenter
                sum += hpFilter[k] * extendedValue(signal, index: signalIndex)
            }
            highpass[i] = sum
        }

        return (lowpass: lowpass, highpass: highpass)
    }

    // MARK: - 1D Inverse Transform

    /// Performs a 1D inverse wavelet transform using direct convolution.
    ///
    /// Reconstructs the original signal from lowpass and highpass subbands by
    /// upsampling by 2 (inserting zeros), convolving each with the corresponding
    /// synthesis filter, and summing the results.
    ///
    /// - Parameters:
    ///   - lowpass: Lowpass (approximation) coefficients.
    ///   - highpass: Highpass (detail) coefficients.
    /// - Returns: Reconstructed signal.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands are empty or incompatible.
    ///
    /// Example:
    /// ```swift
    /// let reconstructed = try transform.inverseTransform1D(lowpass: low, highpass: high)
    /// ```
    public func inverseTransform1D(
        lowpass: [Double],
        highpass: [Double]
    ) throws -> [Double] {
        guard !lowpass.isEmpty && !highpass.isEmpty else {
            throw J2KError.invalidParameter("Subbands cannot be empty")
        }
        guard abs(lowpass.count - highpass.count) <= 1 else {
            throw J2KError.invalidParameter(
                "Incompatible subband sizes: lowpass=\(lowpass.count), highpass=\(highpass.count)"
            )
        }

        let n = lowpass.count + highpass.count
        let synthLP = kernel.synthesisLowpass
        let synthHP = kernel.synthesisHighpass
        let lpCenter = synthLP.count / 2
        let hpCenter = synthHP.count / 2

        // Upsample: insert zeros between samples
        var upsampledLow = [Double](repeating: 0, count: n)
        var upsampledHigh = [Double](repeating: 0, count: n)

        for i in 0..<lowpass.count {
            upsampledLow[2 * i] = lowpass[i]
        }
        for i in 0..<highpass.count {
            upsampledHigh[2 * i + 1] = highpass[i]
        }

        // Convolve each upsampled subband with its synthesis filter, then sum
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sumLP = 0.0
            for k in 0..<synthLP.count {
                let idx = i + k - lpCenter
                sumLP += synthLP[k] * extendedValue(upsampledLow, index: idx)
            }

            var sumHP = 0.0
            for k in 0..<synthHP.count {
                let idx = i + k - hpCenter
                sumHP += synthHP[k] * extendedValue(upsampledHigh, index: idx)
            }

            result[i] = sumLP + sumHP
        }

        return result
    }

    // MARK: - 2D Forward Transform

    /// Performs a multi-level 2D forward wavelet transform.
    ///
    /// Uses the separable row-column approach: first applies the 1D forward
    /// transform to each row, then to each column. At each subsequent level,
    /// only the LL (approximation) subband is further decomposed.
    ///
    /// - Parameters:
    ///   - image: 2D image data as an array of rows.
    ///   - levels: Number of decomposition levels (must be ≥ 1).
    /// - Returns: The multi-level decomposition result.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the image is too small or levels invalid.
    ///
    /// Example:
    /// ```swift
    /// let image: [[Double]] = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]]
    /// let decomposition = try transform.forwardTransform2D(image: image, levels: 2)
    /// ```
    public func forwardTransform2D(
        image: [[Double]],
        levels: Int
    ) throws -> J2KArbitraryDecomposition {
        guard levels >= 1 else {
            throw J2KError.invalidParameter("Decomposition levels must be at least 1, got \(levels)")
        }
        guard !image.isEmpty && !image[0].isEmpty else {
            throw J2KError.invalidParameter("Image must have non-zero dimensions")
        }

        let rows = image.count
        let cols = image[0].count
        guard rows >= 2 && cols >= 2 else {
            throw J2KError.invalidParameter(
                "Image dimensions must be at least 2×2, got \(rows)×\(cols)"
            )
        }

        var currentLL = image
        var decompositionLevels: [J2KArbitraryDecompositionLevel] = []

        for level in 0..<levels {
            let currentRows = currentLL.count
            let currentCols = currentLL[0].count

            guard currentRows >= 2 && currentCols >= 2 else {
                throw J2KError.invalidParameter(
                    "Image too small for level \(level + 1): \(currentRows)×\(currentCols)"
                )
            }

            // Step 1: Transform rows
            let lowColCount = (currentCols + 1) / 2
            let highColCount = currentCols / 2

            var rowL = [[Double]](repeating: [Double](repeating: 0, count: lowColCount), count: currentRows)
            var rowH = [[Double]](repeating: [Double](repeating: 0, count: highColCount), count: currentRows)

            for r in 0..<currentRows {
                let (low, high) = try forwardTransform1D(signal: currentLL[r])
                rowL[r] = low
                rowH[r] = high
            }

            // Step 2: Transform columns of rowL -> LL, LH
            let llRows = (currentRows + 1) / 2
            let lhRows = currentRows / 2

            var ll = [[Double]](repeating: [Double](repeating: 0, count: lowColCount), count: llRows)
            var lh = [[Double]](repeating: [Double](repeating: 0, count: lowColCount), count: lhRows)

            for c in 0..<lowColCount {
                let column = (0..<currentRows).map { rowL[$0][c] }
                let (low, high) = try forwardTransform1D(signal: column)
                for r in 0..<llRows { ll[r][c] = low[r] }
                for r in 0..<lhRows { lh[r][c] = high[r] }
            }

            // Step 3: Transform columns of rowH -> HL, HH
            let hlRows = (currentRows + 1) / 2
            let hhRows = currentRows / 2

            var hl = [[Double]](repeating: [Double](repeating: 0, count: highColCount), count: hlRows)
            var hh = [[Double]](repeating: [Double](repeating: 0, count: highColCount), count: hhRows)

            for c in 0..<highColCount {
                let column = (0..<currentRows).map { rowH[$0][c] }
                let (low, high) = try forwardTransform1D(signal: column)
                for r in 0..<hlRows { hl[r][c] = low[r] }
                for r in 0..<hhRows { hh[r][c] = high[r] }
            }

            decompositionLevels.append(J2KArbitraryDecompositionLevel(lh: lh, hl: hl, hh: hh))
            currentLL = ll
        }

        return J2KArbitraryDecomposition(
            levels: decompositionLevels,
            coarsestApproximation: currentLL,
            kernel: kernel
        )
    }

    // MARK: - 2D Inverse Transform

    /// Performs a multi-level 2D inverse wavelet transform.
    ///
    /// Reconstructs the original image from a multi-level decomposition by
    /// reversing the separable row-column approach at each level, starting
    /// from the coarsest level.
    ///
    /// - Parameter decomposition: The multi-level decomposition to reconstruct from.
    /// - Returns: The reconstructed 2D image.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the decomposition is invalid.
    ///
    /// Example:
    /// ```swift
    /// let reconstructed = try transform.inverseTransform2D(decomposition: decomposition)
    /// ```
    public func inverseTransform2D(
        decomposition: J2KArbitraryDecomposition
    ) throws -> [[Double]] {
        guard !decomposition.levels.isEmpty else {
            throw J2KError.invalidParameter("Decomposition must have at least one level")
        }

        var currentLL = decomposition.coarsestApproximation

        // Reconstruct from coarsest to finest
        for level in stride(from: decomposition.levels.count - 1, through: 0, by: -1) {
            let decomLevel = decomposition.levels[level]
            let lh = decomLevel.lh
            let hl = decomLevel.hl
            let hh = decomLevel.hh

            let llRows = currentLL.count
            let lhRows = lh.count
            let hlRows = hl.count
            let hhRows = hh.count

            let lowColCount = currentLL[0].isEmpty ? 0 : currentLL[0].count
            let highColCount = hl[0].isEmpty ? 0 : hl[0].count

            // Step 1: Inverse column transform for LL + LH -> rowL
            let reconstructedRows = llRows + lhRows
            var rowL = [[Double]](repeating: [Double](repeating: 0, count: lowColCount), count: reconstructedRows)

            for c in 0..<lowColCount {
                let lowCol = (0..<llRows).map { currentLL[$0][c] }
                let highCol = (0..<lhRows).map { lh[$0][c] }
                let column = try inverseTransform1D(lowpass: lowCol, highpass: highCol)
                for r in 0..<reconstructedRows { rowL[r][c] = column[r] }
            }

            // Step 2: Inverse column transform for HL + HH -> rowH
            let reconstructedRowsH = hlRows + hhRows
            var rowH = [[Double]](repeating: [Double](repeating: 0, count: highColCount), count: reconstructedRowsH)

            for c in 0..<highColCount {
                let lowCol = (0..<hlRows).map { hl[$0][c] }
                let highCol = (0..<hhRows).map { hh[$0][c] }
                let column = try inverseTransform1D(lowpass: lowCol, highpass: highCol)
                for r in 0..<reconstructedRowsH { rowH[r][c] = column[r] }
            }

            // Step 3: Inverse row transform for rowL, rowH -> reconstructed image
            let outCols = lowColCount + highColCount
            var reconstructed = [[Double]](repeating: [Double](repeating: 0, count: outCols), count: reconstructedRows)

            for r in 0..<reconstructedRows {
                let reconstructedRow = try inverseTransform1D(lowpass: rowL[r], highpass: rowH[r])
                reconstructed[r] = reconstructedRow
            }

            currentLL = reconstructed
        }

        return currentLL
    }

    // MARK: - Private Helpers

    /// Gets a value from a signal array with boundary extension.
    ///
    /// - Parameters:
    ///   - signal: The signal array.
    ///   - index: The index (may be out of bounds).
    /// - Returns: The extended value.
    private func extendedValue(_ signal: [Double], index: Int) -> Double {
        let n = signal.count
        guard n > 0 else { return 0 }

        if index >= 0 && index < n {
            return signal[index]
        }

        switch boundaryExtension {
        case .symmetric:
            if index < 0 {
                let mirrorIndex = -index - 1
                return signal[min(mirrorIndex, n - 1)]
            } else {
                let mirrorIndex = 2 * n - index - 1
                return signal[max(mirrorIndex, 0)]
            }

        case .periodic:
            var wrappedIndex = index % n
            if wrappedIndex < 0 {
                wrappedIndex += n
            }
            return signal[wrappedIndex]

        case .zeroPadding:
            return 0
        }
    }
}
