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
