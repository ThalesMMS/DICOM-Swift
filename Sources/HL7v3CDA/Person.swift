//
//  Person.swift
//  HL7v3CDA
//
//  Represents the CDA person and names.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Person: CDAElement {
    public static let elementName = "person"
    public static let childOrder = "realmCode typeId templateId name".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Person {
    public var names: [PN] {
        get { values("name") }
        set { setValues("name", newValue) }
    }
}
