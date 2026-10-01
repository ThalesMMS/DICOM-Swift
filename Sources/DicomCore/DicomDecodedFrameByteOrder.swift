/// Byte order used by multi-byte samples in a Data-backed decoded frame.
public enum DicomDecodedFrameByteOrder: String, Equatable, Sendable {
    /// The format contains only one-byte component samples.
    case notApplicable
    /// Multi-byte samples are stored least-significant byte first.
    case littleEndian
    /// Multi-byte samples are stored most-significant byte first.
    case bigEndian
}
