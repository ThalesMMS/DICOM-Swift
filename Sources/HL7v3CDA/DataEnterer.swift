import Foundation

public struct DataEnterer: CDAElement {
    public static let elementName = "dataEnterer"
    public static let childOrder = "realmCode typeId templateId time assignedEntity".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension DataEnterer {
    public var time: TS? {
        get { value("time") }
        set { setValue("time", newValue) }
    }
    public var assignedEntity: AssignedEntity? {
        get { element("assignedEntity") }
        set { setElement("assignedEntity", newValue) }
    }
}
