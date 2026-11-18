//
//  OutputFormatter.swift
//  dicomtool
//
//  Utility for formatting CLI output in various formats.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import ArgumentParser

// MARK: - Output Format Types

/// Supported output formats for CLI commands.
public enum OutputFormat: String, CaseIterable, Codable, Sendable, ExpressibleByArgument {
    case text
    case json

    /// Human-readable description of the format.
    public var description: String {
        switch self {
        case .text:
            return "Plain text (human-readable)"
        case .json:
            return "JSON (machine-readable)"
        }
    }
}

// MARK: - Output Formatter

/// Utility for formatting CLI output in text or JSON format.
///
/// ## Overview
///
/// ``OutputFormatter`` provides a consistent way to format command output across all CLI
/// commands. It supports both human-readable text output and machine-readable JSON output
/// for scripting and automation workflows.
///
/// ## Usage
///
/// Create a formatter instance and use it to format various types of output:
///
/// ```swift
/// let formatter = OutputFormatter(format: .json, prettyPrint: true)
///
/// // Format metadata dictionary
/// let metadata = ["PatientName": "John Doe", "Modality": "CT"]
/// let output = try formatter.formatMetadata(metadata)
/// print(output)
///
/// // Format validation results
/// let results = ValidationResult(isValid: true, errors: [], warnings: [])
/// let output = try formatter.formatValidation(results)
/// print(output)
/// ```
///
/// ## Topics
///
/// ### Creating Formatters
///
/// - ``init(format:prettyPrint:colorize:)``
///
/// ### Formatting Methods
///
/// - ``formatMetadata(_:title:)``
/// - ``formatValidation(_:)``
/// - ``formatError(_:)``
/// - ``formatSuccess(_:)``
/// - ``formatJSON(_:)``
/// - ``formatTable(headers:rows:)``
///
/// ### Properties
///
/// - ``format``
/// - ``prettyPrint``
/// - ``colorize``
public struct OutputFormatter {

    // MARK: - Properties

    /// The output format to use.
    public let format: OutputFormat

    /// Whether to pretty-print JSON output.
    public let prettyPrint: Bool

    /// Whether to use ANSI color codes in text output.
    public let colorize: Bool

    // MARK: - Initialization

    /// Creates a new output formatter.
    ///
    /// - Parameters:
    ///   - format: The output format (text or JSON).
    ///   - prettyPrint: Whether to pretty-print JSON output (default: true).
    ///   - colorize: Whether to colorize text output (default: true for text, false for JSON).
    public init(format: OutputFormat, prettyPrint: Bool = true, colorize: Bool? = nil) {
        self.format = format
        self.prettyPrint = prettyPrint
        self.colorize = colorize ?? (format == .text)
    }

    // MARK: - Formatting Methods

