// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Errors that can occur during JLISwift encoding or decoding operations.
public enum JLIError: Error, Sendable {
    /// The image dimensions are invalid (zero or negative).
    case invalidImageDimensions(width: Int, height: Int)

    /// The provided pixel buffer size does not match the expected size for the given dimensions and format.
    case bufferSizeMismatch(expected: Int, actual: Int)

    /// The provided quality value is outside the valid range.
    case invalidQuality(Double)

    /// The provided distance value is outside the valid range.
    case invalidDistance(Double)

    /// The input data is not a valid JPEG bitstream.
    case invalidJPEGData

    /// The JPEG data contains unsupported features or markers.
    case unsupportedJPEGFeature(String)

    /// An internal encoding error occurred.
    case encodingFailed(String)

    /// An internal decoding error occurred.
    case decodingFailed(String)

    /// The requested color space conversion is not supported.
    case unsupportedColorSpaceConversion(from: String, to: String)

    /// A feature is not yet implemented in the current milestone.
    case notImplemented(String)
}

extension JLIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidImageDimensions(let width, let height):
            return "Invalid image dimensions: \(width)×\(height)"
        case .bufferSizeMismatch(let expected, let actual):
            return "Buffer size mismatch: expected \(expected) bytes, got \(actual)"
        case .invalidQuality(let quality):
            return "Invalid quality value: \(quality) (must be 0.0–100.0)"
        case .invalidDistance(let distance):
            return "Invalid distance value: \(distance) (must be ≥ 0.0)"
        case .invalidJPEGData:
            return "The input data is not a valid JPEG bitstream"
        case .unsupportedJPEGFeature(let feature):
            return "Unsupported JPEG feature: \(feature)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .unsupportedColorSpaceConversion(let from, let to):
            return "Unsupported color space conversion: \(from) → \(to)"
        case .notImplemented(let feature):
            return "Not yet implemented: \(feature)"
        }
    }
}
