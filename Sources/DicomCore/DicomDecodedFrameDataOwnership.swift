/// Retention model of a Data-backed decoded frame.
public enum DicomDecodedFrameDataOwnership: String, Equatable, Sendable {
    /// The decoded result owns its immutable Data value.
    case ownedData
    /// The Data value retains immutable storage shared with its codec backend.
    case retainedImmutableShared
}
