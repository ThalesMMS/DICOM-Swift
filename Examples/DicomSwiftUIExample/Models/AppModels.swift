//
//  AppModels.swift
//  DicomSwiftUIExample
//
//  App-level data models for imported studies and file management
//

import Foundation
import DicomCore

// MARK: - DICOMModality Extension

extension DICOMModality {
    /// Display name for the modality (app-level helper)
    var appDisplayName: String {
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
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - PatientSex Extension

extension PatientSex {
    /// Display name for the patient sex (app-level helper)
    var appDisplayName: String {
        switch self {
        case .male: return "M"
        case .female: return "F"
        case .other: return "O"
        case .unknown: return "U"
        @unknown default: return "U"
        }
    }
}

// MARK: - Import Status

/// Status of an imported DICOM study or file
public enum ImportStatus: String, Codable, Sendable {
    /// Import in progress
    case importing
    /// Successfully imported
    case completed
    /// Import failed with error
    case failed
    /// Pending import (queued)
    case pending

    var displayName: String {
        switch self {
        case .importing: return "Importing..."
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .pending: return "Pending"
        }
    }

    var iconName: String {
        switch self {
        case .importing: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "clock.circle"
        }
    }
}

// MARK: - Series Information

/// Lightweight series information for app-level tracking
public struct SeriesInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let seriesInstanceUID: String
    public let seriesNumber: Int
    public let seriesDescription: String?
    public let modality: DICOMModality
    public let numberOfImages: Int
    public let imagePaths: [String]
    public let thumbnailPath: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        seriesInstanceUID: String,
        seriesNumber: Int = 0,
        seriesDescription: String? = nil,
        modality: DICOMModality = .unknown,
        numberOfImages: Int = 0,
        imagePaths: [String] = [],
        thumbnailPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.seriesInstanceUID = seriesInstanceUID
        self.seriesNumber = seriesNumber
        self.seriesDescription = seriesDescription
        self.modality = modality
        self.numberOfImages = numberOfImages
        self.imagePaths = imagePaths
        self.thumbnailPath = thumbnailPath
        self.createdAt = createdAt
    }

    /// Display name for the series
    public var displayName: String {
        if let description = seriesDescription, !description.isEmpty {
            return "Series \(seriesNumber): \(description)"
        }
        return "Series \(seriesNumber)"
    }

    /// Sample series for testing/preview
    public static var sample: SeriesInfo {
        SeriesInfo(
            seriesInstanceUID: "1.2.3.4.5.6789.1",
            seriesNumber: 1,
            seriesDescription: "Chest CT",
            modality: .ct,
            numberOfImages: 150,
            imagePaths: [],
            thumbnailPath: nil
        )
    }
}

// MARK: - Imported Study

