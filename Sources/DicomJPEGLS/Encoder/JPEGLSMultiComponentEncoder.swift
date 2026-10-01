// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// Multi-component JPEG-LS encoder with interleaving support
///
/// Implements component interleaving modes per ITU-T.87:
/// - None: Components encoded separately in sequential scans
/// - Line: Components interleaved by scan line
/// - Sample: Components interleaved by pixel sample (best for RGB)

import Foundation

/// Multi-component JPEG-LS encoder
///
/// Orchestrates encoding of multi-component images with support for
/// all interleaving modes defined in JPEG-LS standard.
public struct JPEGLSMultiComponentEncoder: Sendable {
    /// Frame header defining image parameters
    private let frameHeader: JPEGLSFrameHeader

    /// Scan header defining encoding parameters
    private let scanHeader: JPEGLSScanHeader

    /// Preset parameters for encoding
    private let parameters: JPEGLSPresetParameters

    /// Initialize multi-component encoder
    ///
    /// - Parameters:
    ///   - frameHeader: Frame header with image parameters
    ///   - scanHeader: Scan header with encoding parameters
    /// - Throws: `JPEGLSError` if parameters are incompatible
    public init(
        frameHeader: JPEGLSFrameHeader,
        scanHeader: JPEGLSScanHeader
    ) throws {
        // Validate scan header against frame header
        try scanHeader.validate(against: frameHeader)

        self.frameHeader = frameHeader
        self.scanHeader = scanHeader

        // Create preset parameters from frame header using defaults
        self.parameters = try JPEGLSPresetParameters.defaultParameters(
            bitsPerSample: frameHeader.bitsPerSample,
            near: scanHeader.near
        )
    }

    /// Encode a scan according to the interleave mode
    ///
    /// Routes to the appropriate encoding method based on the scan's
    /// interleave mode (none, line, or sample).
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Encoded scan statistics (for testing/validation)
    /// - Throws: `JPEGLSError` if encoding fails
    public func encodeScan(buffer: JPEGLSPixelBuffer) throws -> EncodedScanStatistics {
        switch scanHeader.interleaveMode {
        case .none:
            return try encodeNoneInterleaved(buffer: buffer)
        case .line:
            return try encodeLineInterleaved(buffer: buffer)
        case .sample:
            return try encodeSampleInterleaved(buffer: buffer)
        }
    }

    // MARK: - None Interleaved (Separate Scans)

    /// Encode with no interleaving (components in separate scans)
    ///
    /// Per ITU-T.87, when interleave mode is none, each component is encoded
    /// in its own scan in raster order (left-to-right, top-to-bottom).
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Encoding statistics
    /// - Throws: `JPEGLSError` if encoding fails
    private func encodeNoneInterleaved(buffer: JPEGLSPixelBuffer) throws -> EncodedScanStatistics {
        // For none interleaving, scan must have exactly 1 component
        guard scanHeader.componentCount == 1 else {
            throw JPEGLSError.encodingFailed(
                reason: "None interleaving requires exactly 1 component in scan, got \(scanHeader.componentCount)"
            )
        }

        let componentId = scanHeader.components[0].id
        var totalPixels = 0

        // Encode component in raster order
        for row in 0..<buffer.height {
            for col in 0..<buffer.width {
                guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                    throw JPEGLSError.encodingFailed(reason: "Failed to get neighbors for pixel at (\(row), \(col))")
                }
                totalPixels += 1
            }
        }

        return EncodedScanStatistics(
            componentCount: 1,
            pixelsEncoded: totalPixels,
            interleaveMode: .none
        )
    }

    // MARK: - Line Interleaved

    /// Encode with line interleaving
    ///
    /// Per ITU-T.87, components alternate by scan line. All components
    /// of row 0 are encoded, then all components of row 1, etc.
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Encoding statistics
    /// - Throws: `JPEGLSError` if encoding fails
    private func encodeLineInterleaved(buffer: JPEGLSPixelBuffer) throws -> EncodedScanStatistics {
        guard scanHeader.componentCount > 1 else {
            throw JPEGLSError.encodingFailed(
                reason: "Line interleaving requires multiple components, got \(scanHeader.componentCount)"
            )
        }

        var totalPixels = 0

        // Encode line-by-line, all components per line
        for row in 0..<buffer.height {
            for componentSelector in scanHeader.components {
                let componentId = componentSelector.id

                for col in 0..<buffer.width {
                    guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                        throw JPEGLSError.encodingFailed(
                            reason: "Failed to get neighbors for component \(componentId) at (\(row), \(col))"
                        )
                    }
                    totalPixels += 1
                }
            }
        }

        return EncodedScanStatistics(
            componentCount: scanHeader.componentCount,
            pixelsEncoded: totalPixels,
            interleaveMode: .line
        )
    }

    // MARK: - Sample Interleaved

    /// Encode with sample interleaving
    ///
    /// Per ITU-T.87, components alternate by pixel sample. For each pixel
    /// position, all components are encoded before moving to the next pixel.
    /// This provides best compression for correlated components (e.g., RGB).
    ///
    /// - Parameter buffer: Pixel buffer containing image data
    /// - Returns: Encoding statistics
    /// - Throws: `JPEGLSError` if encoding fails
    private func encodeSampleInterleaved(buffer: JPEGLSPixelBuffer) throws -> EncodedScanStatistics {
        guard scanHeader.componentCount > 1 else {
            throw JPEGLSError.encodingFailed(
                reason: "Sample interleaving requires multiple components, got \(scanHeader.componentCount)"
            )
        }

        var totalPixels = 0

        // Encode pixel-by-pixel, all components per pixel
        for row in 0..<buffer.height {
            for col in 0..<buffer.width {
                for componentSelector in scanHeader.components {
                    let componentId = componentSelector.id

                    guard let _ = buffer.getNeighbors(componentId: componentId, row: row, column: col) else {
                        throw JPEGLSError.encodingFailed(
                            reason: "Failed to get neighbors for component \(componentId) at (\(row), \(col))"
                        )
                    }
                    totalPixels += 1
                }
            }
        }

        return EncodedScanStatistics(
            componentCount: scanHeader.componentCount,
            pixelsEncoded: totalPixels,
            interleaveMode: .sample
        )
    }
}

/// Encoded scan statistics
///
/// Contains metadata about the encoded scan for validation and testing.
public struct EncodedScanStatistics: Sendable, Equatable {
    /// Number of components in scan
    public let componentCount: Int

    /// Total number of pixels encoded
    public let pixelsEncoded: Int

    /// Interleave mode used for encoding
    public let interleaveMode: JPEGLSInterleaveMode

    /// Initialize scan statistics
    public init(componentCount: Int, pixelsEncoded: Int, interleaveMode: JPEGLSInterleaveMode) {
        self.componentCount = componentCount
        self.pixelsEncoded = pixelsEncoded
        self.interleaveMode = interleaveMode
    }
}
