//
//  Order.swift
//  HL7v3CDA
//
//  Represents the CDA clinical order.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Order: CDAElement {
    public static let elementName = "order"
    public static let childOrder = "realmCode typeId templateId id code priorityCode".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
