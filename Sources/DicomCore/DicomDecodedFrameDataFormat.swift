/// Canonical byte interpretation of a Data-backed decoded frame.
public enum DicomDecodedFrameDataFormat: String, Equatable, Sendable {
    /// Unsigned 8-bit grayscale after signed-value normalization and MONOCHROME1 inversion.
    case gray8NormalizedUnsigned
    /// Unsigned 16-bit grayscale after signed-value normalization and MONOCHROME1 inversion.
    case gray16NormalizedUnsigned
    /// Interleaved 8-bit red, green, and blue component samples.
    case rgb8Interleaved
}
