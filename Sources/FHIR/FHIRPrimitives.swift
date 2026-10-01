import Foundation

/// FHIR R4 primitive types with the lexical rules of https://hl7.org/fhir/R4/datatypes.html#primitive.
public enum FHIRPrimitiveType: String, CaseIterable, Sendable {
    case boolean, integer, string, decimal, uri, url, canonical, base64Binary, instant, date, dateTime, time
    case code, oid, id, markdown, unsignedInt, positiveInt, uuid, xhtml

    /// JSON representation family of the type.
    public enum JSONKind: Sendable { case bool, number, string }
    public var jsonKind: JSONKind {
        switch self {
        case .boolean: return .bool
        case .integer, .decimal, .unsignedInt, .positiveInt: return .number
        default: return .string
        }
    }

    private static let patterns: [FHIRPrimitiveType: String] = [
        .integer: "^-?(0|[1-9][0-9]*)$",
        .unsignedInt: "^(0|[1-9][0-9]*)$",
        .positiveInt: "^[1-9][0-9]*$",
        .decimal: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$",
        .date: "^-?[0-9]{4}(-(0[1-9]|1[0-2])(-(0[1-9]|[12][0-9]|3[01]))?)?$",
        .dateTime: "^-?[0-9]{4}(-(0[1-9]|1[0-2])(-(0[1-9]|[12][0-9]|3[01])(T([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\\.[0-9]+)?(Z|[+-]((0[0-9]|1[0-3]):[0-5][0-9]|14:00)))?)?)?$",
        .instant: "^-?[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\\.[0-9]+)?(Z|[+-]((0[0-9]|1[0-3]):[0-5][0-9]|14:00))$",
        .time: "^([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\\.[0-9]+)?$",
        .id: "^[A-Za-z0-9\\-\\.]{1,64}$",
        .code: "^[^\\s]+(\\s[^\\s]+)*$",
        .oid: "^urn:oid:[0-2](\\.(0|[1-9][0-9]*))+$",
        .uuid: "^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        .base64Binary: "^(\\s*([0-9a-zA-Z+/=]){4}\\s*)+$",
        .uri: "^\\S*$",
        .url: "^\\S*$",
        .canonical: "^\\S*$"
    ]

    /// Lexical validity of a string representation; integers additionally respect the 32-bit range.
    public func isValid(_ text: String) -> Bool {
        switch self {
        case .boolean: return text == "true" || text == "false"
        case .string, .markdown, .xhtml: return !text.isEmpty
        case .integer: return Self.patterns[self].map { text.range(of: $0, options: .regularExpression) != nil } == true && Int32(text) != nil
        case .unsignedInt, .positiveInt: return Self.patterns[self].map { text.range(of: $0, options: .regularExpression) != nil } == true && Int32(text) != nil
        default: return Self.patterns[self].map { text.range(of: $0, options: .regularExpression) != nil } ?? true
        }
    }
}

public enum FHIRPrecision: Int, Comparable, Sendable {
    case year = 1, month, day, hour, minute, second, fraction
    public static func < (lhs: FHIRPrecision, rhs: FHIRPrecision) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum FHIRComparison: Sendable, Equatable { case less, equal, greater, indeterminate }

/// `date`: year, year-month or full date; comparison is indeterminate across precisions.
public struct FHIRDate: Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int?
    public let day: Int?

    public init?(_ text: String) {
        guard FHIRPrimitiveType.date.isValid(text) else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        let negative = text.hasPrefix("-")
        let fields = negative ? Array(parts.dropFirst()) : Array(parts)
        guard let year = Int(fields[0]) else { return nil }
        self.year = negative ? -year : year
        month = fields.count > 1 ? Int(fields[1]) : nil
        day = fields.count > 2 ? Int(fields[2]) : nil
        if let month, let day, !FHIRDate.isValidDay(year: self.year, month: month, day: day) { return nil }
    }

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    static func isValidDay(year: Int, month: Int, day: Int) -> Bool {
        let lengths = [31, (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...12).contains(month) && day >= 1 && day <= lengths[month - 1]
    }

    public var precision: FHIRPrecision { day != nil ? .day : (month != nil ? .month : .year) }
    public var description: String {
        var text = (year < 0 ? "-" : "") + String(format: "%04llu", UInt64(year.magnitude))
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        return text
    }

    public func compare(_ other: FHIRDate) -> FHIRComparison {
        guard precision == other.precision else { return .indeterminate }
        let lhs = [year, month ?? 0, day ?? 0], rhs = [other.year, other.month ?? 0, other.day ?? 0]
        return lhs == rhs ? .equal : (lhs.lexicographicallyPrecedes(rhs) ? .less : .greater)
    }
}

/// `time`: hh:mm:ss with an optional fraction whose digits are preserved.
public struct FHIRTime: Hashable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int
    public let second: Int
    public let fraction: String?

