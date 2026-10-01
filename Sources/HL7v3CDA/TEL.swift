import Foundation

public struct TEL: HL7DataType {
    public static let typeName = "TEL"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
