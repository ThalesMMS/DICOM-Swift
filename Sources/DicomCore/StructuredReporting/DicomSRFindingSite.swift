import Foundation

public struct DicomSRFindingSite: Equatable, Sendable {
    public var site: DicomCodedConcept
    public var laterality: DicomCodedConcept?
    public var modifier: DicomCodedConcept?

    public init(
        site: DicomCodedConcept,
        laterality: DicomCodedConcept? = nil,
        modifier: DicomCodedConcept? = nil
    ) {
        self.site = site
        self.laterality = laterality
        self.modifier = modifier
    }
}
