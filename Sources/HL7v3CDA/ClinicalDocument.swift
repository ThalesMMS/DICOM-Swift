import Foundation

public struct ClinicalDocument: CDAElement {
    public static let elementName = "ClinicalDocument"
    public static let childOrder = "realmCode typeId templateId id code title statusCode effectiveTime confidentialityCode languageCode setId versionNumber copyTime recordTarget author dataEnterer informant custodian informationRecipient legalAuthenticator authenticator participant inFulfillmentOf documentationOf relatedDocument authorization componentOf component".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension ClinicalDocument {
    public var typeId: II? {
        get { value("typeId") }
        set { setValue("typeId", newValue) }
    }
    public var id: II? {
        get { value("id") }
        set { setValue("id", newValue) }
    }
    public var title: ST? {
        get { value("title") }
        set { setValue("title", newValue) }
    }
    public var effectiveTime: TS? {
        get { value("effectiveTime") }
        set { setValue("effectiveTime", newValue) }
    }
    public var confidentialityCode: CE? {
        get { value("confidentialityCode") }
        set { setValue("confidentialityCode", newValue) }
    }
    public var languageCode: CS? {
        get { value("languageCode") }
        set { setValue("languageCode", newValue) }
    }
    public var setId: II? {
        get { value("setId") }
        set { setValue("setId", newValue) }
    }
    public var versionNumber: INT? {
        get { value("versionNumber") }
        set { setValue("versionNumber", newValue) }
    }
    public var copyTime: TS? {
        get { value("copyTime") }
        set { setValue("copyTime", newValue) }
    }
    public var recordTargets: [RecordTarget] {
        get { elements("recordTarget") }
        set { setElements("recordTarget", newValue) }
    }
    public var custodian: Custodian? {
        get { element("custodian") }
        set { setElement("custodian", newValue) }
    }
    public var dataEnterer: DataEnterer? {
        get { element("dataEnterer") }
        set { setElement("dataEnterer", newValue) }
    }
    public var informants: [Informant] {
        get { elements("informant") }
        set { setElements("informant", newValue) }
    }
    public var informationRecipients: [InformationRecipient] {
        get { elements("informationRecipient") }
        set { setElements("informationRecipient", newValue) }
    }
    public var legalAuthenticator: LegalAuthenticator? {
        get { element("legalAuthenticator") }
        set { setElement("legalAuthenticator", newValue) }
    }
    public var authenticators: [Authenticator] {
        get { elements("authenticator") }
        set { setElements("authenticator", newValue) }
    }
    public var inFulfillmentOf: [InFulfillmentOf] {
        get { elements("inFulfillmentOf") }
        set { setElements("inFulfillmentOf", newValue) }
    }
    public var documentationOf: [DocumentationOf] {
        get { elements("documentationOf") }
        set { setElements("documentationOf", newValue) }
    }
    public var relatedDocuments: [RelatedDocument] {
        get { elements("relatedDocument") }
        set { setElements("relatedDocument", newValue) }
    }
    public var componentOf: ComponentOf? {
        get { element("componentOf") }
        set { setElement("componentOf", newValue) }
    }
    public var authorizations: [Authorization] {
        get { elements("authorization") }
        set { setElements("authorization", newValue) }
    }
}
