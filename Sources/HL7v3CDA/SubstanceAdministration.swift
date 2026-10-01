import Foundation

public struct SubstanceAdministration: CDAElement {
    public static let elementName = "substanceAdministration"
    public static let childOrder = "realmCode typeId templateId id code text statusCode effectiveTime priorityCode repeatNumber routeCode approachSiteCode doseQuantity rateQuantity maxDoseQuantity administrationUnitCode subject specimen consumable performer author informant participant entryRelationship reference precondition".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
