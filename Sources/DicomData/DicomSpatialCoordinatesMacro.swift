import Foundation

/// PS3.3 C.18.6/C.18.9 attribute rules. Mathematical shape and referenced-image bounds require separate geometric evidence.
public enum DicomSpatialCoordinatesMacro {
    public static let standardEdition = "2026c"

    public enum Kind: String, Sendable {
        case spatial = "SCOORD", spatial3D = "SCOORD3D"
    }

    public struct Conditions: Sendable {
        /// A referenced image contains both Total Pixel Matrix Columns and Rows. Do not infer from origin-attribute presence.
        public var referencedImageIsTiled: DicomAttributeRule.Truth = .undetermined
        public init() {}
    }

    public static func rules(kind: Kind, conditions: Conditions = .init()) -> [DicomAttributeRule] {
        let types: Set<String> = kind == .spatial ? ["POINT", "MULTIPOINT", "POLYLINE", "CIRCLE", "ELLIPSE"] :
            ["POINT", "MULTIPOINT", "POLYLINE", "POLYGON", "ELLIPSE", "ELLIPSOID"]
        var result: [DicomAttributeRule] = [
            .init(tag: 0x00700023, requirement: .type1, constraints: [.valueCount(1...1), .strings(types)]),
            .init(tag: 0x00700022, requirement: .type1, constraints: [.spatialCoordinateValues(kind)]),
            .init(tag: 0x0070031A, requirement: .type3, constraints: [.valueCount(0...1)])
        ]
        if kind == .spatial {
            result.append(.init(tag: 0x00480301, requirement: .type1C, condition: .known(conditions.referencedImageIsTiled),
                mayBePresentOtherwise: true, constraints: [.valueCount(1...1), .strings(["FRAME", "VOLUME"])]))
        } else {
            result.append(.init(tag: 0x30060024, requirement: .type1, constraints: [.valueCount(1...1)]))
        }
        return result
    }

    /// Qualifies attribute presence, component counts, finite value domains and polygon closure, not full geometry or IODs.
    public static func validate(_ dataSet: DicomDataSet, kind: Kind, conditions: Conditions = .init(),
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(kind: kind, conditions: conditions), limits: limits)
    }
}
