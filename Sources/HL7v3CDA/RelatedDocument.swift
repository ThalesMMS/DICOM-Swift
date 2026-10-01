import Foundation

public struct RelatedDocument: CDAElement {
    public static let elementName = "relatedDocument"
    public static let childOrder = "realmCode typeId templateId parentDocument".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension RelatedDocument {
    public var parentDocument: ParentDocument? {
        get { element("parentDocument") }
        set { setElement("parentDocument", newValue) }
    }
}
