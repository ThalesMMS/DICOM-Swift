/// Structural resource limits applied while parsing one encoded DICOM dataset tree.
public struct DicomDataSetParseLimits: Equatable, Sendable {
    /// Limits used by parser entry points that do not receive an explicit policy.
    public static let `default` = DicomDataSetParseLimits(
        maximumSequenceDepth: 64,
        maximumElementCount: 1_000_000,
        maximumItemCount: 500_000
    )

    /// Maximum nested SQ/undefined-length UN depth. The root dataset has depth zero.
    public let maximumSequenceDepth: Int
    /// Maximum number of encoded element headers across the complete dataset tree.
    public let maximumElementCount: Int
    /// Maximum number of sequence items across the complete dataset tree, including
    /// the Basic Offset Table and fragments of skipped encapsulated Pixel Data.
    public let maximumItemCount: Int

    /// Creates an inclusive structural parsing budget. Negative values are normalized to zero.
    public init(maximumSequenceDepth: Int,
                maximumElementCount: Int,
                maximumItemCount: Int) {
        self.maximumSequenceDepth = max(0, maximumSequenceDepth)
        self.maximumElementCount = max(0, maximumElementCount)
        self.maximumItemCount = max(0, maximumItemCount)
    }
}
