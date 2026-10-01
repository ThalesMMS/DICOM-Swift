import Foundation

public struct Participant: CDAElement {
    public static let elementName = "participant"
    public static let childOrder = "realmCode typeId templateId functionCode time associatedEntity participantRole".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
