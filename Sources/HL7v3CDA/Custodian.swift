import Foundation

public struct Custodian: CDAElement {
    public static let elementName = "custodian"
    public static let childOrder = "realmCode typeId templateId assignedCustodian".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Custodian {
    public var assignedCustodian: AssignedCustodian? {
        get { element("assignedCustodian") }
        set { setElement("assignedCustodian", newValue) }
    }
}
