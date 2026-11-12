//
//  Participant.swift
//  HL7v3CDA
//
//  Represents the CDA document participation and its role.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Participant: CDAElement {
    public static let elementName = "participant"
    public static let childOrder = "realmCode typeId templateId functionCode time associatedEntity participantRole".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
