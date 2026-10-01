import Foundation

/// An identifier together with the authority that assigned it. Two identifiers are the same entity
/// only when both value and authority match; equal text under different authorities never is.
public struct AssignedIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    public var value: String
    /// Assigning authority: HL7 HD namespace, DICOM Issuer of Patient ID / Issuer of Accession Number, FHIR `system`.
    public var authority: String?

    public init(value: String, authority: String? = nil) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = authority?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authority = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public var description: String { authority.map { value + "@" + $0 } ?? value }

    /// Same entity: identical value and identical (case-sensitive) authority; an absent authority
    /// matches only an absent authority.
    public func sameEntity(as other: AssignedIdentifier) -> Bool { value == other.value && authority == other.authority }
    /// Same text but a different (or one-sided) authority: a conflict that needs a human or a policy.
    public func conflicts(with other: AssignedIdentifier) -> Bool { value == other.value && authority != other.authority }
}

/// The six identity fields Isis unifies on (#2260): name parts, patient identifier with issuer,
/// birth date and sex. Mapping never reconciles identities; it reports matches and conflicts.
public struct ClinicalPatientIdentity: Equatable, Sendable, Codable {
    public var familyName: String?
    public var givenName: String?
    public var identifier: AssignedIdentifier?
    /// ISO 8601 date (`YYYY-MM-DD`), partial dates allowed.
    public var birthDate: String?
    /// `M`, `F`, `O` or nil (DICOM spelling; FHIR/HL7 v2 values are translated).
    public var sex: String?
    public var otherIdentifiers: [AssignedIdentifier]

    public init(familyName: String? = nil, givenName: String? = nil, identifier: AssignedIdentifier? = nil, birthDate: String? = nil,
                sex: String? = nil, otherIdentifiers: [AssignedIdentifier] = []) {
        self.familyName = familyName
        self.givenName = givenName
        self.identifier = identifier
        self.birthDate = birthDate
        self.sex = sex
        self.otherIdentifiers = otherIdentifiers
    }

    public var isEmpty: Bool { familyName == nil && givenName == nil && identifier == nil && birthDate == nil && sex == nil && otherIdentifiers.isEmpty }

    public enum Comparison: Equatable, Sendable {
        /// Shared identifier+authority or populated demographic evidence, without conflicting fields.
        case same
        /// Same identifier text under another authority, or demographics that disagree.
        case conflict([String])
        /// Nothing in common to decide on.
        case unrelated
    }

    /// Identity decision without reconciliation: the host decides what to do with conflicts.
    public func compare(with other: ClinicalPatientIdentity) -> Comparison {
        var conflicts: [String] = []
        var hasEvidence = false
        if let mine = identifier, let theirs = other.identifier, !mine.value.isEmpty, !theirs.value.isEmpty {
            if mine.conflicts(with: theirs) { conflicts.append("identifier authority") }
        }
        let mine = ([identifier].compactMap { $0 } + otherIdentifiers).filter { !$0.value.isEmpty }
        let theirs = ([other.identifier].compactMap { $0 } + other.otherIdentifiers).filter { !$0.value.isEmpty }
        if !mine.isEmpty || !theirs.isEmpty {
            hasEvidence = mine.contains { candidate in theirs.contains { candidate.sameEntity(as: $0) } }
            if !hasEvidence, conflicts.isEmpty {
                if mine.contains(where: { candidate in theirs.contains { candidate.conflicts(with: $0) } }) {
                    conflicts.append("identifier authority")
                } else if !mine.isEmpty && !theirs.isEmpty { return .unrelated }
            }
        }
        var matchedDemographics: Set<String> = []
        for (field, lhs, rhs) in [("birthDate", birthDate, other.birthDate), ("sex", sex, other.sex),
                                  ("familyName", familyName, other.familyName), ("givenName", givenName, other.givenName)] {
            guard let a = lhs, let b = rhs, !a.isEmpty, !b.isEmpty else { continue }
            let equal = field == "familyName" || field == "givenName" ? a.caseInsensitiveCompare(b) == .orderedSame : a == b
            if equal { matchedDemographics.insert(field) } else { conflicts.append(field) }
        }
        if !conflicts.isEmpty { return .conflict(conflicts) }
        hasEvidence = hasEvidence || matchedDemographics.contains("birthDate") ||
            (matchedDemographics.count > 1 && !matchedDemographics.isDisjoint(with: ["familyName", "givenName"]))
        return hasEvidence ? .same : .unrelated
    }
}

