import Foundation

public struct DicomPresentationVOISelection: Equatable, Sendable {
    public let referencedImages: [DicomPresentationReferencedImage]
    public let displayTransformProfile: DicomDisplayTransformProfile

    public init(
        referencedImages: [DicomPresentationReferencedImage] = [],
        displayTransformProfile: DicomDisplayTransformProfile
    ) {
        self.referencedImages = referencedImages
        self.displayTransformProfile = displayTransformProfile
    }
}
