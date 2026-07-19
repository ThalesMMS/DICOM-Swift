//
//  PatientModel.swift
//
//  Modern Swift version of PatientModel with DICOM compliance and Codable conformance
//

import Foundation

// MARK: - DICOM Enumerations

/// DICOM modality types following the DICOM standard.
///
/// Represents the imaging modality used to acquire medical images. Each case corresponds
/// to a standard DICOM modality code and provides display properties for UI presentation.
///
/// ## Overview
///
/// ``DICOMModality`` provides a type-safe enumeration of common medical imaging modalities.
/// It includes factory methods for converting DICOM tag values to enum cases, display properties
/// for UI presentation, and Codable conformance for persistence.
///
/// **Supported Modalities:**
/// - CT (Computed Tomography)
/// - MR (Magnetic Resonance)
/// - DX/CR (Digital/Computed Radiography)
/// - US (Ultrasound)
/// - MG (Mammography)
/// - PT (Positron Emission Tomography)
/// - NM (Nuclear Medicine)
/// - RF (Radiofluoroscopy)
/// - XC/SC (Photography/Secondary Capture)
///
/// ## Usage Example
/// ```swift
/// let modality = DICOMModality.from(string: "CT")
/// print(modality.displayName)  // "Computed Tomography"
/// print(modality.iconName)     // "cross.case"
/// ```
///
/// ## Topics
///
/// ### Modality Cases
///
/// - ``ct``
/// - ``mr``
/// - ``dx``
/// - ``cr``
/// - ``us``
/// - ``mg``
/// - ``pt``
/// - ``nm``
/// - ``rf``
/// - ``xc``
/// - ``sc``
/// - ``unknown``
///
/// ### Factory Methods
///
/// - ``from(string:)``
///
/// ### Display Properties
///
/// - ``displayName``
/// - ``iconName``
/// - ``rawStringValue``
/// - ``associatedModality``
///
@objc public enum DICOMModality: Int, CaseIterable, Codable, Sendable {
    /// Computed Tomography
    case ct = 0
    /// Magnetic Resonance
    case mr = 1
    /// Digital Radiography
    case dx = 2
    /// Computed Radiography
    case cr = 3
    /// Ultrasound
    case us = 4
    /// Mammography
    case mg = 5
    /// Radiofluoroscopy
    case rf = 6
    /// External-camera Photography
    case xc = 7
    /// Secondary Capture
    case sc = 8
    /// Positron Emission Tomography
    case pt = 9
    /// Nuclear Medicine
    case nm = 10
    /// Unknown or unsupported modality
    case unknown = 999

    // MARK: - String Representation

    /// DICOM standard modality code (e.g., "CT", "MR", "XR")
    var rawStringValue: String {
        switch self {
        case .ct: return "CT"
        case .mr: return "MR"
        case .dx: return "DX"
        case .cr: return "CR"
        case .us: return "US"
        case .mg: return "MG"
        case .rf: return "RF"
        case .xc: return "XC"
        case .sc: return "SC"
        case .pt: return "PT"
        case .nm: return "NM"
        case .unknown: return "UNKNOWN"
        }
    }
    
    // MARK: - Factory Methods

    /// Creates a modality enum from a DICOM modality string.
    ///
    /// - Parameter string: DICOM modality code (e.g., "CT", "MR", "XR")
    /// - Returns: Corresponding ``DICOMModality`` case (defaults to ``unknown`` if unrecognized)
    ///
    /// ## Example
    /// ```swift
    /// let modality = DICOMModality.from(string: "CT")  // .ct
    /// let unknown = DICOMModality.from(string: "ZZ")   // .unknown
    /// ```
    static func from(string: String) -> DICOMModality {
        switch string.uppercased() {
        case "CT": return .ct
        case "MR": return .mr
        case "DX": return .dx
        case "CR": return .cr
        case "US": return .us
        case "MG": return .mg
        case "RF": return .rf
        case "XC": return .xc
        case "SC": return .sc
        case "PT": return .pt
        case "NM": return .nm
        default: return .unknown
        }
    }

