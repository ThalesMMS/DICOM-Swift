//
//  TEL.swift
//  HL7v3CDA
//
//  Represents the HL7 CDA telecommunication address datatype and its XML values.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct TEL: HL7DataType {
    public static let typeName = "TEL"
    public let node: XMLNode
    public init(node: XMLNode) throws {
        try HL7TypeValidation.validate(node, type: Self.typeName)
        self.node = node
    }
}
