//
//  DicomJXLSwiftRolloutMode.swift
//  DicomCore
//
//  The own JPEG XL codec is qualified against libjxl 0.12 (issue #3245): exact for Modular (.110,
//  reversible .112) and for JPEG recompression (.111), within one code for VarDCT (.112). It is
//  preferred by default; `disabled` is the documented rollback, and an absent or unknown value
//  means the default, as for the other codecs.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation

enum DicomJXLSwiftRolloutMode: String, CaseIterable, Sendable {
    case disabled
    case preferred
    /// Kept so existing launch configurations stay valid; executes like `preferred` but reports experimental.
    case experimental
    case forcedForTests = "forced-for-tests"

    static let environmentKey = "DICOM_JXLSWIFT_MODE"

    /// Reads `DICOM_JXLSWIFT_MODE`; unset or empty gives `.preferred`, and an unrecognized value is logged once and
    /// also falls back to `.preferred`.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configured = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let configured, !configured.isEmpty, Self(rawValue: configured) == nil {
            Self.reportUnrecognized(configured)
        }
        self = configured.flatMap(Self.init(rawValue:)) ?? .preferred
    }

    private static let logger: LoggerProtocol = DicomLogger.make(subsystem: "com.dicomcore", category: "codec-rollout")
    private static let reported = ReportedValues()

    /// A typo such as `disable` must not silently keep the codec on: the value is logged once, then the default applies.
    private static func reportUnrecognized(_ value: String) {
        guard reported.insert(value) else { return }
        logger.warning("Unrecognized \(environmentKey)=\(value); using preferred (accepted: \(allCases.map(\.rawValue).joined(separator: ", ")))")
    }

    var qualification: DicomCodecDecision.Qualification {
        switch self {
        case .preferred, .disabled: .qualified
        case .experimental: .experimental
        case .forcedForTests: .testOnly
        }
    }

    static let disabledDiagnostic = "The JPEG XL codec is disabled (DICOM_JXLSWIFT_MODE=disabled)."
}

/// Values already reported, so a decode loop that re-reads the environment logs a typo once.
private final class ReportedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []

    /// Records `value`; true the first time it is seen.
    func insert(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.insert(value).inserted
    }
}
