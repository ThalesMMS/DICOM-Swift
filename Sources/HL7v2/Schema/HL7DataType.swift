import Foundation

public enum HL7DataTypeName: String, Codable, CaseIterable, Sendable {
    case ST, TX, FT, NM, SI, ID, IS, DT, TM, DTM, TS, HD, CX, XPN, XAD, XTN, CE, CWE, CNE
    case EI, PL, XCN, TQ, MSG, PT, VID, EIP, RP, AUI, CP, CQ, DLD, DLN, ELD, ERL, FC
    case JCC, MOC, NDL, PRL, SPS, SRT, VR, XON, FN, SAD, DR, SN, ED, MO, RI, SCV, QIP, QSC
    case CNN, OSD, TN
    case varies, withdrawn
}

public struct HL7DataTypeDefinition: Codable, Equatable, Sendable {
    public struct Component: Codable, Equatable, Sendable {
        public var name: String
        public var dataType: HL7DataTypeName
        public var optionality: HL7Optionality
        public var maxLength: Int?
        public init(name: String, dataType: HL7DataTypeName, optionality: HL7Optionality = .O,
                    maxLength: Int? = nil) {
            self.name = name; self.dataType = dataType; self.optionality = optionality; self.maxLength = maxLength
        }
    }
    public var name: HL7DataTypeName
    public var components: [Component]
    public var maxLength: Int?
    public var versions: [String]
    public init(name: HL7DataTypeName, components: [Component] = [], maxLength: Int? = nil,
                versions: [String] = []) {
        self.name = name; self.components = components; self.maxLength = maxLength; self.versions = versions
    }
}

public protocol HL7TypedValue: Sendable { var hl7Value: HL7Repetition { get } }

func hl7Repetition(_ values: [String]) -> HL7Repetition {
    HL7Repetition(components: values.map { HL7Component(subcomponents: [.text($0)]) })
}

func hl7Scalar(_ value: HL7Value) -> HL7Repetition {
    HL7Repetition(components: [HL7Component(subcomponents: [value])])
}

func hl7HasValue(_ field: HL7Field) -> Bool {
    field.isPresent && field.repetitions.contains { rep in
        rep.components.contains { $0.subcomponents.contains { if case .text(let s) = $0 { return !s.isEmpty }; return false } }
    }
}

/// Retains the lexical precision, fraction and signed offset without inventing missing calendar components.
public struct HL7Timestamp: Equatable, HL7TypedValue {
    public enum Precision: Int, Sendable { case year = 4, month = 6, day = 8, hour = 10, minute = 12, second = 14 }
    public let rawValue: String
    public let precision: Precision
    public let fraction: String?
    public let timezoneOffsetMinutes: Int?
    public var hl7Value: HL7Repetition { hl7Repetition([rawValue]) }
    public init?(_ value: HL7Value, definition: HL7DataTypeDefinition? = nil) {
        guard let text = value.text else { return nil }
        self.init(text)
    }
    public init?(_ value: HL7Repetition, definition: HL7DataTypeDefinition? = nil) {
        guard value.components.count <= (definition?.name == .TS ? 2 : 1) else { return nil }
        self.init(value[1][1], definition: definition)
    }
    public init?(_ text: String) {
        guard text.range(of: #"^[0-9]{4}([0-9]{2}){0,5}(\.[0-9]{1,4})?([+-][0-9]{4})?$"#,
                         options: .regularExpression) != nil else { return nil }
        var body = text
        var offset: Int?
        if let sign = body.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = String(body[body.index(after: sign)...])
            let h = Int(zone.prefix(2))!, m = Int(zone.suffix(2))!
            guard h <= 23, m <= 59 else { return nil }
            offset = (h * 60 + m) * (body[sign] == "-" ? -1 : 1)
            body = String(body[..<sign])
        }
        let pieces = body.split(separator: ".")
        let digits = String(pieces[0])
        guard let precision = Precision(rawValue: digits.count), pieces.count == 1 || precision == .second else { return nil }
        func number(_ start: Int, _ length: Int) -> Int { Int(digits.dropFirst(start).prefix(length))! }
        let year = number(0, 4)
        guard year > 0 else { return nil }
        if digits.count >= 6, !(1...12).contains(number(4, 2)) { return nil }
        if digits.count >= 8 {
            let month = number(4, 2), day = number(6, 2)
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...days[month - 1]).contains(day) else { return nil }
        }
        if digits.count >= 10, number(8, 2) > 23 { return nil }
        if digits.count >= 12, number(10, 2) > 59 { return nil }
        if digits.count >= 14, number(12, 2) > 59 { return nil }
        self.rawValue = text; self.precision = precision
        self.fraction = pieces.count == 2 ? String(pieces[1]) : nil
        self.timezoneOffsetMinutes = offset
    }
}

