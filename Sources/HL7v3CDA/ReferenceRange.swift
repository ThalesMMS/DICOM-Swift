import Foundation

public struct ReferenceRange: CDAElement {
    public static let elementName = "referenceRange"
    public static let childOrder = "realmCode typeId templateId observationRange".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
