import Foundation

/// Composable validation evidence. A passed layer says nothing about unevaluated layers.
/// Diagnostics contain schema identifiers and locations, never values read from an instance; the only exception is
/// `detail`, which carries technical codestream facts such as a video profile or level, never patient data.
public struct DicomValidationReport: Equatable, Sendable, Codable {
    public enum Layer: String, CaseIterable, Sendable, Codable {
        case structure, vrAndVM, attributes, references, pixelsAndGeometry, codestream, operation
    }

    public enum Outcome: String, Sendable, Codable {
        case passed, failed, incomplete, notEvaluated
    }

    public enum Severity: String, Sendable, Codable {
        case error, warning, limitation
    }

    public enum Code: String, Sendable, Codable {
        case requiredAttributeMissing, requiredValueEmpty, conditionalAttributeForbidden
        case conditionUndetermined, sequenceExpected, valueUnavailable, evaluationLimitReached, emptyRuleSet
        case attributeValueNotAllowed, sequenceItemCountInvalid, attributeValueContradiction
        case moduleRuleUnavailable
        case exclusiveAttributeChoiceInvalid
        case invalidTextEncoding, invalidTextValue, unsupportedCharacterSet
        case invalidBinaryLength, invalidValueLength, invalidMultiplicity
        case invalidPrivateCreator, duplicatePrivateCreator, duplicateElement, ambiguousVR, incompatibleVR
        case invalidDataSetStructure, invalidDeflatedDataSet, validationInterrupted
        case referenceEvidenceMissing, referenceEvidenceUnexpected, referenceEvidenceConflict
        case referenceIdentityContradiction, referenceTargetUnavailable, referenceRuleUnavailable
        case contentReferenceIdentifierInvalid, contentReferenceTargetMissing, contentReferenceTargetNotByValue
        case contentReferenceAncestorForbidden, relationshipNotAllowed
        case referenceSelectionInvalid, referenceSelectionOutOfRange, referenceTargetGeometryInvalid
        case pixelDataLengthMismatch, pixelMetadataContradiction
        case semanticScopeUnavailable, semanticValueMissing, semanticGraphicDataInvalid
        case semanticProjectionUnavailable
        case referenceSOPClassNotAllowed
        case requiredRelationshipMissing
        case spatialGeometryInvalid, spatialGeometryDegenerate, spatialGeometryPrecisionUnavailable
        case spatialCoordinateOutOfRange
        case temporalCoordinateOutOfRange, temporalAlignmentUnavailable
        case invalidCodestream, codestreamRuleUnavailable, codestreamRowBoundaryViolation, codestreamReplicateRunRequired
        case codestreamSegmentPaddingMissing
        case codestreamProfileMismatch, codestreamPayloadUnverified, codestreamColorProfileUnavailable
        case videoBitstreamConstraintViolation
    }

    public enum PathComponent: Equatable, Sendable, Codable {
        case tag(Int)
        /// Zero-based sequence item index. For encapsulated Pixel Data, item zero
        /// is the Basic Offset Table; fragment items do not identify frame numbers.
        case item(Int)
        /// Zero-based frame index.
        case frame(Int)
    }

    public struct Diagnostic: Equatable, Sendable, Codable {
        public let code: Code
        public let severity: Severity
        public let layer: Layer
        public let path: [PathComponent]
        public let requirement: DicomAttributeRule.Requirement?
        /// The found and expected codestream facts behind the diagnostic, when the code alone does not say them.
        public let detail: String?

        public init(code: Code, severity: Severity, layer: Layer, path: [PathComponent] = [],
                    requirement: DicomAttributeRule.Requirement? = nil, detail: String? = nil) {
            self.code = code
            self.severity = severity
            self.layer = layer
            self.path = path
            self.requirement = requirement
            self.detail = detail
        }
    }

    public let diagnostics: [Diagnostic]
    public let evaluatedLayers: Set<Layer>

    public init(evaluatedLayers: Set<Layer> = [], diagnostics: [Diagnostic] = []) {
        self.evaluatedLayers = evaluatedLayers.union(diagnostics.map(\.layer))
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey { case evaluatedLayers, diagnostics, outcomes }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evaluatedLayers.sorted { $0.rawValue < $1.rawValue }, forKey: .evaluatedLayers)
        try container.encode(diagnostics, forKey: .diagnostics)
        try container.encode(Dictionary(uniqueKeysWithValues: Layer.allCases.map { ($0.rawValue, self[$0]) }), forKey: .outcomes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(evaluatedLayers: Set(try container.decode([Layer].self, forKey: .evaluatedLayers)),
                  diagnostics: try container.decode([Diagnostic].self, forKey: .diagnostics))
        // Outcomes are derived from evidence, never trusted from serialized summaries.
    }

    public subscript(layer: Layer) -> Outcome {
        let relevant = diagnostics.filter { $0.layer == layer }
        if relevant.contains(where: { $0.severity == .error }) { return .failed }
        if relevant.contains(where: { $0.severity == .limitation }) { return .incomplete }
        return evaluatedLayers.contains(layer) ? .passed : .notEvaluated
    }

    /// Combines independent checks without promoting missing evidence to success.
    public func merging(_ other: Self) -> Self {
        Self(evaluatedLayers: evaluatedLayers.union(other.evaluatedLayers),
             diagnostics: diagnostics + other.diagnostics)
    }

    /// Keeps a terminal limit marker within a composing module's diagnostic allowance.
    func limitingDiagnostics(to maximum: Int) -> Self {
        let maximum = max(0, maximum)
        guard diagnostics.count > maximum else { return self }
        let terminal = diagnostics.last { $0.code == .evaluationLimitReached }
            ?? .init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes)
        let retained = maximum > 0 ? Array(diagnostics.prefix(maximum - 1)) + [terminal] : []
        let truncatedLayers = Set(diagnostics.dropFirst(max(0, maximum - 1)).map(\.layer))
        let unevaluated = truncatedLayers.filter { layer in
            !retained.contains { $0.layer == layer && ($0.severity == .error || $0.severity == .limitation) }
        }
        return Self(evaluatedLayers: evaluatedLayers.subtracting(unevaluated),
                    diagnostics: retained.filter { !unevaluated.contains($0.layer) })
    }

    /// The caller must identify the layers required by its profile or operation.
    /// An empty selection is incomplete, not a vacuous claim of conformance.
    public func outcome(requiring layers: Set<Layer>) -> Outcome {
        let outcomes = layers.map { self[$0] }
        if outcomes.contains(.failed) { return .failed }
        if layers.isEmpty || outcomes.contains(.incomplete) || outcomes.contains(.notEvaluated) { return .incomplete }
        return .passed
    }
}
