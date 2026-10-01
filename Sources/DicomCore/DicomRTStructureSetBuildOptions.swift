/// Patient, study, series and equipment metadata; empty strings encode Type 2 values.
public struct DicomRTStructureSetBuildOptions: Equatable, Sendable {
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
    public var operatorsName = ""
    public var manufacturer = "DICOM-Swift"
    public var manufacturerModelName = "DicomRTStructureSetBuilder"
    public var deviceSerialNumber = "DICOM-Swift"
    public var softwareVersions = "DICOM-Swift"

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
        operatorsName: String = "",
        manufacturer: String = "DICOM-Swift",
        manufacturerModelName: String = "DicomRTStructureSetBuilder",
        deviceSerialNumber: String = "DICOM-Swift",
        softwareVersions: String = "DICOM-Swift"
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
        self.operatorsName = operatorsName
        self.manufacturer = manufacturer
        self.manufacturerModelName = manufacturerModelName
        self.deviceSerialNumber = deviceSerialNumber
        self.softwareVersions = softwareVersions
    }
}
