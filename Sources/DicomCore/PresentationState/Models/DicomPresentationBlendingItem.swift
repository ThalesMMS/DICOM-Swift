import Foundation

public struct DicomPresentationBlendingItem: Equatable, Sendable {
    public enum Position: String, Equatable, Sendable {
        case superimposed = "SUPERIMPOSED"
        case underlying = "UNDERLYING"
    }

    public let position: Position
    public let studyInstanceUID: String
    public let displayTransformProfile: DicomDisplayTransformProfile
    public let voiSelections: [DicomPresentationVOISelection]
    public let referencedSeries: [DicomPresentationReferencedSeries]
    /// Per-image Modality LUT values exposed for the viewer and print consumers (issue #2396).
    public var modalityLUT: DicomLookupTable? { displayTransformProfile.modalityLUTs.first }
    public var rescaleIntercept: Double? { displayTransformProfile.rescaleParameters.intercept }
    public var rescaleSlope: Double? { displayTransformProfile.rescaleParameters.slope }
    public var rescaleType: String? { displayTransformProfile.rescaleType }

    public init(position: Position, studyInstanceUID: String,
                referencedSeries: [DicomPresentationReferencedSeries],
                modalityLUT: DicomLookupTable? = nil,
                rescaleIntercept: Double? = nil,
                rescaleSlope: Double? = nil,
                rescaleType: String? = nil,
                displayTransformProfile: DicomDisplayTransformProfile? = nil,
                voiSelections: [DicomPresentationVOISelection] = []) {
        self.position = position
        self.studyInstanceUID = studyInstanceUID
        self.referencedSeries = referencedSeries
        self.displayTransformProfile = displayTransformProfile ?? DicomDisplayTransformProfile(
            rescaleParameters: .init(intercept: rescaleIntercept ?? 0, slope: rescaleSlope ?? 1),
            rescaleType: rescaleType ?? (modalityLUT == nil ? "US" : nil),
            modalityLUTs: modalityLUT.map { [$0] } ?? []
        )
        self.voiSelections = voiSelections
    }
}