    public init?(_ text: String) {
        guard FHIRPrimitiveType.time.isValid(text) else { return nil }
        let main = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = main[0].split(separator: ":")
        guard parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2]) else { return nil }
        self.hour = hour
        self.minute = minute
        self.second = second
        fraction = main.count > 1 ? String(main[1]) : nil
    }

    public var description: String {
        String(format: "%02d:%02d:%02d", hour, minute, second) + (fraction.map { "." + $0 } ?? "")
    }
    public var precision: FHIRPrecision { fraction == nil ? .second : .fraction }
}

/// UTC offset in minutes, or `Z`; the original spelling is kept.
public struct FHIRTimeZone: Hashable, Sendable, CustomStringConvertible {
    public let offsetMinutes: Int
    public let text: String

    public init?(_ text: String) {
        if text == "Z" { offsetMinutes = 0; self.text = text; return }
        guard text.count == 6, let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let parts = text.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]), hours <= 14, minutes < 60 else { return nil }
        offsetMinutes = (hours * 60 + minutes) * (sign == "-" ? -1 : 1)
        self.text = text
    }
    public var description: String { text }
}

/// `dateTime`/`instant`: partial dates allowed for dateTime; time requires a time zone.
public struct FHIRDateTime: Hashable, Sendable, CustomStringConvertible {
    public let date: FHIRDate
    public let time: FHIRTime?
    public let timeZone: FHIRTimeZone?

    public init?(_ text: String) {
        guard FHIRPrimitiveType.dateTime.isValid(text) else { return nil }
        guard let tIndex = text.firstIndex(of: "T") else {
            guard let date = FHIRDate(text) else { return nil }
            self.date = date
            time = nil
            timeZone = nil
            return
        }
        guard let date = FHIRDate(String(text[..<tIndex])) else { return nil }
        var rest = String(text[text.index(after: tIndex)...])
        var zone: FHIRTimeZone?
        if rest.hasSuffix("Z") { zone = FHIRTimeZone("Z"); rest.removeLast() }
        else if let sign = rest.lastIndex(where: { $0 == "+" || $0 == "-" }), rest.distance(from: sign, to: rest.endIndex) == 6 {
            zone = FHIRTimeZone(String(rest[sign...]))
            rest = String(rest[..<sign])
        }
        guard let zone, let time = FHIRTime(rest) else { return nil }
        self.date = date
        self.time = time
        timeZone = zone
    }

    public init(date: FHIRDate, time: FHIRTime? = nil, timeZone: FHIRTimeZone? = nil) {
        self.date = date
        self.time = time
        self.timeZone = timeZone
    }

    public var precision: FHIRPrecision { time?.precision ?? date.precision }
    public var isInstant: Bool { date.precision == .day && time != nil && timeZone != nil }
    public var description: String {
        var text = date.description
        if let time { text += "T" + time.description + (timeZone?.description ?? "") }
        return text
    }

    /// Absolute instant in seconds since 1970 when the value carries a time and zone; partial values have none.
    public var epochSeconds: Double? {
        guard let time, let timeZone, let day = date.day, let month = date.month else { return nil }
        var components = DateComponents()
        components.year = date.year; components.month = month; components.day = day
        components.hour = time.hour; components.minute = time.minute; components.second = time.second
        components.timeZone = TimeZone(secondsFromGMT: timeZone.offsetMinutes * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let value = calendar.date(from: components) else { return nil }
        let fraction = time.fraction.flatMap { Double("0." + $0) } ?? 0
        return value.timeIntervalSince1970 + fraction
    }

    /// Precision-aware comparison: differing precisions are indeterminate, as FHIRPath specifies.
    public func compare(_ other: FHIRDateTime) -> FHIRComparison {
        if let lhs = epochSeconds, let rhs = other.epochSeconds, precision == other.precision {
            return lhs == rhs ? .equal : (lhs < rhs ? .less : .greater)
        }
        guard time == nil, other.time == nil else { return .indeterminate }
        return date.compare(other.date)
    }
}
