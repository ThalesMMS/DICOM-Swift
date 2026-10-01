/// A property that changed during a Part 10 metadata rewrite.
public enum DicomPart10PreservationFailure: Equatable, Sendable {
    /// The reopened transfer syntax differs from the source.
    case transferSyntax
    /// The dataset SOP Class differs from the source.
    case sopClassUID
    /// File Meta Information does not carry the intended SOP Class.
    case mediaStorageSOPClassUID
    /// File Meta Information does not carry the intended SOP Instance UID.
    case mediaStorageSOPInstanceUID
    /// The complete Pixel Data value differs from the source.
    case pixelData(beforeByteCount: Int?, afterByteCount: Int?)
}
