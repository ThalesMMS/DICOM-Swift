import Foundation

/// Declares the Structured Report semantic scope that DicomCore validates.
public struct DicomSRSupportMatrix: Equatable, Sendable {
    /// SR SOP Class UIDs with semantic validation support.
    public let supportedSOPClassUIDs: Set<String>

    /// Supported template identifiers per SOP Class UID.
    public let supportedTemplateIdentifiersBySOPClassUID: [String: Set<String>]

    /// SR value types accepted by the semantic validator.
    public let supportedValueTypes: Set<String>
    public var supportedValueTypesBySOPClassUID: [String: Set<String>] = [:]

    /// SR relationship types accepted for by-value content items.
    public let supportedRelationshipTypes: Set<String>

    /// SR relationship types accepted for by-reference content items.
    public let supportedByReferenceRelationshipTypes: Set<String>

    /// Coding scheme designators accepted for coded concepts in supported SR content.
    public let supportedCodingSchemeDesignators: Set<String>

    /// Coding scheme designators accepted for numeric measurement units.
    public let supportedMeasurementUnitSchemes: Set<String>

    /// Measurement group patterns covered by validator and round-trip tests.
    public let supportedMeasurementGroups: Set<String>

    /// Value types accepted as observation context content.
    public let supportedObservationContextValueTypes: Set<String>

    /// Whether Current Requested Procedure Evidence and content IMAGE references are supported.
    public let supportsEvidenceReferences: Bool

    /// Default DicomCore semantic scope: Comprehensive/Enhanced SR TID 1500 and KOS references.
    public static let standard = DicomSRSupportMatrix(
        supportedSOPClassUIDs: [
            DicomSRDocument.enhancedSRStorageSOPClassUID,
            DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            DicomSRDocument.comprehensive3DSRStorageSOPClassUID,
            DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
        ],
        supportedTemplateIdentifiersBySOPClassUID: [
            DicomSRDocument.enhancedSRStorageSOPClassUID: ["1500"],
            DicomSRDocument.comprehensiveSRStorageSOPClassUID: ["1500"],
            DicomSRDocument.comprehensive3DSRStorageSOPClassUID: ["1500"],
            DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID: ["2010"]
        ],
        supportedValueTypes: [
            "CONTAINER",
            "TEXT",
            "CODE",
            "NUM",
            "IMAGE",
            "SCOORD",
            "COMPOSITE", "WAVEFORM", "TCOORD",
            "UIDREF",
            "DATETIME",
            "DATE",
            "TIME",
            "PNAME"
        ],
        supportedValueTypesBySOPClassUID: Dictionary(uniqueKeysWithValues:
            DicomSRProfileConstraints.allCases.map { ($0.sopClassUID, $0.valueTypes) }),
        supportedRelationshipTypes: [
            "CONTAINS",
            "HAS OBS CONTEXT",
            "HAS CONCEPT MOD",
            "HAS ACQ CONTEXT", "HAS PROPERTIES",
            "INFERRED FROM",
            "SELECTED FROM"
        ],
        supportedByReferenceRelationshipTypes: [],
        supportedCodingSchemeDesignators: [
            "DCM",
            "SCT",
            "SRT",
            "UCUM",
            "RFC5646",
            "ISO639_2",
            "UMLS",
            "NCIt",
            "LN",
            "99LOCAL"
        ],
        supportedMeasurementUnitSchemes: ["UCUM"],
        supportedMeasurementGroups: [
            "TID1500 Imaging Measurement Report",
            "TID1500 numeric measurement with optional SCOORD ROI",
            "CAD finding container"
        ],
        supportedObservationContextValueTypes: [
            "COMPOSITE",
            "TEXT",
            "CODE",
            "UIDREF",
            "DATETIME",
            "DATE",
            "TIME",
            "PNAME"
        ],
        supportsEvidenceReferences: true
    )

