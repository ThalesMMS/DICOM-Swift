//
//  EntryRelationship.swift
//  HL7v3CDA
//
//  Represents the CDA relationship between clinical statement entries.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct EntryRelationship: CDAElement {
    public static let elementName = "entryRelationship"
    public static let childOrder = "realmCode typeId templateId sequenceNumber seperatableInd act encounter observation observationMedia organizer procedure regionOfInterest substanceAdministration supply".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