public struct ClinicalCode: Hashable, Sendable, Codable {
    public var system: String?
    public var code: String
    public var display: String?
    public init(system: String? = nil, code: String, display: String? = nil) {
        self.system = system
        self.code = code
        self.display = display
    }
}

public struct ClinicalPractitioner: Equatable, Sendable, Codable {
    public var identifier: AssignedIdentifier?
    public var familyName: String?
    public var givenName: String?
    public init(identifier: AssignedIdentifier? = nil, familyName: String? = nil, givenName: String? = nil) {
        self.identifier = identifier
        self.familyName = familyName
        self.givenName = givenName
    }
    public var displayName: String { [givenName, familyName].compactMap { $0 }.joined(separator: " ") }
}

/// An imaging order (ORM/ServiceRequest/MWL scheduled step) with every identifier and authority kept.
public struct ClinicalOrder: Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Codable { case requested, scheduled, inProgress, completed, cancelled, unknown }
    public var placerOrderNumber: AssignedIdentifier?
    public var fillerOrderNumber: AssignedIdentifier?
    public var accessionNumber: AssignedIdentifier?
    public var requestedProcedureID: String?
    public var procedure: ClinicalCode?
    public var procedureDescription: String?
    public var modality: String?
    public var scheduledStart: String?    // ISO 8601 dateTime or date
    public var scheduledStationAETitle: String?
    public var referringPhysician: ClinicalPractitioner?
    public var patient: ClinicalPatientIdentity
    public var status: Status
    public var priority: String?
    public var reason: String?

    public init(patient: ClinicalPatientIdentity, placerOrderNumber: AssignedIdentifier? = nil, fillerOrderNumber: AssignedIdentifier? = nil,
                accessionNumber: AssignedIdentifier? = nil, requestedProcedureID: String? = nil, procedure: ClinicalCode? = nil,
                procedureDescription: String? = nil, modality: String? = nil, scheduledStart: String? = nil, scheduledStationAETitle: String? = nil,
                referringPhysician: ClinicalPractitioner? = nil, status: Status = .requested, priority: String? = nil, reason: String? = nil) {
        self.patient = patient
        self.placerOrderNumber = placerOrderNumber
        self.fillerOrderNumber = fillerOrderNumber
        self.accessionNumber = accessionNumber
        self.requestedProcedureID = requestedProcedureID
        self.procedure = procedure
        self.procedureDescription = procedureDescription
        self.modality = modality
        self.scheduledStart = scheduledStart
        self.scheduledStationAETitle = scheduledStationAETitle
        self.referringPhysician = referringPhysician
        self.status = status
        self.priority = priority
        self.reason = reason
    }

    /// Idempotency key: placer number with authority, else accession with issuer, else filler number.
    public var idempotencyKey: String? {
        (placerOrderNumber ?? accessionNumber ?? fillerOrderNumber).map { "order:" + $0.description }
    }
}

/// A performed imaging study as seen from DICOM (or an ImagingStudy resource).
public struct ClinicalStudy: Equatable, Sendable, Codable {
    public struct Series: Equatable, Sendable, Codable {
        public var uid: String
        public var number: Int?
        public var modality: String?
        public var description: String?
        public var instanceUIDs: [String]
        /// SOP Class UIDs keyed by SOP Instance UID; nil also supports older serialized studies.
        public var sopClassUIDs: [String: String]?
        public init(uid: String, number: Int? = nil, modality: String? = nil, description: String? = nil, instanceUIDs: [String] = [], sopClassUIDs: [String: String]? = nil) {
            self.uid = uid
            self.number = number
            self.modality = modality
            self.description = description
            self.instanceUIDs = instanceUIDs
            self.sopClassUIDs = sopClassUIDs
        }
    }
    public var studyInstanceUID: String
    public var accessionNumber: AssignedIdentifier?
    public var placerOrderNumber: AssignedIdentifier?
    public var fillerOrderNumber: AssignedIdentifier?
    public var requestedProcedureID: String?
    public var studyID: String?
    public var description: String?
    public var modalities: [String]
    public var started: String?
    public var patient: ClinicalPatientIdentity
    public var referringPhysician: ClinicalPractitioner?
    public var series: [Series]
    public var performedProcedureStepID: String?

