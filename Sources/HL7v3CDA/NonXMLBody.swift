import Foundation

public struct NonXMLBody: CDAElement {
    public static let elementName = "nonXMLBody"
    public static let childOrder = "realmCode typeId templateId text confidentialityCode languageCode".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
