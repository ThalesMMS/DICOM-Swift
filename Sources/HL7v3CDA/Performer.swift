import Foundation

public struct Performer: CDAElement {
    public static let elementName = "performer"
    public static let childOrder = "realmCode typeId templateId functionCode time modeCode assignedEntity".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Performer {
    public var assignedEntity: AssignedEntity? {
        get { element("assignedEntity") }
        set { setElement("assignedEntity", newValue) }
    }
}
