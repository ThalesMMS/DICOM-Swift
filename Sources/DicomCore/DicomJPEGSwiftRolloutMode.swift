//
//  DicomJPEGSwiftRolloutMode.swift
//  DicomCore
//
//  Rollout switch for the own JPEG (SOF0/SOF1/SOF2/SOF3) backend built on the vendored DicomJPEG target.
//

import Foundation

/// `DICOM_JPEGSWIFT_MODE`: `preferred` (default) decodes with the own backend and falls back to the
/// established ImageIO/native paths when it declines a shape; `shadow` keeps the established decoder and
/// records the own result; `disabled` keeps the pre-#2326 behaviour; `forced-for-tests` never falls back.
enum DicomJPEGSwiftRolloutMode: String, CaseIterable, Sendable {
    case disabled
    case shadow
    case preferred
    case forcedForTests = "forced-for-tests"

    static let environmentKey = "DICOM_JPEGSWIFT_MODE"

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = configured.flatMap(Self.init(rawValue:)) ?? .preferred
    }
}
