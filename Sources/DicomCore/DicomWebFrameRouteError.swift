//
//  DicomWebFrameRouteError.swift
//  DicomCore
//
//  Describes failures reported during DICOM Web Frame Route operations.
//
//  Thales Matheus Mendonça Santos — August 2026
//

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
