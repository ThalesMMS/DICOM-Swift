import Foundation

public struct DicomSRImageLibraryEntry: Equatable, Sendable {
    public var reference: DicomSourceImageReference
    public var modality: DicomCodedConcept?
    public var studyDate: DicomDate?
    public var studyTime: DicomTime?
    public var seriesUID: String?
    public var seriesNumber: String?
    public var seriesDescription: String?
    public var frameOfReferenceUID: String?
    public var rows: Double?
    public var columns: Double?
    public var numberOfFrames: Double?
    public var instanceNumber: String?
    public var contentDate: DicomDate?
    public var contentTime: DicomTime?
    public var acquisitionDate: DicomDate?
    public var acquisitionTime: DicomTime?
    public var horizontalPixelSpacing: Double?
    public var verticalPixelSpacing: Double?
    public var sliceThickness: Double?
    public var spacingBetweenSlices: Double?
    public var ctAcquisitionType: DicomCodedConcept?
    public var ctReconstructionAlgorithm: DicomCodedConcept?
    public var mrPulseSequenceName: String?
    public var mrMagneticFieldStrength: Double?
    public var imagePosition: [Double]
    public var imageOrientation: [Double]
    public var mrDiffusionBValues: [Double]
    public var additionalDescriptors: [DicomSRContentItem]

    public init(
        reference: DicomSourceImageReference,
        modality: DicomCodedConcept? = nil,
        studyDate: DicomDate? = nil,
        studyTime: DicomTime? = nil,
        seriesUID: String? = nil,
        seriesNumber: String? = nil,
        seriesDescription: String? = nil,
        frameOfReferenceUID: String? = nil,
        rows: Double? = nil,
        columns: Double? = nil,
        numberOfFrames: Double? = nil,
        instanceNumber: String? = nil,
        contentDate: DicomDate? = nil,
        contentTime: DicomTime? = nil,
        acquisitionDate: DicomDate? = nil,
        acquisitionTime: DicomTime? = nil,
        horizontalPixelSpacing: Double? = nil,
        verticalPixelSpacing: Double? = nil,
        sliceThickness: Double? = nil,
        spacingBetweenSlices: Double? = nil,
        ctAcquisitionType: DicomCodedConcept? = nil,
        ctReconstructionAlgorithm: DicomCodedConcept? = nil,
        mrPulseSequenceName: String? = nil,
        mrMagneticFieldStrength: Double? = nil,
        imagePosition: [Double] = [],
        imageOrientation: [Double] = [],
        mrDiffusionBValues: [Double] = [],
        additionalDescriptors: [DicomSRContentItem] = []
    ) {
        self.reference = reference
        self.modality = modality
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.seriesUID = seriesUID
        self.seriesNumber = seriesNumber
        self.seriesDescription = seriesDescription
        self.frameOfReferenceUID = frameOfReferenceUID
        self.rows = rows
        self.columns = columns
        self.numberOfFrames = numberOfFrames
        self.instanceNumber = instanceNumber
        self.contentDate = contentDate
        self.contentTime = contentTime
        self.acquisitionDate = acquisitionDate
        self.acquisitionTime = acquisitionTime
        self.horizontalPixelSpacing = horizontalPixelSpacing
        self.verticalPixelSpacing = verticalPixelSpacing
        self.sliceThickness = sliceThickness
        self.spacingBetweenSlices = spacingBetweenSlices
        self.ctAcquisitionType = ctAcquisitionType
        self.ctReconstructionAlgorithm = ctReconstructionAlgorithm
        self.mrPulseSequenceName = mrPulseSequenceName
        self.mrMagneticFieldStrength = mrMagneticFieldStrength
        self.imagePosition = imagePosition
        self.imageOrientation = imageOrientation
        self.mrDiffusionBValues = mrDiffusionBValues
        self.additionalDescriptors = additionalDescriptors
    }
}
