//
//  Authenticator.swift
//  HL7v3CDA
//
//  Represents the CDA document authentication participant.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Authenticator: CDAElement {
    public static let elementName = "authenticator"
    public static let childOrder = "realmCode typeId templateId time signatureCode assignedEntity".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Authenticator {
    public var time: TS? {
        get { value("time") }
        set { setValue("time", newValue) }
    }
    public var signatureCode: CS? {
        get { value("signatureCode") }
        set { setValue("signatureCode", newValue) }
    }
    public var assignedEntity: AssignedEntity? {
        get { element("assignedEntity") }
        set { setElement("assignedEntity", newValue) }
    }
}