/// App-level model for an imported DICOM study
public struct ImportedStudy: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let studyInstanceUID: String
    public let patientName: String
    public let patientID: String
    public let patientSex: PatientSex
    public let patientAge: String?
    public let studyDate: Date?
    public let studyDescription: String?
    public let modality: DICOMModality
    public let bodyPartExamined: String?
    public let institutionName: String?
    public let series: [SeriesInfo]
    public let importStatus: ImportStatus
    public let importDate: Date
    public let lastAccessedAt: Date?
    public let storagePath: String
    public let fileSize: Int64

    public init(
        id: UUID = UUID(),
        studyInstanceUID: String,
        patientName: String,
        patientID: String,
        patientSex: PatientSex = .unknown,
        patientAge: String? = nil,
        studyDate: Date? = nil,
        studyDescription: String? = nil,
        modality: DICOMModality = .unknown,
        bodyPartExamined: String? = nil,
        institutionName: String? = nil,
        series: [SeriesInfo] = [],
        importStatus: ImportStatus = .pending,
        importDate: Date = Date(),
        lastAccessedAt: Date? = nil,
        storagePath: String = "",
        fileSize: Int64 = 0
    ) {
        self.id = id
        self.studyInstanceUID = studyInstanceUID
        self.patientName = patientName
        self.patientID = patientID
        self.patientSex = patientSex
        self.patientAge = patientAge
        self.studyDate = studyDate
        self.studyDescription = studyDescription
        self.modality = modality
        self.bodyPartExamined = bodyPartExamined
        self.institutionName = institutionName
        self.series = series
        self.importStatus = importStatus
        self.importDate = importDate
        self.lastAccessedAt = lastAccessedAt
        self.storagePath = storagePath
        self.fileSize = fileSize
    }

    // MARK: - Computed Properties

    /// Display name for the patient
    public var displayPatientName: String {
        patientName.isEmpty ? "Unknown Patient" : patientName
    }

    /// Display age string
    public var displayAge: String {
        patientAge ?? "Unknown"
    }

    /// Formatted study date
    public var displayStudyDate: String {
        guard let date = studyDate else { return "Unknown Date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Human-readable file size
    public var displayFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    /// Total number of images across all series
    public var totalImageCount: Int {
        series.reduce(0) { $0 + $1.numberOfImages }
    }

    /// Study summary for display
    public var studySummary: String {
        var components: [String] = []

        if let description = studyDescription, !description.isEmpty {
            components.append(description)
        } else if let bodyPart = bodyPartExamined, !bodyPart.isEmpty {
            components.append(bodyPart)
        }

        components.append(modality.appDisplayName)

        if totalImageCount > 0 {
            components.append("\(totalImageCount) images")
        }

        if series.count > 1 {
            components.append("\(series.count) series")
        }

        return components.joined(separator: " • ")
    }

    // MARK: - Factory Methods

    /// Create ImportedStudy from PatientModel
    public static func from(patientModel: PatientModel, storagePath: String, series: [SeriesInfo] = []) -> ImportedStudy {
        ImportedStudy(
            studyInstanceUID: patientModel.studyInstanceUID,
            patientName: patientModel.patientName,
            patientID: patientModel.patientID,
            patientSex: patientModel.patientSex,
            patientAge: patientModel.patientAge,
            studyDate: patientModel.studyDate,
            studyDescription: patientModel.studyDescription,
            modality: patientModel.modality,
            bodyPartExamined: patientModel.bodyPartExamined,
            institutionName: patientModel.institutionName,
            series: series,
            importStatus: .completed,
            importDate: patientModel.createdAt,
            lastAccessedAt: patientModel.lastAccessedAt,
            storagePath: storagePath,
            fileSize: patientModel.fileSize
        )
    }

    /// Update access time
    public func withUpdatedAccessTime() -> ImportedStudy {
        ImportedStudy(
            id: id,
            studyInstanceUID: studyInstanceUID,
            patientName: patientName,
            patientID: patientID,
            patientSex: patientSex,
            patientAge: patientAge,
            studyDate: studyDate,
            studyDescription: studyDescription,
            modality: modality,
            bodyPartExamined: bodyPartExamined,
            institutionName: institutionName,
            series: series,
            importStatus: importStatus,
            importDate: importDate,
            lastAccessedAt: Date(),
            storagePath: storagePath,
            fileSize: fileSize
        )
    }

    /// Update import status
    public func withStatus(_ status: ImportStatus) -> ImportedStudy {
        ImportedStudy(
            id: id,
            studyInstanceUID: studyInstanceUID,
            patientName: patientName,
            patientID: patientID,
            patientSex: patientSex,
            patientAge: patientAge,
            studyDate: studyDate,
            studyDescription: studyDescription,
            modality: modality,
            bodyPartExamined: bodyPartExamined,
            institutionName: institutionName,
            series: series,
            importStatus: status,
            importDate: importDate,
            lastAccessedAt: lastAccessedAt,
            storagePath: storagePath,
            fileSize: fileSize
        )
    }

    // MARK: - Sample Data

    /// Sample study for testing/preview
    public static var sample: ImportedStudy {
        ImportedStudy(
            studyInstanceUID: "1.2.3.4.5.6789",
            patientName: "Doe^John",
            patientID: "PAT001",
            patientSex: .male,
            patientAge: "045Y",
            studyDate: Date(),
            studyDescription: "Chest CT without contrast",
            modality: .ct,
            bodyPartExamined: "CHEST",
            institutionName: "General Hospital",
            series: [.sample],
            importStatus: .completed,
            storagePath: "/path/to/study",
            fileSize: 1024 * 1024 * 50
        )
    }

    /// Multiple sample studies for testing
    public static var samples: [ImportedStudy] {
        [
            ImportedStudy(
                studyInstanceUID: "1.2.3.4.5.001",
                patientName: "Doe^John",
                patientID: "PAT001",
                patientSex: .male,
                patientAge: "045Y",
                studyDate: Date(),
                studyDescription: "Chest CT",
                modality: .ct,
                bodyPartExamined: "CHEST",
                series: [.sample],
                importStatus: .completed,
                storagePath: "/path/to/study1",
                fileSize: 1024 * 1024 * 50
            ),
            ImportedStudy(
                studyInstanceUID: "1.2.3.4.5.002",
                patientName: "Smith^Jane",
                patientID: "PAT002",
                patientSex: .female,
                patientAge: "032Y",
                studyDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()),
                studyDescription: "Brain MRI",
                modality: .mr,
                bodyPartExamined: "BRAIN",
                series: [.sample],
                importStatus: .completed,
                storagePath: "/path/to/study2",
                fileSize: 1024 * 1024 * 80
            ),
            ImportedStudy(
                studyInstanceUID: "1.2.3.4.5.003",
                patientName: "Johnson^Robert",
                patientID: "PAT003",
                patientSex: .male,
                patientAge: "028Y",
                studyDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()),
                studyDescription: "Chest X-Ray",
                modality: .dx,
                bodyPartExamined: "CHEST",
                series: [.sample],
                importStatus: .completed,
                storagePath: "/path/to/study3",
                fileSize: 1024 * 1024 * 5
            )
        ]
    }
}

