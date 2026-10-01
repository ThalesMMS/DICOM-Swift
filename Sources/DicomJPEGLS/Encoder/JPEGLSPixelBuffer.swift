// Modified for Isis from JLSwift 299b9a2 (Apache-2.0); the modifications are recorded in Git.

/// Multi-component pixel buffer for JPEG-LS encoding
///
/// Provides component-aware pixel access with neighbor tracking for
/// multi-component images. Supports all interleaving modes (none, line, sample).

import Foundation

/// Multi-component image data representation
///
/// Organizes pixel data by component for efficient access during encoding
/// with different interleaving modes.
public struct MultiComponentImageData: Sendable {
    /// Image components
    public let components: [ComponentData]

    /// Frame header defining image parameters
    public let frameHeader: JPEGLSFrameHeader

    /// Individual component data
    public struct ComponentData: Sendable {
        /// Component identifier (matches frame header component ID)
        public let id: UInt8

        /// Pixel values organized as [row][column]
        /// Each pixel value must be in range [0, MAXVAL]
        public let pixels: [[Int]]

        /// Initialize component data
        ///
        /// - Parameters:
        ///   - id: Component identifier
        ///   - pixels: 2D array of pixel values [row][column]
        public init(id: UInt8, pixels: [[Int]]) {
            self.id = id
            self.pixels = pixels
        }
    }

    /// Initialize multi-component image data
    ///
    /// Supports both uniform-resolution images (all components at `frameHeader.width × frameHeader.height`)
    /// and sub-sampled images where each component's resolution is derived from its sampling factors
    /// stored in `frameHeader.components`.  The expected dimensions for component *i* are:
    ///
    /// ```
    /// width_i  = ⌈ frameWidth  × H_i / Hmax ⌉
    /// height_i = ⌈ frameHeight × V_i / Vmax ⌉
    /// ```
    ///
    /// where `Hmax` / `Vmax` are the maximum horizontal / vertical sampling factors across all
    /// frame components.  When all sampling factors equal 1 the formula reduces to the full
    /// frame dimensions, preserving backward compatibility.
    ///
    /// - Parameters:
    ///   - components: Array of component data
    ///   - frameHeader: Frame header with image parameters
    /// - Throws: `JPEGLSError` if validation fails
    public init(components: [ComponentData], frameHeader: JPEGLSFrameHeader) throws {
        // Validate component count matches frame header
        guard components.count == frameHeader.componentCount else {
            throw JPEGLSError.invalidFrameHeader(
                reason: "Component count mismatch: expected \(frameHeader.componentCount), got \(components.count)"
            )
        }

        // Compute max sampling factors for sub-sampling support.
        let hMax = max(1, frameHeader.components.map { Int($0.horizontalSamplingFactor) }.max() ?? 1)
        let vMax = max(1, frameHeader.components.map { Int($0.verticalSamplingFactor) }.max() ?? 1)

        // Build a lookup from component ID to its frame spec for dimension computation.
        let frameCompByID = Dictionary(uniqueKeysWithValues: frameHeader.components.map { ($0.id, $0) })

        // Validate all component IDs exist in frame header
        for component in components {
            guard let frameComp = frameCompByID[component.id] else {
                throw JPEGLSError.invalidFrameHeader(
                    reason: "Component ID \(component.id) not found in frame header"
                )
            }

            // Compute expected dimensions for this component using its sampling factors.
            let h = Int(frameComp.horizontalSamplingFactor)
            let v = Int(frameComp.verticalSamplingFactor)
            let expectedWidth  = (frameHeader.width  * h + hMax - 1) / hMax
            let expectedHeight = (frameHeader.height * v + vMax - 1) / vMax

            guard component.pixels.count == expectedHeight else {
                throw JPEGLSError.invalidDimensions(
                    width: component.pixels.first?.count ?? 0,
                    height: component.pixels.count
                )
            }

            for row in component.pixels {
                guard row.count == expectedWidth else {
                    throw JPEGLSError.invalidDimensions(
                        width: row.count,
                        height: expectedHeight
                    )
                }
            }

            // Validate pixel values are in range [0, MAXVAL]
            let maxValue = (1 << frameHeader.bitsPerSample) - 1
            for row in component.pixels {
                for pixel in row {
                    guard pixel >= 0 && pixel <= maxValue else {
                        throw JPEGLSError.encodingFailed(
                            reason: "Pixel value \(pixel) out of range [0, \(maxValue)] for component \(component.id)"
                        )
                    }
                }
            }
        }

        self.components = components
        self.frameHeader = frameHeader
    }

