import Foundation

public struct Patient: CDAElement {
    public static let elementName = "patient"
    public static let childOrder = "realmCode typeId templateId id name desc administrativeGenderCode birthTime deceasedInd deceasedTime multipleBirthInd multipleBirthOrderNumber maritalStatusCode religiousAffiliationCode raceCode ethnicGroupCode guardian birthplace languageCommunication".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Patient {
    public var names: [PN] {
        get { values("name") }
        set { setValues("name", newValue) }
    }
    public var administrativeGenderCode: CE? {
        get { value("administrativeGenderCode") }
        set { setValue("administrativeGenderCode", newValue) }
    }
    public var birthTime: TS? {
        get { value("birthTime") }
        set { setValue("birthTime", newValue) }
    }
}
