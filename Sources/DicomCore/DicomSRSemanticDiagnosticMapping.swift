import Foundation

/// Maps only existing per-item semantic errors. Never includes instance values or localized error text.
enum DicomSRSemanticDiagnosticMapping {
    static func map(_ error: DicomSRSemanticValidationError, dataSet: DicomDataSet) -> DicomValidationReport.Diagnostic {
        switch error {
        case .unsupportedSOPClassUID:
            return scope([.tag(0x00080016)])
        case .unsupportedTemplateIdentifier:
            return scope([.tag(0x0040A504)])
        case .unsupportedRootValueType, .unsupportedValueType:
            return scope([.tag(0x0040A040)])
        case .unsupportedRootConcept:
            return scope([.tag(0x0040A043)])
        case .unsupportedRelationshipType, .unsupportedByReferenceRelationship:
            return scope([.tag(0x0040A010)])
        case .unsupportedCodingScheme(let path, _):
            return scope(concept(path, dataSet: dataSet) + [.item(0), .tag(0x00080102)])
        case .unsupportedMeasurementUnit:
            return scope(measuredPath(dataSet) + [.tag(0x004008EA), .item(0), .tag(0x00080102)])
        case .missingConceptName(let path):
            return missing(concept(path, dataSet: dataSet))
        case .missingRelationshipType:
            return missing([.tag(0x0040A010)])
        case .missingValue(_, let type):
            let tags: [String: Int] = ["TEXT": 0x0040A160, "CODE": 0x0040A168, "DATETIME": 0x0040A120,
                                      "DATE": 0x0040A121, "TIME": 0x0040A122, "PNAME": 0x0040A123, "UIDREF": 0x0040A124]
            return missing(tags[type].map { [.tag($0)] } ?? [])
        case .missingNumericValue:
            return missing(measuredPath(dataSet) + (hasMeasurement(dataSet) ? [.tag(0x0040A30A)] : []))
        case .missingMeasurementUnits:
            return missing(measuredPath(dataSet) + (hasMeasurement(dataSet) ? [.tag(0x004008EA)] : []))
        case .missingReferencedSOP(let path):
            var location: [DicomValidationReport.PathComponent] = [.tag(0x00081199)]
            let prefix = "root.referencedSOP["
            if path.hasPrefix(prefix), path.hasSuffix("]"),
               let index = Int(path.dropFirst(prefix.count).dropLast()), index >= 0,
               index < dataSet.sequenceItems(for: .referencedSOPSequence).count {
                location.append(.item(index))
            }
            return missing(location)
        case .invalidGraphicData:
            return .init(code: .semanticGraphicDataInvalid, severity: .error, layer: .operation, path: [.tag(0x00700022)])
        case .byReferenceNotPermitted:
            return .init(code: .relationshipNotAllowed, severity: .error, layer: .operation, path: [.tag(0x0040DB73)])
        case .byReferenceTargetMissing:
            return .init(code: .contentReferenceTargetMissing, severity: .error, layer: .operation, path: [.tag(0x0040DB73)])
        case .byReferenceTargetIsByReference:
            return .init(code: .contentReferenceTargetNotByValue, severity: .error, layer: .operation, path: [.tag(0x0040DB73)])
        case .byReferenceToSelfOrAncestor, .byReferenceCycle:
            return .init(code: .contentReferenceAncestorForbidden, severity: .error, layer: .operation, path: [.tag(0x0040DB73)])
        case .missingFrameOfReferenceUID:
            return missing([.tag(0x30060024)])
        case .invalidTemporalCoordinates:
            return .init(code: .referenceSelectionInvalid, severity: .error, layer: .operation, path: [.tag(0x0040A130)])
        case .missingEvidenceReference:
            return missing([.tag(0x0040A375)])
        }
    }

    private static func concept(_ path: String, dataSet: DicomDataSet) -> [DicomValidationReport.PathComponent] {
        if path == "root.codeValue" { return [.tag(0x0040A168)] }
        if path == "root.measurementUnits" { return measuredPath(dataSet) + [.tag(0x004008EA)] }
        return [.tag(0x0040A043)]
    }

    private static func hasMeasurement(_ dataSet: DicomDataSet) -> Bool {
        !dataSet.sequenceItems(for: .measuredValueSequence).isEmpty
    }

    private static func measuredPath(_ dataSet: DicomDataSet) -> [DicomValidationReport.PathComponent] {
        [.tag(0x0040A300)] + (hasMeasurement(dataSet) ? [.item(0)] : [])
    }

    private static func scope(_ path: [DicomValidationReport.PathComponent]) -> DicomValidationReport.Diagnostic {
        .init(code: .semanticScopeUnavailable, severity: .limitation, layer: .operation, path: path)
    }

    private static func missing(_ path: [DicomValidationReport.PathComponent]) -> DicomValidationReport.Diagnostic {
        .init(code: .semanticValueMissing, severity: .error, layer: .operation, path: path)
    }
}
