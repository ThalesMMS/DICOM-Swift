//
//  DicomDisplayFormatter.swift
//
//  Shared display-formatting helpers for DicomSwiftUI views.
//

import Foundation
import DicomCore

/// A small collection of pure functions for formatting common DICOM display values.
///
/// This type is intentionally UI-agnostic so SwiftUI views can focus on layout while
/// these helpers handle value presentation concerns (fallback strings, formatting,
/// rounding).
public enum DicomDisplayFormatter {

    /// Default fallback string for missing/empty values.
    public static let notAvailable = "N/A"

    /// Formats the DICOM Patient Sex value.
    ///
    /// - Parameter value: DICOM Patient Sex (0010,0040), typically "M", "F", or "O".
    /// - Returns: A human-readable string ("Male", "Female", "Other"), the original
    ///   value if unrecognized, or `notAvailable` when nil/empty.
    public static func sex(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return notAvailable }

        switch value.uppercased() {
        case "M": return "Male"
        case "F": return "Female"
        case "O": return "Other"
        default: return value
        }
    }

    /// Formats a DICOM modality value.
    ///
    /// - Parameter value: DICOM Modality (0008,0060).
    /// - Returns: The original modality value when present, otherwise `notAvailable`.
    public static func modality(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return notAvailable }
        return value
    }

    /// Formats a DICOM date string (DA) into `YYYY-MM-DD` when possible.
    ///
    /// - Parameter value: DICOM DA value, commonly `YYYYMMDD`.
    /// - Returns: `YYYY-MM-DD` when `value` has at least 8 characters; otherwise returns
    ///   the original value when present, or `notAvailable` when nil.
    public static func date(_ value: String?) -> String {
        guard let value, value.count >= 8 else { return value ?? notAvailable }

        let year = value.prefix(4)
        let month = value.dropFirst(4).prefix(2)
        let day = value.dropFirst(6).prefix(2)
        return "\(year)-\(month)-\(day)"
    }

    /// Formats a DICOM time string (TM) into `HH:MM:SS` when possible.
    ///
    /// - Parameter value: DICOM TM value, commonly `HHMMSS` (may include fractional seconds).
    /// - Returns: `HH:MM:SS` when at least 6 characters are present; otherwise returns
    ///   the original value when present, or `notAvailable` when nil.
    public static func time(_ value: String?) -> String {
        guard let value, value.count >= 6 else { return value ?? notAvailable }

        let hour = value.prefix(2)
        let minute = value.dropFirst(2).prefix(2)
        let second = value.dropFirst(4).prefix(2)
        return "\(hour):\(minute):\(second)"
    }

    /// Formats image dimensions.
    public static func dimensions(width: Int, height: Int) -> String {
        "\(width) × \(height) pixels"
    }

    /// Formats pixel spacing.
    ///
    /// - Returns: `notAvailable` when spacing is invalid; otherwise a string like
    ///   `"X.XX × Y.YY mm"` or `"X.XX × Y.YY × Z.ZZ mm"`.
    public static func pixelSpacing(_ spacing: PixelSpacing) -> String {
        guard spacing.x > 0, spacing.y > 0, spacing.z >= 0 else { return notAvailable }

        let x = String(format: "%.2f", spacing.x)
        let y = String(format: "%.2f", spacing.y)

        if spacing.z > 0 {
            let zStr = String(format: "%.2f", spacing.z)
            return "\(x) × \(y) × \(zStr) mm"
        } else {
            return "\(x) × \(y) mm"
        }
    }

    /// Formats a measurement value with a unit.
    public static func measurement(_ value: String?, unit: String) -> String {
        guard let value, !value.isEmpty else { return notAvailable }
        return "\(value) \(unit)"
    }

    /// Formats a window center/width value.
    ///
    /// - Parameters:
    ///   - value: Window center/width value.
    ///   - isValid: Whether the value is considered valid by the caller.
    /// - Returns: `notAvailable` when `isValid` is false, otherwise the value rounded
    ///   to one fractional digit.
    public static func windowValue(_ value: Double, isValid: Bool) -> String {
        guard isValid else { return notAvailable }
        return String(format: "%.1f", value)
    }
}
