/// Resolved Frame VOI LUT Functional Group values for one frame.
public struct DicomFrameVOI: Equatable, Sendable {
    public let windows: [DicomFrameVOIWindow]
    public let voiLUTs: [DicomLookupTable]
    public let lutFunction: String?

    public init(
        windows: [DicomFrameVOIWindow],
        voiLUTs: [DicomLookupTable] = [],
        lutFunction: String? = nil
    ) {
        self.windows = windows
        self.voiLUTs = voiLUTs
        self.lutFunction = lutFunction
    }
}
