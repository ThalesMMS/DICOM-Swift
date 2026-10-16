//
//  DicomJ2KFallbackLedger.swift
//  DicomCore
//

import Foundation

/// Frames that an established external runtime decoded in place of the own decoder: OpenJPEG for JPEG 2000 under the
/// `preferred` rollout (#3077), and CharLS for JPEG-LS when the own decoder declines a frame (#3086). Where such a
/// runtime exists (macOS with Homebrew) that fallback is silent, and it hid a slice the own decoder refused while the
/// iPhone, which has no runtime, failed on it. Each fallback logs a warning; own-path harnesses read the counter to
/// assert that no frame left the own decoders. Provider selection is unchanged.
public final class DicomJ2KFallbackLedger: @unchecked Sendable {
    public static let shared = DicomJ2KFallbackLedger()

    private static let logger: LoggerProtocol = DicomLogger.make(subsystem: "com.dicomviewer", category: "DCMDecoder")

    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedLastReason: String?

    init() {}

    /// Frames decoded by the fallback since launch or the last `reset()`.
    public var count: Int {
        lock.withLock { recordedCount }
    }

    /// Why the most recent fallback happened.
    public var lastReason: String? {
        lock.withLock { recordedLastReason }
    }

    public func reset() {
        lock.withLock {
            recordedCount = 0
            recordedLastReason = nil
        }
    }

    func record(backend: DicomCodecBackendIdentifier, reason: String) {
        lock.withLock {
            recordedCount += 1
            recordedLastReason = reason
        }
        Self.logger.warning("Codec fallback: \(backend.rawValue) decoded a frame instead of the own decoder: \(reason)")
    }
}
