import Foundation

public struct PatientRole: CDAElement {
    public static let elementName = "patientRole"
    public static let childOrder = "realmCode typeId templateId id addr telecom patient providerOrganization".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension PatientRole {
    public var patient: Patient? {
        get { element("patient") }
        set { setElement("patient", newValue) }
    }
    public var addresses: [AD] {
        get { values("addr") }
        set { setValues("addr", newValue) }
    }
    public var telecoms: [TEL] {
        get { values("telecom") }
        set { setValues("telecom", newValue) }
    }
    public var providerOrganization: Organization? {
        get { element("providerOrganization") }
        set { setElement("providerOrganization", newValue) }
    }
}
