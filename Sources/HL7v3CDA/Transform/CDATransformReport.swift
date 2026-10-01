import Foundation

/// The direction of a single field-level transformation observation.
public enum CDATransformEntryKind: String, Codable, CaseIterable, Sendable {
    case mapped
    case absent
    case changed
    case lost
}

/// A content-free transformation observation.  `source` and `target` are
/// paths or element names; values from a patient document are deliberately not
/// copied into reports.
public struct CDATransformEntry: Codable, Equatable, Sendable {
    public let kind: CDATransformEntryKind
    public let source: String?
    public let target: String?
    public let reason: String?
    public let transformation: String?
    public let changedWithLoss: Bool

    public init(kind: CDATransformEntryKind, source: String? = nil, target: String? = nil,
                reason: String? = nil, transformation: String? = nil, changedWithLoss: Bool = false) {
        self.kind = kind
        self.source = source
        self.target = target
        self.reason = reason
        self.transformation = transformation
        self.changedWithLoss = changedWithLoss
    }

    public static func mapped(_ source: String, _ target: String) -> Self {
        .init(kind: .mapped, source: source, target: target)
    }

    public static func absent(_ target: String, reason: String) -> Self {
        .init(kind: .absent, target: target, reason: reason)
    }

    public static func changed(_ source: String? = nil, _ target: String, transformation: String,
                               withLoss: Bool = false) -> Self {
        .init(kind: .changed, source: source, target: target, transformation: transformation,
              changedWithLoss: withLoss)
    }

    public static func lost(_ source: String, reason: String) -> Self {
        .init(kind: .lost, source: source, reason: reason)
    }

    public var isLoss: Bool { kind == .lost || (kind == .changed && changedWithLoss) }
    public var path: String { target ?? source ?? "" }
}

public struct CDATransformReport: Codable, Equatable, Sendable {
    public var entries: [CDATransformEntry]
    public var warnings: [String]

    public init(entries: [CDATransformEntry] = [], warnings: [String] = []) {
        self.entries = entries
        self.warnings = warnings
    }

    public mutating func add(_ entry: CDATransformEntry) { entries.append(entry) }
    public mutating func warning(_ code: String) { warnings.append(code) }

    public var mapped: [CDATransformEntry] { entries.filter { $0.kind == .mapped } }
    public var absent: [CDATransformEntry] { entries.filter { $0.kind == .absent } }
    public var changed: [CDATransformEntry] { entries.filter { $0.kind == .changed } }
    public var lost: [CDATransformEntry] { entries.filter { $0.kind == .lost } }
    public var losses: [CDATransformEntry] { entries.filter(\.isLoss) }

    public var mappedCount: Int { mapped.count }
    public var absentCount: Int { absent.count }
    public var changedCount: Int { changed.count }
    public var lostCount: Int { lost.count }
    public var warningCount: Int { warnings.count }
    public var hasLoss: Bool { entries.contains(where: \.isLoss) }

    /// Aliases make the report convenient for JSON/CLI clients that use the
    /// noun form rather than the field-level collections.
    public var mappedFields: [CDATransformEntry] { mapped }
    public var absentFields: [CDATransformEntry] { absent }
    public var changedFields: [CDATransformEntry] { changed }
    public var lostFields: [CDATransformEntry] { lost }
    public var totalCount: Int { entries.count }
}

public struct CDATransformOptions: Equatable, Sendable {
    public var strict: Bool
    public init(strict: Bool = false) { self.strict = strict }
}

public enum CDATransformError: Error, Equatable, Sendable, LocalizedError {
    case lossNotAllowed(CDATransformReport)
    case unsupportedProfile(String)
    case unsupportedMessageType(String)
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .lossNotAllowed(let report):
            return "CDA transformation loss is not allowed (\(report.losses.count) loss entries)."
        case .unsupportedProfile(let profile): return "Unsupported CDA transformation profile: \(profile)."
        case .unsupportedMessageType(let type): return "Unsupported HL7 v2 message type: \(type)."
        case .invalidDocument: return "The CDA document is invalid for this transformation."
        }
    }
}

public enum CDATransformProfile: String, Codable, CaseIterable, Sendable {
    case adt
    case oru
    case orm

    public init?(message: String) {
        switch message.uppercased() {
        case "ADT": self = .adt
        case "ORU": self = .oru
        case "ORM": self = .orm
        default: return nil
        }
    }
}

public typealias CDAProfile = CDATransformProfile

/// Small, deterministic vocabulary mappings used by the v2/CDA bridge.  The
/// translator intentionally has no network or terminology-service dependency.
public struct CDACodeTranslation: Equatable, Sendable {
    public let value: String?
    public let changed: Bool
    public let reason: String?

    public init(value: String?, changed: Bool = false, reason: String? = nil) {
        self.value = value
        self.changed = changed
        self.reason = reason
    }
}

public enum CodeSystemTranslator {
    public static let administrativeGenderCodeSystem = "2.16.840.1.113883.5.1"
    public static let resultStatusCodeSystem = "2.16.840.1.113883.5.14"
    public static let observationInterpretationCodeSystem = "2.16.840.1.113883.5.83"

    /// HL7 table 0001 to AdministrativeGender.
    public static func gender(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return .init(value: nil, reason: "codeSystemUnknown")
        }
        switch code.uppercased() {
        case "F": return .init(value: "F")
        case "M": return .init(value: "M")
        case "U": return .init(value: "UN", changed: true, reason: "codeSystemTranslation")
        case "O": return .init(value: "UN", changed: true, reason: "codeSystemTranslation")
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }

