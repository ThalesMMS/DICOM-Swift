//
//  DicomFrameVOIWindow.swift
//  DicomCore
//
//  One valid Window Center/Width pair from a Frame VOI LUT Functional Group.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation

/// One valid Window Center/Width pair from a Frame VOI LUT Functional Group.
public struct DicomFrameVOIWindow: Equatable, Sendable {
    public let center: Double
    public let width: Double
    public let explanation: String?

    public init?(center: Double, width: Double, explanation: String? = nil) {
        guard center.isFinite, width.isFinite, width > 0 else { return nil }
        self.center = center
        self.width = width
        let trimmedExplanation = explanation?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        self.explanation = trimmedExplanation?.isEmpty == false ? trimmedExplanation : nil
    }
}
