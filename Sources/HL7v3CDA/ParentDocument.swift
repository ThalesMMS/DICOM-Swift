import Foundation

public struct ParentDocument: CDAElement {
    public static let elementName = "parentDocument"
    public static let childOrder = "realmCode typeId templateId id code text setId versionNumber".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension ParentDocument {
    public var setId: II? {
        get { value("setId") }
        set { setValue("setId", newValue) }
    }
    public var versionNumber: INT? {
        get { value("versionNumber") }
        set { setValue("versionNumber", newValue) }
    }
}
