import Foundation

public struct ED: HL7DataType {
    public static let typeName = "ED"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
