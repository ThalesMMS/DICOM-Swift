import Foundation

/// Raw C.18.6/C.18.9 component validation before semantic projection can truncate or reinterpret the value.
enum DicomSpatialCoordinateValueValidator {
    static func validate(_ element: DicomDataElement, dataSet: DicomDataSet, kind: DicomSpatialCoordinatesMacro.Kind)
        -> (code: DicomValidationReport.Code, severity: DicomValidationReport.Severity)? {
        guard element.vr == .FL, case .floats(let values) = element.value,
              let graphic = dataSet[0x00700023], graphic.vr == .CS, case .strings(let types) = graphic.value,
              types.count == 1, types[0].utf8.count <= 16 else { return (.valueUnavailable, .limitation) }
        let type = types[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let dimension = kind == .spatial ? 2 : 3
        guard values.count.isMultiple(of: dimension) else { return (.invalidMultiplicity, .error) }
        let points = values.count / dimension
        let validCount: Bool
        switch type {
        case "POINT": validCount = points == 1
        case "MULTIPOINT", "POLYLINE": validCount = points >= 2
        case "CIRCLE" where kind == .spatial: validCount = points == 2
        case "ELLIPSE": validCount = points == 4
        case "POLYGON" where kind == .spatial3D: validCount = points >= 4
        case "ELLIPSOID" where kind == .spatial3D: validCount = points == 6
        default: return (.valueUnavailable, .limitation)
        }
        guard validCount else { return (.invalidMultiplicity, .error) }
        guard values.allSatisfy({ $0.isFinite && Float($0).isFinite && (kind == .spatial3D || $0 >= 0) }) else {
            return (.attributeValueNotAllowed, .error)
        }
        if type == "POLYGON" && !values.prefix(3).elementsEqual(values.suffix(3)) {
            return (.attributeValueContradiction, .error)
        }
        return nil
    }
}
