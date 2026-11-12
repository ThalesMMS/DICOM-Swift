//
//  DicomStorageTier.swift
//  DicomCore
//
//  Describes archive storage tiers and their retrieval characteristics.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public enum DicomStorageTier: String, Codable, Sendable, CaseIterable {
    case online, nearline, offline

    public var instanceAvailability: DicomInstanceAvailability {
        switch self {
        case .online: .online
        case .nearline: .nearline
        case .offline: .offline
        }
    }
}
