//
//  DicomDecodedFrameExecution.swift
//  DicomCore
//
//  Backend/fallback identity for one decoded frame.
//

/// A decoded frame plus the codec policy decision that produced it.
public struct DicomDecodedFrameExecution: Sendable {
    /// Decoded frame produced by the selected backend.
    public let frame: DicomDecodedFrame
    /// Stable identifier of the backend whose pixels were returned.
    public let backendIdentifier: String
    /// Linked or runtime-reported backend version.
    public let backendVersion: String?
    /// How the selected backend entered the process.
    public let backendSource: DicomCodecBackendSource
    /// Active family-specific rollout mode, when applicable.
    public let rolloutMode: String?
    /// Reason the preferred backend was bypassed or failed, when fallback occurred.
    public let fallbackReason: String?
    /// Candidate backend executed without supplying production pixels, when shadowing.
    public let shadowBackendIdentifier: String?

    /// Creates a decoded-frame execution record.
    public init(
        frame: DicomDecodedFrame,
        backendIdentifier: String,
        backendVersion: String? = nil,
        backendSource: DicomCodecBackendSource,
        rolloutMode: String? = nil,
        fallbackReason: String? = nil,
        shadowBackendIdentifier: String? = nil
    ) {
        self.frame = frame
        self.backendIdentifier = backendIdentifier
        self.backendVersion = backendVersion
        self.backendSource = backendSource
        self.rolloutMode = rolloutMode
        self.fallbackReason = fallbackReason
        self.shadowBackendIdentifier = shadowBackendIdentifier
    }
}
