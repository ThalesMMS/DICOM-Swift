//
//  DICOMError.swift
//  DicomCore
//
//  Modern Swift error handling system for DICOM operations.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - DICOM Error Types

/// Comprehensive error types for DICOM operations.
///
/// ## Overview
///
/// ``DICOMError`` provides a type-safe, Swift-native error handling system for all DICOM-related
/// operations. Each error case includes associated values with detailed context about the failure,
/// making it easy to diagnose issues and provide helpful feedback to users.
///
/// The error system conforms to Swift's `LocalizedError` protocol, providing human-readable
/// descriptions and recovery suggestions automatically. All errors are also `Equatable` for
/// easy testing and comparison.
///
/// ## Error Categories
///
/// Errors are organized into five main categories:
///
/// - **File Operations**: File not found, read errors, format issues
/// - **DICOM Parsing**: Invalid format, missing tags, unsupported features
/// - **Medical Data**: Invalid window/level, patient data issues
/// - **Network**: Connection issues, server errors, authentication
/// - **System**: Memory allocation, image processing failures
///
/// ## Usage
///
/// Handle errors using Swift's do-catch syntax:
///
/// ```swift
/// do {
///     let decoder = try DCMDecoder(contentsOf: url)
///     let pixels = decoder.getPixels16()
/// } catch DICOMError.fileNotFound(let path) {
///     print("File not found: \(path)")
/// } catch DICOMError.invalidDICOMFormat(let reason) {
///     print("Invalid DICOM: \(reason)")
/// } catch DICOMError.unsupportedTransferSyntax(let syntax) {
///     print("Unsupported compression: \(syntax)")
/// } catch {
///     print("Error: \(error.localizedDescription)")
/// }
/// ```
///
/// Access error metadata for logging or analytics:
///
/// ```swift
/// let error = DICOMError.memoryAllocationFailed(requestedSize: 1_000_000_000)
/// print("Severity: \(error.severity)")  // .critical
/// print("Category: \(error.category)")  // .system
/// print("Suggestion: \(error.recoverySuggestion ?? "")")
/// ```
///
/// ## Topics
///
/// ### File Operation Errors
///
/// - ``fileNotFound(path:)``
/// - ``fileReadError(path:underlyingError:)``
/// - ``invalidFileFormat(path:expectedFormat:)``
/// - ``fileCorrupted(path:reason:)``
///
/// ### DICOM Parsing Errors
///
/// - ``invalidDICOMFormat(reason:)``
/// - ``missingRequiredTag(tag:description:)``
/// - ``unsupportedTransferSyntax(syntax:)``
/// - ``invalidPixelData(reason:)``
/// - ``bufferOverflow(operation:offset:available:)``
/// - ``invalidOffset(offset:fileSize:context:)``
/// - ``invalidLength(requested:available:context:)``
/// - ``excessiveAllocation(requested:limit:context:)``
///
/// ### Medical Data Errors
///
/// - ``invalidWindowLevel(window:level:reason:)``
/// - ``invalidPatientData(field:value:reason:)``
/// - ``missingStudyInformation(missingFields:)``
/// - ``invalidModality(modality:)``
///
/// ### Network Errors
///
/// - ``networkUnavailable``
/// - ``serverError(statusCode:message:)``
/// - ``authenticationFailed(reason:)``
///
/// ### System Errors
///
/// - ``memoryAllocationFailed(requestedSize:)``
/// - ``imageProcessingFailed(operation:reason:)``
/// - ``unknown(underlyingError:)``
///
/// ### Error Metadata
///
/// - ``severity``
/// - ``category``
/// - ``errorDescription``
/// - ``recoverySuggestion``
public enum DICOMError: Error, LocalizedError, Equatable {
    
    // MARK: - File Operation Errors
    case fileNotFound(path: String)
    case fileReadError(path: String, underlyingError: String)
    case invalidFileFormat(path: String, expectedFormat: String)
    case fileCorrupted(path: String, reason: String)
    
    // MARK: - DICOM Parsing Errors
    case invalidDICOMFormat(reason: String)
    case missingRequiredTag(tag: String, description: String)
    case unsupportedTransferSyntax(syntax: String)
    case invalidPixelData(reason: String)
    case bufferOverflow(operation: String, offset: Int64, available: Int64)
    case invalidOffset(offset: Int64, fileSize: Int64, context: String)
    case invalidLength(requested: Int64, available: Int64, context: String)
    case excessiveAllocation(requested: Int64, limit: Int64, context: String)
    