    // MARK: - Display Properties

    /// Human-readable modality name for UI display.
    ///
    /// Returns the full descriptive name of the modality (e.g., "Computed Tomography" for `.ct`).
    var displayName: String {
        switch self {
        case .ct: return "Computed Tomography"
        case .mr: return "Magnetic Resonance"
        case .dx: return "Digital Radiography"
        case .cr: return "Computed Radiography"
        case .us: return "Ultrasound"
        case .mg: return "Mammography"
        case .rf: return "Radiofluoroscopy"
        case .xc: return "External Photography"
        case .sc: return "Secondary Capture"
        case .pt: return "PET Scan"
        case .nm: return "Nuclear Medicine"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbols icon name for visual representation.
    ///
    /// Returns an appropriate SF Symbols icon name for the modality.
    var iconName: String {
        switch self {
        case .ct: return "cross.case"
        case .mr: return "waveform.path.ecg"
        case .dx, .cr: return "xmark.rectangle"
        case .us: return "water.waves"
        case .mg: return "person.crop.circle"
        case .rf: return "video"
        case .xc: return "camera"
        case .sc: return "doc.circle"
        case .pt: return "atom"
        case .nm: return "bolt.circle"
        case .unknown: return "questionmark.circle"
        }
    }
    
    // MARK: - Codable Implementation
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stringValue = try container.decode(String.self)
        self = DICOMModality.from(string: stringValue)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawStringValue)
    }
}

/// Patient sex enumeration following the DICOM standard.
///
/// ## Overview
///
/// ``PatientSex`` provides a type-safe representation of patient sex values as defined
/// in the DICOM standard (Tag 0010,0040). It includes factory methods for parsing DICOM
/// tag values and display properties for UI presentation.
///
/// **Standard Values:**
/// - M (Male)
/// - F (Female)
/// - O (Other)
/// - U (Unknown)
///
/// ## Usage Example
/// ```swift
/// let sex = PatientSex.from(string: "M")  // .male
/// print(sex.displayName)  // "Male"
/// print(sex.iconName)     // "person.fill"
/// ```
///
/// ## Topics
///
/// ### Sex Cases
///
/// - ``male``
/// - ``female``
/// - ``other``
/// - ``unknown``
///
/// ### Factory Methods
///
/// - ``from(string:)``
///
/// ### Display Properties
///
/// - ``displayName``
/// - ``iconName``
/// - ``rawStringValue``
///
@objc public enum PatientSex: Int, CaseIterable, Codable, Sendable {
    /// Male patient
    case male = 0
    /// Female patient
    case female = 1
    /// Other or non-binary
    case other = 2
    /// Unknown or not specified
    case unknown = 999

    // MARK: - String Representation

    /// DICOM standard sex code ("M", "F", "O", "U")
    var rawStringValue: String {
        switch self {
        case .male: return "M"
        case .female: return "F"
        case .other: return "O"
        case .unknown: return "U"  // Return "U" for unknown instead of empty string
        }
    }
    
    // MARK: - Factory Methods

    /// Creates a sex enum from a DICOM sex string.
    ///
    /// - Parameter string: DICOM sex code ("M", "F", "O") or `nil`
    /// - Returns: Corresponding ``PatientSex`` case (defaults to ``unknown`` if unrecognized)
    ///
    /// ## Example
    /// ```swift
    /// let sex = PatientSex.from(string: "M")    // .male
    /// let unknown = PatientSex.from(string: nil) // .unknown
    /// ```
    static func from(string: String?) -> PatientSex {
        guard let string = string, !string.isEmpty else { return .unknown }
        switch string.uppercased().trimmingCharacters(in: .whitespaces) {
        case "M": return .male
        case "F": return .female
        case "O": return .other
        default: return .unknown
        }
    }

