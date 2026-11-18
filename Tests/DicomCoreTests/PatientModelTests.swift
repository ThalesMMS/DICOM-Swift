//
//  PatientModelTests.swift
//  DicomCoreTests
//
//  Checks patient-array filtering by modality and sex.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class PatientModelTests: XCTestCase {

    // MARK: - DICOMModality Tests

    func testDICOMModalityStringConversion() {
        XCTAssertEqual(DICOMModality.from(string: "CT"), .ct)
        XCTAssertEqual(DICOMModality.from(string: "MR"), .mr)
        XCTAssertEqual(DICOMModality.from(string: "DX"), .dx)
        XCTAssertEqual(DICOMModality.from(string: "CR"), .cr)
        XCTAssertEqual(DICOMModality.from(string: "US"), .us)
        XCTAssertEqual(DICOMModality.from(string: "MG"), .mg)
        XCTAssertEqual(DICOMModality.from(string: "RF"), .rf)
        XCTAssertEqual(DICOMModality.from(string: "XC"), .xc)
        XCTAssertEqual(DICOMModality.from(string: "SC"), .sc)
        XCTAssertEqual(DICOMModality.from(string: "PT"), .pt)
        XCTAssertEqual(DICOMModality.from(string: "NM"), .nm)
    }

    func testDICOMModalityCaseInsensitiveConversion() {
        XCTAssertEqual(DICOMModality.from(string: "ct"), .ct)
        XCTAssertEqual(DICOMModality.from(string: "Ct"), .ct)
        XCTAssertEqual(DICOMModality.from(string: "mr"), .mr)
        XCTAssertEqual(DICOMModality.from(string: "Mr"), .mr)
    }

    func testDICOMModalityUnknownHandling() {
        XCTAssertEqual(DICOMModality.from(string: "INVALID"), .unknown)
        XCTAssertEqual(DICOMModality.from(string: ""), .unknown)
        XCTAssertEqual(DICOMModality.from(string: "XYZ"), .unknown)
    }

    func testDICOMModalityRawStringValue() {
        XCTAssertEqual(DICOMModality.ct.rawStringValue, "CT")
        XCTAssertEqual(DICOMModality.mr.rawStringValue, "MR")
        XCTAssertEqual(DICOMModality.pt.rawStringValue, "PT")
        XCTAssertEqual(DICOMModality.unknown.rawStringValue, "UNKNOWN")
    }

    func testDICOMModalityDisplayNames() {
        XCTAssertEqual(DICOMModality.ct.displayName, "Computed Tomography")
        XCTAssertEqual(DICOMModality.mr.displayName, "Magnetic Resonance")
        XCTAssertEqual(DICOMModality.pt.displayName, "PET Scan")
        XCTAssertEqual(DICOMModality.mg.displayName, "Mammography")
        XCTAssertEqual(DICOMModality.unknown.displayName, "Unknown")
    }

    func testDICOMModalityIconNames() {
        XCTAssertEqual(DICOMModality.ct.iconName, "cross.case")
        XCTAssertEqual(DICOMModality.mr.iconName, "waveform.path.ecg")
        XCTAssertEqual(DICOMModality.us.iconName, "water.waves")
        XCTAssertEqual(DICOMModality.pt.iconName, "atom")
        XCTAssertEqual(DICOMModality.unknown.iconName, "questionmark.circle")
    }

    func testDICOMModalityCodable() throws {
        let modality = DICOMModality.ct
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(modality)
        let decoded = try decoder.decode(DICOMModality.self, from: encoded)

        XCTAssertEqual(decoded, .ct)

        // Test string representation in JSON
        let jsonString = String(data: encoded, encoding: .utf8)
        XCTAssertEqual(jsonString, "\"CT\"")
    }

    func testDICOMModalityAllCases() {
        let allCases = DICOMModality.allCases
        XCTAssertGreaterThan(allCases.count, 0, "Should have at least one modality")
        XCTAssertTrue(allCases.contains(.ct), "Should contain CT modality")
        XCTAssertTrue(allCases.contains(.mr), "Should contain MR modality")
    }

    // MARK: - PatientSex Tests

    func testPatientSexStringConversion() {
        XCTAssertEqual(PatientSex.from(string: "M"), .male)
        XCTAssertEqual(PatientSex.from(string: "F"), .female)
        XCTAssertEqual(PatientSex.from(string: "O"), .other)
        XCTAssertEqual(PatientSex.from(string: "U"), .unknown)
    }

    func testPatientSexCaseInsensitiveConversion() {
        XCTAssertEqual(PatientSex.from(string: "m"), .male)
        XCTAssertEqual(PatientSex.from(string: "f"), .female)
        XCTAssertEqual(PatientSex.from(string: "o"), .other)
    }

    func testPatientSexWhitespaceHandling() {
        XCTAssertEqual(PatientSex.from(string: " M "), .male)
        XCTAssertEqual(PatientSex.from(string: " F "), .female)
        XCTAssertEqual(PatientSex.from(string: "  O  "), .other)
    }

    func testPatientSexEmptyAndNilHandling() {
        XCTAssertEqual(PatientSex.from(string: nil), .unknown)
        XCTAssertEqual(PatientSex.from(string: ""), .unknown)
        XCTAssertEqual(PatientSex.from(string: "INVALID"), .unknown)
    }

    func testPatientSexRawStringValue() {
        XCTAssertEqual(PatientSex.male.rawStringValue, "M")
        XCTAssertEqual(PatientSex.female.rawStringValue, "F")
        XCTAssertEqual(PatientSex.other.rawStringValue, "O")
        XCTAssertEqual(PatientSex.unknown.rawStringValue, "U")
    }

    func testPatientSexDisplayNames() {
        XCTAssertEqual(PatientSex.male.displayName, "Male")
        XCTAssertEqual(PatientSex.female.displayName, "Female")
        XCTAssertEqual(PatientSex.other.displayName, "Other")
        XCTAssertEqual(PatientSex.unknown.displayName, "Unknown")
    }

    func testPatientSexIconNames() {
        XCTAssertEqual(PatientSex.male.iconName, "person.fill")
        XCTAssertEqual(PatientSex.female.iconName, "person.fill")
        XCTAssertEqual(PatientSex.other.iconName, "person.2.fill")
        XCTAssertEqual(PatientSex.unknown.iconName, "person")
    }

    func testPatientSexCodable() throws {
        let sex = PatientSex.male
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(sex)
        let decoded = try decoder.decode(PatientSex.self, from: encoded)

        XCTAssertEqual(decoded, .male)

        // Test string representation in JSON
        let jsonString = String(data: encoded, encoding: .utf8)
        XCTAssertEqual(jsonString, "\"M\"")
    }

    // MARK: - PatientModel Initialization Tests

    func testPatientModelBasicInitialization() {
        let patient = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        XCTAssertEqual(patient.patientName, "John Doe")
        XCTAssertEqual(patient.patientID, "PAT001")
        XCTAssertEqual(patient.studyInstanceUID, "1.2.3.4.5")
        XCTAssertEqual(patient.patientSex, .unknown)
        XCTAssertEqual(patient.modality, .unknown)
    }

    func testPatientModelFullInitialization() {
        let birthDate = Calendar.current.date(byAdding: .year, value: -45, to: Date())
        let studyDate = Date()

        let patient = PatientModel(
            patientName: "Jane Smith",
            patientID: "PAT002",
            patientBirthDate: birthDate,
            patientSex: .female,
            patientAge: "045Y",
            patientWeight: 65.5,
            patientSize: 1.68,
            studyInstanceUID: "1.2.3.4.6",
            studyDate: studyDate,
            studyDescription: "Brain MRI",
            modality: .mr,
            bodyPartExamined: "BRAIN",
            institutionName: "General Hospital",
            numberOfImages: 200,
            fileSize: 104857600
        )

        XCTAssertEqual(patient.patientName, "Jane Smith")
        XCTAssertEqual(patient.patientSex, .female)
        XCTAssertEqual(patient.patientAge, "045Y")
        XCTAssertEqual(patient.patientWeight, 65.5, accuracy: 0.01)
        XCTAssertEqual(patient.patientSize, 1.68, accuracy: 0.01)
        XCTAssertEqual(patient.modality, .mr)
        XCTAssertEqual(patient.bodyPartExamined, "BRAIN")
        XCTAssertEqual(patient.numberOfImages, 200)
        XCTAssertEqual(patient.fileSize, 104857600)
    }

    // MARK: - PatientModel Computed Properties Tests

    func testDisplayName() {
        let patient1 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )
        XCTAssertEqual(patient1.displayName, "John Doe")

        let patient2 = PatientModel(
            patientName: "",
            patientID: "PAT002",
            studyInstanceUID: "1.2.4"
        )
        XCTAssertEqual(patient2.displayName, "Unknown Patient")
    }

    func testDisplayAge() {
        // Test with explicit age string
        let patient1 = PatientModel(
            patientName: "John",
            patientID: "PAT001",
            patientAge: "045Y",
            studyInstanceUID: "1.2.3"
        )
        XCTAssertEqual(patient1.displayAge, "045Y")

        // Test with birth date
        let birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date())!
        let patient2 = PatientModel(
            patientName: "Jane",
            patientID: "PAT002",
            patientBirthDate: birthDate,
            studyInstanceUID: "1.2.4"
        )
        XCTAssertTrue(patient2.displayAge.contains("Y"))

        // Test with no age info
        let patient3 = PatientModel(
            patientName: "Bob",
            patientID: "PAT003",
            studyInstanceUID: "1.2.5"
        )
        XCTAssertEqual(patient3.displayAge, "Unknown")
    }

    func testStudyDateTime() {
        let calendar = Calendar.current
        let studyDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let studyTime = calendar.date(from: DateComponents(hour: 14, minute: 30, second: 0))!

        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3",
            studyDate: studyDate,
            studyTime: studyTime
        )

        let combined = patient.studyDateTime
        XCTAssertNotNil(combined)

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: combined!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }

    func testStudyDateTimeWithDateOnly() {
        let studyDate = Date()
        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3",
            studyDate: studyDate
        )

        XCTAssertEqual(patient.studyDateTime, studyDate)
    }

    func testStudyDateTimeWithNoDate() {
        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )

        XCTAssertNil(patient.studyDateTime)
    }

    func testDisplayStudyDate() {
        let studyDate = Date()
        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3",
            studyDate: studyDate
        )

        XCTAssertNotEqual(patient.displayStudyDate, "Unknown Date")
        XCTAssertFalse(patient.displayStudyDate.isEmpty)
    }

    func testDisplayFileSizeFormatting() {
        let patient1 = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3",
            fileSize: 1024
        )
        XCTAssertFalse(patient1.displayFileSize.isEmpty)

        let patient2 = PatientModel(
            patientName: "Test",
            patientID: "PAT002",
            studyInstanceUID: "1.2.4",
            fileSize: 1048576
        )
        XCTAssertFalse(patient2.displayFileSize.isEmpty)
    }

    func testStudySummary() {
        let patient1 = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3",
            studyDescription: "Brain CT",
            modality: .ct,
            numberOfImages: 150
        )
        XCTAssertTrue(patient1.studySummary.contains("Brain CT"))
        XCTAssertTrue(patient1.studySummary.contains("Computed Tomography"))
        XCTAssertTrue(patient1.studySummary.contains("150 images"))

        let patient2 = PatientModel(
            patientName: "Test",
            patientID: "PAT002",
            studyInstanceUID: "1.2.4",
            modality: .mr,
            bodyPartExamined: "SPINE"
        )
        XCTAssertTrue(patient2.studySummary.contains("SPINE"))
        XCTAssertTrue(patient2.studySummary.contains("Magnetic Resonance"))
    }

    // MARK: - PatientModel Equality Tests

    func testPatientModelEquality() {
        let patient1 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        let patient2 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        XCTAssertEqual(patient1, patient2)
    }

    func testPatientModelInequality() {
        let patient1 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        let patient2 = PatientModel(
            patientName: "Jane Smith",
            patientID: "PAT002",
            studyInstanceUID: "1.2.3.4.6"
        )

        XCTAssertNotEqual(patient1, patient2)
    }

    func testPatientModelHash() {
        let patient1 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        let patient2 = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3.4.5"
        )

        XCTAssertEqual(patient1.hash, patient2.hash)
    }

    // MARK: - PatientModel Codable Tests

    func testPatientModelCodable() throws {
        let original = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            patientBirthDate: Date(),
            patientSex: .male,
            patientAge: "045Y",
            studyInstanceUID: "1.2.3.4.5",
            modality: .ct
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try encoder.encode(original)
        let decoded = try decoder.decode(PatientModel.self, from: encoded)

        XCTAssertEqual(decoded.patientName, original.patientName)
        XCTAssertEqual(decoded.patientID, original.patientID)
        XCTAssertEqual(decoded.patientSex, original.patientSex)
        XCTAssertEqual(decoded.studyInstanceUID, original.studyInstanceUID)
        XCTAssertEqual(decoded.modality, original.modality)
    }

    // MARK: - Legacy Objective-C Bridge Tests

    func testLegacyProperties() {
        let patient = PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            patientSex: .male,
            studyInstanceUID: "1.2.3",
            modality: .ct,
            bodyPartExamined: "CHEST",
            institutionName: "General Hospital"
        )

        XCTAssertEqual(patient.name, "John Doe")
        XCTAssertEqual(patient.number, "PAT001")
        XCTAssertEqual(patient.sex, "M")
        XCTAssertEqual(patient.type, "CT")
        XCTAssertEqual(patient.part, "CHEST")
        XCTAssertEqual(patient.StudyUniqueId, "1.2.3")
        XCTAssertEqual(patient.yiyuan, "General Hospital")
    }

    func testLegacyPropertiesWithDefaults() {
        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )

        XCTAssertEqual(patient.part, "Unknown")
        XCTAssertEqual(patient.yiyuan, "Unknown")
    }

    func testFromLegacyData() {
        let patient = PatientModel.fromLegacyData(
            name: "John Doe",
            type: "CT",
            age: "045Y",
            number: "PAT001",
            sex: "M",
            examineTime: "2024-01-15",
            part: "CHEST",
            studyUniqueId: "1.2.3.4.5",
            yiyuan: "General Hospital"
        )

        XCTAssertEqual(patient.patientName, "John Doe")
        XCTAssertEqual(patient.patientID, "PAT001")
        XCTAssertEqual(patient.modality, .ct)
        XCTAssertEqual(patient.patientSex, .male)
        XCTAssertEqual(patient.patientAge, "045Y")
        XCTAssertEqual(patient.bodyPartExamined, "CHEST")
        XCTAssertEqual(patient.studyInstanceUID, "1.2.3.4.5")
        XCTAssertEqual(patient.institutionName, "General Hospital")
    }

    func testFromLegacyDataWithEmptyFields() {
        let patient = PatientModel.fromLegacyData(
            name: "Test",
            type: "UNKNOWN",
            age: "",
            number: "PAT001",
            sex: "",
            examineTime: "",
            part: "",
            studyUniqueId: "1.2.3",
            yiyuan: ""
        )

        XCTAssertEqual(patient.modality, .unknown)
        XCTAssertEqual(patient.patientSex, .unknown)
        XCTAssertNil(patient.patientAge)
        XCTAssertNil(patient.bodyPartExamined)
        XCTAssertNil(patient.institutionName)
    }

    // MARK: - Sample Patient Tests

    func testSamplePatient() {
        let sample = PatientModel.samplePatient

        XCTAssertEqual(sample.patientName, "John Doe")
        XCTAssertEqual(sample.patientID, "PAT001")
        XCTAssertEqual(sample.patientSex, .male)
        XCTAssertEqual(sample.modality, .ct)
        XCTAssertEqual(sample.bodyPartExamined, "CHEST")
        XCTAssertEqual(sample.numberOfImages, 150)
        XCTAssertNotNil(sample.patientBirthDate)
        XCTAssertNotNil(sample.studyDate)
    }

    // MARK: - Access Time Update Tests

    func testWithUpdatedAccessTime() {
        let original = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )

        XCTAssertNil(original.lastAccessedAt)

        let updated = original.withUpdatedAccessTime()

        XCTAssertNotNil(updated.lastAccessedAt)
        XCTAssertEqual(updated.patientName, original.patientName)
        XCTAssertEqual(updated.patientID, original.patientID)
        XCTAssertEqual(updated.studyInstanceUID, original.studyInstanceUID)
    }

    // MARK: - Array Extension Tests

    func testArraySearchByName() {
        let patients = [
            PatientModel(patientName: "John Doe", patientID: "PAT001", studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Jane Smith", patientID: "PAT002", studyInstanceUID: "1.2.4"),
            PatientModel(patientName: "Bob Johnson", patientID: "PAT003", studyInstanceUID: "1.2.5")
        ]

        let results = patients.search(query: "john")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains(where: { $0.patientName == "John Doe" }))
        XCTAssertTrue(results.contains(where: { $0.patientName == "Bob Johnson" }))
    }

    func testArraySearchByID() {
        let patients = [
            PatientModel(patientName: "John", patientID: "PAT001", studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Jane", patientID: "PAT002", studyInstanceUID: "1.2.4")
        ]

        let results = patients.search(query: "PAT001")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.patientID, "PAT001")
    }

    func testArraySearchByDescription() {
        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3", studyDescription: "Brain CT"),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", studyDescription: "Chest X-Ray")
        ]

        let results = patients.search(query: "brain")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.studyDescription, "Brain CT")
    }

    func testArrayFilterByModality() {
        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3", modality: .ct),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", modality: .mr),
            PatientModel(patientName: "Test3", patientID: "PAT003", studyInstanceUID: "1.2.5", modality: .ct)
        ]

        let ctPatients = patients.filtered(by: .ct)
        XCTAssertEqual(ctPatients.count, 2)
        XCTAssertTrue(ctPatients.allSatisfy { $0.modality == .ct })
    }

    func testArrayFilterBySex() {
        let patients = [
            PatientModel(patientName: "John", patientID: "PAT001", patientSex: .male, studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Jane", patientID: "PAT002", patientSex: .female, studyInstanceUID: "1.2.4"),
            PatientModel(patientName: "Bob", patientID: "PAT003", patientSex: .male, studyInstanceUID: "1.2.5")
        ]

        let malePatients = patients.filtered(by: .male)
        XCTAssertEqual(malePatients.count, 2)
        XCTAssertTrue(malePatients.allSatisfy { $0.patientSex == .male })
    }

    func testArraySortByName() {
        let patients = [
            PatientModel(patientName: "Charlie", patientID: "PAT003", studyInstanceUID: "1.2.5"),
            PatientModel(patientName: "Alice", patientID: "PAT001", studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Bob", patientID: "PAT002", studyInstanceUID: "1.2.4")
        ]

        let sorted = patients.sortedByName()
        XCTAssertEqual(sorted[0].patientName, "Alice")
        XCTAssertEqual(sorted[1].patientName, "Bob")
        XCTAssertEqual(sorted[2].patientName, "Charlie")
    }

    func testArraySortByStudyDate() {
        let calendar = Calendar.current
        let date1 = calendar.date(byAdding: .day, value: -2, to: Date())!
        let date2 = calendar.date(byAdding: .day, value: -1, to: Date())!
        let date3 = Date()

        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3", studyDate: date1),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", studyDate: date3),
            PatientModel(patientName: "Test3", patientID: "PAT003", studyInstanceUID: "1.2.5", studyDate: date2)
        ]

        let sorted = patients.sortedByStudyDate()
        XCTAssertEqual(sorted[0].patientID, "PAT002")  // Most recent
        XCTAssertEqual(sorted[1].patientID, "PAT003")
        XCTAssertEqual(sorted[2].patientID, "PAT001")  // Oldest
    }

    func testArraySortByStudyDateWithNilDates() {
        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", studyDate: Date())
        ]

        let sorted = patients.sortedByStudyDate()
        XCTAssertEqual(sorted.count, 2)
        // Patient with date should come first
        XCTAssertNotNil(sorted[0].studyDate)
    }

    func testArrayGroupByModality() {
        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3", modality: .ct),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", modality: .mr),
            PatientModel(patientName: "Test3", patientID: "PAT003", studyInstanceUID: "1.2.5", modality: .ct)
        ]

        let grouped = patients.groupedByModality()
        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped[.ct]?.count, 2)
        XCTAssertEqual(grouped[.mr]?.count, 1)
    }

    func testArrayGroupByDate() {
        let calendar = Calendar.current
        let date1 = calendar.startOfDay(for: Date())
        let date2 = calendar.date(byAdding: .day, value: -1, to: date1)!

        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3", studyDate: date1),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", studyDate: date1),
            PatientModel(patientName: "Test3", patientID: "PAT003", studyInstanceUID: "1.2.5", studyDate: date2)
        ]

        let grouped = patients.groupedByDate()
        XCTAssertGreaterThan(grouped.keys.count, 0)
    }

    func testArrayGroupByDateWithNilDates() {
        let patients = [
            PatientModel(patientName: "Test1", patientID: "PAT001", studyInstanceUID: "1.2.3"),
            PatientModel(patientName: "Test2", patientID: "PAT002", studyInstanceUID: "1.2.4", studyDate: Date())
        ]

        let grouped = patients.groupedByDate()
        XCTAssertGreaterThan(grouped.keys.count, 0)
        XCTAssertTrue(grouped.keys.contains("Unknown Date"))
    }

    // MARK: - Edge Cases Tests

    func testPatientModelIdentifiable() {
        let patient1 = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )

        let patient2 = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )

        // IDs should be unique even for otherwise identical patients
        XCTAssertNotEqual(patient1.id, patient2.id)
    }

    func testPatientModelCreatedAtDefault() {
        let beforeCreation = Date()
        let patient = PatientModel(
            patientName: "Test",
            patientID: "PAT001",
            studyInstanceUID: "1.2.3"
        )
        let afterCreation = Date()

        XCTAssertGreaterThanOrEqual(patient.createdAt, beforeCreation)
        XCTAssertLessThanOrEqual(patient.createdAt, afterCreation)
    }

    func testEmptyArrayOperations() {
        let emptyArray: [PatientModel] = []

        XCTAssertEqual(emptyArray.search(query: "test").count, 0)
        XCTAssertEqual(emptyArray.filtered(by: .ct).count, 0)
        XCTAssertEqual(emptyArray.sortedByName().count, 0)
        XCTAssertEqual(emptyArray.groupedByModality().count, 0)
    }
}
