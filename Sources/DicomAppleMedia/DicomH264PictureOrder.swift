//
//  DicomH264PictureOrder.swift
//  DicomAppleMedia
//
//  Compatibility facade; the pure Swift inspector owns POC qualification.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation
import DicomCore

/// Compatibility facade; the pure Swift inspector owns POC qualification.
enum DicomH264PictureOrder {
    static func presentationIndices(nalUnits: [Data], accessUnitCount: Int) throws -> [Int] {
        do {
            return try DicomH264StreamPictureOrder.presentationIndices(
                nalUnits: nalUnits, accessUnitCount: accessUnitCount)
        } catch {
            throw DicomVideoRemuxError.frameReorderingUnsupported(codec: .h264)
        }
    }
}
