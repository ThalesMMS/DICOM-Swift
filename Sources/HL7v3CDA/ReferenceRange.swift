//
//  ReferenceRange.swift
//  HL7v3CDA
//
//  Represents the CDA observation reference range.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct ReferenceRange: CDAElement {
    public static let elementName = "referenceRange"
    public static let childOrder = "realmCode typeId templateId observationRange".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
