import Foundation

/// Rectangular source-space region expressed in full-resolution pixel coordinates.
public struct DicomFrameRegion: Sendable, Equatable, Hashable {
    /// Horizontal origin in source pixels.
    public let x: Int
    /// Vertical origin in source pixels.
    public let y: Int
    /// Requested source width in pixels.
    public let width: Int
    /// Requested source height in pixels.
    public let height: Int

    /// Creates a source-space region. The frame reader validates and clips it at execution time.
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
