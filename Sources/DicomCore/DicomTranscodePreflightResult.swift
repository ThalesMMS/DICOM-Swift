/// Capability-only qualification for a declared transcode workflow.
///
/// The preflight parses metadata and evaluates the active encoder and decoder
/// routes without decoding source frames or producing a destination codestream.
/// Data-dependent corruption and codestream limits remain the responsibility
/// of the executing workflow's validation and decoded-pixel comparison.
public struct DicomTranscodePreflightResult: Equatable, Sendable {
    /// Whether the requested transcode and optional decoded-pixel verification
    /// have active, shape-qualified codec routes.
    public let canExecute: Bool

    /// Stable explanation when `canExecute` is false.
    public let unavailableReason: String?

    static let verificationUnavailableReason = "No codec in this build can verify its decoded pixels"

    static var executable: Self {
        Self(canExecute: true, unavailableReason: nil)
    }

    static func unavailable(_ reason: String) -> Self {
        Self(canExecute: false, unavailableReason: reason)
    }
}
