import Foundation

public struct DicomSRMeasurementValue: Equatable, Sendable {
    public var concept: DicomCodedConcept
    public var value: Double
    public var units: DicomCodedConcept
    public var floatingPointValue: Double?
    public var derivation: DicomCodedConcept?
    public var method: DicomCodedConcept?
    public var findingSite: DicomSRFindingSite?
    public var qualifier: DicomCodedConcept?
    public var inferredFrom: [DicomSRMeasurementSource]

    public init(
        concept: DicomCodedConcept,
        value: Double,
        units: DicomCodedConcept,
        floatingPointValue: Double? = nil,
        derivation: DicomCodedConcept? = nil,
        method: DicomCodedConcept? = nil,
        findingSite: DicomSRFindingSite? = nil,
        qualifier: DicomCodedConcept? = nil,
        inferredFrom: [DicomSRMeasurementSource] = []
    ) {
        self.concept = concept
        self.value = value
        self.units = units
        self.floatingPointValue = floatingPointValue
        self.derivation = derivation
        self.method = method
        self.findingSite = findingSite
        self.qualifier = qualifier
        self.inferredFrom = inferredFrom
    }
}
