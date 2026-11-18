//
//  DicomPresentationCompoundGraphicMajorTick.swift
//  DicomCore
//
//  Represents DICOM Presentation Compound Graphic Major Tick metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomPresentationCompoundGraphicMajorTick: Equatable, Sendable {
    public let position: Double
    public let label: String

    public init(position: Double, label: String) {
        self.position = position
        self.label = label
    }
}