public struct HL7Number: Equatable, HL7TypedValue {
    public let rawValue: String
    public var decimal: Decimal? { Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) }
    public var hl7Value: HL7Repetition { hl7Repetition([rawValue]) }
    public init?(_ value: HL7Value, definition: HL7DataTypeDefinition? = nil) {
        guard let text = value.text, text.range(of: #"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$"#,
            options: .regularExpression) != nil else { return nil }
        if definition?.name == .SI, text.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil { return nil }
        rawValue = text
    }
    public init?(_ value: HL7Repetition, definition: HL7DataTypeDefinition? = nil) {
        guard value.components.count == 1, value[1].subcomponents.count == 1 else { return nil }
        self.init(value[1][1], definition: definition)
    }
}

/// Composite wrappers retain every component, including those not exposed as named properties.
public protocol HL7CompositeValue: HL7TypedValue {
    static var acceptedTypes: [HL7DataTypeName] { get }
    init(unchecked: HL7Repetition)
}
extension HL7CompositeValue {
    public init?(_ value: HL7Repetition, definition: HL7DataTypeDefinition? = nil) {
        if let definition {
            guard Self.acceptedTypes.contains(definition.name),
                  value.components.count <= definition.components.count || definition.components.isEmpty else { return nil }
        }
        guard hl7HasValue(HL7Field(repetitions: [value])) else { return nil }
        if let definition {
            let version = definition.versions.first.map(HL7Version.init(rawValue:)) ?? .v2_5_1
            guard var definitions = HL7SchemaRegistry.shared.schema(for: version)?.dataTypes else { return nil }
            definitions[definition.name] = definition
            guard typeFindings(value, type: definition.name, definitions: definitions, path: HL7Path())
                .allSatisfy({ $0.severity != .error }) else { return nil }
        }
        self.init(unchecked: value)
    }
    public init?(_ value: HL7Value, definition: HL7DataTypeDefinition? = nil) {
        self.init(hl7Scalar(value), definition: definition)
    }
}

public struct HL7CodedElement: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.CE, .CWE, .CNE]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(identifier: String, text: String = "", system: String = "", alternateIdentifier: String = "",
                alternateText: String = "", alternateSystem: String = "") {
        hl7Value = hl7Repetition([identifier, text, system, alternateIdentifier, alternateText, alternateSystem])
    }
    public var identifier: String? { hl7Value[1][1].text }
    public var text: String? { hl7Value[2][1].text }
    public var system: String? { hl7Value[3][1].text }
    public var alternateIdentifier: String? { hl7Value[4][1].text }
    public var alternateText: String? { hl7Value[5][1].text }
    public var alternateSystem: String? { hl7Value[6][1].text }
}

public struct HL7PersonName: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.XPN]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(family: String, given: String = "", middle: String = "", suffix: String = "", prefix: String = "") {
        hl7Value = hl7Repetition([family, given, middle, suffix, prefix])
    }
    public var family: String? { hl7Value[1][1].text }
    public var given: String? { hl7Value[2][1].text }
    public var middle: String? { hl7Value[3][1].text }
    public var suffix: String? { hl7Value[4][1].text }
    public var prefix: String? { hl7Value[5][1].text }
}

public struct HL7HierarchicDesignator: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.HD]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(namespace: String, universalID: String = "", universalIDType: String = "") {
        hl7Value = hl7Repetition([namespace, universalID, universalIDType])
    }
    public var namespace: String? { hl7Value[1][1].text }
    public var universalID: String? { hl7Value[2][1].text }
    public var universalIDType: String? { hl7Value[3][1].text }
}

public struct HL7ExtendedID: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.CX]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(id: String, authority: HL7HierarchicDesignator? = nil, identifierType: String = "") {
        var rep = hl7Repetition([id, "", "", "", identifierType])
        if let authority { rep[4] = HL7Component(subcomponents: authority.hl7Value.components.map { $0[1] }) }
        hl7Value = rep
    }
    public var id: String? { hl7Value[1][1].text }
    public var checkDigit: String? { hl7Value[2][1].text }
    public var identifierType: String? { hl7Value[5][1].text }
    public var authority: HL7HierarchicDesignator? {
        HL7HierarchicDesignator(HL7Repetition(components: hl7Value[4].subcomponents.map {
            HL7Component(subcomponents: [$0])
        }))
    }
}

public struct HL7Address: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.XAD]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(street: String, other: String = "", city: String = "", state: String = "", postalCode: String = "",
                country: String = "") { hl7Value = hl7Repetition([street, other, city, state, postalCode, country]) }
    public var street: String? { hl7Value[1][1].text }
    public var city: String? { hl7Value[3][1].text }
    public var state: String? { hl7Value[4][1].text }
    public var postalCode: String? { hl7Value[5][1].text }
    public var country: String? { hl7Value[6][1].text }
}

public struct HL7Telecom: Equatable, HL7CompositeValue {
    public static let acceptedTypes: [HL7DataTypeName] = [.XTN]
    public let hl7Value: HL7Repetition
    public init(unchecked: HL7Repetition) { hl7Value = unchecked }
    public init(number: String = "", use: String = "", equipment: String = "", email: String = "") {
        hl7Value = hl7Repetition([number, use, equipment, email])
    }
    public var number: String? { hl7Value[1][1].text }
    public var use: String? { hl7Value[2][1].text }
    public var equipment: String? { hl7Value[3][1].text }
    public var email: String? { hl7Value[4][1].text }
}
