//
// J2KDWT2DTiled.swift
// J2KSwift
//
// J2KDWT2DTiled.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-06.
//

import Foundation

/// Tile-aware 2D Discrete Wavelet Transform for JPEG 2000.
///
/// This module extends the 2D DWT with tile-by-tile processing capabilities,
/// enabling efficient handling of large images through spatial decomposition.
/// In JPEG 2000, tiles are independently encoded regions that allow parallel
/// processing and memory-efficient streaming.
///
/// ## Tile Boundary Handling
///
/// A critical aspect of tiled DWT is proper boundary handling. According to
/// ISO/IEC 15444-1, wavelet filters must NOT read across tile boundaries.
/// Each tile is processed independently with boundary extension applied only
/// at the tile edges, not across neighboring tiles.
///
/// ## Memory Efficiency
///
/// Tile-by-tile processing enables:
/// - Processing images larger than available RAM
/// - Parallel tile encoding/decoding
/// - Reduced peak memory usage
/// - Progressive image loading
///
/// ## Usage
///
/// ```swift
/// let image = J2KImage(width: 1024, height: 1024, components: 3,
///                      tileWidth: 512, tileHeight: 512)
///
/// // Process each tile independently
/// let tiler = J2KDWT2DTiled()
/// for tileIndex in 0..<image.tileCount {
///     let tile = try tiler.extractTile(from: image, tileIndex: tileIndex)
///     let decomposition = try tiler.forwardTransform(
///         tile: tile,
///         levels: 3,
///         filter: .reversible53
///     )
///     // Process decomposed tile...
/// }
/// ```
public struct J2KDWT2DTiled: Sendable {
    // MARK: - Types

    /// Result of a tile-wise 2D DWT decomposition.
    public struct TileDecompositionResult: Sendable {
        /// The tile metadata.
        public let tile: J2KTile

        /// Multi-level decomposition result for the tile.
        public let decomposition: J2KDWT2D.MultiLevelDecomposition

        public init(tile: J2KTile, decomposition: J2KDWT2D.MultiLevelDecomposition) {
            self.tile = tile
            self.decomposition = decomposition
        }
    }

    /// Configuration for tile processing.
    public struct Configuration: Sendable {
        /// Whether to use memory pooling for temporary buffers.
        public let useMemoryPooling: Bool

        /// Maximum number of tiles to keep in memory simultaneously.
        public let maxCachedTiles: Int

        public init(useMemoryPooling: Bool = true, maxCachedTiles: Int = 4) {
            self.useMemoryPooling = useMemoryPooling
            self.maxCachedTiles = maxCachedTiles
        }
    }

    private let configuration: Configuration

    /// Creates a new tiled DWT processor.
    ///
    /// - Parameter configuration: Configuration options for tile processing.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Tile Extraction

    /// Extracts a specific tile from an image.
    ///
    /// Creates a J2KTile structure containing metadata for the specified
    /// tile region. Each tile is extracted independently and can be processed
    /// without loading the entire image into memory.
    ///
    /// - Parameters:
    ///   - image: The source image with tile configuration.
    ///   - tileIndex: The linear tile index (0-based).
    /// - Returns: A tile containing the extracted region metadata.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if tile index is invalid.
    /// - Throws: ``J2KError/invalidTileConfiguration(_:)`` if image is not tiled.
    public func extractTile(
        from image: J2KImage,
        tileIndex: Int
    ) throws -> J2KTile {
        // Validate tile index
        guard tileIndex >= 0 && tileIndex < image.tileCount else {
            throw J2KError.invalidParameter(
                "Tile index \(tileIndex) out of range [0, \(image.tileCount))"
            )
        }

        // Calculate tile grid position
        let tileX = tileIndex % image.tilesX
        let tileY = tileIndex / image.tilesX

        // Calculate tile boundaries in image coordinates
        let tileStartX = tileX * image.tileWidth + image.tileOffsetX
        let tileStartY = tileY * image.tileHeight + image.tileOffsetY

        // Calculate actual tile dimensions (may be smaller at image edges)
        let tileEndX = min(tileStartX + image.tileWidth, image.width)
        let tileEndY = min(tileStartY + image.tileHeight, image.height)

        let actualTileWidth = tileEndX - tileStartX
        let actualTileHeight = tileEndY - tileStartY

        // Extract tile-components for each image component
        var tileComponents: [J2KTileComponent] = []

        for (compIndex, component) in image.components.enumerated() {
            // Calculate tile-component dimensions accounting for subsampling
            let tcWidth = (actualTileWidth + component.subsamplingX - 1) / component.subsamplingX
            let tcHeight = (actualTileHeight + component.subsamplingY - 1) / component.subsamplingY

            let tileComponent = J2KTileComponent(
                componentIndex: compIndex,
                width: tcWidth,
                height: tcHeight
            )

            tileComponents.append(tileComponent)
        }

        let tile = J2KTile(
            index: tileIndex,
            x: tileX,
            y: tileY,
            width: actualTileWidth,
            height: actualTileHeight,
            offsetX: tileStartX,
            offsetY: tileStartY,
            components: tileComponents
        )

        return tile
    }

