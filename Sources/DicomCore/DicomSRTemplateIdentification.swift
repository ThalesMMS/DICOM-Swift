import Foundation

public struct DicomSRTemplateIdentification: Equatable, Sendable {
    public let mappingResource: String
    public let templateIdentifier: String

    public init(mappingResource: String, templateIdentifier: String) {
        self.mappingResource = mappingResource
        self.templateIdentifier = templateIdentifier
    }
}
