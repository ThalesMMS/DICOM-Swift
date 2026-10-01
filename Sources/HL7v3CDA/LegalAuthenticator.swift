import Foundation

public struct LegalAuthenticator: CDAElement {
    public static let elementName = "legalAuthenticator"
    public static let childOrder = "realmCode typeId templateId time signatureCode assignedEntity".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension LegalAuthenticator {
    public var time: TS? {
        get { value("time") }
        set { setValue("time", newValue) }
    }
    public var signatureCode: CS? {
        get { value("signatureCode") }
        set { setValue("signatureCode", newValue) }
    }
    public var assignedEntity: AssignedEntity? {
        get { element("assignedEntity") }
        set { setElement("assignedEntity", newValue) }
    }
}
