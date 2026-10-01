import Foundation

public struct II: HL7DataType {
    public static let typeName = "II"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
