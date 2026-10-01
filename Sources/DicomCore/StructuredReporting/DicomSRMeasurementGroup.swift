import Foundation

public struct DicomSRMeasurementGroup: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case generic = "1501", planarROI = "1410", volumetricROI = "1411" }
    public var kind: Kind
    public var trackingIdentifier: String?
    public var trackingUID: String?
    public var activitySession: String?
    public var findingCategory: DicomCodedConcept?
    public var finding: DicomCodedConcept?
    public var findingSites: [DicomSRFindingSite]
    public var method: DicomCodedConcept?
    public var timePoint: DicomSRTimePoint?
    public var region: DicomSRMeasurementRegion
    public var sourceImages: [DicomSourceImageReference]
    public var sourceSeriesUID: String?
    public var measurements: [DicomSRMeasurementValue]
    public var qualitativeEvaluations: [DicomSRQualitativeEvaluation]

    public init(
        kind: Kind = .generic,
        trackingIdentifier: String? = nil,
        trackingUID: String?,
        activitySession: String? = nil,
        findingCategory: DicomCodedConcept? = nil,
        finding: DicomCodedConcept? = nil,
        findingSites: [DicomSRFindingSite] = [],
        method: DicomCodedConcept? = nil,
        timePoint: DicomSRTimePoint? = nil,
        region: DicomSRMeasurementRegion = .none,
        sourceImages: [DicomSourceImageReference] = [],
        sourceSeriesUID: String? = nil,
        measurements: [DicomSRMeasurementValue] = [],
        qualitativeEvaluations: [DicomSRQualitativeEvaluation] = []
    ) {
        self.kind = kind
        self.trackingIdentifier = trackingIdentifier
        self.trackingUID = trackingUID
        self.activitySession = activitySession
        self.findingCategory = findingCategory
        self.finding = finding
        self.findingSites = findingSites
        self.method = method
        self.timePoint = timePoint
        self.region = region
        self.sourceImages = sourceImages
        self.sourceSeriesUID = sourceSeriesUID
        self.measurements = measurements
        self.qualitativeEvaluations = qualitativeEvaluations
    }
}
