import Foundation

public struct EN: HL7DataType {
    public static let typeName = "EN"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
