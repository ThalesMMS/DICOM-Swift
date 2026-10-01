import Foundation

/// Keeps each selected frame attached to its decoder while sharing volume validation and assembly.
struct DicomEnhancedVolumeFrame {
    let frame: DicomEnhancedFrame
    let decoder: DCMDecoder
    let url: URL
    let reference: DicomEnhancedFrameCollection.Reference

    var index: Int { frame.index }
    var functionalGroups: DicomFrameFunctionalGroups { frame.functionalGroups }
}
