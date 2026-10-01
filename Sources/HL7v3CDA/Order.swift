import Foundation

public struct Order: CDAElement {
    public static let elementName = "order"
    public static let childOrder = "realmCode typeId templateId id code priorityCode".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
