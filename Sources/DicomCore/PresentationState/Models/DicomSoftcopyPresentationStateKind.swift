//
//  DicomSoftcopyPresentationStateKind.swift
//  DicomCore
//
//  Represents DICOM Softcopy Presentation State Kind metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomSoftcopyPresentationStateKind: String, Equatable, Sendable {
    case grayscale
    case color
    case blending
    case pseudoColor
}
