import Foundation

public struct ADXP: HL7DataType {
    public static let typeName = "ADXP"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
