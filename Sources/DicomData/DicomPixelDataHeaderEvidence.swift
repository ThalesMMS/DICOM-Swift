/// Original encoded Pixel Data header, captured only by the validation traversal.
/// No sample bytes or instance identifiers are retained. Length includes any value-field padding.
public struct DicomPixelDataHeaderEvidence: Equatable, Sendable {
    public let path: [DicomValidationReport.PathComponent]
    public let vr: DicomVR
    /// UInt32.max denotes undefined length, not a native byte count.
    public let valueLength: UInt32
    /// Byte offset of the value field within the validated dataset bytes.
    public let valueOffset: Int
}
