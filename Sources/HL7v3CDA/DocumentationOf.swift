import Foundation

public struct DocumentationOf: CDAElement {
    public static let elementName = "documentationOf"
    public static let childOrder = "realmCode typeId templateId serviceEvent".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension DocumentationOf {
    public var serviceEvent: ServiceEvent? {
        get { element("serviceEvent") }
        set { setElement("serviceEvent", newValue) }
    }
}
