import Foundation

public struct CE: HL7DataType {
    public static let typeName = "CE"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
