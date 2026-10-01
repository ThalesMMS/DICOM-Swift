import Foundation

/// Object identity and metadata retained without decoding its pixel payload.
public struct DicomEnhancedFrameSource: Equatable, Sendable {
    public struct Concatenation: Equatable, Sendable {
        public let uid: String
        public let sourceSOPInstanceUID: String?
        public let number: Int?
        public let totalNumber: Int?
        public let frameOffset: Int?

        public init(uid: String, sourceSOPInstanceUID: String?, number: Int?, totalNumber: Int?, frameOffset: Int?) {
            self.uid = uid
            self.sourceSOPInstanceUID = sourceSOPInstanceUID
            self.number = number
            self.totalNumber = totalNumber
            self.frameOffset = frameOffset
        }
    }

    public let sopClassUID: String
    public let sopInstanceUID: String
    public let seriesInstanceUID: String
    public let frameOfReferenceUID: String?
    public let concatenation: Concatenation?
    public let groups: DicomEnhancedMultiframeFunctionalGroups

    public init(
        sopClassUID: String, sopInstanceUID: String, seriesInstanceUID: String,
        frameOfReferenceUID: String?, concatenation: Concatenation? = nil,
        groups: DicomEnhancedMultiframeFunctionalGroups
    ) {
        self.sopClassUID = sopClassUID
        self.sopInstanceUID = sopInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.concatenation = concatenation
        self.groups = groups
    }

    public init(decoder: DCMDecoder) throws {
        guard let groups = decoder.enhancedMultiframeFunctionalGroups else {
            throw DicomEnhancedFramePartition.ResolutionError.incompleteFrameGroups
        }
        let dataSet = decoder.dataSet
        let concatenation = dataSet.string(for: 0x0020_9161).map {
            Concatenation(
                uid: $0, sourceSOPInstanceUID: dataSet.string(for: 0x0020_0242),
                number: dataSet.int(for: 0x0020_9162), totalNumber: dataSet.int(for: 0x0020_9163),
                frameOffset: dataSet.int(for: 0x0020_9228)
            )
        }
        self.init(
            sopClassUID: decoder.info(for: .sopClassUID), sopInstanceUID: decoder.info(for: .sopInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            frameOfReferenceUID: dataSet.string(for: .frameOfReferenceUID),
            concatenation: concatenation, groups: groups
        )
    }
}
