import Foundation

public struct Act: CDAElement {
    public static let elementName = "act"
    public static let childOrder = "realmCode typeId templateId id code text statusCode effectiveTime priorityCode languageCode subject specimen performer author informant participant entryRelationship reference precondition".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
