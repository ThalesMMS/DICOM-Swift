public struct DicomRTReferencedSeries: Equatable, Sendable {
    public let seriesInstanceUID: String
    public let instances: [DicomSourceImageReference]

    public init(seriesInstanceUID: String, instances: [DicomSourceImageReference] = []) {
        self.seriesInstanceUID = seriesInstanceUID
        self.instances = instances
    }
}