    /// Returns true when the SOP Class UID and template identifier are supported together.
    public func supportsTemplate(_ templateIdentifier: String?, sopClassUID: String?) -> Bool {
        guard let sopClassUID,
              let supportedTemplates = supportedTemplateIdentifiersBySOPClassUID[sopClassUID] else {
            return false
        }
        guard !supportedTemplates.isEmpty else {
            return templateIdentifier == nil || templateIdentifier?.isEmpty == true
        }
        guard let templateIdentifier else {
            // A document without an identifier uses the root template its IOD mandates, when supported.
            return supportedTemplates.contains { DicomSRProfileConstraints(sopClassUID: sopClassUID)?.rootTemplateIdentifier == $0 }
        }
        return supportedTemplates.contains(templateIdentifier)
    }
}

/// Stable SR semantic validation errors for unsupported or malformed supported-scope content.
public enum DicomSRSemanticValidationError: Error, Equatable, LocalizedError, Sendable {
    /// The SR SOP Class UID is outside the semantic validation matrix.
    case unsupportedSOPClassUID(String?)

    /// The template identifier is unsupported for the SOP Class UID.
    case unsupportedTemplateIdentifier(String?, sopClassUID: String?)

    /// The root item is not a CONTAINER.
    case unsupportedRootValueType(String)

    /// The root concept does not match the declared supported template.
    case unsupportedRootConcept(path: String, codeValue: String?, codingSchemeDesignator: String?)

    /// A content item that requires a concept name is missing one.
    case missingConceptName(path: String)

    /// A coded concept uses a coding scheme outside the support matrix.
    case unsupportedCodingScheme(path: String, codingSchemeDesignator: String)

    /// A non-root content item has no relationship type.
    case missingRelationshipType(path: String)

    /// A relationship type is outside the support matrix.
    case unsupportedRelationshipType(path: String, relationshipType: String)

    /// A by-reference relationship was requested but is outside the support matrix.
    case unsupportedByReferenceRelationship(path: String, relationshipType: String)

    /// A content item value type is outside the support matrix.
    case unsupportedValueType(path: String, valueType: String)

    /// A content item lacks the value required by its value type.
    case missingValue(path: String, valueType: String)

    /// A NUM content item has no numeric value.
    case missingNumericValue(path: String)

    /// A NUM content item has no measurement units.
    case missingMeasurementUnits(path: String)

    /// A NUM content item uses unsupported measurement unit coding.
    case unsupportedMeasurementUnit(path: String, codingSchemeDesignator: String)

    /// An IMAGE content item or evidence item lacks a referenced SOP class or instance UID.
    case missingReferencedSOP(path: String)

    /// A SCOORD content item has invalid graphic type/data pairing.
    case invalidGraphicData(path: String, graphicType: String?, pointCount: Int)

    /// A KOS document has no evidence or IMAGE references.
    case missingEvidenceReference

