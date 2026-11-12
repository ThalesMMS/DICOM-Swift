//
//  Custodian.swift
//  HL7v3CDA
//
//  Represents the CDA document custodian.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Custodian: CDAElement {
    public static let elementName = "custodian"
    public static let childOrder = "realmCode typeId templateId assignedCustodian".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Custodian {
    public var assignedCustodian: AssignedCustodian? {
        get { element("assignedCustodian") }
        set { setElement("assignedCustodian", newValue) }
    }
}
