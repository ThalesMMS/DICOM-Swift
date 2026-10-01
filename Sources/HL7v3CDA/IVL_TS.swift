import Foundation

public struct IVL_TS: HL7DataType {
    public static let typeName = "IVL_TS"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
