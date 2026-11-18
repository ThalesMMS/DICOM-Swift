//
//  DicomMTLMaterial.swift
//  DicomDocumentContent
//
//  Represents DICOM MTL Material metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomMTLMaterial: Equatable, Sendable {
    public let name: String
    public internal(set) var ambient: SIMD3<Float>?
    public internal(set) var diffuse: SIMD3<Float>?
    public internal(set) var specular: SIMD3<Float>?
    public internal(set) var opacity: Float?
    public internal(set) var maps: [String: String] = [:]
}