    /// Trusted initializer for decoder-produced components.
    ///
    /// Skips the O(W·H) dimension and range validation of the public
    /// initializer: the decode pipeline clamps every sample to [0, MAXVAL]
    /// by construction and allocates rows at exact scan dimensions. Internal
    /// only — public API always goes through the validating initializer.
    internal init(uncheckedComponents components: [ComponentData], frameHeader: JPEGLSFrameHeader) {
        self.components = components
        self.frameHeader = frameHeader
    }

    /// Create grayscale image data
    ///
    /// ```swift
    /// // 8-bit greyscale image
    /// let pixels: [[Int]] = (0..<256).map { y in
    ///     (0..<256).map { x in (x + y) % 256 }
    /// }
    /// let imageData = try MultiComponentImageData.grayscale(pixels: pixels, bitsPerSample: 8)
    ///
    /// // 12-bit greyscale image (e.g., CT scan slice)
    /// let ctData = try MultiComponentImageData.grayscale(
    ///     pixels: ctPixels,
    ///     bitsPerSample: 12
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - pixels: 2D array of pixel values [row][column]
    ///   - bitsPerSample: Bits per sample (2-16)
    /// - Returns: Multi-component image data with single grayscale component
    /// - Throws: `JPEGLSError` if validation fails
    public static func grayscale(pixels: [[Int]], bitsPerSample: Int) throws -> MultiComponentImageData {
        let height = pixels.count
        let width = pixels.first?.count ?? 0

        let frameHeader = try JPEGLSFrameHeader.grayscale(
            bitsPerSample: bitsPerSample,
            width: width,
            height: height
        )

        return try MultiComponentImageData(
            components: [ComponentData(id: 1, pixels: pixels)],
            frameHeader: frameHeader
        )
    }

    /// Create RGB image data
    ///
    /// ```swift
    /// // 8-bit RGB image with separate component planes
    /// let rgbData = try MultiComponentImageData.rgb(
    ///     redPixels:   redPlane,
    ///     greenPixels: greenPlane,
    ///     bluePixels:  bluePlane,
    ///     bitsPerSample: 8
    /// )
    ///
    /// // 12-bit RGB image
    /// let rgb12 = try MultiComponentImageData.rgb(
    ///     redPixels: red12, greenPixels: green12, bluePixels: blue12,
    ///     bitsPerSample: 12
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - redPixels: Red component pixels [row][column]
    ///   - greenPixels: Green component pixels [row][column]
    ///   - bluePixels: Blue component pixels [row][column]
    ///   - bitsPerSample: Bits per sample (2-16)
    /// - Returns: Multi-component image data with RGB components
    /// - Throws: `JPEGLSError` if validation fails
    public static func rgb(
        redPixels: [[Int]],
        greenPixels: [[Int]],
        bluePixels: [[Int]],
        bitsPerSample: Int
    ) throws -> MultiComponentImageData {
        let height = redPixels.count
        let width = redPixels.first?.count ?? 0

        let frameHeader = try JPEGLSFrameHeader.rgb(
            bitsPerSample: bitsPerSample,
            width: width,
            height: height
        )

        return try MultiComponentImageData(
            components: [
                ComponentData(id: 1, pixels: redPixels),
                ComponentData(id: 2, pixels: greenPixels),
                ComponentData(id: 3, pixels: bluePixels)
            ],
            frameHeader: frameHeader
        )
    }
}

/// Component-aware pixel buffer with neighbor tracking
///
/// Provides efficient access to pixels and their neighbors for JPEG-LS encoding.
/// Handles boundary conditions per ITU-T.87 specifications.
public struct JPEGLSPixelBuffer: Sendable {
    /// Component pixel data indexed by component ID
    private let componentPixels: [UInt8: [[Int]]]

    /// Image width
    public let width: Int

    /// Image height
    public let height: Int

