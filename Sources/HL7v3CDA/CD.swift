//
//  CD.swift
//  HL7v3CDA
//
//  Represents the HL7 CDA concept descriptor datatype and its XML values.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct CD: HL7DataType {
    public static let typeName = "CD"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
