import Foundation

public struct EncompassingEncounter: CDAElement {
    public static let elementName = "encompassingEncounter"
    public static let childOrder = "realmCode typeId templateId id code effectiveTime dischargeDispositionCode responsibleParty encounterParticipant location".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}
