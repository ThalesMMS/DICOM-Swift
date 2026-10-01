import Foundation

public struct DicomSRVolumeSurface: Equatable, Sendable {
    public var graphicType: String
    public var data: [Double]
    public var frameOfReferenceUID: String

    public init(
        graphicType: String,
        data: [Double],
        frameOfReferenceUID: String
    ) {
        self.graphicType = graphicType
        self.data = data
        self.frameOfReferenceUID = frameOfReferenceUID
    }
}
