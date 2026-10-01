import Foundation

public struct InformationRecipient: CDAElement {
    public static let elementName = "informationRecipient"
    public static let childOrder = "realmCode typeId templateId intendedRecipient".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension InformationRecipient {
    public var intendedRecipient: IntendedRecipient? {
        get { element("intendedRecipient") }
        set { setElement("intendedRecipient", newValue) }
    }
}
