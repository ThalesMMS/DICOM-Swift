//
//  DicomCodecOutputOwnership.swift
//  DicomCore
//
//  Lifetime contract for the returned pixel bytes.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

/// Lifetime contract for the returned pixel bytes.
public enum DicomCodecOutputOwnership: String, Codable, Hashable, Sendable {
    case ownedData = "owned-data"
    case sharedBuffer = "shared-buffer"
}
