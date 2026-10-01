public struct DicomDataSetReadResult: Sendable {
    public struct Diagnostic: Error, Equatable, Sendable {
        public enum Reason: String, Error, Sendable {
            case invalidTextEncoding
            case invalidTextValue
            case unsupportedCharacterSet
            case invalidBinaryLength
            case invalidValueLength
            case invalidMultiplicity
            case invalidPrivateCreator
            case duplicatePrivateCreator
            case duplicateElement
            case ambiguousVR
            case incompatibleVR
        }

        public let tag: Int
        /// Value offset in the decoded dataset bytes (after dataset-level inflation).
        public let offset: Int
        public let reason: Reason
        /// Sequence tags and zero-based item indexes, followed by the affected attribute.
        public let path: [DicomValidationReport.PathComponent]

        public init(tag: Int, offset: Int, reason: Reason, path: [DicomValidationReport.PathComponent]? = nil) {
            self.tag = tag
            self.offset = offset
            self.reason = reason
            self.path = path ?? [.tag(tag)]
        }
    }

    public let dataSet: DicomDataSet
    /// Recoveries contain no original strings, patient identifiers or pixel data.
    public let diagnostics: [Diagnostic]
}
