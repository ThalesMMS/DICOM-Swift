//
//  DicomJXLSwiftRolloutMode.swift
//  DicomCore
//

import Foundation

enum DicomJXLSwiftRolloutMode: String, CaseIterable, Sendable {
    case disabled
    case experimental
    case forcedForTests = "forced-for-tests"

    static let environmentKey = "DICOM_JXLSWIFT_MODE"

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = configured.flatMap(Self.init(rawValue:)) ?? .disabled
    }
}
