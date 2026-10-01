/// PHI-free geometric findings; contour indexes are zero-based within the ROI.
public struct DicomRTContourGeometryDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unknownGeometricType
        case invalidPointCount
        case consecutiveDuplicatePoints
        case nonFinitePoint
        case nonPlanarContour
        case degenerateClosedContour
        case selfIntersection
        case intersectionTestPointLimit
        case referencedImageOutsideFrameOfReference
        case xorWithoutCoplanarCompanion
        case mixedXORROI
        case imageOffPlane
        case imageOutsideExtent
        case invalidImagePlane
        case invalidValidationOptions
    }

    public let roiNumber: Int
    public let contourIndex: Int
    public let code: Code
    public let measuredValue: Double?

    public init(roiNumber: Int, contourIndex: Int, code: Code, measuredValue: Double? = nil) {
        self.roiNumber = roiNumber
        self.contourIndex = contourIndex
        self.code = code
        self.measuredValue = measuredValue
    }
}
