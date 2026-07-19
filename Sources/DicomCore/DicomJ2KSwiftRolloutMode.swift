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
        self = configured.flatMap(Self.init(rawValue:)) ?? .shadow
    }
}