    // MARK: - Medical Data Errors
    case invalidWindowLevel(window: Double, level: Double, reason: String)
    case invalidPatientData(field: String, value: String, reason: String)
    case missingStudyInformation(missingFields: [String])
    case invalidModality(modality: String)
    
    // MARK: - Network Errors
    case networkUnavailable
    case serverError(statusCode: Int, message: String)
    case authenticationFailed(reason: String)
    
    // MARK: - System Errors
    case memoryAllocationFailed(requestedSize: Int64)
    case imageProcessingFailed(operation: String, reason: String)
    case unknown(underlyingError: String)
    
    // MARK: - LocalizedError Implementation
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "DICOM file not found at path: \(path)"
        case .fileReadError(let path, let error):
            return "Failed to read DICOM file at \(path): \(error)"
        case .invalidFileFormat(let path, let expectedFormat):
            return "Invalid file format at \(path). Expected: \(expectedFormat)"
        case .fileCorrupted(let path, let reason):
            return "File corrupted at \(path): \(reason)"
        case .invalidDICOMFormat(let reason):
            return "Invalid DICOM format: \(reason)"
        case .missingRequiredTag(let tag, let description):
            return "Missing required DICOM tag \(tag): \(description)"
        case .unsupportedTransferSyntax(let syntax):
            return "Unsupported transfer syntax: \(syntax)"
        case .invalidPixelData(let reason):
            return "Invalid pixel data: \(reason)"
        case .bufferOverflow(let operation, let offset, let available):
            return "Buffer overflow during \(operation): attempted to read at offset \(offset) but only \(available) bytes available"
        case .invalidOffset(let offset, let fileSize, let context):
            return "Invalid offset \(offset) in \(context): exceeds file size of \(fileSize) bytes"
        case .invalidLength(let requested, let available, let context):
            return "Invalid length in \(context): requested \(requested) bytes but only \(available) bytes available"
        case .excessiveAllocation(let requested, let limit, let context):
            return "Excessive memory allocation in \(context): requested \(requested) bytes exceeds safety limit of \(limit) bytes"
        case .invalidWindowLevel(let window, let level, let reason):
            return "Invalid window/level settings (W:\(window) L:\(level)): \(reason)"
        case .invalidPatientData(let field, let value, let reason):
            return "Invalid patient data - \(field): '\(value)' - \(reason)"
        case .missingStudyInformation(let missingFields):
            return "Missing study information: \(missingFields.joined(separator: ", "))"
        case .invalidModality(let modality):
            return "Invalid or unsupported modality: \(modality)"
        case .networkUnavailable:
            return "Network connection unavailable"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .memoryAllocationFailed(let requestedSize):
            return "Memory allocation failed for \(requestedSize) bytes"
        case .imageProcessingFailed(let operation, let reason):
            return "Image processing failed during \(operation): \(reason)"
        case .unknown(let underlyingError):
            return "Unknown error: \(underlyingError)"
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .fileNotFound:
            return "Please check the file path and ensure the file exists."
        case .fileReadError, .fileCorrupted:
            return "Try opening a different DICOM file or check file permissions."
        case .invalidFileFormat:
            return "Please select a valid DICOM file (.dcm, .dicom)."
        case .invalidDICOMFormat, .missingRequiredTag:
            return "This file may not be a valid DICOM image or may be corrupted."
        case .bufferOverflow, .invalidOffset, .invalidLength, .excessiveAllocation:
            return "This file appears to be malformed or corrupted. Try opening a different file."
        case .unsupportedTransferSyntax:
            return "This DICOM file uses an unsupported format. Try converting it first."
        case .invalidWindowLevel:
            return "Please enter valid window/level values or select a preset."
        case .networkUnavailable:
            return "Please check your internet connection and try again."
        case .serverError:
            return "Please try again later or contact your system administrator."
        case .memoryAllocationFailed:
            return "Close other applications to free up memory and try again."
        default:
            return "Please try again or contact support if the problem persists."
        }
    }
}

