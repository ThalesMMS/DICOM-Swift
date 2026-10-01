import Foundation

public struct BL: HL7DataType {
    public static let typeName = "BL"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
