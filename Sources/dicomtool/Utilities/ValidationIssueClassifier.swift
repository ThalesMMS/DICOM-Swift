//
//  ValidationIssueClassifier.swift
//  dicomtool
//
//  Shared heuristics for classifying DICOM validation issues.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

/// Classifies raw validation issue strings as warnings or errors.
///
/// - Important: This currently uses message-text heuristics because
///   `DCMDecoder.validateDICOMFile(_:)` does not return structured severities.
///   If the upstream message format changes, these rules may need updates.
enum ValidationIssueClassifier {
    private static let warningIndicators = [
        "warning",
        "smaller than",
        "missing optional",
    ]

    static func isWarning(_ issue: String) -> Bool {
        let normalized = issue.lowercased()
        return warningIndicators.contains { normalized.contains($0) }
    }
}
