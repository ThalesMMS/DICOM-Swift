/// Failures that prevent a supported semantic model from being serialized without
/// losing its selected frame scope. No instance identifiers or content are exposed.
public enum DicomStructuredReportBuildError: Error, Equatable, Sendable {
    case unrepresentedEvidenceFrames(index: Int)
}
