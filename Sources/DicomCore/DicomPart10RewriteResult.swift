import Foundation

/// A Part 10 payload that was reopened and checked before being returned.
public struct DicomPart10RewriteResult: Sendable {
    /// The validated rewritten Part 10 bytes.
    public let fileData: Data
    /// The dataset obtained by reopening ``fileData``.
    public let dataSet: DicomDataSet
    /// The recognized transfer syntax preserved from the source.
    public let transferSyntax: DicomTransferSyntax

    /// Creates a validated rewrite result.
    public init(fileData: Data, dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax) {
        self.fileData = fileData
        self.dataSet = dataSet
        self.transferSyntax = transferSyntax
    }
}
