/// Strict reading rejects invalid values; recovery preserves their bytes as UN
/// and records each change. Structural corruption is never repaired by guessing.
public enum DicomDataSetReadMode: Sendable {
    case strict
    case recover
}