    // MARK: - Display Properties

    /// Human-readable sex name for UI display.
    ///
    /// Returns the full descriptive name (e.g., "Male", "Female", "Other", "Unknown").
    var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbols icon name for visual representation.
    ///
    /// Returns an appropriate SF Symbols icon name for the sex value.
    var iconName: String {
        switch self {
        case .male: return "person.fill"
        case .female: return "person.fill"
        case .other: return "person.2.fill"
        case .unknown: return "person"
        }
    }
    
    // MARK: - Codable Implementation
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stringValue = try container.decode(String.self)
        self = PatientSex.from(string: stringValue)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawStringValue)
    }
}

// MARK: - Patient Model

/// Modern Swift representation of a DICOM patient with comprehensive medical information.
///
/// ## Overview
///
/// ``PatientModel`` provides a structured, type-safe model for DICOM patient and study data
/// following the DICOM information hierarchy (Patient → Study → Series → Image). It includes
/// comprehensive patient demographics, study metadata, and series information extracted from
/// DICOM files.
///
/// The class conforms to `Codable` for JSON persistence, `Identifiable` for stable identity,
/// and includes Objective-C compatibility for bridge applications. All DICOM groups are properly
/// organized and documented with their corresponding tag numbers.
///
/// **Key Features:**
/// - Complete patient demographics (Group 0010)
/// - Study identification and timing (Groups 0008, 0020)
/// - Series organization (Group 0020)
/// - Modality-specific information
/// - Type-safe enumerations for modality and sex
/// - Codable JSON persistence
/// - Objective-C interoperability
///
/// ## Usage
///
/// Create from DICOM metadata:
///
/// ```swift
/// let patient = PatientModel(
///     patientName: "Doe^John",
///     patientID: "12345",
///     studyInstanceUID: "1.2.840.113619...",
///     modality: .ct
/// )
/// ```
///
/// Create from ``StudyDataService``:
///
/// ```swift
/// let service = StudyDataService(decoderFactory: { path in try DCMDecoder(contentsOfFile: path) })
/// if let metadata = await service.extractStudyMetadata(from: filePath) {
///     let patient = service.createPatientModel(from: metadata)
///     print("\(patient.patientName) - \(patient.modality.displayName)")
/// }
/// ```
///
/// Encode to JSON:
///
/// ```swift
/// let encoder = JSONEncoder()
/// encoder.outputFormatting = .prettyPrinted
/// let data = try encoder.encode(patient)
/// print(String(data: data, encoding: .utf8)!)
/// ```
///
/// ## Topics
///
/// ### Creating a Patient Model
///
/// - ``init(patientName:patientID:studyInstanceUID:modality:)``
/// - ``init(patientName:patientID:patientBirthDate:patientSex:patientAge:patientWeight:patientSize:studyInstanceUID:studyDate:studyTime:studyDescription:accessionNumber:referringPhysicianName:performingPhysicianName:institutionName:modality:bodyPartExamined:manufacturerModelName:protocolName:stationName:seriesNumber:acquisitionNumber:imageNumber:)``
///
/// ### Patient Demographics
///
/// - ``patientName``
/// - ``patientID``
/// - ``patientBirthDate``
/// - ``patientSex``
/// - ``patientAge``
/// - ``patientWeight``
/// - ``patientSize``
///
/// ### Study Information
///
/// - ``studyInstanceUID``
/// - ``studyDate``
/// - ``studyTime``
/// - ``studyDescription``
/// - ``accessionNumber``
///
/// ### Series Information
///
/// - ``modality``
/// - ``bodyPartExamined``
/// - ``seriesNumber``
/// - ``acquisitionNumber``
/// - ``imageNumber``
///
/// ### Medical Personnel
///
/// - ``referringPhysicianName``
/// - ``performingPhysicianName``
///
/// ### Equipment Information
///
/// - ``institutionName``
/// - ``manufacturerModelName``
/// - ``stationName``
/// - ``protocolName``
///
@objc(SwiftPatientModel)
public final class PatientModel: NSObject, Codable, Identifiable, @unchecked Sendable {
    
