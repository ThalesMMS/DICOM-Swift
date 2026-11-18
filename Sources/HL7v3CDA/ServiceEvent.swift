//
//  ServiceEvent.swift
//  HL7v3CDA
//
//  Represents the CDA documented clinical service event.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct ServiceEvent: CDAElement {
    public static let elementName = "serviceEvent"
    public static let childOrder = "realmCode typeId templateId id code effectiveTime performer".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
