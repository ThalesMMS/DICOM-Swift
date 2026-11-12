//
//  CDADocumentParser.swift
//  HL7v3CDA
//
//  Parses CDA XML into typed clinical document structures.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct CDADocumentParser: Sendable {
    public var limits: XMLLimits
    public init(limits: XMLLimits = XMLLimits()) { self.limits = limits }
    public func parse(_ data: Data) throws -> ClinicalDocument {
        try document(SafeXMLParser(limits: limits).parse(data))
    }
    public func parse(_ url: URL) throws -> ClinicalDocument {
        try document(SafeXMLParser(limits: limits).parse(url))
    }
    private func document(_ node: XMLNode) throws -> ClinicalDocument {
        guard node.name.localName == "ClinicalDocument", node.name.namespaceURI == CDANamespace.hl7 else {
            throw CDAError.invalidDocument
        }
        try CDAInspection.validateTypes(node)
        return ClinicalDocument(node: node)
    }
}
