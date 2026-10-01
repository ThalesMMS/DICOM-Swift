import Foundation

public struct CDAParseDiagnostic: Equatable, Sendable {
    public enum Kind: Sendable { case unknownElement, unknownAttribute, unknownNamespace, unknownDataType }
    public let kind: Kind
    public let path: String
}

extension ClinicalDocument {
    public var diagnostics: [CDAParseDiagnostic] { CDAInspection.diagnostics(node) }
}

enum CDAInspection {
    static let dataTypes = Set("II CD CE CS CV ST ED TS IVL_TS PIVL_TS PQ IVL_PQ INT REAL BL TEL AD ADXP EN PN ON".split(separator: " ").map(String.init))
    static let attributes = Set("nullFlavor classCode moodCode typeCode contextControlCode contextConductionInd determinerCode negationInd inversionInd independentInd institutionSpecified operator unit value root extension assigningAuthorityName code codeSystem codeSystemName codeSystemVersion displayName mediaType representation compression integrityCheck integrityCheckAlgorithm language ID IDREF IDREFS referencedObject href use qualifier inclusive alignment styleCode colspan rowspan align valign width height IDREFS".split(separator: " ").map(String.init))
    static let narrativeNames = Set("text content paragraph br linkHtml renderMultiMedia footnote footnoteRef list item caption table thead tbody tfoot tr th td col colgroup sub sup".split(separator: " ").map(String.init))
    static let auxiliaryNames = Set("component low high width center phase period translation qualifier originalText reference given family prefix suffix delimiter streetAddressLine houseNumber streetName streetNameBase streetNameType city state postalCode country county additionalLocator unitID unitType censusTract careOf direction postBox deliveryAddressLine buildingNumberSuffix explicitAddressLine desc assignedPerson representedOrganization representedCustodianOrganization providerOrganization assignedEntity relatedEntity associatedEntity participantRole playingEntity playingDevice manufacturedProduct manufacturedMaterial consumable product name addr telecom observationRange interpretationCode subject relatedSubject subjectPerson specimen specimenRole specimenPlayingEntity precondition criterion externalAct externalDocument externalObservation externalProcedure guardian guardianPerson birthplace place languageCommunication languageCode modeCode proficiencyLevelCode preferenceInd targetSiteCode methodCode approachSiteCode routeCode doseQuantity rateQuantity maxDoseQuantity administrationUnitCode quantity priorityCode repeatNumber expectedUseTime encounterParticipant responsibleParty location healthCareFacility serviceProviderOrganization encompassingEncounter order consent signatureCode time realmCode typeId templateId id code title effectiveTime confidentialityCode setId versionNumber copyTime statusCode value sequenceNumber seperatableInd observationMedia regionOfInterest".split(separator: " ").map(String.init))

    static func diagnostics(_ root: XMLNode) -> [CDAParseDiagnostic] {
        var result: [CDAParseDiagnostic] = []
        var pending = [(root, "/" + root.name.localName)]
        while let (node, path) = pending.popLast() {
            if ![CDANamespace.hl7, CDANamespace.sdtc].contains(node.name.namespaceURI) {
                result.append(.init(kind: .unknownNamespace, path: path))
            } else if node.name.namespaceURI == CDANamespace.hl7 && orders[node.name.localName] == nil &&
                        !auxiliaryNames.contains(node.name.localName) && !narrativeNames.contains(node.name.localName) {
                result.append(.init(kind: .unknownElement, path: path))
            }
            for name in node.attributes.keys.sorted(by: { $0.qualifiedName < $1.qualifiedName }) {
                let recognized = name.namespaceURI.isEmpty ? attributes.contains(name.localName) :
                    (name.namespaceURI == CDANamespace.xsi && ["type", "schemaLocation", "nil"].contains(name.localName)) ||
                    (name.namespaceURI == CDANamespace.xml && ["lang", "space", "base"].contains(name.localName))
                if !recognized { result.append(.init(kind: .unknownAttribute, path: path + "/@" + name.localName)) }
            }
            if let type = node.schemaTypeName,
               type.namespaceURI != CDANamespace.hl7 || !dataTypes.contains(type.localName) {
                result.append(.init(kind: .unknownDataType, path: path))
            }
            for child in node.children.reversed() { pending.append((child, path + "/" + child.name.localName)) }
        }
        return result
    }