    case byReferenceNotPermitted(path: String)
    case byReferenceTargetMissing(path: String, identifier: [Int])
    case byReferenceTargetIsByReference(path: String)
    case byReferenceToSelfOrAncestor(path: String)
    case byReferenceCycle(path: String)
    case missingFrameOfReferenceUID(path: String)
    case invalidTemporalCoordinates(path: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSOPClassUID(let sopClassUID):
            return "Unsupported SR SOP Class UID: \(sopClassUID ?? "nil")"
        case .unsupportedTemplateIdentifier(let templateIdentifier, let sopClassUID):
            return "Unsupported SR template \(templateIdentifier ?? "nil") for SOP Class UID \(sopClassUID ?? "nil")"
        case .unsupportedRootValueType(let valueType):
            return "Unsupported SR root value type: \(valueType)"
        case .unsupportedRootConcept(let path, let codeValue, let scheme):
            return "Unsupported SR root concept at \(path): \(scheme ?? "nil")/\(codeValue ?? "nil")"
        case .missingConceptName(let path):
            return "Missing SR concept name at \(path)"
        case .unsupportedCodingScheme(let path, let codingSchemeDesignator):
            return "Unsupported SR coding scheme at \(path): \(codingSchemeDesignator)"
        case .missingRelationshipType(let path):
            return "Missing SR relationship type at \(path)"
        case .unsupportedRelationshipType(let path, let relationshipType):
            return "Unsupported SR relationship type at \(path): \(relationshipType)"
        case .unsupportedByReferenceRelationship(let path, let relationshipType):
            return "Unsupported SR by-reference relationship at \(path): \(relationshipType)"
        case .unsupportedValueType(let path, let valueType):
            return "Unsupported SR value type at \(path): \(valueType)"
        case .missingValue(let path, let valueType):
            return "Missing SR \(valueType) value at \(path)"
        case .missingNumericValue(let path):
            return "Missing SR numeric value at \(path)"
        case .missingMeasurementUnits(let path):
            return "Missing SR measurement units at \(path)"
        case .unsupportedMeasurementUnit(let path, let codingSchemeDesignator):
            return "Unsupported SR measurement unit scheme at \(path): \(codingSchemeDesignator)"
        case .missingReferencedSOP(let path):
            return "Missing SR referenced SOP at \(path)"
        case .invalidGraphicData(let path, let graphicType, let pointCount):
            return "Invalid SR graphic data at \(path): \(graphicType ?? "nil") with \(pointCount) values"
        case .byReferenceNotPermitted(let path):
            return "byReferenceNotPermitted at \(path)"
        case .byReferenceTargetMissing(let path, _):
            return "byReferenceTargetMissing at \(path)"
        case .byReferenceTargetIsByReference(let path):
            return "byReferenceTargetIsByReference at \(path)"
        case .byReferenceToSelfOrAncestor(let path):
            return "byReferenceToSelfOrAncestor at \(path)"
        case .byReferenceCycle(let path):
            return "byReferenceCycle at \(path)"
        case .missingFrameOfReferenceUID(let path):
            return "missingFrameOfReferenceUID at \(path)"
        case .invalidTemporalCoordinates(let path):
            return "invalidTemporalCoordinates at \(path)"
        case .missingEvidenceReference:
            return "Missing SR evidence reference"
        }
    }
}

/// Result of Structured Report semantic validation.
public struct DicomSRSemanticValidationResult: Equatable, Sendable {
    /// Stable validation errors. Empty means the document is within the declared semantic scope.
    public let errors: [DicomSRSemanticValidationError]

    /// True when no semantic validation errors were found.
    public var isValid: Bool {
        errors.isEmpty
    }

    /// Creates a semantic validation result.
    public init(errors: [DicomSRSemanticValidationError]) {
        self.errors = errors
    }
}

/// Throwable validation failure containing every semantic validation error.
public struct DicomSRSemanticValidationFailure: Error, Equatable, LocalizedError, Sendable {
    /// Stable validation errors that caused the failure.
    public let errors: [DicomSRSemanticValidationError]

    /// Creates a throwable validation failure.
    public init(errors: [DicomSRSemanticValidationError]) {
        self.errors = errors
    }

    public var errorDescription: String? {
        errors.map { $0.errorDescription ?? String(describing: $0) }.joined(separator: "; ")
    }
}

/// Validates a parsed or builder-created Structured Report against the declared semantic scope.
public enum DicomSRSemanticValidator {
    public static func validateWithTemplate(_ document: DicomSRDocument) -> (
        semantic: DicomSRSemanticValidationResult, template: DicomSRTemplateValidationResult
    ) {
        (validate(document), DicomSRTemplateValidator.validate(document))
    }

    /// Validates a document and returns every semantic error found.
    public static func validate(
        _ document: DicomSRDocument,
        supportMatrix: DicomSRSupportMatrix = .standard
    ) -> DicomSRSemanticValidationResult {
        var errors: [DicomSRSemanticValidationError] = []
        validateDocumentIdentity(document, supportMatrix: supportMatrix, errors: &errors)
        validateItems(document.root, sopClassUID: document.sopClassUID, supportMatrix: supportMatrix, errors: &errors)
        validateEvidenceReferences(document.evidenceReferences, errors: &errors)

        if document.sopClassUID == DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID,
           document.keyObjectReferences.isEmpty {
            errors.append(.missingEvidenceReference)
        }

        return DicomSRSemanticValidationResult(errors: errors)
    }

