import Foundation

public struct TS: HL7DataType {
    public static let typeName = "TS"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
