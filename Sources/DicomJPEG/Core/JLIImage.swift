// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// A pixel format describing how color components are stored in memory.
public enum JLIPixelFormat: Sendable {
    /// 8-bit unsigned integer per component (standard JPEG).
    case uint8

    /// 16-bit unsigned integer per component (10+ bit encoding).
    case uint16

    /// 32-bit floating point per component.
    case float32

    /// The number of bytes per component for this pixel format.
    public var bytesPerComponent: Int {
        switch self {
        case .uint8: return 1
        case .uint16: return 2
        case .float32: return 4
        }
    }

    /// The number of bits per component for this pixel format.
    public var bitsPerComponent: Int {
        bytesPerComponent * 8
    }
}

/// Describes the color model used by the image data.
public enum JLIColorModel: Sendable {
    /// Grayscale (single channel).
    case grayscale

    /// Red, Green, Blue (3 channels).
    case rgb

    /// Red, Green, Blue, Alpha (4 channels).
    case rgba

    /// YCbCr luminance/chrominance (3 channels) — standard JPEG internal format.
    case yCbCr

    /// CMYK (4 channels).
    case cmyk

    /// XYB perceptual color space from JPEG XL (3 channels).
    case xyb

    /// The number of components (channels) for this color model.
    public var componentCount: Int {
        switch self {
        case .grayscale: return 1
        case .rgb, .yCbCr, .xyb: return 3
        case .rgba, .cmyk: return 4
        }
    }
}

/// A container for image pixel data used as input to the encoder or output from the decoder.
///
/// `JLIImage` holds a contiguous buffer of pixel data along with its dimensions,
/// pixel format, and color model. It supports 8-bit, 16-bit, and 32-bit floating
/// point component formats to enable jpegli's 10+ bit encoding capability.
public struct JLIImage: Sendable {
    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The pixel format of the stored data.
    public let pixelFormat: JLIPixelFormat

    /// The color model describing the channel layout.
    public let colorModel: JLIColorModel

    /// Whether the integer samples are signed two's-complement (e.g. DICOM
    /// `PixelRepresentation == 1`, as in signed CT Hounsfield data).
    ///
    /// JPEG itself stores unsigned samples, so this is provenance the container
    /// carries on the caller's behalf: the **lossless** path preserves the exact
    /// sample bytes regardless of sign (so signed data round-trips bit-exactly and
    /// this flag is propagated to the decoded image), while the **lossy DCT** path
    /// is undefined for signed samples and rejects them rather than silently
    /// corrupting values — encode signed data losslessly, or offset it to unsigned
    /// first. Only meaningful for integer formats; ignored for `.float32`.
    public let isSigned: Bool

    /// The raw pixel data as a contiguous byte buffer.
    ///
    /// Data is stored in row-major order with components interleaved per pixel.
    /// The total size is `width * height * colorModel.componentCount * pixelFormat.bytesPerComponent`.
    public let data: [UInt8]

    /// The embedded ICC color profile, if any.
    ///
    /// On decode this holds the profile reassembled from the JPEG's APP2
    /// `ICC_PROFILE` segments (`nil` when none is present). On encode, set it (or
    /// ``JLIEncoderConfiguration/iccProfile``) to embed a profile so color-managed
    /// viewers interpret the pixels correctly.
    public let iccProfile: [UInt8]?

    /// The raw Exif payload (APP1 `Exif\0\0` segment body), if any.
    ///
    /// Preserved verbatim across decode→encode for metadata round-tripping. `nil`
    /// when the JPEG carries no Exif segment.
    public let exif: [UInt8]?

    /// The number of bytes per row (stride).
    public var bytesPerRow: Int {
        width * colorModel.componentCount * pixelFormat.bytesPerComponent
    }

    /// Creates a new image from raw pixel data.
    ///
    /// - Parameters:
    ///   - width: The width of the image in pixels.
    ///   - height: The height of the image in pixels.
    ///   - pixelFormat: The pixel format of the data.
    ///   - colorModel: The color model of the data.
    ///   - data: The raw pixel bytes in row-major, interleaved order.
    /// - Throws: ``JLIError/invalidImageDimensions`` if width or height is non-positive,
    ///   or ``JLIError/bufferSizeMismatch`` if the data size doesn't match the expected size.
    public init(
        width: Int,
        height: Int,
        pixelFormat: JLIPixelFormat,
        colorModel: JLIColorModel,
        data: [UInt8],
        isSigned: Bool = false,
        iccProfile: [UInt8]? = nil,
        exif: [UInt8]? = nil
    ) throws {
        guard width > 0, height > 0 else {
            throw JLIError.invalidImageDimensions(width: width, height: height)
        }
        let expectedSize = width * height * colorModel.componentCount * pixelFormat.bytesPerComponent
        guard data.count == expectedSize else {
            throw JLIError.bufferSizeMismatch(expected: expectedSize, actual: data.count)
        }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.colorModel = colorModel
        self.isSigned = isSigned
        self.data = data
        self.iccProfile = iccProfile
        self.exif = exif
    }
}
