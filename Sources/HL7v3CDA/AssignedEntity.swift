//
//  AssignedEntity.swift
//  HL7v3CDA
//
//  Represents the CDA entity assigned to a clinical participation.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct AssignedEntity: CDAElement {
    public static let elementName = "assignedEntity"
    public static let childOrder = "realmCode typeId templateId id code addr telecom assignedPerson representedOrganization".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension AssignedEntity {
    public var assignedPerson: Person? {
        get { element("assignedPerson") }
        set { setElement("assignedPerson", newValue) }
    }
    public var representedOrganization: Organization? {
        get { element("representedOrganization") }
        set { setElement("representedOrganization", newValue) }
    }
}
