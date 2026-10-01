/// Evidence from an encoded dataset, not a complete Part 10 file or IOD qualification.
/// A dataset is returned only after the complete metadata traversal succeeds.
public struct DicomDataSetValidationResult: Sendable {
    public let dataSet: DicomDataSet?
    public let report: DicomValidationReport
    public let pixelDataHeaders: [DicomPixelDataHeaderEvidence]
    public let pixelDataHeadersTruncated: Bool
    /// Query-key lexical validity must not be substituted for stored-instance validity.
    public let purpose: DicomDataSetPurpose
    init(dataSet: DicomDataSet?, report: DicomValidationReport, purpose: DicomDataSetPurpose,
         pixelDataHeaders: [DicomPixelDataHeaderEvidence] = [], pixelDataHeadersTruncated: Bool = false) {
        self.dataSet = dataSet
        self.report = report
        self.purpose = purpose
        self.pixelDataHeaders = pixelDataHeaders
        self.pixelDataHeadersTruncated = pixelDataHeadersTruncated
    }
}
