import Foundation

enum DicomWebFrameRouteError: Error, Equatable, Sendable {
    case invalidFrameList
    case frameNotFound
    case mediaTypeNotAcceptable
    case responseTooLarge
    case malformedPixelData
    case invalidRenderParameter
    case renderingFailed
}
