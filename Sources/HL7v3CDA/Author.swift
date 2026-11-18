//
//  Author.swift
//  HL7v3CDA
//
//  Represents the CDA document author and authorship time.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct Author: CDAElement {
    public static let elementName = "author"
    public static let childOrder = "realmCode typeId templateId functionCode time assignedAuthor".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Author {
    public var time: TS? {
        get { value("time") }
        set { setValue("time", newValue) }
    }
    public var assignedAuthor: AssignedAuthor? {
        get { element("assignedAuthor") }
        set { setElement("assignedAuthor", newValue) }
    }
}
