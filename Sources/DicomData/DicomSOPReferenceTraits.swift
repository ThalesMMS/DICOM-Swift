import Foundation

/// Reference applicability for the 171 storage IODs in the audited PS3.3/PS3.4 2026c catalogue.
/// These traits do not claim storage, decoding or full IOD support. Unlisted classes remain unknown.
public struct DicomSOPReferenceTraits: Sendable {
    public static let standardEdition = "2026c"
    public let kind: DicomContentReferenceMacro.Kind
    /// Whether the class requires, permits conditionally or excludes the Multi-frame module family.
    public let isMultiframeImage: DicomAttributeRule.Truth
    public let isSegmentation: Bool
    public let isSoftcopyPresentationState: Bool
    public let isRealWorldValueMapping: Bool

    /// Exact UIDs only; private, retired/unlisted and future classes have no inferred fallback.
    public static let entries: [String: Self] = {
        let prefix = "1.2.840.10008.5.1.4.1.1."
        let images = [
            "1", "1.1", "1.1.1", "1.2", "1.2.1", "1.3", "1.3.1", "12.1", "12.1.1", "12.2", "12.2.1",
            "128", "128.1", "13.1.1", "13.1.2", "13.1.3", "13.1.4", "13.1.5", "130", "14.1", "14.2",
            "2", "2.1", "2.2", "2.3", "2.4", "2.5", "20", "3.1", "30", "4", "4.1", "4.3", "4.4",
            "481.1", "481.2", "481.23", "481.24", "6.1", "6.2", "6.3", "66.4", "66.7", "66.8",
            "7", "7.1", "7.2", "7.3", "7.4", "77.1.1", "77.1.1.1", "77.1.2", "77.1.2.1", "77.1.3",
            "77.1.4", "77.1.4.1", "77.1.5.1", "77.1.5.2", "77.1.5.4", "77.1.5.5", "77.1.5.6",
            "77.1.5.7", "77.1.5.8", "77.1.6", "77.1.7", "77.1.8", "77.1.9", "81.1", "82.1"
        ]
        let waveforms = [
            "9.1.1", "9.1.2", "9.1.3", "9.1.4", "9.2.1", "9.3.1", "9.4.1", "9.4.2", "9.5.1",
            "9.6.1", "9.6.2", "9.7.1", "9.7.2", "9.7.3", "9.7.4", "9.8.1"
        ]
        let composites = [
            "104.1", "104.2", "104.3", "104.4", "104.5", "11.1", "11.2", "11.3", "11.4", "11.5",
            "11.6", "11.7", "11.8", "11.9", "11.10", "11.11", "11.12", "131", "200.2", "200.8", "4.2",
            "481.3", "481.4", "481.5", "481.6", "481.7", "481.8", "481.9", "481.10", "481.11", "481.12",
            "481.13", "481.14", "481.15", "481.16", "481.17", "481.18", "481.19", "481.20", "481.21",
            "481.22", "481.25", "66", "66.1", "66.2", "66.3", "66.5", "66.6", "67", "68.1", "68.2",
            "77.1.5.3", "78.1", "78.2", "78.3", "78.4", "78.5", "78.6", "78.7", "78.8", "79.1", "80.1",
            "88.11", "88.22", "88.33", "88.34", "88.35", "88.40", "88.50", "88.59", "88.65", "88.67",
            "88.68", "88.69", "88.70", "88.71", "88.72", "88.73", "88.74", "88.75", "88.76", "88.77",
            "9.100.1", "9.100.2"
        ]
        // PS3.4 Annex N: volumetric (Annex FF) and waveform presentation states are separate classes.
        let softcopy: Set<String> = ["11.1", "11.2", "11.3", "11.4", "11.5", "11.8", "11.12"]
        let singleFrame: Set<String> = ["1", "1.1", "1.1.1", "1.2", "1.2.1", "1.3", "1.3.1", "128", "2", "2.3", "4", "6.1", "7",
            "77.1.1", "77.1.2", "77.1.3", "77.1.4", "77.1.5.7", "77.1.7", "81.1", "82.1"]
        let conditionalMultiframe: Set<String> = ["12.1", "12.2", "481.1", "481.2"]
        let segmentation: Set<String> = ["66.4", "66.7", "66.8"]
        var result: [String: Self] = [:]
        for (kind, suffixes) in [(DicomContentReferenceMacro.Kind.image, images), (.waveform, waveforms), (.composite, composites)] {
            for suffix in suffixes {
                let multiframe: DicomAttributeRule.Truth = kind != .image || singleFrame.contains(suffix) ? .unsatisfied :
                    conditionalMultiframe.contains(suffix) ? .undetermined : .satisfied
                result[prefix + suffix] = .init(kind: kind, isMultiframeImage: multiframe, isSegmentation: segmentation.contains(suffix),
                                              isSoftcopyPresentationState: softcopy.contains(suffix),
                                              isRealWorldValueMapping: suffix == "67")
            }
        }
        for uid in ["1.2.840.10008.5.1.4.34.7", "1.2.840.10008.5.1.4.34.10"] {
            result[uid] = .init(kind: .composite, isMultiframeImage: .unsatisfied, isSegmentation: false,
                                isSoftcopyPresentationState: false, isRealWorldValueMapping: false)
        }
        return result
    }()
}