    // MARK: - Properties
    
    public let id = UUID()
    
    // Patient Demographics (DICOM Group 0010)
    @objc public let patientName: String           // (0010,0010) Patient's Name
    @objc public let patientID: String             // (0010,0020) Patient ID
    @objc public let patientBirthDate: Date?       // (0010,0030) Patient's Birth Date
    @objc public let patientSex: PatientSex        // (0010,0040) Patient's Sex
    @objc public let patientAge: String?           // (0010,1010) Patient's Age
    @objc public let patientWeight: Double         // (0010,1030) Patient's Weight (kg) - default 0 for Obj-C
    @objc public let patientSize: Double           // (0010,1020) Patient's Size (m) - default 0 for Obj-C
    
    // Study Information (DICOM Group 0008, 0020)
    @objc public let studyInstanceUID: String      // (0020,000D) Study Instance UID
    @objc public let studyDate: Date?              // (0008,0020) Study Date
    @objc public let studyTime: Date?              // (0008,0030) Study Time
    @objc public let studyDescription: String?     // (0008,1030) Study Description
    @objc public let accessionNumber: String?      // (0008,0050) Accession Number
    
    // Series Information
    @objc public let modality: DICOMModality       // (0008,0060) Modality
    @objc public let bodyPartExamined: String?     // (0018,0015) Body Part Examined
    @objc public let seriesDescription: String?    // (0008,103E) Series Description
    
    // Institution Information
    @objc public let institutionName: String?      // (0008,0080) Institution Name
    @objc public let institutionAddress: String?   // (0008,0081) Institution Address
    @objc public let stationName: String?          // (0008,1010) Station Name
    
    // Additional Metadata
    @objc public let numberOfImages: Int           // Derived - number of instances in study
    @objc public let fileSize: Int64              // File size in bytes - default 0 for Obj-C
    @objc public let createdAt: Date              // When this record was created
    @objc public let lastAccessedAt: Date?        // Last time this study was accessed
    
    // MARK: - Computed Properties
    
    /// Patient's full display name
    @objc public var displayName: String {
        return patientName.isEmpty ? "Unknown Patient" : patientName
    }
    
    /// Patient's age as display string
    @objc public var displayAge: String {
        if let age = patientAge, !age.isEmpty {
            return age
        } else if let birthDate = patientBirthDate {
            let calendar = Calendar.current
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
            if let years = ageComponents.year {
                return "\(years)Y"
            }
        }
        return "Unknown"
    }
    
    /// Combined study date and time
    @objc public var studyDateTime: Date? {
        guard let studyDate = studyDate else { return nil }
        
        if let studyTime = studyTime {
            let calendar = Calendar.current
            let dateComponents = calendar.dateComponents([.year, .month, .day], from: studyDate)
            let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: studyTime)
            
            var combinedComponents = DateComponents()
            combinedComponents.year = dateComponents.year
            combinedComponents.month = dateComponents.month
            combinedComponents.day = dateComponents.day
            combinedComponents.hour = timeComponents.hour
            combinedComponents.minute = timeComponents.minute
            combinedComponents.second = timeComponents.second
            
            return calendar.date(from: combinedComponents)
        }
        
