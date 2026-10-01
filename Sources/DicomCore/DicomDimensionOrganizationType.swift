/// Unknown values are retained; absence has the positioning semantics of TILED_SPARSE.
public enum DicomDimensionOrganizationType: Sendable, Equatable {
    case tiledFull, tiledSparse, threeDimensional, threeDimensionalTemporal, other(String), absent

    public init(rawValue: String?) {
        switch rawValue {
        case nil: self = .absent
        case "TILED_FULL": self = .tiledFull
        case "TILED_SPARSE": self = .tiledSparse
        case "3D": self = .threeDimensional
        case "3D_TEMPORAL": self = .threeDimensionalTemporal
        case let value?: self = .other(value)
        }
    }
}
