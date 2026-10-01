import Foundation

public struct ON: HL7DataType {
    public static let typeName = "ON"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
