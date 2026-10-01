import Foundation

public struct CD: HL7DataType {
    public static let typeName = "CD"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
