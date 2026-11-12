//
//  II.swift
//  HL7v3CDA
//
//  Represents the HL7 CDA instance identifier datatype and its XML values.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct II: HL7DataType {
    public static let typeName = "II"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
