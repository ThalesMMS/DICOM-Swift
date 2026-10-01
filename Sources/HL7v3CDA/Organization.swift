import Foundation

public struct Organization: CDAElement {
    public static let elementName = "organization"
    public static let childOrder = "realmCode typeId templateId id name telecom addr standardIndustryClassCode asOrganizationPartOf".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Organization {
    public var names: [ON] {
        get { values("name") }
        set { setValues("name", newValue) }
    }
}
