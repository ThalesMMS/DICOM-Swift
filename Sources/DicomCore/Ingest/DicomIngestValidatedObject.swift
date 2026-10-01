import Foundation

/// A staged Part 10 object's identity, checked against its dataset, and the dataset's metadata (Pixel Data
/// omitted), as the ingest validates it.
struct DicomIngestValidatedObject: Sendable {
    let sopClassUID: String
    let sopInstanceUID: String
    let transferSyntax: DicomTransferSyntax
    let dataSet: DicomDataSet
}
