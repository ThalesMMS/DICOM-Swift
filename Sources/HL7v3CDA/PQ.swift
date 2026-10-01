import Foundation

public struct PQ: HL7DataType {
    public static let typeName = "PQ"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
