import Foundation

/// Failures produced while converting H.264 parameter sets and AVCC samples into an Annex-B elementary stream.
public enum DicomH264ElementaryStreamError: Error, Equatable, LocalizedError, Sendable {
    /// The supplied CoreMedia format description does not describe H.264 video.
    case unsupportedFormat

    /// The format description does not provide both sequence and picture parameter sets.
    case missingParameterSets

    /// The AVCC NAL-unit length prefix is outside the supported one-to-four-byte range.
    case invalidNALUnitHeaderLength(Int)

    /// An AVCC sample declares a zero-length NAL unit.
    case zeroLengthNALUnit

    /// A NAL unit declares more payload bytes than remain in the sample.
    case truncatedNALUnit(declaredLength: Int, availableBytes: Int)

    /// Bytes remain at the end of a sample but do not form a complete NAL-unit length prefix.
    case trailingLengthPrefix(byteCount: Int)

    /// Appending the converted sample would exceed the caller's output budget.
    case outputLimitExceeded(limit: Int)

    /// A localized description of the elementary-stream conversion failure.
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The format description does not contain H.264 video."
        case .missingParameterSets:
            return "The H.264 format description does not contain complete SPS and PPS parameter sets."
        case .invalidNALUnitHeaderLength(let length):
            return "The H.264 AVCC NAL-unit length prefix must contain one to four bytes; found \(length)."
        case .zeroLengthNALUnit:
            return "The H.264 AVCC sample contains a zero-length NAL unit."
        case .truncatedNALUnit(let declaredLength, let availableBytes):
            return "The H.264 AVCC sample declares \(declaredLength) NAL bytes with only \(availableBytes) available."
        case .trailingLengthPrefix(let byteCount):
            return "The H.264 AVCC sample ends with an incomplete \(byteCount)-byte NAL-unit length prefix."
        case .outputLimitExceeded(let limit):
            return "The H.264 Annex-B stream would exceed its \(limit)-byte output limit."
        }
    }
}
