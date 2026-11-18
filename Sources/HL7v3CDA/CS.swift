//
//  CS.swift
//  HL7v3CDA
//
//  Represents the HL7 CDA coded simple value datatype and its XML values.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct CS: HL7DataType {
    public static let typeName = "CS"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
