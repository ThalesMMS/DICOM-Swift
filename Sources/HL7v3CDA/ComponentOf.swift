import Foundation

public struct ComponentOf: CDAElement {
    public static let elementName = "componentOf"
    public static let childOrder = "realmCode typeId templateId encompassingEncounter".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension ComponentOf {
    public var encompassingEncounter: EncompassingEncounter? {
        get { element("encompassingEncounter") }
        set { setElement("encompassingEncounter", newValue) }
    }
}
