import Foundation

public struct Reference: CDAElement {
    public static let elementName = "reference"
    public static let childOrder = "realmCode typeId templateId seperatableInd externalAct externalObservation externalProcedure externalDocument".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
