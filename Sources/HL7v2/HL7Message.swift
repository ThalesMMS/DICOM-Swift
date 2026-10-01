import Foundation

public enum HL7Value: Codable, Equatable, Sendable {
    case absent, empty, null, text(String)
    public var text: String? {
        switch self {
        case .text(let text): text
        case .empty: ""
        case .absent, .null: nil
        }
    }
}

public struct HL7Component: Codable, Equatable, Sendable {
    public var subcomponents: [HL7Value]
    // Parallel snapshots let a mutation retain the wire spelling of every untouched leaf.
    var raw: [String] = []
    var original: [HL7Value] = []
    public init(subcomponents: [HL7Value] = [.empty]) { self.subcomponents = subcomponents }
    public subscript(index: Int) -> HL7Value {
        get { index > 0 && index <= subcomponents.count ? subcomponents[index - 1] : .absent }
        set {
            precondition(index > 0)
            while subcomponents.count < index { subcomponents.append(.empty) }
            subcomponents[index - 1] = newValue
        }
    }
}

public struct HL7Repetition: Codable, Equatable, Sendable {
    public var components: [HL7Component]
    public init(components: [HL7Component] = [HL7Component()]) { self.components = components }
    public subscript(index: Int) -> HL7Component {
        get { index > 0 && index <= components.count ? components[index - 1] : HL7Component(subcomponents: [.absent]) }
        set {
            precondition(index > 0)
            while components.count < index { components.append(HL7Component()) }
            components[index - 1] = newValue
        }
    }
}

public struct HL7Field: Codable, Equatable, Sendable {
    public var repetitions: [HL7Repetition]
    public var isPresent: Bool
    public init(repetitions: [HL7Repetition] = [HL7Repetition()], isPresent: Bool = true) {
        self.repetitions = repetitions
        self.isPresent = isPresent
    }
    public init(_ value: HL7Value) {
        self.init(repetitions: [HL7Repetition(components: [HL7Component(subcomponents: [value])])],
                  isPresent: value != .absent)
    }
    public subscript(index: Int) -> HL7Repetition {
        get {
            isPresent && index > 0 && index <= repetitions.count ? repetitions[index - 1] :
                HL7Repetition(components: [HL7Component(subcomponents: [.absent])])
        }
        set {
            precondition(index > 0)
            isPresent = true
            while repetitions.count < index { repetitions.append(HL7Repetition()) }
            repetitions[index - 1] = newValue
        }
    }
}

public struct HL7Segment: Equatable, Sendable {
    public var name: String
    /// MSH includes its literal MSH-1 and MSH-2 as the first two fields.
    public var fields: [HL7Field]
    public let originalLineIndex: Int
    public init(name: String, fields: [HL7Field] = [], originalLineIndex: Int = 0) {
        self.name = name
        self.fields = fields
        self.originalLineIndex = originalLineIndex
    }
    public subscript(index: Int) -> HL7Field {
        get { index > 0 && index <= fields.count ? fields[index - 1] : HL7Field(.absent) }
        set {
            precondition(index > 0)
            while fields.count < index { fields.append(HL7Field(.empty)) }
            fields[index - 1] = newValue
        }
    }
}

public struct HL7MessageType: Equatable, Sendable {
    public let code: String?
    public let triggerEvent: String?
    public let structure: String?
}

public struct HL7Message: Equatable, Sendable {
    public var segments: [HL7Segment]
    public let encoding: HL7EncodingCharacters
    public let charset: HL7Charset
    public let charsetDeclarations: [String]
    public var diagnostics: [HL7Diagnostic]
    /// Includes charset fallbacks caused by invalid byte sequences; serialization uses this encoding.
    public let effectiveCharset: HL7Charset
    public var hasTrailingTerminator: Bool

    public init(segments: [HL7Segment], encoding: HL7EncodingCharacters = .standard,
                charset: HL7Charset = .ascii, charsetDeclarations: [String] = [],
                diagnostics: [HL7Diagnostic] = [], hasTrailingTerminator: Bool = true) {
        self.segments = segments
        self.encoding = encoding
        self.charset = charset
        self.charsetDeclarations = charsetDeclarations
        self.diagnostics = diagnostics
        self.effectiveCharset = charset
        self.hasTrailingTerminator = hasTrailingTerminator
    }

    init(segments: [HL7Segment], encoding: HL7EncodingCharacters, charset: HL7Charset,
         effectiveCharset: HL7Charset, charsetDeclarations: [String], diagnostics: [HL7Diagnostic],
         hasTrailingTerminator: Bool) {
        self.segments = segments
        self.encoding = encoding
        self.charset = charset
        self.effectiveCharset = effectiveCharset
        self.charsetDeclarations = charsetDeclarations
        self.diagnostics = diagnostics
        self.hasTrailingTerminator = hasTrailingTerminator
    }

    public subscript(name: String) -> HL7Segment? {
        get { segments.first { $0.name == name } }
        set {
            if let index = segments.firstIndex(where: { $0.name == name }) {
                if let newValue { segments[index] = newValue } else { segments.remove(at: index) }
            } else if let newValue { segments.append(newValue) }
        }
    }
    public func value(at path: HL7Path) -> HL7Value? {
        guard let segment = self[path.segment], let field = path.field else { return nil }
        return segment[field][path.repetition][path.component ?? 1][path.subcomponent ?? 1]
    }
    public var version: HL7Version? {
        guard let value = self["MSH"]?[12][1][1][1].text, !value.isEmpty else { return nil }
        return HL7Version(rawValue: value)
    }
    public var messageType: HL7MessageType {
        HL7MessageType(code: self["MSH"]?[9][1][1][1].text,
                       triggerEvent: self["MSH"]?[9][1][2][1].text, structure: self["MSH"]?[9][1][3][1].text)
    }
    public var controlID: String? { self["MSH"]?[10][1][1][1].text }
    public var lossReport: [HL7Diagnostic] { diagnostics.filter { $0.code == .segmentSkipped } }
}
