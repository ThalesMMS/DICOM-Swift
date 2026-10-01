import Foundation

public struct Informant: CDAElement {
    public static let elementName = "informant"
    public static let childOrder = "realmCode typeId templateId assignedEntity relatedEntity".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Informant {
    public var assignedEntity: AssignedEntity? {
        get { element("assignedEntity") }
        set { setElement("assignedEntity", newValue) }
    }
}
