import Foundation

/// Parsed Softcopy Presentation State with graphic annotations.
///
/// The historical type name is retained for source compatibility. `kind`
/// distinguishes Grayscale, Color, and Pseudo-Color Softcopy Presentation
/// State Storage instances.
public struct DicomGrayscalePresentationState: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.11.1"
    public static let colorStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.11.2"
    public static let pseudoColorStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.11.3"
    public static let blendingStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.11.4"
    public static let supportedStorageSOPClassUIDs: Set<String> = [
        storageSOPClassUID,
        colorStorageSOPClassUID,
        pseudoColorStorageSOPClassUID,
        blendingStorageSOPClassUID
    ]

    public let blendingItems: [DicomPresentationBlendingItem]
    public let relativeOpacity: Double?
    public let kind: DicomSoftcopyPresentationStateKind
    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let contentLabel: String?
    public let contentDescription: String?
    public let presentationCreationDate: String?
    public let presentationCreationTime: String?
    public let referencedSeries: [DicomPresentationReferencedSeries]
    public let displayedAreas: [DicomPresentationDisplayedArea]
    public let spatialTransform: DicomPresentationSpatialTransform
    public let shutters: [DicomPresentationShutter]
    public let shutterPresentationValue: UInt16?
    public let displayTransformProfile: DicomDisplayTransformProfile
    public let voiSelections: [DicomPresentationVOISelection]
    public let graphicLayers: [DicomPresentationGraphicLayer]
    public let graphicAnnotations: [DicomPresentationGraphicAnnotation]
    public let paletteColorLookupTable: DicomPaletteColorLookupTable?
    public let iccProfile: Data?
    public let diagnostics: [DicomPresentationStateDiagnostic]

    public init(
        kind: DicomSoftcopyPresentationStateKind = .grayscale,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        contentLabel: String? = nil,
        contentDescription: String? = nil,
        presentationCreationDate: String? = nil,
        presentationCreationTime: String? = nil,
        referencedSeries: [DicomPresentationReferencedSeries],
        displayedAreas: [DicomPresentationDisplayedArea] = [],
        spatialTransform: DicomPresentationSpatialTransform = .identity,
        shutters: [DicomPresentationShutter] = [],
        shutterPresentationValue: UInt16? = nil,
        displayTransformProfile: DicomDisplayTransformProfile = .identity,
        voiSelections: [DicomPresentationVOISelection] = [],
        graphicLayers: [DicomPresentationGraphicLayer],
        graphicAnnotations: [DicomPresentationGraphicAnnotation],
        paletteColorLookupTable: DicomPaletteColorLookupTable? = nil,
        iccProfile: Data? = nil,
        diagnostics: [DicomPresentationStateDiagnostic] = [],
        blendingItems: [DicomPresentationBlendingItem] = [],
        relativeOpacity: Double? = nil
    ) {
        self.blendingItems = blendingItems
        self.relativeOpacity = relativeOpacity
        self.kind = kind
        self.sopInstanceUID = sopInstanceUID?.dicomGSPSNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomGSPSNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomGSPSNonEmptyValue
        self.contentLabel = contentLabel?.dicomGSPSNonEmptyValue
        self.contentDescription = contentDescription?.dicomGSPSNonEmptyValue
        self.presentationCreationDate = presentationCreationDate?.dicomGSPSNonEmptyValue
        self.presentationCreationTime = presentationCreationTime?.dicomGSPSNonEmptyValue
        self.referencedSeries = referencedSeries
        self.displayedAreas = displayedAreas
        self.spatialTransform = spatialTransform
        self.shutters = shutters
        self.shutterPresentationValue = shutterPresentationValue
        self.displayTransformProfile = displayTransformProfile
        self.voiSelections = voiSelections
        self.graphicLayers = graphicLayers
        self.graphicAnnotations = graphicAnnotations
        self.paletteColorLookupTable = paletteColorLookupTable
        self.iccProfile = iccProfile
        self.diagnostics = diagnostics
    }
}