    /// Throws when the document is outside the declared semantic support matrix.
    public static func validateForSemanticUse(
        _ document: DicomSRDocument,
        supportMatrix: DicomSRSupportMatrix = .standard
    ) throws {
        let result = validate(document, supportMatrix: supportMatrix)
        guard result.isValid else {
            throw DicomSRSemanticValidationFailure(errors: result.errors)
        }
    }

    static func validateDocumentIdentity(
        _ document: DicomSRDocument,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard let sopClassUID = document.sopClassUID,
              supportMatrix.supportedSOPClassUIDs.contains(sopClassUID) else {
            errors.append(.unsupportedSOPClassUID(document.sopClassUID))
            return
        }

        if !supportMatrix.supportsTemplate(document.templateIdentifier, sopClassUID: sopClassUID) {
            errors.append(.unsupportedTemplateIdentifier(document.templateIdentifier, sopClassUID: sopClassUID))
        }

        if document.root.valueType != "CONTAINER" {
            errors.append(.unsupportedRootValueType(document.root.valueType))
        }

        if sopClassUID == DicomSRDocument.comprehensiveSRStorageSOPClassUID ||
            sopClassUID == DicomSRDocument.enhancedSRStorageSOPClassUID ||
            sopClassUID == DicomSRDocument.comprehensive3DSRStorageSOPClassUID {
            validateExpectedRootConcept(
                document.root.conceptName,
                path: "root",
                expectedCodeValue: "126000",
                expectedScheme: "DCM",
                errors: &errors
            )
        }
    }

    private static func validateExpectedRootConcept(
        _ concept: DicomCodedConcept?,
        path: String,
        expectedCodeValue: String,
        expectedScheme: String,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard let concept else {
            errors.append(.missingConceptName(path: path))
            return
        }
        guard concept.codeValue == expectedCodeValue,
              concept.codingSchemeDesignator == expectedScheme else {
            errors.append(.unsupportedRootConcept(
                path: path,
                codeValue: concept.codeValue,
                codingSchemeDesignator: concept.codingSchemeDesignator
            ))
            return
        }
    }

    private struct ValidationChildrenFrame {
        let children: [DicomSRContentItem]
        let sourceValueType: String
        var nextChildIndex: Int
    }

    /// Validates the tree in the same preorder as the former recursive walk while
    /// keeping only one child cursor per level. The mutable index path avoids
    /// retaining a complete path string in every frame of a deep report.
    private static func validateItems(
        _ root: DicomSRContentItem,
        sopClassUID: String?,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        validateItemContents(
            root,
            path: "root",
            isRoot: true,
            sopClassUID: sopClassUID,
            supportMatrix: supportMatrix,
            errors: &errors
        )

        var pathIndices: [Int] = []
        var frames = [ValidationChildrenFrame(children: root.children, sourceValueType: root.valueType, nextChildIndex: 0)]
        while !frames.isEmpty {
            let frameIndex = frames.index(before: frames.endIndex)
            guard frames[frameIndex].nextChildIndex < frames[frameIndex].children.count else {
                frames.removeLast()
                if !pathIndices.isEmpty {
                    pathIndices.removeLast()
                }
                continue
            }

            let childIndex = frames[frameIndex].nextChildIndex
            let child = frames[frameIndex].children[childIndex]
            frames[frameIndex].nextChildIndex += 1
            pathIndices.append(childIndex)

            if child.isByReference {
                validateByReference(child, root: root, indices: pathIndices,
                    source: frames[frameIndex].sourceValueType, sopClassUID: sopClassUID, errors: &errors)
                pathIndices.removeLast()
                continue
            }
            if let relationship = child.relationshipType, !relationship.hasPrefix("R-"),
               let constraints = sopClassUID.flatMap(DicomSRRelationshipConstraints.init(rawValue:)),
               !constraints.permits(source: frames[frameIndex].sourceValueType, relationship: relationship,
                    target: child.valueType, byReference: false) {
                errors.append(.unsupportedRelationshipType(path: itemPath(indices: pathIndices), relationshipType: relationship))
            }
            validateItemContents(
                child,
                path: itemPath(indices: pathIndices),
                isRoot: false,
                sopClassUID: sopClassUID,
                supportMatrix: supportMatrix,
                errors: &errors
            )
            frames.append(ValidationChildrenFrame(children: child.children, sourceValueType: child.valueType, nextChildIndex: 0))
        }
    }

