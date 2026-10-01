import Foundation

public struct ST: HL7DataType {
    public static let typeName = "ST"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
