public struct DicomSpecimenIssuer: Sendable, Equatable {
    public let localNamespaceEntityID: String?
    public let universalEntityID: String?
    public let universalEntityIDType: String?

    public init(
        localNamespaceEntityID: String? = nil,
        universalEntityID: String? = nil,
        universalEntityIDType: String? = nil
    ) {
        self.localNamespaceEntityID = localNamespaceEntityID
        self.universalEntityID = universalEntityID
        self.universalEntityIDType = universalEntityIDType
    }
}

public struct DicomSpecimenPreparationItem: Sendable, Equatable {
    public let valueType: String?
    public let conceptName: DicomCodedConcept?
    public let codedValue: DicomCodedConcept?
    public let textValue: String?

    public init(
        valueType: String? = nil,
        conceptName: DicomCodedConcept? = nil,
        codedValue: DicomCodedConcept? = nil,
        textValue: String? = nil
    ) {
        self.valueType = valueType
        self.conceptName = conceptName
        self.codedValue = codedValue
        self.textValue = textValue
    }
}

public struct DicomSpecimenDescription: Sendable, Equatable {
    public let identifier: String?
    public let uid: String?
    public let issuer: DicomSpecimenIssuer?
    public let shortDescription: String?
    public let detailedDescription: String?
    public let preparationSteps: [[DicomSpecimenPreparationItem]]

    public init(
        identifier: String? = nil,
        uid: String? = nil,
        issuer: DicomSpecimenIssuer? = nil,
        shortDescription: String? = nil,
        detailedDescription: String? = nil,
        preparationSteps: [[DicomSpecimenPreparationItem]] = []
    ) {
        self.identifier = identifier
        self.uid = uid
        self.issuer = issuer
        self.shortDescription = shortDescription
        self.detailedDescription = detailedDescription
        self.preparationSteps = preparationSteps
    }
}

public struct DicomWholeSlideSpecimen: Sendable, Equatable {
    public let containerIdentifier: String?
    public let issuer: DicomSpecimenIssuer?
    public let containerTypeCode: DicomCodedConcept?
    public let specimens: [DicomSpecimenDescription]

    public init(
        containerIdentifier: String? = nil,
        issuer: DicomSpecimenIssuer? = nil,
        containerTypeCode: DicomCodedConcept? = nil,
        specimens: [DicomSpecimenDescription] = []
    ) {
        self.containerIdentifier = containerIdentifier
        self.issuer = issuer
        self.containerTypeCode = containerTypeCode
        self.specimens = specimens
    }
}
