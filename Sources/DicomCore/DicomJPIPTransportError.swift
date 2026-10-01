import Foundation

/// Stable, PHI-safe failures emitted by the JPIP transport boundary.
public enum DicomJPIPTransportError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidWindow
    case invalidURL
    case originNotAllowed
    case conflictingQueryParameter(String)
    case insecureTransportRejected
    case invalidFrameCount(Int)
    case invalidFrameIndex(Int)
    case frameIndexOutOfRange(index: Int, frameCount: Int)
    case multiFrameVolumeRequiresFrameRequests(frameCount: Int)
    case invalidLayerRange
    case layerLimitExceeded(limit: Int, requested: Int)
    case responseTooLarge(limit: Int)
    case totalResponseTooLarge(limit: Int)
    case redirectRejected
    case authenticationRequired(statusCode: Int)
    case unexpectedHTTPStatus(Int)
    case unsupportedMediaType(String?)
    case unsupportedContentEncoding(String)
    case unsupportedTransferSyntax(String)
    case invalidResponseHeader(String)
    case authorizationFailed
    case networkFailure(code: Int?)
}
