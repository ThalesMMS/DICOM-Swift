public struct DicomSurfaceSegmentationBuildOptions: Equatable, Sendable {
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
    public var instanceNumber = 1
    public var contentDate = ""
    public var contentTime = ""
    public var manufacturer = "DICOM-Swift"
    public var manufacturerModelName = "DicomSurfaceSegmentationBuilder"
    public var deviceSerialNumber = "DICOM-Swift"
    public var softwareVersions = "DICOM-Swift"
    public var positionReferenceIndicator = ""

    public init(
        patientName: String = "",
        patientID: String = "",
        patientBirthDate: String = "",
        patientSex: String = "",
        studyDate: String = "",
        studyTime: String = "",
        referringPhysicianName: String = "",
        studyID: String = "",
        accessionNumber: String = "",
        seriesNumber: Int = 1,
        instanceNumber: Int = 1,
        contentDate: String = "",
        contentTime: String = "",
        manufacturer: String = "DICOM-Swift",
        manufacturerModelName: String = "DicomSurfaceSegmentationBuilder",
        deviceSerialNumber: String = "DICOM-Swift",
        softwareVersions: String = "DICOM-Swift",
        positionReferenceIndicator: String = ""
    ) {
        self.patientName = patientName
        self.patientID = patientID
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.referringPhysicianName = referringPhysicianName
        self.studyID = studyID
        self.accessionNumber = accessionNumber
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.contentDate = contentDate
        self.contentTime = contentTime
        self.manufacturer = manufacturer
        self.manufacturerModelName = manufacturerModelName
        self.deviceSerialNumber = deviceSerialNumber
        self.softwareVersions = softwareVersions
        self.positionReferenceIndicator = positionReferenceIndicator
    }
}
