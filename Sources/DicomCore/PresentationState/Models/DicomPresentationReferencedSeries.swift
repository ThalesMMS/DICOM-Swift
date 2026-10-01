import Foundation

/// A referenced image series in a presentation state relationship module.
public struct DicomPresentationReferencedSeries: Equatable, Sendable {
    public let seriesInstanceUID: String
    public let images: [DicomPresentationReferencedImage]

    public init(seriesInstanceUID: String, images: [DicomPresentationReferencedImage]) throws {
        guard let seriesInstanceUID = seriesInstanceUID.dicomGSPSNonEmptyValue else {
            throw DICOMError.missingRequiredTag(tag: "0020,000E", description: "Referenced Series Instance UID")
        }
        self.seriesInstanceUID = seriesInstanceUID
        self.images = images
    }
}
