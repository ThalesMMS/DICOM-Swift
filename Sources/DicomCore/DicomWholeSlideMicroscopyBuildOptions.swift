import Foundation

/// Inputs for one WSI instance. Tile coordinates and source frame numbers are one-based.
public struct DicomWholeSlideMicroscopyBuildOptions: Sendable {
    public struct Position: Sendable, Equatable {
        public var column: Int
        public var row: Int
        public var plane: Int
        public var opticalPathIdentifier: String
        public init(column: Int, row: Int, plane: Int = 0, opticalPathIdentifier: String) {
            self.column = column; self.row = row; self.plane = plane
            self.opticalPathIdentifier = opticalPathIdentifier
        }
    }
    public struct Derivation: Sendable {
        public var sourceSOPInstanceUID: String
        public var sourceStudyInstanceUID: String
        public var sourceSeriesInstanceUID: String
        public var sourceFrames: [Int]
        public var code: DicomCodedConcept
        public var resampled: Bool
        public init(sourceSOPInstanceUID: String, sourceStudyInstanceUID: String, sourceSeriesInstanceUID: String,
                    sourceFrames: [Int], code: DicomCodedConcept, resampled: Bool = false) {
            self.sourceSOPInstanceUID = sourceSOPInstanceUID; self.sourceStudyInstanceUID = sourceStudyInstanceUID
            self.sourceSeriesInstanceUID = sourceSeriesInstanceUID; self.sourceFrames = sourceFrames
            self.code = code; self.resampled = resampled
        }
    }
    public var sopInstanceUID = ""
    public var studyInstanceUID = ""
    public var seriesInstanceUID = ""
    public var frameOfReferenceUID: String?
    public var pyramidUID: String?
    public var flavor: DicomWholeSlideImageType.Flavor = .volume
    public var matrixColumns = 1
    public var matrixRows = 1
    public var tileColumns = 1
    public var tileRows = 1
    public var origin = DicomSlideOrigin(xMillimeters: 0, yMillimeters: 0)
    public var orientation: [Double] = [1, 0, 0, 0, 1, 0]
    public var pixelSpacingXMillimeters = 0.001
    public var pixelSpacingYMillimeters = 0.001
    public var sliceThicknessMillimeters = 0.001
    public var focalPlanes = 1
    public var spacingBetweenSlicesMillimeters = 0.001
    public var extendedDepthOfField = false
    public var acquisitionFocalPlanes: Int?
    public var distanceBetweenFocalPlanesMicrometers: Double?
    public var opticalPaths: [DicomWholeSlideOpticalPath] = []
    public var specimen = DicomWholeSlideSpecimen()
    public var organization: DicomDimensionOrganizationType = .tiledFull
    /// Required in pixel-frame order for TILED_SPARSE; nil for TILED_FULL.
    public var positions: [Position]?
    public var photometricInterpretation = "RGB"
    public var bitsAllocated = 8
    public var frames: [Data] = []
    /// Native frames use Explicit VR Little Endian; compressed frames are passed through unchanged.
    public var transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    public var extendedOffsetTable = false
    public var lossyImageCompression = false
    public var lossyRatios: [Double] = []
    public var lossyMethods: [String] = []
    public var derivation: Derivation?
    public var label: DicomWholeSlideLabel?
    public var burnedInAnnotation = false
    public var focusMethod = "AUTO"
    public var acquisitionDateTime = ""
    public var contentDate = ""
    public var contentTime = ""
    public var instanceNumber = 1
    public var patientName = ""
    public var patientID = ""
    public var patientBirthDate = ""
    public var patientSex = ""
    public var studyDate = ""
    public var studyTime = ""
    public var referringPhysicianName = ""
    public var studyID = ""
    public var accessionNumber = ""
    public var seriesNumber = 1
    public var manufacturer = "DICOM-Swift"
    public var manufacturerModelName = "WSI Builder"
    public var deviceSerialNumber = "SOFTWARE"
    public var softwareVersions = "1"
    public init() {}
}