    /// Formats a metadata dictionary.
    ///
    /// - Parameters:
    ///   - metadata: Dictionary of metadata key-value pairs.
    ///   - title: Optional title for the output.
    /// - Returns: Formatted string representation.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if JSON encoding fails.
    public func formatMetadata(_ metadata: [String: String], title: String? = nil) throws -> String {
        switch format {
        case .text:
            var output = ""
            if let title = title {
                output += formatHeader(title) + "\n"
            }
            let maxKeyLength = metadata.keys.map { $0.count }.max() ?? 0
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                let paddedKey = key.padding(toLength: maxKeyLength, withPad: " ", startingAt: 0)
                output += colorize(paddedKey, color: .cyan) + ": " + value + "\n"
            }
            return output
        case .json:
            return try formatJSON(metadata)
        }
    }

    /// Formats validation results.
    ///
    /// - Parameter result: Validation result containing validity status, errors, and warnings.
    /// - Returns: Formatted string representation.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if JSON encoding fails.
    public func formatValidation(_ result: ValidationResult) throws -> String {
        switch format {
        case .text:
            var output = ""
            if result.isValid {
                output += try formatSuccess("✓ Validation passed") + "\n"
            } else {
                output += try formatError("✗ Validation failed") + "\n"
            }
            if !result.errors.isEmpty {
                output += "\n" + formatHeader("Errors") + "\n"
                for (index, error) in result.errors.enumerated() {
                    output += "  \(index + 1). " + colorize(error, color: .red) + "\n"
                }
            }
            if !result.warnings.isEmpty {
                output += "\n" + formatHeader("Warnings") + "\n"
                for (index, warning) in result.warnings.enumerated() {
                    output += "  \(index + 1). " + colorize(warning, color: .yellow) + "\n"
                }
            }
            return output
        case .json:
            return try formatJSON(result)
        }
    }

    /// Formats an error message.
    ///
    /// - Parameter message: Error message to format.
    /// - Returns: Formatted error string.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if JSON encoding fails.
    public func formatError(_ message: String) throws -> String {
        switch format {
        case .text:
            return colorize("ERROR: ", color: .red) + message
        case .json:
            return try formatJSON(["error": message])
        }
    }

    /// Formats a success message.
    ///
    /// - Parameter message: Success message to format.
    /// - Returns: Formatted success string.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if JSON encoding fails.
    public func formatSuccess(_ message: String) throws -> String {
        switch format {
        case .text:
            return colorize(message, color: .green)
        case .json:
            let response = SuccessResponse(success: true, message: message)
            return try formatJSON(response)
        }
    }

    /// Formats any Codable value as JSON.
    ///
    /// - Parameter value: Any Codable value to encode as JSON.
    /// - Returns: JSON string representation.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if encoding fails.
    public func formatJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(value)
            guard let string = String(data: data, encoding: .utf8) else {
                throw CLIError.encodingFailed(reason: "Failed to convert JSON data to string")
            }
            return string
        } catch {
            throw CLIError.encodingFailed(reason: error.localizedDescription)
        }
    }

    /// Formats data as a table with headers and rows.
    ///
    /// - Parameters:
    ///   - headers: Column headers.
    ///   - rows: Data rows (each row is an array of strings).
    /// - Returns: Formatted table string.
    /// - Throws: ``CLIError.encodingFailed(reason:)`` if JSON encoding fails.
    public func formatTable(headers: [String], rows: [[String]]) throws -> String {
        switch format {
        case .text:
            guard !headers.isEmpty, !rows.isEmpty else {
                return ""
            }

            // Calculate column widths
            var columnWidths = headers.map { $0.count }
            for row in rows {
                for (index, cell) in row.enumerated() where index < columnWidths.count {
                    columnWidths[index] = max(columnWidths[index], cell.count)
                }
            }

            var output = ""

            // Format headers
            let headerRow = headers.enumerated().map { index, header in
                header.padding(toLength: columnWidths[index], withPad: " ", startingAt: 0)
            }.joined(separator: " | ")
            output += colorize(headerRow, color: .cyan) + "\n"

            // Separator line
            let separator = columnWidths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
            output += separator + "\n"

            // Format data rows
            for row in rows {
                let formattedRow = row.enumerated().map { index, cell in
                    cell.padding(toLength: columnWidths[index], withPad: " ", startingAt: 0)
                }.joined(separator: " | ")
                output += formattedRow + "\n"
            }

            return output
        case .json:
            // Convert table to array of dictionaries
            let tableData = rows.map { row in
                Dictionary(uniqueKeysWithValues: zip(headers, row))
            }
            return try formatJSON(tableData)
        }
    }

    // MARK: - Private Helpers

    private func formatHeader(_ text: String) -> String {
        colorize(text.uppercased(), color: .bold)
    }

    private func colorize(_ text: String, color: ANSIColor) -> String {
        guard colorize else { return text }
        return color.rawValue + text + ANSIColor.reset.rawValue
    }
}

// MARK: - Validation Result

/// Result of a validation operation.
public struct ValidationResult: Codable, Sendable {
    /// Whether validation passed.
    public let isValid: Bool

    /// List of validation errors.
    public let errors: [String]

    /// List of validation warnings.
    public let warnings: [String]

    /// Creates a new validation result.
    ///
    /// - Parameters:
    ///   - isValid: Whether validation passed.
    ///   - errors: List of validation errors (default: empty).
    ///   - warnings: List of validation warnings (default: empty).
    public init(isValid: Bool, errors: [String] = [], warnings: [String] = []) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }
}

// MARK: - Success Response

/// Response structure for success messages in JSON format.
private struct SuccessResponse: Codable, Sendable {
    /// Whether the operation succeeded.
    let success: Bool

    /// Success message.
    let message: String
}

// MARK: - ANSI Color Codes

/// ANSI color codes for terminal output.
private enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case cyan = "\u{001B}[36m"
}
