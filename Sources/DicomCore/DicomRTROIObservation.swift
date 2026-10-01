public struct DicomRTROIObservation: Equatable, Sendable {
    public let number: Int
    public let referencedROINumber: Int
    public let label: String?
    public let interpretedType: String?
    public let interpreter: String?
    public let identificationCode: DicomCodedConcept?
    public let therapeuticRoleTypeCode: DicomCodedConcept?
    public let physicalProperties: [DicomRTPhysicalProperty]

    public init(number: Int, referencedROINumber: Int, label: String? = nil, interpretedType: String? = nil,
                interpreter: String? = nil, identificationCode: DicomCodedConcept? = nil,
                therapeuticRoleTypeCode: DicomCodedConcept? = nil,
                physicalProperties: [DicomRTPhysicalProperty] = []) {
        self.number = number
        self.referencedROINumber = referencedROINumber
        self.label = label
        self.interpretedType = interpretedType
        self.interpreter = interpreter
        self.identificationCode = identificationCode
        self.therapeuticRoleTypeCode = therapeuticRoleTypeCode
        self.physicalProperties = physicalProperties
    }
}
