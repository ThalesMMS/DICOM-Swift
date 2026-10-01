import Foundation

public struct DicomSRTemplateDefinition: Equatable, Sendable {
    public let identifier: String
    public let isExtensible: Bool
    public let rows: [DicomSRTemplateRow]

    public init(identifier: String, isExtensible: Bool = true, rows: [DicomSRTemplateRow]) {
        self.identifier = identifier
        self.isExtensible = isExtensible
        self.rows = rows
    }
}
