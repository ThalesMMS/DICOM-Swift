import Foundation

public struct DicomPresentationStateBuildOptions: Equatable, Sendable {
    public var kind: DicomSoftcopyPresentationStateKind
    public var paletteColorLookupTable: DicomPaletteColorLookupTable?
    public var blendingItems: [DicomPresentationBlendingItem]
    public var relativeOpacity: Double?
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    /// Type 2 identification and equipment of the Presentation State IOD; empty values are written when unknown.
    public var patientBirthDate: String
    public var patientSex: String
    public var studyDate: String
    public var studyTime: String
    public var referringPhysicianName: String
    public var studyID: String
    public var accessionNumber: String
    public var manufacturer: String
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var contentLabel: String
    public var contentDescription: String?
    public var contentCreatorName: String?
    public var presentationCreationDate: String?
    public var presentationCreationTime: String?
    public var displayedArea: DicomPresentationDisplayedArea?
    public var displayedAreas: [DicomPresentationDisplayedArea]
    public var spatialTransform: DicomPresentationSpatialTransform
    public var shutters: [DicomPresentationShutter]
    public var shutterPresentationValue: UInt16?
    public var displayTransformProfile: DicomDisplayTransformProfile
    public var voiSelections: [DicomPresentationVOISelection]
    public var iccProfile: Data?

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        patientBirthDate: String = "",
        patientSex: String = "",
        studyDate: String = "",
        studyTime: String = "",
        referringPhysicianName: String = "",
        studyID: String = "",
        accessionNumber: String = "",
        manufacturer: String = "",
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        contentLabel: String = "AI_FINDINGS",
        contentDescription: String? = "External inference annotations",
        contentCreatorName: String? = nil,
        presentationCreationDate: String? = nil,
        presentationCreationTime: String? = nil,
        displayedArea: DicomPresentationDisplayedArea? = nil,
        displayedAreas: [DicomPresentationDisplayedArea] = [],
        spatialTransform: DicomPresentationSpatialTransform = .identity,
        shutters: [DicomPresentationShutter] = [],
        shutterPresentationValue: UInt16? = nil,
        displayTransformProfile: DicomDisplayTransformProfile = .identity,
        voiSelections: [DicomPresentationVOISelection] = [],
        iccProfile: Data? = nil,
        kind: DicomSoftcopyPresentationStateKind = .grayscale,
        paletteColorLookupTable: DicomPaletteColorLookupTable? = nil,
        blendingItems: [DicomPresentationBlendingItem] = [],
        relativeOpacity: Double? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomGSPSNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomGSPSNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomGSPSNonEmptyValue
        self.patientName = patientName?.dicomGSPSNonEmptyValue
        self.patientID = patientID?.dicomGSPSNonEmptyValue
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.studyID = studyID
        self.accessionNumber = accessionNumber
        self.manufacturer = manufacturer
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.contentLabel = contentLabel.dicomGSPSNonEmptyValue ?? "AI_FINDINGS"
        self.contentDescription = contentDescription?.dicomGSPSNonEmptyValue
        self.contentCreatorName = contentCreatorName?.dicomGSPSNonEmptyValue
        self.presentationCreationDate = presentationCreationDate?.dicomGSPSNonEmptyValue
        self.presentationCreationTime = presentationCreationTime?.dicomGSPSNonEmptyValue
        self.displayedArea = displayedArea
        self.displayedAreas = displayedAreas
        self.spatialTransform = spatialTransform
        self.shutters = shutters
        self.shutterPresentationValue = shutterPresentationValue
        self.displayTransformProfile = displayTransformProfile
        self.voiSelections = voiSelections
        self.iccProfile = iccProfile
        self.kind = kind
        self.paletteColorLookupTable = paletteColorLookupTable
        self.blendingItems = blendingItems
        self.relativeOpacity = relativeOpacity
    }
}
