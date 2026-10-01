import Foundation

public struct Supply: CDAElement {
    public static let elementName = "supply"
    public static let childOrder = "realmCode typeId templateId id code text statusCode effectiveTime priorityCode repeatNumber independentInd quantity expectedUseTime subject specimen product performer author informant participant entryRelationship reference precondition".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
