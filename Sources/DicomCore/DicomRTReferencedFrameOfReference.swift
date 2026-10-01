public struct DicomRTReferencedFrameOfReference: Equatable, Sendable {
    public let frameOfReferenceUID: String
    public let studies: [DicomRTReferencedStudy]

    public init(frameOfReferenceUID: String, studies: [DicomRTReferencedStudy] = []) {
        self.frameOfReferenceUID = frameOfReferenceUID
        self.studies = studies
    }
}
