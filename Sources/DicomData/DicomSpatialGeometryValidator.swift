import Foundation

/// Mathematical C.18.6/C.18.9 shape checks on one owned spatial Content Item.
/// Image/frame/matrix bounds and Frame of Reference identity are separate evidence.
public enum DicomSpatialGeometryValidator {
    public static func validate(_ dataSet: DicomDataSet, kind: DicomSpatialCoordinatesMacro.Kind,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        evaluate(dataSet, kind: kind, limits: limits).report
    }

    /// Geometry reserves 16 work units per component for its bounded predicate passes.
    package static func evaluate(_ dataSet: DicomDataSet, kind: DicomSpatialCoordinatesMacro.Kind,
                                 limits: DicomAttributeValidator.Limits) -> (report: DicomValidationReport, evaluations: Int) {
        var work = 0
        func result(_ code: DicomValidationReport.Code? = nil, severity: DicomValidationReport.Severity = .error)
            -> (report: DicomValidationReport, evaluations: Int) {
            let diagnostics: [DicomValidationReport.Diagnostic] = code.map {
                [.init(code: $0, severity: severity, layer: .pixelsAndGeometry, path: [.tag(0x00700022)], requirement: .type1)]
            } ?? []
            return (.init(evaluatedLayers: [.pixelsAndGeometry], diagnostics: diagnostics), work)
        }
        guard limits.maximumRuleEvaluations > 0 else { return result(.evaluationLimitReached, severity: .limitation) }
        work = 1
        guard let element = dataSet[0x00700022], element.vr == .FL, case .floats(let values) = element.value,
              !values.isEmpty else { return result(.valueUnavailable, severity: .limitation) }
        guard values.count <= (limits.maximumRuleEvaluations - work) / 16 else { return result(.evaluationLimitReached, severity: .limitation) }
        work += values.count * 16
        if let invalid = DicomSpatialCoordinateValueValidator.validate(element, dataSet: dataSet, kind: kind) {
            return result(invalid.code, severity: invalid.severity)
        }
        let type = dataSet[0x00700023]?.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: " ")) ?? ""
        if ["POINT", "MULTIPOINT", "POLYLINE"].contains(type) { return result() }
        // Exact predicates qualify the encoded binary32 coordinates, not a repaired rounding of an owned Double array.
        guard values.allSatisfy({ Double(Float($0)) == $0 }) else { return result(.spatialGeometryPrecisionUnavailable, severity: .limitation) }
        let dimension = kind == .spatial ? 2 : 3
        let points = stride(from: 0, to: values.count, by: dimension).map { offset in
            Vector(values[offset], values[offset + 1], dimension == 3 ? values[offset + 2] : 0)
        }
        let truth: DicomAttributeRule.Truth?
        switch type {
        case "CIRCLE": truth = (points[1] - points[0]).squared.isZero ? nil : .satisfied
        case "ELLIPSE", "ELLIPSOID": truth = axes(points, ellipse: type == "ELLIPSE")
        case "POLYGON": truth = polygon(points)
        default: return result(.valueUnavailable, severity: .limitation)
        }
        switch truth {
        case .satisfied: return result()
        case .unsatisfied: return result(.spatialGeometryInvalid)
        case .undetermined: return result(.spatialGeometryPrecisionUnavailable, severity: .limitation)
        case nil: return result(.spatialGeometryDegenerate, severity: .limitation)
        }
    }

    private struct Vector {
        let x: DicomSpatialGeometryScalar, y: DicomSpatialGeometryScalar, z: DicomSpatialGeometryScalar
        init(_ x: Double, _ y: Double, _ z: Double) { self.x = .init(x); self.y = .init(y); self.z = .init(z) }
        init(_ x: DicomSpatialGeometryScalar, _ y: DicomSpatialGeometryScalar, _ z: DicomSpatialGeometryScalar) {
            self.x = x; self.y = y; self.z = z
        }
        static func + (lhs: Self, rhs: Self) -> Self { .init(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z) }
        static func - (lhs: Self, rhs: Self) -> Self { .init(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z) }
        func dot(_ other: Self) -> DicomSpatialGeometryScalar { x * other.x + y * other.y + z * other.z }
        func cross(_ other: Self) -> Self { .init(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x) }
        var squared: DicomSpatialGeometryScalar { dot(self) }
        var zero: DicomAttributeRule.Truth { combine([x.zero, y.zero, z.zero]) }
    }

    private static func axes(_ points: [Vector], ellipse: Bool) -> DicomAttributeRule.Truth? {
        let directions = stride(from: 0, to: points.count, by: 2).map { points[$0 + 1] - points[$0] }
        guard !directions.contains(where: { $0.squared.isZero }) else { return nil }
        let center = points[0] + points[1] // Compare doubled centers without introducing division.
        var checks: [DicomAttributeRule.Truth] = []
        for index in 1..<directions.count {
            checks.append((points[index * 2] + points[index * 2 + 1] - center).zero)
            for previous in 0..<index { checks.append(directions[index].dot(directions[previous]).zero) }
        }
        if ellipse {
            let order = directions[0].squared - directions[1].squared
            checks.append(order.sign >= 0 ? .satisfied : order.zero == .unsatisfied ? .unsatisfied : .undetermined)
        }
        return combine(checks)
    }

    private static func polygon(_ points: [Vector]) -> DicomAttributeRule.Truth? {
        let offsets = points.dropFirst().map { $0 - points[0] }
        guard let baseline = offsets.max(by: { $0.squared.magnitude < $1.squared.magnitude }), !baseline.squared.isZero else { return nil }
        let normals = offsets.map { baseline.cross($0) }
        // Compare components, not squared normals: predicates stay degree <= 3 over binary32 inputs.
        guard let normal = normals.max(by: { $0.x.magnitude + $0.y.magnitude + $0.z.magnitude < $1.x.magnitude + $1.y.magnitude + $1.z.magnitude }),
              !normal.x.isZero || !normal.y.isZero || !normal.z.isZero else { return nil }
        return combine(offsets.map { normal.dot($0).zero })
    }

    private static func combine(_ checks: [DicomAttributeRule.Truth]) -> DicomAttributeRule.Truth {
        if checks.contains(where: { $0 == .unsatisfied }) { return .unsatisfied }
        return checks.contains(where: { $0 == .undetermined }) ? .undetermined : .satisfied
    }
}