    public init(studyInstanceUID: String, patient: ClinicalPatientIdentity, accessionNumber: AssignedIdentifier? = nil,
                placerOrderNumber: AssignedIdentifier? = nil, fillerOrderNumber: AssignedIdentifier? = nil, requestedProcedureID: String? = nil,
                studyID: String? = nil, description: String? = nil, modalities: [String] = [], started: String? = nil,
                referringPhysician: ClinicalPractitioner? = nil, series: [Series] = [], performedProcedureStepID: String? = nil) {
        self.studyInstanceUID = studyInstanceUID
        self.patient = patient
        self.accessionNumber = accessionNumber
        self.placerOrderNumber = placerOrderNumber
        self.fillerOrderNumber = fillerOrderNumber
        self.requestedProcedureID = requestedProcedureID
        self.studyID = studyID
        self.description = description
        self.modalities = modalities
        self.started = started
        self.referringPhysician = referringPhysician
        self.series = series
        self.performedProcedureStepID = performedProcedureStepID
    }

    public var idempotencyKey: String { "study:" + studyInstanceUID }
    public var instanceCount: Int { series.reduce(0) { $0 + $1.instanceUIDs.count } }
}

/// One observation of a result: numeric with units, coded, or text. Free text is never turned into a code.
public struct ClinicalObservation: Equatable, Sendable, Codable {
    public enum Value: Equatable, Sendable, Codable {
        case numeric(value: String, unit: String?)
        case coded(ClinicalCode)
        case text(String)
        case absent(reason: String)
    }
    public var code: ClinicalCode
    public var value: Value
    public var status: String?             // HL7 0085 / FHIR observation-status spelling of the source
    public var effective: String?
    public var interpretation: String?     // HL7 0078 code
    public var referenceRange: String?
    public var subID: String?

    public init(code: ClinicalCode, value: Value, status: String? = nil, effective: String? = nil, interpretation: String? = nil,
                referenceRange: String? = nil, subID: String? = nil) {
        self.code = code
        self.value = value
        self.status = status
        self.effective = effective
        self.interpretation = interpretation
        self.referenceRange = referenceRange
        self.subID = subID
    }
}

/// A result/report (ORU, DiagnosticReport, SR) linked to its order and study by identifiers, never by guesswork.
public struct ClinicalResult: Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Codable { case preliminary, final, corrected, cancelled, unknown }
    public var identifier: AssignedIdentifier?
    public var placerOrderNumber: AssignedIdentifier?
    public var fillerOrderNumber: AssignedIdentifier?
    public var accessionNumber: AssignedIdentifier?
    public var studyInstanceUID: String?
    public var procedure: ClinicalCode?
    public var status: Status
    public var issued: String?
    public var observations: [ClinicalObservation]
    public var reportText: [String]
    public var author: ClinicalPractitioner?
    public var patient: ClinicalPatientIdentity
    /// Identifier of the result this one corrects/replaces.
    public var supersedes: AssignedIdentifier?
    public var version: Int

    public init(patient: ClinicalPatientIdentity, identifier: AssignedIdentifier? = nil, placerOrderNumber: AssignedIdentifier? = nil,
                fillerOrderNumber: AssignedIdentifier? = nil, accessionNumber: AssignedIdentifier? = nil, studyInstanceUID: String? = nil,
                procedure: ClinicalCode? = nil, status: Status = .final, issued: String? = nil, observations: [ClinicalObservation] = [],
                reportText: [String] = [], author: ClinicalPractitioner? = nil, supersedes: AssignedIdentifier? = nil, version: Int = 1) {
        self.patient = patient
        self.identifier = identifier
        self.placerOrderNumber = placerOrderNumber
        self.fillerOrderNumber = fillerOrderNumber
        self.accessionNumber = accessionNumber
        self.studyInstanceUID = studyInstanceUID
        self.procedure = procedure
        self.status = status
        self.issued = issued
        self.observations = observations
        self.reportText = reportText
        self.author = author
        self.supersedes = supersedes
        self.version = version
    }

    public var idempotencyKey: String? {
        (identifier ?? fillerOrderNumber ?? placerOrderNumber ?? accessionNumber).map { "result:" + $0.description + ":v\(version)" }
    }
}

