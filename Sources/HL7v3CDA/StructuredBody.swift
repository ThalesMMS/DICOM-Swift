//
//  StructuredBody.swift
//  HL7v3CDA
//
//  Represents the CDA document sections in a structured body.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct StructuredBody: CDAElement {
    public static let elementName = "structuredBody"
    public static let childOrder = "realmCode typeId templateId confidentialityCode languageCode component".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
