import Foundation

/// One SOP Instance referenced by a Grayscale Softcopy Presentation State.
public struct DicomPresentationReferencedImage: Equatable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let referencedFrameNumbers: [Int]

    public init(
        referencedSOPClassUID: String?,
        referencedSOPInstanceUID: String?,
        referencedFrameNumbers: [Int] = []
    ) {
        self.referencedSOPClassUID = referencedSOPClassUID?.dicomGSPSNonEmptyValue
        self.referencedSOPInstanceUID = referencedSOPInstanceUID?.dicomGSPSNonEmptyValue
        self.referencedFrameNumbers = referencedFrameNumbers
    }

    public var sourceImageReference: DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: referencedSOPClassUID,
            referencedSOPInstanceUID: referencedSOPInstanceUID,
            referencedFrameNumbers: referencedFrameNumbers
        )
    }
}
