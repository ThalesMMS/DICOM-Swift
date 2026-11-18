//
//  FileImportServiceProtocol.swift
//  DicomCore
//
//  Protocol abstraction for DICOM file import operations. Defines the public API for importing
//  DICOM files and ZIP archives, handling file extraction, and managing secure file storage.
//  Implementations must support async operations for file I/O and provide appropriate user feedback
//  during long-running operations.
//
//  Thread Safety:
//
//  All protocol methods should be called from the MainActor context for UI-related operations.
//  Implementations handle file system synchronization internally.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - Result Types

/// Result of a file import operation
public struct ImportResult: Sendable {
    /// Whether the import was successful
    public let success: Bool
    /// Path to the imported file if successful
    public let filePath: String?
    /// Error that occurred during import, if any
    public let error: Error?

    public init(success: Bool, filePath: String?, error: Error?) {
        self.success = success
        self.filePath = filePath
        self.error = error
    }
}

/// Result of a ZIP extraction operation
public struct ExtractResult: Sendable {
    /// Number of files successfully extracted
    public let extractedCount: Int
    /// Errors encountered during extraction
    public let errors: [Error]
    /// Paths to extracted files
    public let paths: [String]

    public init(extractedCount: Int, errors: [Error], paths: [String]) {
        self.extractedCount = extractedCount
        self.errors = errors
        self.paths = paths
    }
}

// MARK: - Protocol

/// Protocol defining the public API for DICOM file import operations.
/// Implementations handle importing DICOM files and ZIP archives,
/// extracting compressed files, validating DICOM data, organizing
/// files by study/series hierarchy, and providing user feedback.
///
/// **Thread Safety:** All methods should be called from MainActor
/// context for proper UI integration. File system operations are
/// synchronized internally by the implementation.
@MainActor
public protocol FileImportServiceProtocol {

    // MARK: - File Import

    /// Import a DICOM file from the specified URL.
    /// Validates the file, extracts DICOM metadata, and moves it to
    /// secure storage organized by study/series hierarchy.
    /// - Parameters:
    ///   - url: URL of the file to import
    ///   - silent: If true, suppresses UI feedback (default: false)
    /// - Returns: Import result with success status and file path
    /// - Throws: Error if import operation fails
    func importFile(from url: URL, silent: Bool) async throws -> ImportResult

    /// Extract ZIP archive and import contained DICOM files.
    /// Recursively processes nested ZIP files and subdirectories,
    /// validates each file as DICOM, and organizes in secure storage.
    /// - Parameters:
    ///   - url: URL of the ZIP file to extract
    ///   - silent: If true, suppresses UI feedback (default: false)
    /// - Returns: Extraction result with count of imported files
    /// - Throws: Error if extraction operation fails
    func extractZip(at url: URL, silent: Bool) async throws -> ExtractResult

    /// Handle file import with automatic type detection.
    /// Detects whether the file is a ZIP archive or DICOM file
    /// and processes accordingly. Provides progress feedback and
    /// posts notification when complete.
    /// - Parameters:
    ///   - url: URL of the file to import
    ///   - silent: If true, suppresses UI feedback (default: false)
    /// - Returns: True if import was successful, false otherwise
    func handleFileImport(url: URL, silent: Bool) async -> Bool
}
