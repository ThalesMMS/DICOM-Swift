//
//  CLIError.swift
//  dicomtool
//
//  Command-line interface error handling system.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - CLI Error Types

/// Error types for command-line interface operations.
///
/// ## Overview
///
/// ``CLIError`` provides a comprehensive error handling system for CLI operations including
/// argument parsing, file I/O, output formatting, and command execution. Each error case
/// includes detailed context to help users diagnose and resolve issues quickly.
///
/// The error system conforms to Swift's `LocalizedError` protocol, providing human-readable
/// descriptions and recovery suggestions. All errors are also `Equatable` for testing.
///
/// ## Error Categories
///
/// Errors are organized into five main categories:
///
/// - **Argument Errors**: Invalid arguments, missing required values
/// - **File Operations**: File access, directory operations, path resolution
/// - **Output Errors**: Formatting failures, write errors
/// - **Validation Errors**: Input validation, DICOM file validation
/// - **Runtime Errors**: Execution failures, system errors
///
/// ## Usage
///
/// Handle errors using Swift's do-catch syntax:
///
/// ```swift
/// do {
///     let output = try formatter.format(data, as: .json)
///     print(output)
/// } catch CLIError.invalidFormat(let format) {
///     print("Unsupported format: \(format)")
/// } catch CLIError.fileNotReadable(let path, let reason) {
///     print("Cannot read \(path): \(reason)")
/// } catch {
///     print("Error: \(error.localizedDescription)")
/// }
/// ```
///
/// ## Topics
///
/// ### Argument Errors
///
/// - ``invalidArgument(argument:value:reason:)``
/// - ``missingRequiredArgument(argument:)``
/// - ``conflictingArguments(arguments:)``
///
/// ### File Operation Errors
///
/// - ``fileNotReadable(path:reason:)``
/// - ``fileNotWritable(path:reason:)``
/// - ``directoryNotFound(path:)``
/// - ``invalidPath(path:reason:)``
/// - ``outputFileExists(path:)``
///
/// ### Output Errors
///
/// - ``invalidFormat(format:supportedFormats:)``
/// - ``outputGenerationFailed(operation:reason:)``
/// - ``encodingFailed(reason:)``
///
/// ### Validation Errors
///
/// - ``validationFailed(file:errors:)``
/// - ``invalidDICOMFile(path:reason:)``
/// - ``emptyInputSet``
///
/// ### Runtime Errors
///
/// - ``commandExecutionFailed(command:reason:)``
/// - ``insufficientPermissions(operation:)``
/// - ``operationCancelled``
/// - ``unknown(underlyingError:)``
///
/// ### Error Metadata
///
/// - ``severity``
/// - ``category``
/// - ``errorDescription``
/// - ``recoverySuggestion``
public enum CLIError: Error, LocalizedError, Equatable, Sendable {

    // MARK: - Argument Errors
    case invalidArgument(argument: String, value: String, reason: String)
    case missingRequiredArgument(argument: String)
    case conflictingArguments(arguments: [String])

    // MARK: - File Operation Errors
    case fileNotReadable(path: String, reason: String)
    case fileNotWritable(path: String, reason: String)
    case directoryNotFound(path: String)
    case invalidPath(path: String, reason: String)
    case outputFileExists(path: String)

    // MARK: - Output Errors
    case invalidFormat(format: String, supportedFormats: [String])
    case outputGenerationFailed(operation: String, reason: String)
    case encodingFailed(reason: String)

    // MARK: - Validation Errors
    case validationFailed(file: String, errors: [String])
    case invalidDICOMFile(path: String, reason: String)
    case emptyInputSet

    // MARK: - Runtime Errors
    case commandExecutionFailed(command: String, reason: String)
    case insufficientPermissions(operation: String)
    case operationCancelled
    case unknown(underlyingError: String)