    /// Extracts tile data from a 2D image array.
    ///
    /// Extracts the pixel data for a specific tile region from a 2D array.
    /// This is used internally to extract tiles before DWT processing.
    ///
    /// - Parameters:
    ///   - imageData: The full image data as a 2D array.
    ///   - tile: The tile metadata specifying the region to extract.
    /// - Returns: 2D array containing the tile data.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if tile bounds exceed image dimensions.
    public func extractTileData(
        from imageData: [[Int32]],
        tile: J2KTile
    ) throws -> [[Int32]] {
        let imageHeight = imageData.count
        let imageWidth = imageData.isEmpty ? 0 : imageData[0].count

        // Validate tile bounds
        guard tile.offsetY >= 0 && tile.offsetX >= 0 else {
            throw J2KError.invalidParameter("Tile offset cannot be negative")
        }

        guard tile.offsetY + tile.height <= imageHeight &&
              tile.offsetX + tile.width <= imageWidth else {
            throw J2KError.invalidParameter(
                "Tile bounds [\(tile.offsetX),\(tile.offsetY)] + [\(tile.width)x\(tile.height)] " +
                "exceed image dimensions [\(imageWidth)x\(imageHeight)]"
            )
        }

        // Extract tile region
        var tileData: [[Int32]] = []
        tileData.reserveCapacity(tile.height)

        for y in tile.offsetY..<(tile.offsetY + tile.height) {
            let row = Array(imageData[y][tile.offsetX..<(tile.offsetX + tile.width)])
            tileData.append(row)
        }

        return tileData
    }

    // MARK: - Tile Assembly

    /// Assembles tiles back into a full image.
    ///
    /// Combines multiple tile results back into a single image array.
    /// This is the inverse operation of tile extraction.
    ///
    /// - Parameters:
    ///   - tiles: Array of tile data in tile-index order.
    ///   - image: The image metadata defining tile layout.
    /// - Returns: The assembled full image as a 2D array.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if tile count doesn't match image.
    public func assembleTiles(
        _ tiles: [[[Int32]]],
        into image: J2KImage
    ) throws -> [[Int32]] {
        guard tiles.count == image.tileCount else {
            throw J2KError.invalidParameter(
                "Expected \(image.tileCount) tiles, got \(tiles.count)"
            )
        }

        // Initialise output image
        var result: [[Int32]] = Array(
            repeating: Array(repeating: 0, count: image.width),
            count: image.height
        )

        // Place each tile into the output
        for tileIndex in 0..<tiles.count {
            let tile = try extractTile(from: image, tileIndex: tileIndex)
            let tileData = tiles[tileIndex]

            guard tileData.count == tile.height else {
                throw J2KError.invalidParameter(
                    "Tile \(tileIndex) has incorrect height: \(tileData.count) vs expected \(tile.height)"
                )
            }

            // Copy tile data into result
            for (localY, row) in tileData.enumerated() {
                let globalY = tile.offsetY + localY
                guard row.count == tile.width else {
                    throw J2KError.invalidParameter(
                        "Tile \(tileIndex) row \(localY) has incorrect width: \(row.count) vs expected \(tile.width)"
                    )
                }

                for (localX, value) in row.enumerated() {
                    let globalX = tile.offsetX + localX
                    result[globalY][globalX] = value
                }
            }
        }

        return result
    }

    // MARK: - Tile-wise DWT