        return studyDate
    }
    
    /// Formatted study date for display
    @objc public var displayStudyDate: String {
        guard let studyDateTime = studyDateTime else { return "Unknown Date" }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: studyDateTime)
    }
    
    /// Human readable file size
    @objc public var displayFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    /// Study summary description
    @objc public var studySummary: String {
        var components: [String] = []
        
        if let description = studyDescription, !description.isEmpty {
            components.append(description)
        } else if let bodyPart = bodyPartExamined, !bodyPart.isEmpty {
            components.append(bodyPart)
        }
        
        components.append(modality.displayName)
        
        if numberOfImages > 0 {
            components.append("\(numberOfImages) images")
        }
        
        return components.joined(separator: " • ")
    }
    
    // MARK: - Initialization
    
    @objc public init(
        patientName: String,
        patientID: String,
        patientBirthDate: Date? = nil,
        patientSex: PatientSex = .unknown,
        patientAge: String? = nil,
        patientWeight: Double = 0,
        patientSize: Double = 0,
        studyInstanceUID: String,
        studyDate: Date? = nil,
        studyTime: Date? = nil,
        studyDescription: String? = nil,
        accessionNumber: String? = nil,
        modality: DICOMModality = .unknown,
        bodyPartExamined: String? = nil,
        seriesDescription: String? = nil,
        institutionName: String? = nil,
        institutionAddress: String? = nil,
        stationName: String? = nil,
        numberOfImages: Int = 0,
        fileSize: Int64 = 0,
        createdAt: Date = Date(),
        lastAccessedAt: Date? = nil
    ) {
        self.patientName = patientName
        self.patientID = patientID
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.patientAge = patientAge
        self.patientWeight = patientWeight
        self.patientSize = patientSize
        self.studyInstanceUID = studyInstanceUID
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.studyDescription = studyDescription
        self.accessionNumber = accessionNumber
        self.modality = modality
        self.bodyPartExamined = bodyPartExamined
        self.seriesDescription = seriesDescription
        self.institutionName = institutionName
        self.institutionAddress = institutionAddress
        self.stationName = stationName
        self.numberOfImages = numberOfImages
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        super.init()
    }
    
    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case patientName, patientID, patientBirthDate, patientSex, patientAge
        case patientWeight, patientSize, studyInstanceUID, studyDate, studyTime
        case studyDescription, accessionNumber, modality, bodyPartExamined
        case seriesDescription, institutionName, institutionAddress, stationName
        case numberOfImages, fileSize, createdAt, lastAccessedAt
    }
    
    // MARK: - NSObject Overrides for Objective-C Compatibility
    
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PatientModel else { return false }
        return studyInstanceUID == other.studyInstanceUID &&
               patientID == other.patientID
    }
    
    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(studyInstanceUID)
        hasher.combine(patientID)
        return hasher.finalize()
    }
}

// MARK: - Legacy Objective-C Bridge Properties
// For compatibility with existing Objective-C code that expects specific property names

extension PatientModel {
    
    /// Legacy name property for Objective-C compatibility
    @objc public var name: String {
        return patientName
    }
    
    /// Legacy type property for Objective-C compatibility (modality)
    @objc public var type: String {
        return modality.rawStringValue
    }
    
    /// Legacy age property for Objective-C compatibility
    @objc public var age: String {
        return displayAge
    }
    
    /// Legacy number property for Objective-C compatibility (patient ID)
    @objc public var number: String {
        return patientID
    }
    
    /// Legacy sex property for Objective-C compatibility
    @objc public var sex: String {
        return patientSex.rawStringValue
    }
    
    /// Legacy examineTime property for Objective-C compatibility
    @objc public var examineTime: String {
        return displayStudyDate
    }
    
    /// Legacy part property for Objective-C compatibility
    @objc public var part: String {
        return bodyPartExamined ?? "Unknown"
    }
    
    /// Legacy StudyUniqueId property for Objective-C compatibility
    @objc public var StudyUniqueId: String {
        return studyInstanceUID
    }
    
    /// Legacy yiyuan property for Objective-C compatibility (institution)
    @objc public var yiyuan: String {
        return institutionName ?? "Unknown"
    }
    
