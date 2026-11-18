//
//  DicomWebFrameRepresentation.swift
//  DicomCore
//
//  Represents DICOM Web Frame Representation metadata and state.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import Foundation

struct DicomWebFrameRepresentation: Equatable, Sendable {
    let frameNumbers: [Int]
    let mediaType: String
    let transferSyntaxUID: String?
    let data: Data
}