    /// Performs forward DWT on a single tile.
    ///
    /// Applies multi-level 2D DWT to a tile's data. The boundary extension
    /// is applied at tile edges, ensuring the transform doesn't read across
    /// tile boundaries (required by JPEG 2000 standard).
    ///
    /// - Parameters:
    ///   - tileData: The tile data as a 2D array.
    ///   - levels: Number of decomposition levels.
    ///   - filter: Wavelet filter to use.
    ///   - boundaryExtension: Boundary extension mode (applied at tile edges).
    /// - Returns: Multi-level decomposition result.
    /// - Throws: ``J2KError`` if transform fails.
    ///
    /// Example:
    /// ```swift
    /// let tiler = J2KDWT2DTiled()
    /// let tileData = try tiler.extractTileData(from: imageData, tile: tile)
    /// let decomposition = try tiler.forwardTransformTile(
    ///     tileData: tileData,
    ///     levels: 3,
    ///     filter: .reversible53
    /// )
    /// ```
    public func forwardTransformTile(
        tileData: [[Int32]],
        levels: Int,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> J2KDWT2D.MultiLevelDecomposition {
        // Apply standard 2D DWT to the tile
        // Since the tile has already been extracted, boundary extension
        // naturally occurs at tile edges without crossing tile boundaries
        try J2KDWT2D.forwardDecomposition(
            image: tileData,
            levels: levels,
            filter: filter,
            boundaryExtension: boundaryExtension
        )
    }

    /// Performs forward DWT on a tile with metadata.
    ///
    /// Convenience method that combines tile data extraction and transformation.
    ///
    /// - Parameters:
    ///   - imageData: Full image data.
    ///   - tile: Tile metadata.
    ///   - levels: Number of decomposition levels.
    ///   - filter: Wavelet filter to use.
    ///   - boundaryExtension: Boundary extension mode.
    /// - Returns: Tile decomposition result including metadata.
    /// - Throws: ``J2KError`` if extraction or transform fails.
    public func forwardTransformTile(
        imageData: [[Int32]],
        tile: J2KTile,
        levels: Int,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> TileDecompositionResult {
        let tileData = try extractTileData(from: imageData, tile: tile)
        let decomposition = try forwardTransformTile(
            tileData: tileData,
            levels: levels,
            filter: filter,
            boundaryExtension: boundaryExtension
        )

        return TileDecompositionResult(tile: tile, decomposition: decomposition)
    }

    /// Performs inverse DWT on a tile.
    ///
    /// Reconstructs tile data from its multi-level decomposition.
    ///
    /// - Parameters:
    ///   - decomposition: Multi-level decomposition result.
    ///   - filter: Wavelet filter to use (must match forward transform).
    ///   - boundaryExtension: Boundary extension mode (must match forward transform).
    /// - Returns: Reconstructed tile data.
    /// - Throws: ``J2KError`` if reconstruction fails.
    public func inverseTransformTile(
        decomposition: J2KDWT2D.MultiLevelDecomposition,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [[Int32]] {
        try J2KDWT2D.inverseDecomposition(
            decomposition: decomposition,
            filter: filter,
            boundaryExtension: boundaryExtension
        )
    }

    // MARK: - Full Image Processing

    /// Processes an entire image tile-by-tile.
    ///
    /// Applies DWT to each tile independently and returns all decomposition results.
    /// This enables parallel processing and memory-efficient handling of large images.
    ///
    /// - Parameters:
    ///   - imageData: The full image data.
    ///   - image: Image metadata with tiling configuration.
    ///   - levels: Number of decomposition levels per tile.
    ///   - filter: Wavelet filter to use.
    ///   - boundaryExtension: Boundary extension mode.
    /// - Returns: Array of tile decomposition results.
    /// - Throws: ``J2KError`` if processing fails.
    ///
    /// Example:
    /// ```swift
    /// let image = J2KImage(width: 1024, height: 1024, components: 3,
    ///                      tileWidth: 512, tileHeight: 512)
    /// let tiler = J2KDWT2DTiled()
    /// let results = try tiler.processImageTiled(
    ///     imageData: pixelData,
    ///     image: image,
    ///     levels: 3,
    ///     filter: .reversible53
    /// )
    /// // Process each tile's decomposition...
    /// ```
    public func processImageTiled(
        imageData: [[Int32]],
        image: J2KImage,
        levels: Int,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [TileDecompositionResult] {
        var results: [TileDecompositionResult] = []
        results.reserveCapacity(image.tileCount)

        // Process each tile
        for tileIndex in 0..<image.tileCount {
            let tile = try extractTile(from: image, tileIndex: tileIndex)
            let result = try forwardTransformTile(
                imageData: imageData,
                tile: tile,
                levels: levels,
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            results.append(result)
        }

        return results
    }

    /// Reconstructs a full image from tile decompositions.
    ///
    /// Applies inverse DWT to each tile and assembles the results into a full image.
    ///
    /// - Parameters:
    ///   - tileDecompositions: Array of tile decomposition results.
    ///   - image: Image metadata with tiling configuration.
    ///   - filter: Wavelet filter to use (must match forward transform).
    ///   - boundaryExtension: Boundary extension mode (must match forward transform).
    /// - Returns: The reconstructed full image.
    /// - Throws: ``J2KError`` if reconstruction fails.
    public func reconstructImageFromTiles(
        tileDecompositions: [TileDecompositionResult],
        image: J2KImage,
        filter: J2KDWT1D.Filter,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) throws -> [[Int32]] {
        guard tileDecompositions.count == image.tileCount else {
            throw J2KError.invalidParameter(
                "Expected \(image.tileCount) tile decompositions, got \(tileDecompositions.count)"
            )
        }

        // Reconstruct each tile
        var reconstructedTiles: [[[Int32]]] = []
        reconstructedTiles.reserveCapacity(tileDecompositions.count)

        for tileResult in tileDecompositions {
            let tileData = try inverseTransformTile(
                decomposition: tileResult.decomposition,
                filter: filter,
                boundaryExtension: boundaryExtension
            )
            reconstructedTiles.append(tileData)
        }

        // Assemble tiles into full image
        return try assembleTiles(reconstructedTiles, into: image)
    }
}
