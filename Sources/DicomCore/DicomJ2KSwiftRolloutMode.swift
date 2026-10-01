//
//  DicomJ2KSwiftRolloutMode.swift
//  DicomCore
//

import Foundation

enum DicomJ2KSwiftRolloutMode: String, CaseIterable, Sendable {
    case disabled
    case shadow
    case preferred
    case forcedForTests = "forced-for-tests"

    static let environmentKey = "DICOM_J2KSWIFT_MODE"

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Since #2329 the JPEG 2000 codec is the own DicomJPEG2000 target; it is preferred by default and OpenJPEG
        // (when present) remains the fallback and the independent oracle.
        self = configured.flatMap(Self.init(rawValue:)) ?? .preferred
    }
}
