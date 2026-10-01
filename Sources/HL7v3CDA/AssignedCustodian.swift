import Foundation

public struct AssignedCustodian: CDAElement {
    public static let elementName = "assignedCustodian"
    public static let childOrder = "realmCode typeId templateId representedCustodianOrganization".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension AssignedCustodian {
    public var representedCustodianOrganization: Organization? {
        get { element("representedCustodianOrganization") }
        set { setElement("representedCustodianOrganization", newValue) }
    }
}