    /// Create PatientModel from legacy Objective-C data
    @objc public static func fromLegacyData(
        name: String,
        type: String,
        age: String,
        number: String,
        sex: String,
        examineTime: String,
        part: String,
        studyUniqueId: String,
        yiyuan: String
    ) -> PatientModel {
        
        // Parse modality from type string
        let modality = DICOMModality.from(string: type)
        
        // Parse patient sex
        let patientSex = PatientSex.from(string: sex)
        
        return PatientModel(
            patientName: name,
            patientID: number,
            patientSex: patientSex,
            patientAge: age.isEmpty ? nil : age,
            studyInstanceUID: studyUniqueId,
            modality: modality,
            bodyPartExamined: part.isEmpty ? nil : part,
            institutionName: yiyuan.isEmpty ? nil : yiyuan
        )
    }
}

// MARK: - PatientModel Extensions

extension PatientModel {
    
    /// Create a sample patient for testing/demo purposes
    public static var samplePatient: PatientModel {
        return PatientModel(
            patientName: "John Doe",
            patientID: "PAT001",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -45, to: Date()),
            patientSex: .male,
            patientAge: "045Y",
            studyInstanceUID: "1.2.3.4.5.6789",
            studyDate: Date(),
            studyDescription: "Chest CT without contrast",
            modality: .ct,
            bodyPartExamined: "CHEST",
            institutionName: "General Hospital",
            numberOfImages: 150
        )
    }
    
    /// Update last accessed time
    public func withUpdatedAccessTime() -> PatientModel {
        return PatientModel(
            patientName: patientName,
            patientID: patientID,
            patientBirthDate: patientBirthDate,
            patientSex: patientSex,
            patientAge: patientAge,
            patientWeight: patientWeight,
            patientSize: patientSize,
            studyInstanceUID: studyInstanceUID,
            studyDate: studyDate,
            studyTime: studyTime,
            studyDescription: studyDescription,
            accessionNumber: accessionNumber,
            modality: modality,
            bodyPartExamined: bodyPartExamined,
            seriesDescription: seriesDescription,
            institutionName: institutionName,
            institutionAddress: institutionAddress,
            stationName: stationName,
            numberOfImages: numberOfImages,
            fileSize: fileSize,
            createdAt: createdAt,
            lastAccessedAt: Date()
        )
    }
}

// MARK: - Array Extensions

extension Array where Element == PatientModel {
    
    /// Search patients by name, ID, or study description
    public func search(query: String) -> [PatientModel] {
        let lowercasedQuery = query.lowercased()
        return self.filter { patient in
            patient.patientName.lowercased().contains(lowercasedQuery) ||
            patient.patientID.lowercased().contains(lowercasedQuery) ||
            patient.studyDescription?.lowercased().contains(lowercasedQuery) == true ||
            patient.bodyPartExamined?.lowercased().contains(lowercasedQuery) == true
        }
    }
    
    /// Filter patients by modality
    public func filtered(by modality: DICOMModality) -> [PatientModel] {
        return self.filter { $0.modality == modality }
    }
    
    /// Filter patients by sex
    public func filtered(by sex: PatientSex) -> [PatientModel] {
        return self.filter { $0.patientSex == sex }
    }
    
    /// Sort patients by study date (most recent first)
    public func sortedByStudyDate() -> [PatientModel] {
        return self.sorted { lhs, rhs in
            guard let lhsDate = lhs.studyDateTime else { return false }
            guard let rhsDate = rhs.studyDateTime else { return true }
            return lhsDate > rhsDate
        }
    }
    
    /// Sort patients by name
    public func sortedByName() -> [PatientModel] {
        return self.sorted { $0.patientName < $1.patientName }
    }
    
    /// Group patients by modality
    public func groupedByModality() -> [DICOMModality: [PatientModel]] {
        return Dictionary(grouping: self) { $0.modality }
    }
    
    /// Group patients by date
    public func groupedByDate() -> [String: [PatientModel]] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        
        return Dictionary(grouping: self) { patient in
            guard let studyDate = patient.studyDateTime else { return "Unknown Date" }
            return formatter.string(from: studyDate)
        }
    }
}
