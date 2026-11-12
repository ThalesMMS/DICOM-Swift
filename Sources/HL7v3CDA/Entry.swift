//
//  Entry.swift
//  HL7v3CDA
//
//  Represents the CDA section entry and its clinical statement.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Entry: CDAElement {
    public static let elementName = "entry"
    public static let childOrder = "realmCode typeId templateId act encounter observation observationMedia organizer procedure regionOfInterest substanceAdministration supply".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
