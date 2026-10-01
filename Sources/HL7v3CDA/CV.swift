import Foundation

public struct CV: HL7DataType {
    public static let typeName = "CV"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
