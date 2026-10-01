import Foundation

/// One image-relative or display-relative graphic object in a GSPS annotation.
public struct DicomPresentationGraphicObject: Equatable, Sendable {
    public let annotationUnits: String
    public let graphicType: String
    public let graphicData: [Double]
    public let graphicFilled: Bool?
    public let compoundGraphicInstanceID: UInt32?
    public let trackingID: String?
    public let trackingUID: String?

    public init(
        annotationUnits: String = "PIXEL",
        graphicType: String,
        graphicData: [Double],
        graphicFilled: Bool? = nil,
        compoundGraphicInstanceID: UInt32? = nil,
        trackingID: String? = nil,
        trackingUID: String? = nil
    ) {
        self.annotationUnits = annotationUnits.dicomGSPSNonEmptyValue?.uppercased() ?? "PIXEL"
        self.graphicType = graphicType.dicomGSPSNonEmptyValue?.uppercased() ?? "POLYLINE"
        self.graphicData = graphicData
        self.graphicFilled = graphicFilled
        self.compoundGraphicInstanceID = compoundGraphicInstanceID
        self.trackingID = trackingID?.dicomGSPSNonEmptyValue
        self.trackingUID = trackingUID?.dicomGSPSNonEmptyValue
    }

    public var numberOfGraphicPoints: Int {
        graphicData.count / 2
    }
}
