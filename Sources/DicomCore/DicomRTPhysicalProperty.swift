public struct DicomRTPhysicalProperty: Equatable, Sendable {
    public let name: String
    public let value: Double
    /// Units follow PS3.3 C.8.8.8 and are never encoded as an extra attribute.
    public var units: String? {
        switch name {
        case "MEAN_EXCI_ENERGY": return "eV"
        case "EFF_Z_PER_A": return "AMU^-1"
        case "REL_MASS_DENSITY", "REL_ELEC_DENSITY", "EFFECTIVE_Z", "REL_STOP_RATIO": return "1"
        default: return nil
        }
    }

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}