    static func referencedItem(in root: DicomSRContentItem, identifier: [Int]) -> DicomSRContentItem? {
        guard identifier.first == 1 else { return nil }
        var item = root
        for component in identifier.dropFirst() {
            guard component > 0, component <= item.children.count else { return nil }
            item = item.children[component - 1]
        }
        return item
    }

    static func validateByReference(
        _ item: DicomSRContentItem,
        root: DicomSRContentItem,
        indices: [Int],
        source: String,
        sopClassUID: String?,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        let path = itemPath(indices: indices)
        let identifier = item.referencedContentItemIdentifier ?? []
        let ownIdentifier = [1] + indices.map { $0 + 1 }
        let constraints = sopClassUID.flatMap(DicomSRRelationshipConstraints.init(rawValue:))
        if constraints != .comprehensive && constraints != .comprehensive3D {
            errors.append(.byReferenceNotPermitted(path: path))
        }
        if item.relationshipType == nil { errors.append(.missingRelationshipType(path: path)) }
        guard let target = referencedItem(in: root, identifier: identifier) else {
            errors.append(.byReferenceTargetMissing(path: path, identifier: identifier))
            return
        }
        if target.isByReference { errors.append(.byReferenceTargetIsByReference(path: path)) }
        if ownIdentifier.starts(with: identifier) {
            errors.append(.byReferenceToSelfOrAncestor(path: path))
        }
        if let constraints, !constraints.permits(source: source, relationship: item.relationshipType ?? "",
            target: target.valueType, byReference: true) {
            errors.append(.byReferenceNotPermitted(path: path))
        }
        // Include by-value edges: two sibling source items may reference each other through their children.
        var pending = [identifier]
        var visited = Set<[Int]>()
        let parentIdentifier = Array(ownIdentifier.dropLast())
        while let current = pending.popLast() {
            if current == ownIdentifier || current == parentIdentifier {
                errors.append(.byReferenceCycle(path: path))
                break
            }
            guard visited.insert(current).inserted,
                  let node = referencedItem(in: root, identifier: current) else { continue }
            if let reference = node.referencedContentItemIdentifier {
                pending.append(reference)
            } else {
                for index in node.children.indices { pending.append(current + [index + 1]) }
            }
        }
    }

    private static func itemPath(indices: [Int]) -> String {
        var path = "root"
        for index in indices {
            path.append("/")
            path.append(String(index))
        }
        return path
    }

