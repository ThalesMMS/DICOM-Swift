import Foundation

public struct CS: HL7DataType {
    public static let typeName = "CS"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
