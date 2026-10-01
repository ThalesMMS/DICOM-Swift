import Foundation

public struct InFulfillmentOf: CDAElement {
    public static let elementName = "inFulfillmentOf"
    public static let childOrder = "realmCode typeId templateId order".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension InFulfillmentOf {
    public var order: Order? {
        get { element("order") }
        set { setElement("order", newValue) }
    }
}
