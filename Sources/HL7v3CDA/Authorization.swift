//
//  Authorization.swift
//  HL7v3CDA
//
//  Represents the CDA document authorization and consent.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Authorization: CDAElement {
    public static let elementName = "authorization"
    public static let childOrder = "realmCode typeId templateId consent".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Authorization {
    public var consent: Consent? {
        get { element("consent") }
        set { setElement("consent", newValue) }
    }
}
