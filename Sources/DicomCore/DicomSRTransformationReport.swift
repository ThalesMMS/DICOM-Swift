import Foundation

public struct DicomSRTransformationReport: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case valueTypeNotPermitted
        case relationshipNotPermitted
        case byReferenceNotPermitted
        case attributeNotRepresentable
        case itemSkipped
    }

    public struct Entry: Equatable, Sendable {
        public let path: [Int]
        public let kind: Kind
        public let detail: String

        public init(path: [Int], kind: Kind, detail: String) {
            self.path = path
            self.kind = kind
            self.detail = detail
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(parseDiagnostics: [DicomSRParseDiagnostic]) {
        entries = parseDiagnostics.map {
            Entry(path: $0.path, kind: $0.code == "itemSkipped" ? .itemSkipped : .attributeNotRepresentable,
                detail: $0.code == "itemSkipped" ? "Content item was skipped." : "Attribute could not be represented.")
        }
    }
}

extension DicomStructuredReportBuilder {
    public static func transformationReport(for document: DicomSRDocument) -> DicomSRTransformationReport {
        var entries = DicomSRTransformationReport(parseDiagnostics: document.parseDiagnostics).entries
        let profile = document.sopClassUID.flatMap(DicomSRProfileConstraints.init(sopClassUID:))
        let relationships = document.sopClassUID.flatMap(DicomSRRelationshipConstraints.init(rawValue:))
        var pending: [(DicomSRContentItem, [Int], String?)] = [(document.root, [], nil)]
        while let (item, path, source) = pending.popLast() {
            if item.isByReference {
                var errors: [DicomSRSemanticValidationError] = []
                DicomSRSemanticValidator.validateByReference(item, root: document.root, indices: path,
                    source: source ?? "", sopClassUID: document.sopClassUID, errors: &errors)
                if !errors.isEmpty {
                    entries.append(.init(path: path, kind: .byReferenceNotPermitted,
                        detail: "By-reference relationship is not permitted or its target cannot be resolved."))
                }
                if item.valueType != "CONTAINER" || item.conceptName != nil || !item.children.isEmpty || item.textValue != nil ||
                    item.codeValue != nil || item.numericValue != nil || item.contentTemplate != nil ||
                    item.frameOfReferenceUID != nil || item.observationUID != nil || item.observationDateTime != nil ||
                    item.fiducialUID != nil || item.temporalRangeType != nil || !item.referencedSamplePositions.isEmpty ||
                    !item.referencedTimeOffsets.isEmpty || !item.referencedDateTimes.isEmpty ||
                    item.numericValueQualifier != nil || item.floatingPointValue != nil ||
                    item.rationalNumeratorValue != nil || item.rationalDenominatorValue != nil ||
                    item.measurementUnits != nil || item.dateTimeValue != nil || item.dateValue != nil ||
                    item.timeValue != nil || item.personNameValue != nil || item.uidValue != nil ||
                    !item.referencedSOPs.isEmpty || item.graphicType != nil || !item.graphicData.isEmpty ||
                    item.trackingID != nil || item.trackingUID != nil || item.continuityOfContent != nil {
                    entries.append(.init(path: path, kind: .attributeNotRepresentable,
                        detail: "By-reference serialization carries only the relationship and target identifier."))
                }
                continue
            }
            if profile?.valueTypes.contains(item.valueType) != true {
                entries.append(.init(path: path, kind: .valueTypeNotPermitted,
                    detail: "Value Type is not permitted by the SOP Class."))
            }
            if let source, relationships?.permits(source: source, relationship: item.relationshipType ?? "",
                target: item.valueType, byReference: false) != true {
                entries.append(.init(path: path, kind: .relationshipNotPermitted,
                    detail: "Relationship is not permitted by the SOP Class."))
            }
            if item.contentTemplate != nil && item.valueType != "CONTAINER" {
                entries.append(.init(path: path, kind: .attributeNotRepresentable,
                    detail: "Content Template Identification requires a CONTAINER."))
            }
            for index in item.children.indices.reversed() {
                pending.append((item.children[index], path + [index], item.valueType))
            }
        }
        return .init(entries: entries)
    }
}
