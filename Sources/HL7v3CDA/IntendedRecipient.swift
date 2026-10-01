import Foundation

public struct IntendedRecipient: CDAElement {
    public static let elementName = "intendedRecipient"
    public static let childOrder = "realmCode typeId templateId id addr telecom informationRecipient receivedOrganization".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension IntendedRecipient {
    public var informationRecipient: Person? {
        get { element("informationRecipient") }
        set { setElement("informationRecipient", newValue) }
    }
    public var receivedOrganization: Organization? {
        get { element("receivedOrganization") }
        set { setElement("receivedOrganization", newValue) }
    }
}