// MARK: - Array Extensions

extension Array where Element == ImportedStudy {

    /// Search studies by patient name, ID, or study description
    public func search(query: String) -> [ImportedStudy] {
        let lowercasedQuery = query.lowercased()
        return self.filter { study in
            study.patientName.lowercased().contains(lowercasedQuery) ||
            study.patientID.lowercased().contains(lowercasedQuery) ||
            study.studyDescription?.lowercased().contains(lowercasedQuery) == true ||
            study.bodyPartExamined?.lowercased().contains(lowercasedQuery) == true
        }
    }

    /// Filter studies by modality
    public func filtered(by modality: DICOMModality) -> [ImportedStudy] {
        self.filter { $0.modality == modality }
    }

    /// Filter studies by import status
    public func filtered(by status: ImportStatus) -> [ImportedStudy] {
        self.filter { $0.importStatus == status }
    }

    /// Sort studies by study date (most recent first)
    public func sortedByStudyDate() -> [ImportedStudy] {
        self.sorted { lhs, rhs in
            guard let lhsDate = lhs.studyDate else { return false }
            guard let rhsDate = rhs.studyDate else { return true }
            return lhsDate > rhsDate
        }
    }

    /// Sort studies by import date (most recent first)
    public func sortedByImportDate() -> [ImportedStudy] {
        self.sorted { $0.importDate > $1.importDate }
    }

    /// Sort studies by patient name
    public func sortedByPatientName() -> [ImportedStudy] {
        self.sorted { $0.patientName < $1.patientName }
    }

    /// Group studies by modality
    public func groupedByModality() -> [DICOMModality: [ImportedStudy]] {
        Dictionary(grouping: self) { $0.modality }
    }

    /// Group studies by import date
    public func groupedByImportDate() -> [String: [ImportedStudy]] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        return Dictionary(grouping: self) { study in
            formatter.string(from: study.importDate)
        }
    }

    /// Get only completed studies
    public var completed: [ImportedStudy] {
        self.filter { $0.importStatus == .completed }
    }

    /// Get only failed studies
    public var failed: [ImportedStudy] {
        self.filter { $0.importStatus == .failed }
    }

    /// Get only pending or importing studies
    public var inProgress: [ImportedStudy] {
        self.filter { $0.importStatus == .importing || $0.importStatus == .pending }
    }
}

// MARK: - Import Task

/// Represents an active import task
public struct ImportTask: Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let fileURL: URL
    public var status: ImportStatus
    public var progress: Double
    public var error: String?
    public let startedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        fileName: String,
        fileURL: URL,
        status: ImportStatus = .pending,
        progress: Double = 0.0,
        error: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.status = status
        self.progress = progress
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// Display name for the task
    public var displayName: String {
        fileName
    }

    /// Formatted progress percentage
    public var displayProgress: String {
        String(format: "%.0f%%", progress * 100)
    }
}
