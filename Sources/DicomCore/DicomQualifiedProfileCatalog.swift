import Foundation

/// One SOP Class whose IOD composition the instance validator qualifies on native transfer syntaxes: every
/// module of its tables is composed, a valid instance passes all non-operation layers, and a profile corpus
/// with an independent comparison exists (issue #2321). The catalog is the single source of
/// `DicomInstanceValidator.qualifiedProfiles` and of the generated conformance declaration.
public struct DicomQualifiedProfile: Codable, Equatable, Sendable {
    public let sopClassUID: String
    public let name: String
    /// Profile family as named in Docs/QA/DICOMValidationAcceptance.md.
    public let family: String
    /// Lot of the #2321 plan that qualified the profile.
    public let lot: String
    /// Coverage map under Docs/QA, relative to the repository root.
    public let coverageDocument: String
    /// Oracle output family name: the `Scripts/conformance/<oracle>.py` whose corpus covers the profile.
    public let oracle: String
}

public enum DicomQualifiedProfileCatalog {
    public static let profiles: [DicomQualifiedProfile] = [
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.6.1", name: "Ultrasound Image Storage", family: "US", lot: "L14",
              coverageDocument: "Docs/QA/UltrasoundConformanceCoverage.md", oracle: "ultrasound"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.77.1.1.1", name: "Video Endoscopic Image Storage", family: "Video", lot: "L13",
              coverageDocument: "Docs/QA/VideoConformanceCoverage.md", oracle: "video"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.77.1.2.1", name: "Video Microscopic Image Storage", family: "Video", lot: "L13",
              coverageDocument: "Docs/QA/VideoConformanceCoverage.md", oracle: "video"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.77.1.4.1", name: "Video Photographic Image Storage", family: "Video", lot: "L13",
              coverageDocument: "Docs/QA/VideoConformanceCoverage.md", oracle: "video"),

        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.77.1.6", name: "VL Whole Slide Microscopy Image Storage", family: "WSI", lot: "L12",
              coverageDocument: "Docs/QA/WSIConformanceCoverage.md", oracle: "wsi"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.1", name: "Spatial Registration Storage", family: "Registration", lot: "L11",
              coverageDocument: "Docs/QA/RegistrationConformanceCoverage.md", oracle: "registration"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.3", name: "Deformable Spatial Registration Storage", family: "Registration", lot: "L11",
              coverageDocument: "Docs/QA/RegistrationConformanceCoverage.md", oracle: "registration"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.7", name: "Secondary Capture Image Storage", family: "SC", lot: "L0",
              coverageDocument: "Docs/QA/SCConformanceCoverage.md", oracle: "sc_profile"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.7.1", name: "Multi-frame Single Bit Secondary Capture Image Storage", family: "SC", lot: "L1",
              coverageDocument: "Docs/QA/SCConformanceCoverage.md", oracle: "sc_multiframe"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.7.2", name: "Multi-frame Grayscale Byte Secondary Capture Image Storage", family: "SC", lot: "L1",
              coverageDocument: "Docs/QA/SCConformanceCoverage.md", oracle: "sc_multiframe"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.7.3", name: "Multi-frame Grayscale Word Secondary Capture Image Storage", family: "SC", lot: "L1",
              coverageDocument: "Docs/QA/SCConformanceCoverage.md", oracle: "sc_multiframe"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.7.4", name: "Multi-frame True Color Secondary Capture Image Storage", family: "SC", lot: "L1",
              coverageDocument: "Docs/QA/SCConformanceCoverage.md", oracle: "sc_multiframe"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.2", name: "CT Image Storage", family: "CT/MR/CR", lot: "L2",
              coverageDocument: "Docs/QA/ClassicImageConformanceCoverage.md", oracle: "classic_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.4", name: "MR Image Storage", family: "CT/MR/CR", lot: "L2",
              coverageDocument: "Docs/QA/ClassicImageConformanceCoverage.md", oracle: "classic_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.1", name: "Computed Radiography Image Storage", family: "CT/MR/CR", lot: "L2",
              coverageDocument: "Docs/QA/ClassicImageConformanceCoverage.md", oracle: "classic_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.22", name: "Enhanced SR Storage", family: "SR/KOS", lot: "L3",
              coverageDocument: "Docs/QA/SRConformanceCoverage.md", oracle: "sr_profile"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.33", name: "Comprehensive SR Storage", family: "SR/KOS", lot: "L3",
              coverageDocument: "Docs/QA/SRConformanceCoverage.md", oracle: "sr_profile"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.34", name: "Comprehensive 3D SR Storage", family: "SR/KOS", lot: "L3",
              coverageDocument: "Docs/QA/SRConformanceCoverage.md", oracle: "sr_profile"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.59", name: "Key Object Selection Document Storage", family: "SR/KOS", lot: "L3",
              coverageDocument: "Docs/QA/SRConformanceCoverage.md", oracle: "sr_profile"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.2.1", name: "Enhanced CT Image Storage", family: "Enhanced CT/MR/XA", lot: "L4",
              coverageDocument: "Docs/QA/EnhancedImageConformanceCoverage.md", oracle: "enhanced_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.4.1", name: "Enhanced MR Image Storage", family: "Enhanced CT/MR/XA", lot: "L4",
              coverageDocument: "Docs/QA/EnhancedImageConformanceCoverage.md", oracle: "enhanced_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.12.1.1", name: "Enhanced XA Image Storage", family: "Enhanced CT/MR/XA", lot: "L4",
              coverageDocument: "Docs/QA/EnhancedImageConformanceCoverage.md", oracle: "enhanced_image"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.5", name: "Surface Segmentation Storage", family: "SEG/PM", lot: "L5",
              coverageDocument: "Docs/QA/SegmentationParametricMapConformanceCoverage.md", oracle: "seg_pm"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.7", name: "Label Map Segmentation Storage", family: "SEG/PM", lot: "L5",
              coverageDocument: "Docs/QA/SegmentationParametricMapConformanceCoverage.md", oracle: "seg_pm"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.4", name: "Segmentation Storage", family: "SEG/PM", lot: "L5",
              coverageDocument: "Docs/QA/SegmentationParametricMapConformanceCoverage.md", oracle: "seg_pm"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.30", name: "Parametric Map Storage", family: "SEG/PM", lot: "L5",
              coverageDocument: "Docs/QA/SegmentationParametricMapConformanceCoverage.md", oracle: "seg_pm"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.11.1", name: "Grayscale Softcopy Presentation State Storage", family: "PS", lot: "L6",
              coverageDocument: "Docs/QA/PresentationStateConformanceCoverage.md", oracle: "presentation_state"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.11.2", name: "Color Softcopy Presentation State Storage", family: "PS", lot: "L6",
              coverageDocument: "Docs/QA/PresentationStateConformanceCoverage.md", oracle: "presentation_state"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.11.3", name: "Pseudo-Color Softcopy Presentation State Storage", family: "PS", lot: "L6",
              coverageDocument: "Docs/QA/PresentationStateConformanceCoverage.md", oracle: "presentation_state"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.11.4", name: "Blending Softcopy Presentation State Storage", family: "PS", lot: "L6",
              coverageDocument: "Docs/QA/PresentationStateConformanceCoverage.md", oracle: "presentation_state"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.481.2", name: "RT Dose Storage", family: "RT", lot: "L7",
              coverageDocument: "Docs/QA/RTConformanceCoverage.md", oracle: "rt"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.481.3", name: "RT Structure Set Storage", family: "RT", lot: "L7",
              coverageDocument: "Docs/QA/RTConformanceCoverage.md", oracle: "rt"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.481.5", name: "RT Plan Storage", family: "RT", lot: "L7",
              coverageDocument: "Docs/QA/RTConformanceCoverage.md", oracle: "rt"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.1.1", name: "12-lead ECG Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.1.2", name: "General ECG Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.1.3", name: "Ambulatory ECG Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.1.4", name: "General 32-bit ECG Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.2.1", name: "Hemodynamic Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.3.1", name: "Cardiac Electrophysiology Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.4.1", name: "Basic Voice Audio Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.4.2", name: "General Audio Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.5.1", name: "Arterial Pulse Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.6.1", name: "Respiratory Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.6.2", name: "Multi-channel Respiratory Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.7.1", name: "Routine Scalp Electroencephalogram Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.7.2", name: "Electromyogram Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.7.3", name: "Electrooculogram Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.9.7.4", name: "Sleep Electroencephalogram Waveform Storage", family: "Waveform", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.104.1", name: "Encapsulated PDF Storage", family: "Documents", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.104.2", name: "Encapsulated CDA Storage", family: "Documents", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.104.3", name: "Encapsulated STL Storage", family: "Documents", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.104.4", name: "Encapsulated OBJ Storage", family: "Documents", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.104.5", name: "Encapsulated MTL Storage", family: "Documents", lot: "L8",
              coverageDocument: "Docs/QA/WaveformDocumentConformanceCoverage.md", oracle: "waveform_document")
    ]

    /// The SOP Class UIDs of every composition helper, which the catalog must list exactly once each.
    static let composedSOPClassUIDs: Set<String> = Set(["1.2.840.10008.5.1.4.1.1.7", "1.2.840.10008.5.1.4.1.1.2",
        "1.2.840.10008.5.1.4.1.1.4", "1.2.840.10008.5.1.4.1.1.1", "1.2.840.10008.5.1.4.1.1.6.1"] + DicomSCMultiframeModules.Variant.allCases.map(\.sopClassUID)
        + DicomSRProfileConstraints.allCases.map(\.sopClassUID) + DicomEnhancedImageModules.Profile.allCases.map(\.sopClassUID)
        + DicomPresentationStateModules.Profile.allCases.map(\.sopClassUID) + DicomRTModules.Profile.allCases.map(\.sopClassUID)
        + DicomWaveformModules.Profile.allCases.map(\.sopClassUID) + DicomEncapsulatedDocumentModules.Profile.allCases.map(\.sopClassUID))
}
