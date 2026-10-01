import Foundation

/// Raw attribute prerequisites for lossless per-item projection into the existing semantic model.
/// Complete content macro, template and relationship constraints require additional rules.
enum DicomSRContentRules {
    static func rules(for dataSet: DicomDataSet, isRoot: Bool,
                      versionRequirements: [String: DicomAttributeRule.Truth],
                      numericPrecision: DicomNumericMeasurementMacro.PrecisionRequirements = .init(),
                      referenceConditions: DicomContentReferenceMacro.Conditions = .init(),
                      contentConditions: DicomSRContentItemMacro.Conditions = .init(),
                      temporalConditions: DicomTemporalCoordinatesMacro.Conditions = .init(),
                      spatialConditions: DicomSpatialCoordinatesMacro.Conditions = .init()) -> [DicomAttributeRule] {
        var result = DicomSRContentItemMacro.rules(for: dataSet, isRoot: isRoot, conditions: contentConditions,
                                                  versionRequirements: versionRequirements)
        if dataSet.contains(0x0040DB73) { return result }
        let code = DicomCodeSequenceMacro.rules(versionRequirements: versionRequirements)
        let type = DicomSRContentItemMacro.valueType(dataSet) ?? ""
        switch type {
        case "CODE":
            result.append(.init(tag: 0x0040A168, requirement: .type1, itemRules: code, constraints: [.itemCount(1...1)]))
        case "SCOORD", "SCOORD3D":
            if let kind = DicomSpatialCoordinatesMacro.Kind(rawValue: type) {
                result += DicomSpatialCoordinatesMacro.rules(kind: kind, conditions: spatialConditions)
            }
        case "TCOORD":
            result += DicomTemporalCoordinatesMacro.rules(conditions: temporalConditions)
        case "NUM":
            result += DicomNumericMeasurementMacro.rules(for: dataSet, floatingPointRequired: numericPrecision.floatingPoint,
                rationalRepresentationRequired: numericPrecision.rational, versionRequirements: versionRequirements)
        case "IMAGE", "COMPOSITE", "WAVEFORM":
            if let kind = DicomContentReferenceMacro.Kind(rawValue: type) {
                result += DicomContentReferenceMacro.rules(kind: kind, conditions: referenceConditions)
            }
        default: break
        }
        return result
    }
}
