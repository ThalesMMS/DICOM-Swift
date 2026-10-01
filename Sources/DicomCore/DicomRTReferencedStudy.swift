public struct DicomRTReferencedStudy: Equatable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let series: [DicomRTReferencedSeries]

    public init(referencedSOPClassUID: String? = nil, referencedSOPInstanceUID: String? = nil,
                series: [DicomRTReferencedSeries] = []) {
        self.referencedSOPClassUID = referencedSOPClassUID
        self.referencedSOPInstanceUID = referencedSOPInstanceUID
        self.series = series
    }
}
