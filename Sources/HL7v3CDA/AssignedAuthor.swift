import Foundation

public struct AssignedAuthor: CDAElement {
    public static let elementName = "assignedAuthor"
    public static let childOrder = "realmCode typeId templateId id code addr telecom assignedPerson assignedAuthoringDevice representedOrganization".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension AssignedAuthor {
    public var assignedPerson: Person? {
        get { element("assignedPerson") }
        set { setElement("assignedPerson", newValue) }
    }
    public var representedOrganization: Organization? {
        get { element("representedOrganization") }
        set { setElement("representedOrganization", newValue) }
    }
    public var addresses: [AD] {
        get { values("addr") }
        set { setValues("addr", newValue) }
    }
    public var telecoms: [TEL] {
        get { values("telecom") }
        set { setValues("telecom", newValue) }
    }
}
