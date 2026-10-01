/// Controls which encoded payload representations are retained while parsing DICOM video.
public enum DicomVideoPayloadMode: Equatable, Sendable {
    /// Retains both the complete elementary stream and individually indexed frame payloads.
    case indexedFrames

    /// Retains only the complete elementary stream.
    case streamOnly
}
