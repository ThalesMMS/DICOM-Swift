//
//  Organizer.swift
//  HL7v3CDA
//
//  Represents the CDA group of related clinical observations.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Organizer: CDAElement {
    public static let elementName = "organizer"
    public static let childOrder = "realmCode typeId templateId id code statusCode effectiveTime subject specimen performer author informant participant reference precondition component".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
