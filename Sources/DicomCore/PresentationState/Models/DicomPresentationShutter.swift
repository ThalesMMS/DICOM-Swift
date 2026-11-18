//
//  DicomPresentationShutter.swift
//  DicomCore
//
//  Represents DICOM Presentation Shutter metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomPresentationShutter: Equatable, Sendable {
    case rectangular(left: Int32, right: Int32, upper: Int32, lower: Int32)
    case circular(center: SIMD2<Int32>, radius: Int32)
    case polygonal(vertices: [SIMD2<Int32>])
    case bitmap(DicomPresentationBitmapShutter)
}
