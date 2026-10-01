import DicomCore
import Foundation

/// An error raised while remuxing compressed DICOM video for Apple media frameworks.
public enum DicomVideoRemuxError: Error, Equatable, LocalizedError, Sendable {
    /// The requested sample timing does not use a positive, finite frame rate.
    case invalidFrameRate

    /// The DICOM video codec is not supported by the native remuxer.
    case unsupportedCodec(DicomVideoCodec)

    /// The elementary stream does not contain the framing required by its codec.
    case malformedElementaryStream(codec: DicomVideoCodec)

    /// The elementary stream is missing the decoder parameter sets required by its codec.
    case missingParameterSets(codec: DicomVideoCodec)

    /// The elementary stream contains no decodable video access units.
    case noVideoFrames(codec: DicomVideoCodec)

    /// The elementary stream requires decode/display reordering that is not yet supported.
    case frameReorderingUnsupported(codec: DicomVideoCodec)

    /// Core Media could not create a format description for the compressed stream.
    case formatDescriptionFailed(status: Int32)

    /// Core Media could not create a sample buffer for a compressed access unit.
    case sampleBufferFailed(status: Int32)

    /// AVFoundation could not write the playable container.
    case writerFailed(String)

    /// The playable container would exceed its configured byte limit.
    case outputBudgetExceeded(maximumBytes: Int64)

    /// A localized description suitable for diagnostics and user-facing error presentation.
    public var errorDescription: String? {
        switch self {
        case .invalidFrameRate:
            return "The DICOM video frame rate must be a positive finite number."
        case .unsupportedCodec:
            return "The DICOM video codec is not supported for native playback."
        case .malformedElementaryStream(let codec):
            return "The encapsulated \(codec.displayName) stream is malformed."
        case .missingParameterSets(let codec):
            return "The encapsulated \(codec.displayName) stream is missing decoder parameter sets."
        case .noVideoFrames(let codec):
            return "The encapsulated \(codec.displayName) stream has no decodable video frames."
        case .frameReorderingUnsupported(let codec):
            return "The encapsulated \(codec.displayName) stream uses unsupported frame reordering."
        case .formatDescriptionFailed(let status):
            return "AVFoundation could not describe the DICOM video stream (status \(status))."
        case .sampleBufferFailed(let status):
            return "AVFoundation could not prepare a DICOM video sample (status \(status))."
        case .writerFailed(let message):
            return "AVFoundation could not prepare DICOM video playback: \(message)"
        case .outputBudgetExceeded(let maximumBytes):
            return "DICOM video playback output exceeds the \(maximumBytes)-byte limit."
        }
    }
}