    static func validateItemContents(
        _ item: DicomSRContentItem,
        path: String,
        isRoot: Bool,
        sopClassUID: String? = nil,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        if item.isByReference { return }
        let valueTypes = sopClassUID.flatMap { supportMatrix.supportedValueTypesBySOPClassUID[$0] }
            ?? supportMatrix.supportedValueTypes
        if !valueTypes.contains(item.valueType) {
            errors.append(.unsupportedValueType(path: path, valueType: item.valueType))
        }

        validateRelationship(item, path: path, isRoot: isRoot, supportMatrix: supportMatrix, errors: &errors)
        validateConcept(item.conceptName, path: "\(path).conceptName", supportMatrix: supportMatrix, errors: &errors)

        switch item.valueType {
        case "CONTAINER":
            break
        case "TEXT":
            validateRequired(item.textValue, path: path, valueType: item.valueType, errors: &errors)
        case "CODE":
            validateCodeValue(item, path: path, supportMatrix: supportMatrix, errors: &errors)
        case "NUM":
            validateNumericMeasurement(item, path: path, supportsQualifiedValue: sopClassUID != nil,
                supportMatrix: supportMatrix, errors: &errors)
        case "IMAGE", "COMPOSITE", "WAVEFORM":
            validateReferencedSOPs(item.referencedSOPs, path: path, errors: &errors)
        case "SCOORD3D":
            if item.frameOfReferenceUID?.dicomSRNonEmptyValue == nil {
                errors.append(.missingFrameOfReferenceUID(path: path))
            }
            validateGraphicData(item, path: path, errors: &errors)
        case "TCOORD":
            let forms = [!item.referencedSamplePositions.isEmpty, !item.referencedTimeOffsets.isEmpty,
                !item.referencedDateTimes.isEmpty].filter { $0 }.count
            if forms != 1 || !["POINT", "MULTIPOINT", "SEGMENT", "MULTISEGMENT", "BEGIN", "END"]
                .contains(item.temporalRangeType ?? "") || !item.referencedSamplePositions.allSatisfy({ $0 > 0 }) ||
                !item.referencedTimeOffsets.allSatisfy(\.isFinite) {
                errors.append(.invalidTemporalCoordinates(path: path))
            }
        case "SCOORD":
            validateGraphicData(item, path: path, errors: &errors)
        case "UIDREF":
            validateRequired(item.uidValue, path: path, valueType: item.valueType, errors: &errors)
        case "DATETIME":
            validateRequired(item.dateTimeValue?.rawValue, path: path, valueType: item.valueType, errors: &errors)
        case "DATE":
            validateRequired(item.dateValue?.rawValue, path: path, valueType: item.valueType, errors: &errors)
        case "TIME":
            validateRequired(item.timeValue?.rawValue, path: path, valueType: item.valueType, errors: &errors)
        case "PNAME":
            validateRequired(item.personNameValue?.rawValue, path: path, valueType: item.valueType, errors: &errors)
        default:
            break
        }
    }

    private static func validateRelationship(
        _ item: DicomSRContentItem,
        path: String,
        isRoot: Bool,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard !isRoot else { return }
        guard let relationshipType = item.relationshipType else {
            errors.append(.missingRelationshipType(path: path))
            return
        }
        if relationshipType.hasPrefix("R-"),
           !supportMatrix.supportedByReferenceRelationshipTypes.contains(relationshipType) {
            errors.append(.unsupportedByReferenceRelationship(path: path, relationshipType: relationshipType))
            return
        }
        if !supportMatrix.supportedRelationshipTypes.contains(relationshipType) {
            errors.append(.unsupportedRelationshipType(path: path, relationshipType: relationshipType))
        }
        if relationshipType == "HAS OBS CONTEXT",
           !supportMatrix.supportedObservationContextValueTypes.contains(item.valueType) {
            errors.append(.unsupportedValueType(path: path, valueType: item.valueType))
        }
    }

    private static func validateConcept(
        _ concept: DicomCodedConcept?,
        path: String,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard let concept else {
            errors.append(.missingConceptName(path: path))
            return
        }
        if concept.codeValue.dicomSRNonEmptyValue == nil ||
            concept.codingSchemeDesignator.dicomSRNonEmptyValue == nil {
            errors.append(.missingConceptName(path: path))
            return
        }
        if !supportMatrix.supportedCodingSchemeDesignators.contains(concept.codingSchemeDesignator) {
            errors.append(.unsupportedCodingScheme(
                path: path,
                codingSchemeDesignator: concept.codingSchemeDesignator
            ))
        }
    }

    private static func validateCodeValue(
        _ item: DicomSRContentItem,
        path: String,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard let codeValue = item.codeValue else {
            errors.append(.missingValue(path: path, valueType: item.valueType))
            return
        }
        validateConcept(codeValue, path: "\(path).codeValue", supportMatrix: supportMatrix, errors: &errors)
    }