// MARK: - Error Classification Enums

/// Severity levels for DICOM errors.
///
/// ## Overview
///
/// ``ErrorSeverity`` classifies errors by their impact level, helping applications prioritize
/// error handling and user notifications. Severity levels range from warnings (non-critical issues
/// that may allow continued operation) to critical errors (serious failures requiring immediate
/// attention).
///
/// Access the severity level of any ``DICOMError`` via its ``DICOMError/severity`` property.
///
/// ## Usage
///
/// ```swift
/// do {
///     try processFile(url)
/// } catch let error as DICOMError {
///     switch error.severity {
///     case .warning:
///         logWarning(error.localizedDescription)
///     case .error:
///         showUserAlert(error.localizedDescription)
///     case .critical:
///         emergencyShutdown(error.localizedDescription)
///     }
/// }
/// ```
public enum ErrorSeverity: String, CaseIterable {
    /// Non-critical issue that may allow continued operation
    case warning = "Warning"

    /// Standard error requiring user attention
    case error = "Error"

    /// Critical failure requiring immediate action
    case critical = "Critical"
}

/// Categories for DICOM error types.
///
/// ## Overview
///
/// ``ErrorCategory`` groups errors by their functional domain, making it easier to organize
/// error handling logic and provide context-specific recovery strategies. Categories include
/// file operations, DICOM parsing, medical data validation, network operations, and system
/// resources.
///
/// Access the category of any ``DICOMError`` via its ``DICOMError/category`` property.
///
/// ## Usage
///
/// ```swift
/// do {
///     try loadDicomFile(url)
/// } catch let error as DICOMError {
///     switch error.category {
///     case .file:
///         handleFileError(error)
///     case .dicom:
///         handleParsingError(error)
///     case .medical:
///         handleMedicalDataError(error)
///     case .network:
///         handleNetworkError(error)
///     case .system:
///         handleSystemError(error)
///     }
/// }
/// ```
public enum ErrorCategory: String, CaseIterable {
    /// File system operations (read, write, access)
    case file = "File Operation"

    /// DICOM format parsing and validation
    case dicom = "DICOM Processing"

    /// Medical data validation and constraints
    case medical = "Medical Data"

    /// Network communication and authentication
    case network = "Network"

    /// System resources and image processing
    case system = "System"
}

// MARK: - DICOMError Extensions

extension DICOMError {
    
    // MARK: - Error Classification
    
    /// Severity level of the error
    public var severity: ErrorSeverity {
        switch self {
        case .fileNotFound, .invalidFileFormat:
            return .warning
        case .networkUnavailable:
            return .error
        case .memoryAllocationFailed, .bufferOverflow, .excessiveAllocation:
            return .critical
        case .invalidOffset, .invalidLength:
            return .error
        default:
            return .error
        }
    }
    
    /// Category classification of the error
    public var category: ErrorCategory {
        switch self {
        case .fileNotFound, .fileReadError, .invalidFileFormat, .fileCorrupted:
            return .file
        case .invalidDICOMFormat, .missingRequiredTag, .unsupportedTransferSyntax, .invalidPixelData, .bufferOverflow, .invalidOffset, .invalidLength, .excessiveAllocation:
            return .dicom
        case .invalidWindowLevel, .invalidPatientData, .missingStudyInformation, .invalidModality:
            return .medical
        case .networkUnavailable, .serverError, .authenticationFailed:
            return .network
        case .memoryAllocationFailed, .imageProcessingFailed, .unknown:
            return .system
        }
    }
}

// MARK: - Objective-C Bridge

@objc public class DICOMErrorObjC: NSError, @unchecked Sendable {
    private let swiftError: DICOMError

    public override class var supportsSecureCoding: Bool {
        true
    }
    
    public init(from swiftError: DICOMError) {
        self.swiftError = swiftError
        super.init(
            domain: "com.dicomviewer.error",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: swiftError.localizedDescription,
                NSLocalizedRecoverySuggestionErrorKey: swiftError.recoverySuggestion ?? "Try again"
            ]
        )
    }
    
    required init?(coder: NSCoder) {
        swiftError = .unknown(underlyingError: "DICOMErrorObjC decoding is unsupported")
        super.init(coder: coder)
    }
}
