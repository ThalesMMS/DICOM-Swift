import Foundation

public struct DicomSRPatientSubject: Equatable, Sendable {
    public var name: String?
    public var id: DicomCodedConcept?
    public var birthDate: DicomDate?
    public var sex: DicomCodedConcept?

    public init(
        name: String? = nil,
        id: DicomCodedConcept? = nil,
        birthDate: DicomDate? = nil,
        sex: DicomCodedConcept? = nil
    ) {
        self.name = name
        self.id = id
        self.birthDate = birthDate
        self.sex = sex
    }
}
