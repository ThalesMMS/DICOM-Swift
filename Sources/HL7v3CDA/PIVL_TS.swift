import Foundation

public struct PIVL_TS: HL7DataType {
    public static let typeName = "PIVL_TS"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
