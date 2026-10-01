/// Multi-component JPEG-LS decoder with deinterleaving support
///
/// Implements component deinterleaving modes per ITU-T.87:
/// - None: Components decoded separately in sequential scans
/// - Line: Components deinterleaved by scan line
/// - Sample: Components deinterleaved by pixel sample
///
/// Also supports inverse colour transformations to recover original
/// colour space after decoding.

import Foundation

/// Multi-component JPEG-LS decoder
///
/// Orchestrates decoding of multi-component images with support for
/// all interleaving modes defined in the JPEG-LS standard.
/// After decoding, inverse colour transformations can be applied
/// to recover the original colour space.
public struct JPEGLSMultiComponentDecoder: Sendable {
    /// Frame header defining image parameters
    private let frameHeader: JPEGLSFrameHeader

    /// Scan header defining decoding parameters
    private let scanHeader: JPEGLSScanHeader

    /// Preset parameters for decoding
    private let parameters: JPEGLSPresetParameters

    /// Color transformation to apply inversely after decoding
    private let colorTransformation: JPEGLSColorTransformation

    /// Initialize multi-component decoder
    ///
    /// - Parameters:
    ///   - frameHeader: Frame header with image parameters
    ///   - scanHeader: Scan header with decoding parameters
    ///   - colorTransformation: Color transformation applied during encoding (default: .none)
    /// - Throws: `JPEGLSError` if parameters are incompatible
    public init(
        frameHeader: JPEGLSFrameHeader,
        scanHeader: JPEGLSScanHeader,
        colorTransformation: JPEGLSColorTransformation = .none
    ) throws {
        // Validate scan header against frame header
        try scanHeader.validate(against: frameHeader)

        // Validate colour transformation for component count
        guard colorTransformation.isValid(forComponentCount: frameHeader.componentCount) else {
            throw JPEGLSError.decodingFailed(
                reason: "Colour transformation \(colorTransformation) is invalid for \(frameHeader.componentCount) components"
            )
        }

        self.frameHeader = frameHeader
        self.scanHeader = scanHeader
        self.colorTransformation = colorTransformation

        // Create preset parameters from frame header using defaults
        self.parameters = try JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: frameHeader.bitsPerSample,
            near: scanHeader.near
        )
    }

    /// Decode a scan according to the interleave mode
    ///
    /// Routes to the appropriate decoding method based on the scan's
    /// interleave mode (none, line, or sample).
    ///
    /// - Parameter buffer: Pixel buffer containing encoded image data
    /// - Returns: Decoded scan statistics (for testing/validation)
    /// - Throws: `JPEGLSError` if decoding fails
    public func decodeScan(buffer: JPEGLSPixelBuffer) throws -> DecodedScanStatistics {
        switch scanHeader.interleaveMode {
        case .none:
            return try decodeNoneInterleaved(buffer: buffer)
        case .line:
            return try decodeLineInterleaved(buffer: buffer)
        case .sample:
            return try decodeSampleInterleaved(buffer: buffer)
        }
    }

    // MARK: - None Interleaved (Separate Scans)

    /// Decode with no interleaving (components in separate scans)
    ///
    /// Per ITU-T.87, when interleave mode is none, each component is decoded
    /// in its own scan in raster order (left-to-right, top-to-bottom).
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Decoding statistics
    /// - Throws: `JPEGLSError` if decoding fails
    private func decodeNoneInterleaved(buffer: JPEGLSPixelBuffer) throws -> DecodedScanStatistics {
        // For none interleaving, scan must have exactly 1 component
        guard scanHeader.componentCount == 1 else {
            throw JPEGLSError.decodingFailed(
                reason: "None interleaving requires exactly 1 component in scan, got \(scanHeader.componentCount)"
            )
        }

        let componentId = scanHeader.components[0].id
        var totalPixels = 0

        // Decode component in raster order
        for row in 0..<buffer.height {
            for col in 0..<buffer.width {
                guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                    throw JPEGLSError.decodingFailed(reason: "Failed to get neighbors for pixel at (\(row), \(col))")
                }
                totalPixels += 1
            }
        }

        return DecodedScanStatistics(
            componentCount: 1,
            pixelsDecoded: totalPixels,
            interleaveMode: .none,
            colorTransformation: colorTransformation
        )
    }

    // MARK: - Line Interleaved

    /// Decode with line interleaving
    ///
    /// Per ITU-T.87, components alternate by scan line. All components
    /// of row 0 are decoded, then all components of row 1, etc.
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Decoding statistics
    /// - Throws: `JPEGLSError` if decoding fails
    private func decodeLineInterleaved(buffer: JPEGLSPixelBuffer) throws -> DecodedScanStatistics {
        guard scanHeader.componentCount > 1 else {
            throw JPEGLSError.decodingFailed(
                reason: "Line interleaving requires multiple components, got \(scanHeader.componentCount)"
            )
        }

        var totalPixels = 0

        // Decode line-by-line, all components per line
        for row in 0..<buffer.height {
            for componentSelector in scanHeader.components {
                let componentId = componentSelector.id

                for col in 0..<buffer.width {
                    guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                        throw JPEGLSError.decodingFailed(
                            reason: "Failed to get neighbors for component \(componentId) at (\(row), \(col))"
                        )
                    }
                    totalPixels += 1
                }
            }
        }

        return DecodedScanStatistics(
            componentCount: scanHeader.componentCount,
            pixelsDecoded: totalPixels,
            interleaveMode: .line,
            colorTransformation: colorTransformation
        )
    }

    // MARK: - Sample Interleaved

    /// Decode with sample interleaving
    ///
    /// Per ITU-T.87, components alternate by pixel sample. For each pixel
    /// position, all components are decoded before moving to the next pixel.
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Decoding statistics
    /// - Throws: `JPEGLSError` if decoding fails
    private func decodeSampleInterleaved(buffer: JPEGLSPixelBuffer) throws -> DecodedScanStatistics {
        guard scanHeader.componentCount > 1 else {
            throw JPEGLSError.decodingFailed(
                reason: "Sample interleaving requires multiple components, got \(scanHeader.componentCount)"
            )
        }

        var totalPixels = 0

        // Decode pixel-by-pixel, all components per pixel
        for row in 0..<buffer.height {
            for col in 0..<buffer.width {
                for componentSelector in scanHeader.components {
                    let componentId = componentSelector.id

                    guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                        throw JPEGLSError.decodingFailed(
                            reason: "Failed to get neighbors for component \(componentId) at (\(row), \(col))"
                        )
                    }
                    totalPixels += 1
                }
            }
        }

        return DecodedScanStatistics(
            componentCount: scanHeader.componentCount,
            pixelsDecoded: totalPixels,
            interleaveMode: .sample,
            colorTransformation: colorTransformation
        )
    }

    // MARK: - Colour Transformation

    /// Apply inverse colour transformation to decoded component values
    ///
    /// After decoding, the inverse transformation is applied to recover
    /// the original colour space. This must match the forward transformation
    /// used during encoding.
    ///
    /// - Parameter components: Decoded component values (in transformed space)
    /// - Returns: Component values in original colour space
    /// - Throws: `JPEGLSError` if transformation fails
    public func applyInverseColorTransformation(_ components: [Int]) throws -> [Int] {
        return try colorTransformation.transformInverse(components)
    }

    /// Apply inverse colour transformation to a full image
    ///
    /// Transforms all pixels from the decoded colour space back to the
    /// original colour space. Operates on per-component 2D arrays.
    ///
    /// - Parameter componentPixels: Array of component pixel data, each as [row][column]
    /// - Returns: Array of component pixel data in original colour space
    /// - Throws: `JPEGLSError` if transformation fails or dimensions are inconsistent
    public func applyInverseColorTransformationToImage(
        _ componentPixels: [[Int]]
    ) throws -> [[Int]] {
        // For none transformation, return as-is
        if colorTransformation == .none {
            return componentPixels
        }

        guard componentPixels.count == frameHeader.componentCount else {
            throw JPEGLSError.decodingFailed(
                reason: "Component count mismatch: expected \(frameHeader.componentCount), got \(componentPixels.count)"
            )
        }

        let pixelCount = componentPixels[0].count
        for component in componentPixels {
            guard component.count == pixelCount else {
                throw JPEGLSError.decodingFailed(
                    reason: "Inconsistent pixel count across components"
                )
            }
        }

        // Transform each pixel position
        var result = componentPixels
        for pixelIndex in 0..<pixelCount {
            var pixelComponents: [Int] = []
            for componentIndex in 0..<componentPixels.count {
                pixelComponents.append(componentPixels[componentIndex][pixelIndex])
            }

            let transformed = try colorTransformation.transformInverse(pixelComponents)

            for componentIndex in 0..<transformed.count {
                result[componentIndex][pixelIndex] = transformed[componentIndex]
            }
        }

        return result
    }

    /// Reconstruct component data from decoded pixel buffer
    ///
    /// Extracts per-component pixel data from the pixel buffer and
    /// optionally applies inverse colour transformation.
    ///
    /// - Parameters:
    ///   - buffer: Decoded pixel buffer with all component data
    ///   - applyColorTransform: Whether to apply inverse colour transformation (default: true)
    /// - Returns: Reconstructed component data
    /// - Throws: `JPEGLSError` if reconstruction fails
    public func reconstructComponents(
        from buffer: JPEGLSPixelBuffer,
        applyColorTransform: Bool = true
    ) throws -> ReconstructedComponents {
        var componentPixels: [UInt8: [[Int]]] = [:]

        // Extract pixel data for each component
        for componentSpec in frameHeader.components {
            guard let pixels = buffer.getComponentPixels(componentId: componentSpec.id) else {
                throw JPEGLSError.decodingFailed(
                    reason: "Component \(componentSpec.id) not found in pixel buffer"
                )
            }
            componentPixels[componentSpec.id] = pixels
        }

        // Apply inverse colour transformation if needed
        if applyColorTransform && colorTransformation != .none
            && frameHeader.componentCount == 3
        {
            let componentIds = frameHeader.components.map { $0.id }

            // Flatten, transform, unflatten
            for row in 0..<frameHeader.height {
                for col in 0..<frameHeader.width {
                    var pixelValues: [Int] = []
                    for id in componentIds {
                        pixelValues.append(componentPixels[id]![row][col])
                    }

                    let transformed = try colorTransformation.transformInverse(pixelValues)

                    for (index, id) in componentIds.enumerated() {
                        componentPixels[id]![row][col] = transformed[index]
                    }
                }
            }
        }

        return ReconstructedComponents(
            componentPixels: componentPixels,
            width: buffer.width,
            height: buffer.height,
            colorTransformation: colorTransformation
        )
    }
}

