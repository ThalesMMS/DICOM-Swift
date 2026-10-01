import Foundation

/// One GSPS graphic annotation group applied to all or a subset of referenced images.
public struct DicomPresentationGraphicAnnotation: Equatable, Sendable {
    public let graphicLayer: String
    public let referencedImages: [DicomPresentationReferencedImage]
    public let graphicObjects: [DicomPresentationGraphicObject]
    public let textObjects: [DicomPresentationTextObject]
    public let compoundGraphics: [DicomPresentationCompoundGraphic]

    public init(
        graphicLayer: String,
        referencedImages: [DicomPresentationReferencedImage] = [],
        graphicObjects: [DicomPresentationGraphicObject],
        textObjects: [DicomPresentationTextObject] = [],
        compoundGraphics: [DicomPresentationCompoundGraphic] = []
    ) {
        self.graphicLayer = graphicLayer.dicomGSPSLayerName
        self.referencedImages = referencedImages
        self.graphicObjects = graphicObjects
        self.textObjects = textObjects
        self.compoundGraphics = compoundGraphics
    }
}