    public static func translateGender(_ code: String?) -> CDACodeTranslation { gender(code) }

    /// AdministrativeGender to HL7 table 0001.
    public static func reverseGender(_ code: String?) -> CDACodeTranslation {
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "F": return .init(value: "F")
        case "M": return .init(value: "M")
        case "UN": return .init(value: "U", changed: true, reason: "codeSystemTranslation")
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }

    /// HL7 table 0085 to CDA Act/Observation statusCode.
    public static func resultStatus(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return .init(value: nil, reason: "codeSystemUnknown")
        }
        switch code.uppercased() {
        case "F", "C": return .init(value: "completed", changed: true, reason: "codeSystemTranslation")
        case "P", "I", "R": return .init(value: "active", changed: true, reason: "codeSystemTranslation")
        case "X": return .init(value: "cancelled", changed: true, reason: "codeSystemTranslation")
        case "A": return .init(value: "aborted", changed: true, reason: "codeSystemTranslation")
        case "N": return .init(value: "new", changed: true, reason: "codeSystemTranslation")
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }

    public static func translateResultStatus(_ code: String?) -> CDACodeTranslation { resultStatus(code) }

    public static func v2ResultStatus(_ code: String?) -> CDACodeTranslation { resultStatus(code) }

    public static func reverseResultStatus(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return .init(value: nil, reason: "codeSystemUnknown")
        }
        switch code.lowercased() {
        case "completed", "normal": return .init(value: "F", changed: true, reason: "codeSystemTranslation")
        case "active", "new", "held", "suspended": return .init(value: "P", changed: true, reason: "codeSystemTranslation")
        case "cancelled": return .init(value: "X", changed: true, reason: "codeSystemTranslation")
        case "aborted": return .init(value: "A", changed: true, reason: "codeSystemTranslation")
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }

    /// HL7 table 0078 is already the ObservationInterpretation code system for
    /// the common flags.  Unknown flags remain explicit rather than being
    /// silently turned into a clinical interpretation.
    public static func abnormalFlag(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            return .init(value: nil, reason: "codeSystemUnknown")
        }
        let known = Set(["N", "L", "LL", "H", "HH", "A", "AA", "S", "R", "I", "D", "B", "W", "U"])
        guard known.contains(code.uppercased()) else { return .init(value: nil, reason: "codeSystemUnknown") }
        return .init(value: code.uppercased(), changed: true, reason: "codeSystemTranslation")
    }

    public static func translateAbnormalFlag(_ code: String?) -> CDACodeTranslation { abnormalFlag(code) }

    public static func valueType(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.uppercased(), !code.isEmpty else { return .init(value: nil, reason: "valueTypeUnsupported") }
        switch code {
        case "NM": return .init(value: "PQ", changed: true, reason: "valueTypeTranslation")
        case "CE", "CWE", "CNE": return .init(value: "CD", changed: true, reason: "codeSystemTranslation")
        case "ST", "TX", "FT": return .init(value: "ST", changed: code != "ST", reason: code == "ST" ? nil : "valueTypeTranslation")
        case "DT", "TM", "TS", "DTM": return .init(value: "TS", changed: code != "TS", reason: code == "TS" ? nil : "timePrecision")
        case "SN": return .init(value: "IVL_PQ", changed: true, reason: "valueTypeTranslation")
        default: return .init(value: nil, reason: "valueTypeUnsupported")
        }
    }

    public static func translateValueType(_ code: String?) -> CDACodeTranslation { valueType(code) }
}


public extension CodeSystemTranslator {
    /// HL7 table 0201 telecommunication use codes to HL7 v3 TelecommunicationAddressUse.
    /// Codes without a v3 counterpart drop the `use` attribute and are reported as changed.
    static func telecomUse(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !code.isEmpty else {
            return .init(value: nil)
        }
        switch code {
        case "PRN": return .init(value: "HP", changed: true, reason: "codeSystemTranslation")
        case "WPN": return .init(value: "WP", changed: true, reason: "codeSystemTranslation")
        case "EMR": return .init(value: "EC", changed: true, reason: "codeSystemTranslation")
        case "VHN": return .init(value: "HV", changed: true, reason: "codeSystemTranslation")
        case "ASN": return .init(value: "AS", changed: true, reason: "codeSystemTranslation")
        case "BPN": return .init(value: "PG", changed: true, reason: "codeSystemTranslation")
        case "HP", "WP", "EC", "HV", "AS", "PG", "MC", "TMP", "BAD": return .init(value: code)
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }

    /// TelecommunicationAddressUse back to HL7 table 0201; unmapped uses are omitted and reported by the caller.
    static func reverseTelecomUse(_ code: String?) -> CDACodeTranslation {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !code.isEmpty else {
            return .init(value: nil)
        }
        switch code {
        case "HP": return .init(value: "PRN", changed: true, reason: "codeSystemTranslation")
        case "WP": return .init(value: "WPN", changed: true, reason: "codeSystemTranslation")
        case "EC": return .init(value: "EMR", changed: true, reason: "codeSystemTranslation")
        case "HV": return .init(value: "VHN", changed: true, reason: "codeSystemTranslation")
        case "AS": return .init(value: "ASN", changed: true, reason: "codeSystemTranslation")
        case "PG": return .init(value: "BPN", changed: true, reason: "codeSystemTranslation")
        default: return .init(value: nil, reason: "codeSystemUnknown")
        }
    }
}
