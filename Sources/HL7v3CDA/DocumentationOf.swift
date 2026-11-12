//
//  DocumentationOf.swift
//  HL7v3CDA
//
//  Represents the CDA service event documented by the report.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DocumentationOf: CDAElement {
    public static let elementName = "documentationOf"
    public static let childOrder = "realmCode typeId templateId serviceEvent".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension DocumentationOf {
    public var serviceEvent: ServiceEvent? {
        get { element("serviceEvent") }
        set { setElement("serviceEvent", newValue) }
    }
}
