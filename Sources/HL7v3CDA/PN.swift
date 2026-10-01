import Foundation

public struct PN: HL7DataType {
    public static let typeName = "PN"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