    // MARK: - LocalizedError Implementation

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let argument, let value, let reason):
            return "Invalid argument '\(argument)' with value '\(value)': \(reason)"
        case .missingRequiredArgument(let argument):
            return "Missing required argument: \(argument)"
        case .conflictingArguments(let arguments):
            return "Conflicting arguments: \(arguments.joined(separator: ", "))"
        case .fileNotReadable(let path, let reason):
            return "Cannot read file at '\(path)': \(reason)"
        case .fileNotWritable(let path, let reason):
            return "Cannot write file to '\(path)': \(reason)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .invalidPath(let path, let reason):
            return "Invalid path '\(path)': \(reason)"
        case .outputFileExists(let path):
            return "Output file already exists: \(path)"
        case .invalidFormat(let format, let supportedFormats):
            return "Invalid format '\(format)'. Supported formats: \(supportedFormats.joined(separator: ", "))"
        case .outputGenerationFailed(let operation, let reason):
            return "Failed to generate output for '\(operation)': \(reason)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .validationFailed(let file, let errors):
            return "Validation failed for '\(file)': \(errors.joined(separator: "; "))"
        case .invalidDICOMFile(let path, let reason):
            return "Invalid DICOM file at '\(path)': \(reason)"
        case .emptyInputSet:
            return "No input files found matching the specified criteria"
        case .commandExecutionFailed(let command, let reason):
            return "Command '\(command)' failed: \(reason)"
        case .insufficientPermissions(let operation):
            return "Insufficient permissions for operation: \(operation)"
        case .operationCancelled:
            return "Operation was cancelled by user"
        case .unknown(let underlyingError):
            return "Unknown error: \(underlyingError)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidArgument:
            return "Check the command usage with --help and provide a valid value."
        case .missingRequiredArgument:
            return "Provide the required argument. Use --help to see all required arguments."
        case .conflictingArguments:
            return "Use only one of the conflicting arguments. See --help for details."
        case .fileNotReadable:
            return "Ensure the file exists and you have read permissions."
        case .fileNotWritable:
            return "Check that the directory exists and you have write permissions."
        case .directoryNotFound:
            return "Create the directory or specify a valid existing directory."
        case .invalidPath:
            return "Provide a valid file system path."
        case .outputFileExists:
            return "Use --force to overwrite, or specify a different output path."
        case .invalidFormat:
            return "Use one of the supported formats."
        case .outputGenerationFailed:
            return "Check that the input file is valid and not corrupted."
        case .encodingFailed:
            return "Ensure the data can be properly encoded in the requested format."
        case .validationFailed:
            return "Fix the validation errors or use --skip-validation to bypass checks."
        case .invalidDICOMFile:
            return "Ensure the file is a valid DICOM file and not corrupted."
        case .emptyInputSet:
            return "Check your file path or glob pattern and ensure matching files exist."
        case .commandExecutionFailed:
            return "Check the command arguments and try again."
        case .insufficientPermissions:
            return "Run with appropriate permissions or change file/directory permissions."
        case .operationCancelled:
            return nil
        case .unknown:
            return "Please report this issue if it persists."
        }
    }

    // MARK: - Error Metadata

    /// Severity level for the error.
    public var severity: ErrorSeverity {
        switch self {
        case .invalidArgument, .missingRequiredArgument, .conflictingArguments,
             .invalidFormat, .invalidPath, .emptyInputSet:
            return .warning
        case .fileNotReadable, .fileNotWritable, .directoryNotFound,
             .outputFileExists, .validationFailed, .invalidDICOMFile:
            return .error
        case .outputGenerationFailed, .encodingFailed, .commandExecutionFailed,
             .insufficientPermissions:
            return .error
        case .operationCancelled:
            return .info
        case .unknown:
            return .critical
        }
    }

    /// Category for the error.
    public var category: ErrorCategory {
        switch self {
        case .invalidArgument, .missingRequiredArgument, .conflictingArguments:
            return .arguments
        case .fileNotReadable, .fileNotWritable, .directoryNotFound,
             .invalidPath, .outputFileExists:
            return .fileIO
        case .invalidFormat, .outputGenerationFailed, .encodingFailed:
            return .output
        case .validationFailed, .invalidDICOMFile, .emptyInputSet:
            return .validation
        case .commandExecutionFailed, .insufficientPermissions, .operationCancelled, .unknown:
            return .runtime
        }
    }
}

// MARK: - Supporting Types

/// Severity levels for CLI errors.
public enum ErrorSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
    case critical
}

/// Categories for CLI errors.
public enum ErrorCategory: String, Codable, Sendable {
    case arguments
    case fileIO
    case output
    case validation
    case runtime
}
