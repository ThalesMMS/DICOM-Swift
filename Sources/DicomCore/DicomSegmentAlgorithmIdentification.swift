/// Segmentation Algorithm Identification Sequence (0062,0007), Algorithm Identification Macro.
public struct DicomSegmentAlgorithmIdentification: Equatable, Hashable, Sendable {
    public let name: String
    public let version: String
    public let family: DicomCodedConcept
    public let parameters: String?

    public init(name: String, version: String, family: DicomCodedConcept, parameters: String? = nil) {
        self.name = name
        self.version = version
        self.family = family
        self.parameters = parameters
    }
}
