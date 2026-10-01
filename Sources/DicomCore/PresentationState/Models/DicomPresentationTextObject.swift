import Foundation

/// One display text object from a GSPS annotation.
public struct DicomPresentationTextObject: Equatable, Sendable {
    public let text: String
    public let boundingBoxAnnotationUnits: String?
    public let anchorPoint: SIMD2<Double>?
    public let anchorPointAnnotationUnits: String?
    public let anchorPointVisible: Bool?
    public let boundingBoxTopLeft: SIMD2<Double>?
    public let boundingBoxBottomRight: SIMD2<Double>?
    public let boundingBoxHorizontalJustification: String?
    public let compoundGraphicInstanceID: UInt32?
    public let trackingID: String?
    public let trackingUID: String?

    public init(
        text: String,
        boundingBoxAnnotationUnits: String? = nil,
        anchorPoint: SIMD2<Double>? = nil,
        anchorPointAnnotationUnits: String? = nil,
        anchorPointVisible: Bool? = nil,
        boundingBoxTopLeft: SIMD2<Double>? = nil,
        boundingBoxBottomRight: SIMD2<Double>? = nil,
        boundingBoxHorizontalJustification: String? = nil,
        compoundGraphicInstanceID: UInt32? = nil,
        trackingID: String? = nil,
        trackingUID: String? = nil
    ) {
        self.text = text.dicomGSPSNonEmptyValue ?? "Annotation"
        self.boundingBoxAnnotationUnits = boundingBoxAnnotationUnits?.dicomGSPSNonEmptyValue?.uppercased()
        self.anchorPoint = anchorPoint
        self.anchorPointAnnotationUnits = anchorPointAnnotationUnits?.dicomGSPSNonEmptyValue?.uppercased()
        self.anchorPointVisible = anchorPointVisible
        self.boundingBoxTopLeft = boundingBoxTopLeft
        self.boundingBoxBottomRight = boundingBoxBottomRight
        self.boundingBoxHorizontalJustification = boundingBoxHorizontalJustification?
            .dicomGSPSNonEmptyValue?
            .uppercased()
        self.compoundGraphicInstanceID = compoundGraphicInstanceID
        self.trackingID = trackingID?.dicomGSPSNonEmptyValue
        self.trackingUID = trackingUID?.dicomGSPSNonEmptyValue
    }
}
