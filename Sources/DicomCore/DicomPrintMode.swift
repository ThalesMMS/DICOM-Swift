/// The print path requested by the caller. Automatic prefers color and falls
/// back to grayscale only when the peer does not accept color.
public enum DicomPrintMode: String, Equatable, Sendable {
    case automatic
    case grayscale
    case color
}
