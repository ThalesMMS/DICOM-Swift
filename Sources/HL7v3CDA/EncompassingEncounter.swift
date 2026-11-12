//
//  EncompassingEncounter.swift
//  HL7v3CDA
//
//  Represents the CDA encounter context and care participants.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct EncompassingEncounter: CDAElement {
    public static let elementName = "encompassingEncounter"
    public static let childOrder = "realmCode typeId templateId id code effectiveTime dischargeDispositionCode responsibleParty encounterParticipant location".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
