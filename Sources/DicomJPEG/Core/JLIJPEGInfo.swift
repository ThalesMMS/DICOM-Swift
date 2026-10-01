// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Metadata about a decoded JPEG, exposing any advanced features detected in the bitstream.
public struct JLIJPEGInfo: Sendable {
    /// The image width in pixels.
    public let width: Int

    /// The image height in pixels.
    public let height: Int

    /// The number of color components.
    public let componentCount: Int

    /// The bits per component as stored in the JPEG (8 for standard, >8 for jpegli extended).
    public let bitsPerComponent: Int

    /// Whether the JPEG uses progressive encoding.
    public let isProgressive: Bool

    /// Whether the JPEG was encoded with XYB color space (detected via ICC profile).
    public let isXYB: Bool

    /// Whether the JPEG uses jpegli's extended precision (10+ bit).
    public let isExtendedPrecision: Bool

    /// The chroma subsampling mode detected in the JPEG.
    public let chromaSubsampling: JLIChromaSubsampling
}
