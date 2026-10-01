import Foundation

public struct DicomSRTimePoint: Equatable, Sendable {
    public var timePoint: String
    public var subjectIdentifier: String?
    public var protocolIdentifier: String?
    public var types: [DicomCodedConcept]
    public var order: Double?
    public var temporalOffset: Double?
    public var temporalEvent: DicomCodedConcept?

    public init(
        timePoint: String,
        subjectIdentifier: String? = nil,
        protocolIdentifier: String? = nil,
        types: [DicomCodedConcept] = [],
        order: Double? = nil,
        temporalOffset: Double? = nil,
        temporalEvent: DicomCodedConcept? = nil
    ) {
        self.timePoint = timePoint
        self.subjectIdentifier = subjectIdentifier
        self.protocolIdentifier = protocolIdentifier
        self.types = types
        self.order = order
        self.temporalOffset = temporalOffset
        self.temporalEvent = temporalEvent
    }
}
