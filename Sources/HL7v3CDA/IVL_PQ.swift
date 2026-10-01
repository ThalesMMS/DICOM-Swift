import Foundation

public struct IVL_PQ: HL7DataType {
    public static let typeName = "IVL_PQ"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
