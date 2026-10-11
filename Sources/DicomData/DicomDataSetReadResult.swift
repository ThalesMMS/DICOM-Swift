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
            /// Recovery only: the bytes from `offset` on follow a complete root Pixel Data element and are not data
            /// elements of the data set, which ends where the Pixel Data value ends (issue #3039).
            case trailingBytesAfterPixelData
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
    /// The root data set's Pixel Data header (`valueLength` is `UInt32.max` when encapsulated), when it has one. The
    /// value itself is skipped, never read.
    public let pixelDataHeader: DicomPixelDataHeaderEvidence?

    public init(dataSet: DicomDataSet, diagnostics: [Diagnostic], pixelDataHeader: DicomPixelDataHeaderEvidence? = nil) {
        self.dataSet = dataSet
        self.diagnostics = diagnostics
        self.pixelDataHeader = pixelDataHeader
    }
}
