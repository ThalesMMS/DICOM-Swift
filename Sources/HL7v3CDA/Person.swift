import Foundation

public struct Person: CDAElement {
    public static let elementName = "person"
    public static let childOrder = "realmCode typeId templateId name".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Person {
    public var names: [PN] {
        get { values("name") }
        set { setValues("name", newValue) }
    }
}
