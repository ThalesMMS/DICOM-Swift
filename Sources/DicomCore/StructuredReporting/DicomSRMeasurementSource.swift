import Foundation

public enum DicomSRMeasurementSource: Equatable, Sendable {
    case image(DicomSourceImageReference)
    case scoord(DicomSRImageRegion)
    case scoord3D(DicomSRVolumeSurface)
}
