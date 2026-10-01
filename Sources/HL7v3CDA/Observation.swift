import Foundation

public struct Observation: CDAElement {
    public static let elementName = "observation"
    public static let childOrder = "realmCode typeId templateId id code derivationExpr text statusCode effectiveTime priorityCode repeatNumber languageCode value interpretationCode methodCode targetSiteCode subject specimen performer author informant participant entryRelationship reference precondition referenceRange".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