    static func validateTypes(_ root: XMLNode) throws {
        var pending: [(XMLNode, String, [String: String])] = [(root, "", [:])]
        while let (node, parent, inherited) = pending.popLast() {
            var scope = inherited
            scope.merge(node.namespaces) { _, new in new }
            if node.name.namespaceURI == CDANamespace.hl7 {
                var type: String?
                if let raw = node.attributes.first(where: { $0.key.namespaceURI == CDANamespace.xsi && $0.key.localName == "type" })?.value {
                    let pieces = raw.split(separator: ":").map(String.init)
                    let uri = scope[pieces.count == 2 ? pieces[0] : ""] ?? CDANamespace.hl7
                    if uri == CDANamespace.hl7 { type = pieces.last }
                } else {
                    switch node.name.localName {
                    case "id", "templateId", "typeId", "setId": type = "II"
                    case "code", "confidentialityCode", "administrativeGenderCode", "raceCode", "ethnicGroupCode": type = "CD"
                    case "statusCode", "languageCode": type = "CS"
                    case "title": type = "ST"
                    case "text": type = parent == "section" ? nil : "ED"
                    case "birthTime", "copyTime", "time": type = "TS"
                    case "effectiveTime": type = parent == "ClinicalDocument" ? "TS" : "IVL_TS"
                    case "versionNumber": type = "INT"
                    case "telecom", "reference": type = node[attribute: "value"] == nil ? nil : "TEL"
                    default: break
                    }
                }
                if let type, dataTypes.contains(type) { try HL7TypeValidation.validate(node, type: type) }
            }
            for child in node.children { pending.append((child, node.name.localName, scope)) }
        }
    }
}

extension CDAInspection {
    static let orders: [String: [String]] = [
        Act.elementName: Act.childOrder,
        AssignedAuthor.elementName: AssignedAuthor.childOrder,
        AssignedCustodian.elementName: AssignedCustodian.childOrder,
        AssignedEntity.elementName: AssignedEntity.childOrder,
        Authenticator.elementName: Authenticator.childOrder,
        Author.elementName: Author.childOrder,
        Authorization.elementName: Authorization.childOrder,
        ClinicalDocument.elementName: ClinicalDocument.childOrder,
        ComponentOf.elementName: ComponentOf.childOrder,
        Consent.elementName: Consent.childOrder,
        Custodian.elementName: Custodian.childOrder,
        DataEnterer.elementName: DataEnterer.childOrder,
        DocumentationOf.elementName: DocumentationOf.childOrder,
        EncompassingEncounter.elementName: EncompassingEncounter.childOrder,
        Encounter.elementName: Encounter.childOrder,
        Entry.elementName: Entry.childOrder,
        EntryRelationship.elementName: EntryRelationship.childOrder,
        InFulfillmentOf.elementName: InFulfillmentOf.childOrder,
        Informant.elementName: Informant.childOrder,
        InformationRecipient.elementName: InformationRecipient.childOrder,
        IntendedRecipient.elementName: IntendedRecipient.childOrder,
        LegalAuthenticator.elementName: LegalAuthenticator.childOrder,
        NonXMLBody.elementName: NonXMLBody.childOrder,
        Observation.elementName: Observation.childOrder,
        Order.elementName: Order.childOrder,
        Organization.elementName: Organization.childOrder,
        Organizer.elementName: Organizer.childOrder,
        ParentDocument.elementName: ParentDocument.childOrder,
        Participant.elementName: Participant.childOrder,
        Patient.elementName: Patient.childOrder,
        PatientRole.elementName: PatientRole.childOrder,
        Performer.elementName: Performer.childOrder,
        Person.elementName: Person.childOrder,
        Procedure.elementName: Procedure.childOrder,
        RecordTarget.elementName: RecordTarget.childOrder,
        Reference.elementName: Reference.childOrder,
        ReferenceRange.elementName: ReferenceRange.childOrder,
        RelatedDocument.elementName: RelatedDocument.childOrder,
        Section.elementName: Section.childOrder,
        ServiceEvent.elementName: ServiceEvent.childOrder,
        StructuredBody.elementName: StructuredBody.childOrder,
        SubstanceAdministration.elementName: SubstanceAdministration.childOrder,
        Supply.elementName: Supply.childOrder,
    ]
}