    private static func validateNumericMeasurement(
        _ item: DicomSRContentItem,
        path: String,
        supportsQualifiedValue: Bool,
        supportMatrix: DicomSRSupportMatrix,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        if let qualifier = item.numericValueQualifier {
            validateConcept(qualifier, path: "\(path).numericValueQualifier", supportMatrix: supportMatrix, errors: &errors)
        }
        if item.numericValue == nil && item.floatingPointValue == nil &&
            (item.rationalNumeratorValue == nil || item.rationalDenominatorValue == nil) {
            if supportsQualifiedValue && item.numericValueQualifier != nil { return }
            errors.append(.missingNumericValue(path: path))
        }
        guard let units = item.measurementUnits else {
            errors.append(.missingMeasurementUnits(path: path))
            return
        }
        validateConcept(units, path: "\(path).measurementUnits", supportMatrix: supportMatrix, errors: &errors)
        if !supportMatrix.supportedMeasurementUnitSchemes.contains(units.codingSchemeDesignator) {
            errors.append(.unsupportedMeasurementUnit(
                path: path,
                codingSchemeDesignator: units.codingSchemeDesignator
            ))
        }
    }

    private static func validateReferencedSOPs(
        _ references: [DicomSourceImageReference],
        path: String,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard !references.isEmpty else {
            errors.append(.missingReferencedSOP(path: path))
            return
        }
        for (index, reference) in references.enumerated()
            where reference.referencedSOPClassUID?.dicomSRNonEmptyValue == nil ||
            reference.referencedSOPInstanceUID?.dicomSRNonEmptyValue == nil {
            errors.append(.missingReferencedSOP(path: "\(path).referencedSOP[\(index)]"))
        }
    }

    private static func validateEvidenceReferences(
        _ references: [DicomKeyObjectReference],
        errors: inout [DicomSRSemanticValidationError]
    ) {
        for (index, reference) in references.enumerated()
            where reference.referencedSOPClassUID?.dicomSRNonEmptyValue == nil ||
            reference.referencedSOPInstanceUID?.dicomSRNonEmptyValue == nil {
            errors.append(.missingReferencedSOP(path: "evidence[\(index)]"))
        }
    }

    private static func validateGraphicData(
        _ item: DicomSRContentItem,
        path: String,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        guard let graphicType = item.graphicType else {
            errors.append(.invalidGraphicData(path: path, graphicType: nil, pointCount: item.graphicData.count))
            return
        }
        let count = item.graphicData.count
        if item.valueType == "SCOORD3D" {
            let points = count / 3
            let valid: Bool
            switch graphicType {
            case "POINT": valid = points == 1
            case "MULTIPOINT": valid = points >= 1
            case "POLYLINE": valid = points >= 2
            case "POLYGON": valid = points >= 3 && item.graphicData.prefix(3).elementsEqual(item.graphicData.suffix(3))
            case "ELLIPSE": valid = points == 4
            case "ELLIPSOID": valid = points == 6
            default: valid = false
            }
            if !valid || count % 3 != 0 || !item.graphicData.allSatisfy(\.isFinite) {
                errors.append(.invalidGraphicData(path: path, graphicType: graphicType, pointCount: count))
            }
            return
        }
        let valid: Bool
        switch graphicType {
        case "POINT":
            valid = count == 2
        case "MULTIPOINT", "POLYLINE":
            valid = count >= 4 && count % 2 == 0
        case "CIRCLE":
            valid = count == 4
        case "ELLIPSE":
            valid = count == 8
        default:
            valid = false
        }
        if !valid || !item.graphicData.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            errors.append(.invalidGraphicData(path: path, graphicType: graphicType, pointCount: count))
        }
    }

    private static func validateRequired(
        _ value: String?,
        path: String,
        valueType: String,
        errors: inout [DicomSRSemanticValidationError]
    ) {
        if value?.dicomSRNonEmptyValue == nil {
            errors.append(.missingValue(path: path, valueType: valueType))
        }
    }
}

private extension String {
    var dicomSRNonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
