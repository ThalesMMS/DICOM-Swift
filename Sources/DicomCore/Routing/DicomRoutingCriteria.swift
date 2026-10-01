import Foundation

public enum DicomRoutingPriority: String, Codable, Equatable, Sendable {
    case stat, routine
}

/// Only these host-approved evidence fields can participate in routing.
public enum DicomRoutingCriterion: Codable, Equatable, Sendable {
    case modality(in: Set<String>)
    case sopClassUID(in: Set<String>)
    case callingAETitle(in: Set<String>)
    case calledAETitle(in: Set<String>)
    case bodyPartExamined(in: Set<String>)
    case stationName(in: Set<String>)
    case transferSyntax(in: Set<String>)
    case institutionName(matches: String)
    case studyDescription(contains: String)
    case priority(is: DicomRoutingPriority)
    case isDerived(Bool)
    case hasPHIAuthorization(Bool)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case modality, sopClassUID, callingAETitle, calledAETitle, bodyPartExamined, stationName, transferSyntax, institutionName, studyDescription, priority, isDerived, hasPHIAuthorization
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .modality: self = .modality(in: Set(try container.decode([String].self, forKey: .value)))
        case .sopClassUID: self = .sopClassUID(in: Set(try container.decode([String].self, forKey: .value)))
        case .callingAETitle: self = .callingAETitle(in: Set(try container.decode([String].self, forKey: .value)))
        case .calledAETitle: self = .calledAETitle(in: Set(try container.decode([String].self, forKey: .value)))
        case .bodyPartExamined: self = .bodyPartExamined(in: Set(try container.decode([String].self, forKey: .value)))
        case .stationName: self = .stationName(in: Set(try container.decode([String].self, forKey: .value)))
        case .transferSyntax: self = .transferSyntax(in: Set(try container.decode([String].self, forKey: .value)))
        case .institutionName: self = .institutionName(matches: try container.decode(String.self, forKey: .value))
        case .studyDescription: self = .studyDescription(contains: try container.decode(String.self, forKey: .value))
        case .priority: self = .priority(is: try container.decode(DicomRoutingPriority.self, forKey: .value))
        case .isDerived: self = .isDerived(try container.decode(Bool.self, forKey: .value))
        case .hasPHIAuthorization: self = .hasPHIAuthorization(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modality(let value):
            try container.encode(Kind.modality, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .sopClassUID(let value):
            try container.encode(Kind.sopClassUID, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .callingAETitle(let value):
            try container.encode(Kind.callingAETitle, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .calledAETitle(let value):
            try container.encode(Kind.calledAETitle, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .bodyPartExamined(let value):
            try container.encode(Kind.bodyPartExamined, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .stationName(let value):
            try container.encode(Kind.stationName, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .transferSyntax(let value):
            try container.encode(Kind.transferSyntax, forKey: .kind)
            try container.encode(value.sorted(), forKey: .value)
        case .institutionName(let value):
            try container.encode(Kind.institutionName, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .studyDescription(let value):
            try container.encode(Kind.studyDescription, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .priority(let value):
            try container.encode(Kind.priority, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .isDerived(let value):
            try container.encode(Kind.isDerived, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .hasPHIAuthorization(let value):
            try container.encode(Kind.hasPHIAuthorization, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    /// Stable, unambiguous description; set values are always sorted.
    public var description: String {
        switch self {
        case .modality(let value): return "modality:" + String(reflecting: value.sorted())
        case .sopClassUID(let value): return "sopClassUID:" + String(reflecting: value.sorted())
        case .callingAETitle(let value): return "callingAETitle:" + String(reflecting: value.sorted())
        case .calledAETitle(let value): return "calledAETitle:" + String(reflecting: value.sorted())
        case .bodyPartExamined(let value): return "bodyPartExamined:" + String(reflecting: value.sorted())
        case .stationName(let value): return "stationName:" + String(reflecting: value.sorted())
        case .transferSyntax(let value): return "transferSyntax:" + String(reflecting: value.sorted())
        case .institutionName(let value): return "institutionName:" + String(reflecting: value)
        case .studyDescription(let value): return "studyDescription:" + String(reflecting: value)
        case .priority(let value): return "priority:" + value.rawValue
        case .isDerived(let value): return "isDerived:" + String(value)
        case .hasPHIAuthorization(let value): return "hasPHIAuthorization:" + String(value)
        }
    }

    func matches(_ subject: DicomRoutingSubject) -> Bool {
        switch self {
        case .modality(let value): return subject.modality.map(value.contains) ?? false
        case .sopClassUID(let value): return value.contains(subject.sopClassUID)
        case .callingAETitle(let value): return subject.callingAETitle.map(value.contains) ?? false
        case .calledAETitle(let value): return subject.calledAETitle.map(value.contains) ?? false
        case .bodyPartExamined(let value): return subject.bodyPartExamined.map(value.contains) ?? false
        case .stationName(let value): return subject.stationName.map(value.contains) ?? false
        case .transferSyntax(let value): return value.contains(subject.transferSyntaxUID)
        case .institutionName(let value):
            return subject.institutionName?.compare(value, options: [.caseInsensitive],
                                                    locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
        case .studyDescription(let value): return subject.studyDescription?.contains(value) ?? false
        case .priority(let value): return subject.priority == value
        case .isDerived(let value): return subject.isDerived == value
        case .hasPHIAuthorization(let value): return subject.phiAuthorized == value
        }
    }

    var hasValidValue: Bool {
        switch self {
        case .modality(let values), .sopClassUID(let values), .callingAETitle(let values), .calledAETitle(let values), .bodyPartExamined(let values), .stationName(let values), .transferSyntax(let values):
            return !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .institutionName(let value), .studyDescription(let value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .priority, .isDerived, .hasPHIAuthorization: return true
        }
    }
}

public struct DicomRoutingSubject: Equatable, Sendable {
    public let sopInstanceUID: String
    public let sopClassUID: String
    public let studyInstanceUID: String
    public let seriesInstanceUID: String
    public let modality: String?
    public let institutionName: String?
    public let studyDescription: String?
    public let bodyPartExamined: String?
    public let stationName: String?
    public let callingAETitle: String?
    public let calledAETitle: String?
    public let priority: DicomRoutingPriority
    public let isDerived: Bool
    public let phiAuthorized: Bool
    public let transferSyntaxUID: String
    public let contentReferences: [String]

    public init(
        sopInstanceUID: String,
        sopClassUID: String,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        modality: String? = nil,
        institutionName: String? = nil,
        studyDescription: String? = nil,
        bodyPartExamined: String? = nil,
        stationName: String? = nil,
        callingAETitle: String? = nil,
        calledAETitle: String? = nil,
        priority: DicomRoutingPriority = .routine,
        isDerived: Bool = false,
        phiAuthorized: Bool = false,
        transferSyntaxUID: String,
        contentReferences: [String] = []
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.sopClassUID = sopClassUID
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.modality = modality
        self.institutionName = institutionName
        self.studyDescription = studyDescription
        self.bodyPartExamined = bodyPartExamined
        self.stationName = stationName
        self.callingAETitle = callingAETitle
        self.calledAETitle = calledAETitle
        self.priority = priority
        self.isDerived = isDerived
        self.phiAuthorized = phiAuthorized
        self.transferSyntaxUID = transferSyntaxUID
        self.contentReferences = contentReferences
    }

    /// Association identity, priority, PHI authorization and encoding are supplied by the host.
    public static func subject(from dataSet: DicomDataSet, transferSyntaxUID: String,
                               callingAETitle: String? = nil, calledAETitle: String? = nil,
                               priority: DicomRoutingPriority = .routine,
                               phiAuthorized: Bool = false) -> Self {
        func references(in set: DicomDataSet) -> [String] {
            set.elements.flatMap { element in
                let values = element.stringValues.filter {
                    element.vr == .AE || element.vr == .UR || $0.contains("://")
                }
                return values + element.sequenceItems.flatMap { references(in: $0.dataSet) }
            }
        }
        return .init(
            sopInstanceUID: dataSet.string(for: .sopInstanceUID) ?? "",
            sopClassUID: dataSet.string(for: .sopClassUID) ?? "",
            studyInstanceUID: dataSet.string(for: .studyInstanceUID) ?? "",
            seriesInstanceUID: dataSet.string(for: .seriesInstanceUID) ?? "",
            modality: dataSet.string(for: .modality),
            institutionName: dataSet.string(for: .institutionName),
            studyDescription: dataSet.string(for: .studyDescription),
            bodyPartExamined: dataSet.string(for: .bodyPartExamined),
            stationName: dataSet.string(for: 0x00081010),
            callingAETitle: callingAETitle,
            calledAETitle: calledAETitle,
            priority: priority,
            isDerived: dataSet.strings(for: .imageType).first == "DERIVED"
                || dataSet.string(for: .lossyImageCompression) == "01",
            phiAuthorized: phiAuthorized, transferSyntaxUID: transferSyntaxUID,
            contentReferences: references(in: dataSet))
    }
}
