//
//  RecordTarget.swift
//  HL7v3CDA
//
//  Represents the CDA patient record targeted by the document.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct RecordTarget: CDAElement {
    public static let elementName = "recordTarget"
    public static let childOrder = "realmCode typeId templateId patientRole".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension RecordTarget {
    public var patientRole: PatientRole? {
        get { element("patientRole") }
        set { setElement("patientRole", newValue) }
    }
}
