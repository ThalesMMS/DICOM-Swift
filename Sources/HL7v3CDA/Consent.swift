import Foundation

public struct Consent: CDAElement {
    public static let elementName = "consent"
    public static let childOrder = "realmCode typeId templateId id code statusCode".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