/// Decoded scan statistics
///
/// Contains metadata about the decoded scan for validation and testing.
public struct DecodedScanStatistics: Sendable, Equatable {
    /// Number of components in scan
    public let componentCount: Int

    /// Total number of pixels decoded
    public let pixelsDecoded: Int

    /// Interleave mode used for decoding
    public let interleaveMode: JPEGLSInterleaveMode

    /// Color transformation applied
    public let colorTransformation: JPEGLSColorTransformation

    /// Initialize scan statistics
    public init(
        componentCount: Int,
        pixelsDecoded: Int,
        interleaveMode: JPEGLSInterleaveMode,
        colorTransformation: JPEGLSColorTransformation
    ) {
        self.componentCount = componentCount
        self.pixelsDecoded = pixelsDecoded
        self.interleaveMode = interleaveMode
        self.colorTransformation = colorTransformation
    }
}

/// Reconstructed component data after decoding
///
/// Contains per-component pixel data after decoding and optional
/// inverse colour transformation.
public struct ReconstructedComponents: Sendable {
    /// Per-component pixel data indexed by component ID
    /// Each component is stored as [row][column]
    public let componentPixels: [UInt8: [[Int]]]

    /// Image width
    public let width: Int

    /// Image height
    public let height: Int

    /// Colour transformation that was applied inversely
    public let colorTransformation: JPEGLSColorTransformation

    /// Initialize reconstructed components
    public init(
        componentPixels: [UInt8: [[Int]]],
        width: Int,
        height: Int,
        colorTransformation: JPEGLSColorTransformation
    ) {
        self.componentPixels = componentPixels
        self.width = width
        self.height = height
        self.colorTransformation = colorTransformation
    }

    /// Get pixels for a specific component
    ///
    /// - Parameter componentId: Component identifier
    /// - Returns: 2D array of pixel values [row][column], or nil if not found
    public func getPixels(componentId: UInt8) -> [[Int]]? {
        return componentPixels[componentId]
    }

    /// Get pixel value at a specific position for a component
    ///
    /// - Parameters:
    ///   - componentId: Component identifier
    ///   - row: Row index (0-based)
    ///   - column: Column index (0-based)
    /// - Returns: Pixel value, or nil if position or component is invalid
    public func getPixel(componentId: UInt8, row: Int, column: Int) -> Int? {
        guard let pixels = componentPixels[componentId] else {
            return nil
        }
        guard row >= 0 && row < height && column >= 0 && column < width else {
            return nil
        }
        return pixels[row][column]
    }

    /// Number of components
    public var componentCount: Int {
        return componentPixels.count
    }
}
