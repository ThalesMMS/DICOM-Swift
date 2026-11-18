//
//  DicomPresentationSpatialTransform.swift
//  DicomCore
//
//  Represents DICOM Presentation Spatial Transform metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomPresentationSpatialTransform: Equatable, Sendable {
    public let isHorizontallyFlipped: Bool
    public let rotationDegrees: Int

    public init(isHorizontallyFlipped: Bool = false, rotationDegrees: Int = 0) {
        self.isHorizontallyFlipped = isHorizontallyFlipped
        self.rotationDegrees = ((rotationDegrees % 360) + 360) % 360
    }

    public static let identity = DicomPresentationSpatialTransform()
}
