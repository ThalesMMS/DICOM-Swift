import Foundation

public struct AD: HL7DataType {
    public static let typeName = "AD"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
