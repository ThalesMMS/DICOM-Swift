import Foundation

public struct DicomSRObserver: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case person, device }
    public var kind: Kind
    public var name: String?
    public var organisation: String?
    public var role: DicomCodedConcept?
    public var procedureRole: DicomCodedConcept?
    public var deviceUID: String?
    public var manufacturer: String?
    public var model: String?
    public var serial: String?

    public init(
        kind: Kind,
        name: String? = nil,
        organisation: String? = nil,
        role: DicomCodedConcept? = nil,
        procedureRole: DicomCodedConcept? = nil,
        deviceUID: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        serial: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.organisation = organisation
        self.role = role
        self.procedureRole = procedureRole
        self.deviceUID = deviceUID
        self.manufacturer = manufacturer
        self.model = model
        self.serial = serial
    }
}
