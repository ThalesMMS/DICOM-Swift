import Foundation

/// Required Type 2 patient, study, and equipment attributes for derived media instances.
public struct DicomMediaAttachmentType2Attributes: Equatable, Sendable {
    /// Patient's Name (0010,0010).
    public let patientName: String
    /// Patient ID (0010,0020).
    public let patientID: String
    /// Patient's Birth Date (0010,0030).
    public let patientBirthDate: String
    /// Patient's Sex (0010,0040).
    public let patientSex: String
    /// Study Date (0008,0020).
    public let studyDate: String
    /// Study Time (0008,0030).
    public let studyTime: String
    /// Referring Physician's Name (0008,0090).
    public let referringPhysicianName: String
    /// Study ID (0020,0010).
    public let studyID: String
    /// Accession Number (0008,0050).
    public let accessionNumber: String
    /// Manufacturer (0008,0070).
    public let manufacturer: String

    /// Creates the Type 2 values to apply to a derived media dataset.
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
        manufacturer: String = ""
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
        self.manufacturer = manufacturer
    }

    /// Copies the Type 2 patient and study values from a decoded source instance.
    public init(from decoder: DCMDecoder, manufacturer: String) {
        self.init(
            patientName: decoder.info(for: .patientName),
            patientID: decoder.info(for: .patientID),
            patientBirthDate: decoder.info(for: 0x0010_0030),
            patientSex: decoder.info(for: .patientSex),
            studyDate: decoder.info(for: .studyDate),
            studyTime: decoder.info(for: .studyTime),
            referringPhysicianName: decoder.info(for: .referringPhysicianName),
            studyID: decoder.info(for: .studyID),
            accessionNumber: decoder.info(for: .accessionNumber),
            manufacturer: manufacturer
        )
    }

    func apply(to dataSet: inout DicomDataSet) {
        set(patientName, tag: DicomTag.patientName.rawValue, vr: .PN, in: &dataSet)
        set(patientID, tag: DicomTag.patientID.rawValue, vr: .LO, in: &dataSet)
        set(patientBirthDate, tag: 0x0010_0030, vr: .DA, in: &dataSet)
        set(patientSex, tag: DicomTag.patientSex.rawValue, vr: .CS, in: &dataSet)
        set(studyDate, tag: DicomTag.studyDate.rawValue, vr: .DA, in: &dataSet)
        set(studyTime, tag: DicomTag.studyTime.rawValue, vr: .TM, in: &dataSet)
        set(
            referringPhysicianName,
            tag: DicomTag.referringPhysicianName.rawValue,
            vr: .PN,
            in: &dataSet
        )
        set(studyID, tag: DicomTag.studyID.rawValue, vr: .SH, in: &dataSet)
        set(accessionNumber, tag: DicomTag.accessionNumber.rawValue, vr: .SH, in: &dataSet)
        set(manufacturer, tag: 0x0008_0070, vr: .LO, in: &dataSet)
    }

    private func set(
        _ value: String,
        tag: Int,
        vr: DicomVR,
        in dataSet: inout DicomDataSet
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty Type 2 value fills a gap; it never erases a value the builder options already provided.
        if trimmed.isEmpty, let existing = dataSet.element(for: tag), existing.value != .empty { return }
        dataSet.set(DicomDataElement(tag: tag, vr: vr, value: trimmed.isEmpty ? .empty : .strings([value])))
    }
}
