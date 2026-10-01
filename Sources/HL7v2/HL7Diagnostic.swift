import Foundation

/// All indices are one-based, including repetition; line indices in diagnostics are zero-based.
public struct HL7Path: Hashable, Sendable, CustomStringConvertible {
    public let segment: String
    public let field: Int?
    public let component: Int?
    public let subcomponent: Int?
    public let repetition: Int

    public init(segment: String = "", field: Int? = nil, component: Int? = nil,
                subcomponent: Int? = nil, repetition: Int = 1) {
        // Do not let malformed segment content enter error descriptions.
        self.segment = Self.validName(segment) ? segment : ""
        self.field = field
        self.component = component
        self.subcomponent = subcomponent
        self.repetition = repetition
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, Self.validName(String(parts[0])) else { return nil }
        if parts.count == 1 { self.init(segment: String(parts[0])); return }
        var tail = String(parts[1])
        var repetition = 1
        if let bracket = tail.firstIndex(of: "[") {
            guard tail.last == "]", let number = Int(tail[tail.index(after: bracket)..<tail.index(before: tail.endIndex)]),
                  number > 0 else { return nil }
            repetition = number
            tail = String(tail[..<bracket])
        }
        let numbers = tail.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        self.init(segment: String(parts[0]), field: numbers[0],
                  component: numbers.count > 1 ? numbers[1] : nil,
                  subcomponent: numbers.count > 2 ? numbers[2] : nil, repetition: repetition)
    }

    static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count == 3 && bytes[0] >= 65 && bytes[0] <= 90 &&
            bytes.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }

    public var description: String {
        var result = segment.isEmpty ? "message" : segment
        if let field { result += "-\(field)" }
        if let component { result += ".\(component)" }
        if let subcomponent { result += ".\(subcomponent)" }
        if repetition != 1 { result += "[\(repetition)]" }
        return result
    }
}

public struct HL7Diagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unknownEscape, charsetFallback, terminatorNormalized, segmentSkipped, limitExceeded
        case unrepresentableCharacter, encodingCharacterConflict, versionUnknown, charsetSwitchIgnored
        case legacyCharsetAlias, malformedContent
    }
    public enum Severity: String, Sendable { case warning, error }
    public let code: Code
    public let path: HL7Path?
    public let lineIndex: Int?
    public let lengths: [Int]
    public let severity: Severity

    public init(code: Code, path: HL7Path? = nil, lineIndex: Int? = nil,
                lengths: [Int] = [], severity: Severity = .warning) {
        self.code = code
        self.path = path
        self.lineIndex = lineIndex
        self.lengths = lengths
        self.severity = severity
    }

    /// Deliberately contains no message values or raw input.
    public var detail: String { "\(code.rawValue) \(path?.description ?? "message") lengths=\(lengths)" }
}

public enum HL7ParseError: Error, Equatable, Sendable {
    public enum Limit: String, Sendable { case messageBytes, segments, fields, repetitions, componentDepth }
    case limitExceeded(Limit, HL7Path)
    case malformed(HL7Path, lineIndex: Int)
    case encodingCharacters(HL7Path)
}

public struct HL7SerializationError: Error, Equatable, Sendable {
    public let diagnostic: HL7Diagnostic
}