// MARK: - Mapping report and provenance

public enum MappingEntryKind: String, Sendable, Codable { case mapped, absent, changed, lost }

/// One line of a mapping report: paths and codes only, never values.
public struct MappingEntry: Equatable, Sendable, Codable {
    public var kind: MappingEntryKind
    public var source: String?
    public var target: String?
    public var reason: String?
    public init(kind: MappingEntryKind, source: String? = nil, target: String? = nil, reason: String? = nil) {
        self.kind = kind
        self.source = source
        self.target = target
        self.reason = reason
    }
    public static func mapped(_ source: String, _ target: String) -> MappingEntry { .init(kind: .mapped, source: source, target: target) }
    public static func absent(_ target: String, reason: String = "sourceNotPresent") -> MappingEntry { .init(kind: .absent, target: target, reason: reason) }
    public static func changed(_ source: String, _ target: String, reason: String) -> MappingEntry { .init(kind: .changed, source: source, target: target, reason: reason) }
    public static func lost(_ source: String, reason: String) -> MappingEntry { .init(kind: .lost, source: source, reason: reason) }
}

public struct MappingReport: Equatable, Sendable, Codable {
    public var entries: [MappingEntry] = []
    public var warnings: [String] = []
    public init(entries: [MappingEntry] = [], warnings: [String] = []) {
        self.entries = entries
        self.warnings = warnings
    }
    public mutating func add(_ entry: MappingEntry) { entries.append(entry) }
    public var lost: [MappingEntry] { entries.filter { $0.kind == .lost } }
    public var hasLoss: Bool { !lost.isEmpty }
    public func count(_ kind: MappingEntryKind) -> Int { entries.filter { $0.kind == kind }.count }
}

public enum MappingError: Error, Equatable, Sendable {
    case lossNotAllowed(MappingReport)
    case unsupportedMessage(String)
    case missingIdentifier(String)
    case identityConflict([String])
}

public struct MappingOptions: Equatable, Sendable {
    /// Strict mode refuses any `lost` entry.
    public var strict: Bool
    public init(strict: Bool = false) { self.strict = strict }
}

/// Where a mapped entity came from: enough to audit and to detect retries, no clinical content.
public struct ClinicalProvenance: Equatable, Sendable, Codable {
    public enum SourceKind: String, Sendable, Codable { case hl7v2, dicom, fhir, cda }
    public var sourceKind: SourceKind
    /// Message control ID, SOP Instance UID, `Type/id/_history/v`, or a document id; empty when absent.
    public var sourceIdentifier: String
    /// SHA-256 of the source bytes when available, so retries of identical content are recognisable.
    public var sourceDigest: String?
    public var recordedAt: Date
    public var agent: String
    public var mapper: String
    public var report: MappingReport

    public init(sourceKind: SourceKind, sourceIdentifier: String, sourceDigest: String? = nil, recordedAt: Date = Date(),
                agent: String = "DICOM-Swift ClinicalMapping", mapper: String, report: MappingReport) {
        self.sourceKind = sourceKind
        self.sourceIdentifier = sourceIdentifier
        self.sourceDigest = sourceDigest
        self.recordedAt = recordedAt
        self.agent = agent
        self.mapper = mapper
        self.report = report
    }
}

public struct Mapped<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var provenance: ClinicalProvenance
    public var report: MappingReport { provenance.report }
    public init(value: Value, provenance: ClinicalProvenance) {
        self.value = value
        self.provenance = provenance
    }
}