    /// Pixel neighbors for encoding
    public struct PixelNeighbors: Sendable {
        /// Current pixel value (x)
        public let actual: Int

        /// Left neighbor (a = pixel to the left)
        public let left: Int

        /// Top neighbor (b = pixel above)
        public let top: Int

        /// Top-left diagonal neighbor (c)
        public let topLeft: Int

        /// Top-right diagonal neighbor (d) - used for run mode detection
        public let topRight: Int

        /// Initialize pixel neighbors
        public init(actual: Int, left: Int, top: Int, topLeft: Int, topRight: Int) {
            self.actual = actual
            self.left = left
            self.top = top
            self.topLeft = topLeft
            self.topRight = topRight
        }
    }

    /// Initialize pixel buffer from multi-component image data
    ///
    /// - Parameter imageData: Multi-component image data
    public init(imageData: MultiComponentImageData) {
        var pixels: [UInt8: [[Int]]] = [:]
        for component in imageData.components {
            pixels[component.id] = component.pixels
        }

        self.componentPixels = pixels
        self.width = imageData.frameHeader.width
        self.height = imageData.frameHeader.height
    }

    /// Get pixel neighbors for encoding at specified position
    ///
    /// Handles boundary conditions per ITU-T.87:
    /// - First pixel: all neighbors are 0
    /// - First row: top neighbors use left pixel
    /// - First column: left neighbors use top pixel
    ///
    /// - Parameters:
    ///   - componentId: Component identifier
    ///   - row: Row index (0-based)
    ///   - column: Column index (0-based)
    /// - Returns: Pixel neighbors, or nil if position is invalid
    public func getNeighbors(
        componentId: UInt8,
        row: Int,
        column: Int,
        prevRowEdge: Int = 0
    ) -> PixelNeighbors? {
        guard let pixels = componentPixels[componentId] else {
            return nil
        }

        guard row >= 0 && row < height && column >= 0 && column < width else {
            return nil
        }

        let actual = pixels[row][column]

        // Handle boundary conditions per ITU-T.87 Section 3.2
        if row == 0 && column == 0 {
            // First pixel: all neighbors are 0
            return PixelNeighbors(
                actual: actual,
                left: 0,
                top: 0,
                topLeft: 0,
                topRight: 0
            )
        } else if row == 0 {
            // First row: no scan line above; top/top-left/top-right are 0
            // per ITU-T.87 §3.2 boundary initialisation.
            let left = pixels[row][column - 1]
            return PixelNeighbors(
                actual: actual,
                left: left,
                top: 0,
                topLeft: 0,
                topRight: 0
            )
        } else if column == 0 {
            // First column: Ra=Rb=top, Rc=prevRowEdge (per ITU-T.87 edge pixel logic)
            let top = pixels[row - 1][column]
            let topRight = (width > 1) ? pixels[row - 1][column + 1] : top
            return PixelNeighbors(
                actual: actual,
                left: top,
                top: top,
                topLeft: prevRowEdge,
                topRight: topRight
            )
        } else {
            // General case
            let left = pixels[row][column - 1]
            let top = pixels[row - 1][column]
            let topLeft = pixels[row - 1][column - 1]
            let topRight = (column + 1 < width) ? pixels[row - 1][column + 1] : top

            return PixelNeighbors(
                actual: actual,
                left: left,
                top: top,
                topLeft: topLeft,
                topRight: topRight
            )
        }
    }

    /// Get pixel value at specified position
    ///
    /// - Parameters:
    ///   - componentId: Component identifier
    ///   - row: Row index (0-based)
    ///   - column: Column index (0-based)
    /// - Returns: Pixel value, or nil if position is invalid
    public func getPixel(componentId: UInt8, row: Int, column: Int) -> Int? {
        guard let pixels = componentPixels[componentId] else {
            return nil
        }

        guard row >= 0 && row < height && column >= 0 && column < width else {
            return nil
        }

        return pixels[row][column]
    }

    /// Get all pixels for a component
    ///
    /// - Parameter componentId: Component identifier
    /// - Returns: 2D array of pixels [row][column], or nil if component not found
    public func getComponentPixels(componentId: UInt8) -> [[Int]]? {
        return componentPixels[componentId]
    }
}
