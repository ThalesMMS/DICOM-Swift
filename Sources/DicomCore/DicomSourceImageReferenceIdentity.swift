import Foundation

struct DicomSourceImageReferenceIdentity: Hashable, Sendable {
    let referencedSOPClassUID: String?
    let referencedSOPInstanceUID: String?
    let referencedFrameNumbers: [Int]
    let referencedSegmentNumbers: [Int]
    let referencedWaveformChannels: [Int]

    init(_ reference: DicomSourceImageReference, includesFrames: Bool = true, includesContentSelectors: Bool = true) {
        referencedSOPClassUID = reference.referencedSOPClassUID
        referencedSOPInstanceUID = reference.referencedSOPInstanceUID
        referencedFrameNumbers = includesFrames ? reference.referencedFrameNumbers : []
        referencedSegmentNumbers = includesContentSelectors ? reference.referencedSegmentNumbers : []
        referencedWaveformChannels = includesContentSelectors ? reference.referencedWaveformChannels : []
    }
}
