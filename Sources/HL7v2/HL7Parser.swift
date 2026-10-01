import Foundation

public struct HL7ParserOptions: Equatable, Sendable {
    public enum SegmentTerminator: Sendable { case cr }
    public enum Recovery: Sendable { case strict, skipBadSegments }
    public var charsetOverride: HL7Charset?
    public var maxMessageBytes = 16 * 1024 * 1024
    public var maxSegments = 10_000
    public var maxFieldsPerSegment = 1_000
    public var maxRepetitions = 1_000
    public var maxComponentDepth = 3
    public var segmentTerminator: SegmentTerminator = .cr
    public var lenientTerminators = false
    public var recovery: Recovery = .strict
    public init() {}
}

public struct HL7Parser: Sendable {
    public let options: HL7ParserOptions
    public init(options: HL7ParserOptions = HL7ParserOptions()) { self.options = options }

    /// A String is supplied as UTF-8 bytes. Use Data for non-UTF-8 wire messages.
    public func parse(_ string: String) throws -> HL7Message { try parse(Data(string.utf8)) }

    public func parse(_ bytes: Data) throws -> HL7Message {
        guard bytes.count <= options.maxMessageBytes else {
            throw HL7ParseError.limitExceeded(.messageBytes, HL7Path())
        }
        var diagnostics: [HL7Diagnostic] = []
        let lines = try segmentLines(bytes, diagnostics: &diagnostics)
        guard let headerIndex = lines.firstIndex(where: { $0.starts(with: [77, 83, 72]) }),
              lines[headerIndex].count >= 8 else {
            throw HL7ParseError.malformed(HL7Path(segment: "MSH"), lineIndex: 0)
        }
        if headerIndex != 0 && options.recovery == .strict {
            throw HL7ParseError.malformed(HL7Path(), lineIndex: 0)
        }
        let headerBytes = Array(lines[headerIndex])
        let fieldByte = headerBytes[3]
        guard let end = headerBytes[4...].firstIndex(of: fieldByte) else {
            throw HL7ParseError.encodingCharacters(HL7Path(segment: "MSH", field: 2))
        }
        let encoding = try HL7EncodingCharacters(field: Character(Unicode.Scalar(fieldByte)),
            msh2: String(decoding: headerBytes[4..<end], as: UTF8.self))
        // Byte-transparent scan before any message decoding, skipping the special MSH-2 field.
        let headerTail = HL7Charset.iso8859(1).decode(Data(headerBytes[(end + 1)...]))!
        let headerFields = try split(headerTail, separator: encoding.field, encoding: encoding,
            limit: options.maxFieldsPerSegment - 2, kind: .fields, path: HL7Path(segment: "MSH"))
        let declarations = headerFields.count > 15 ? try split(headerFields[15], separator: encoding.repetition,
            encoding: encoding, limit: options.maxRepetitions, kind: .repetitions,
            path: HL7Path(segment: "MSH", field: 18)) : []
        let declaration = declarations.first ?? ""
        let charset = HL7Charset(declaration: declaration)
        var effective = options.charsetOverride ?? charset
        if case .unknown = charset {
            diagnostics.append(HL7Diagnostic(code: .charsetFallback, path: HL7Path(segment: "MSH", field: 18),
                                             lengths: [declaration.utf8.count]))
        } else if effective.decode(bytes) == nil {
            effective = .iso8859(1)
            diagnostics.append(HL7Diagnostic(code: .charsetFallback, path: HL7Path(segment: "MSH", field: 18),
                                             lengths: [bytes.count]))
        }
        if declaration.trimmingCharacters(in: .whitespaces).uppercased() == "UNICODE" {
            diagnostics.append(HL7Diagnostic(code: .legacyCharsetAlias, path: HL7Path(segment: "MSH", field: 18)))
        }
        var segments: [HL7Segment] = []
        for (index, lineBytes) in lines.enumerated() {
            let path = HL7Path()
            do {
                guard index >= headerIndex, let line = effective.decode(lineBytes) else {
                    throw HL7ParseError.malformed(path, lineIndex: index)
                }
                // Parse each segment transactionally: discarded segments cannot leave value diagnostics behind.
                var segmentDiagnostics: [HL7Diagnostic] = []
                let segment = try parseSegment(line, encoding: encoding, charset: effective,
                    lineIndex: index, isHeader: index == headerIndex, diagnostics: &segmentDiagnostics)
                segments.append(segment)
                diagnostics += segmentDiagnostics
            } catch let error as HL7ParseError {
                if case .limitExceeded = error { throw error }
                guard options.recovery == .skipBadSegments, index != headerIndex else { throw error }
                diagnostics.append(HL7Diagnostic(code: .segmentSkipped, path: path, lineIndex: index,
                                                 lengths: [lineBytes.count], severity: .error))
            }
        }
        var message = HL7Message(segments: segments, encoding: encoding, charset: charset, effectiveCharset: effective,
            charsetDeclarations: declarations, diagnostics: diagnostics,
            hasTrailingTerminator: bytes.last == 13 || bytes.last == 10)
        if case .unknown = message.version {
            message.diagnostics.append(HL7Diagnostic(code: .versionUnknown, path: HL7Path(segment: "MSH", field: 12)))
        }
        return message
    }

    private func segmentLines(_ data: Data, diagnostics: inout [HL7Diagnostic]) throws -> [Data] {
        let bytes = Array(data)
        var lines: [Data] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 13 || byte == 10 {
                let crlf = byte == 13 && index + 1 < bytes.count && bytes[index + 1] == 10
                if byte == 10 || crlf {
                    guard options.lenientTerminators else {
                        throw HL7ParseError.malformed(HL7Path(), lineIndex: lines.count)
                    }
                    diagnostics.append(HL7Diagnostic(code: .terminatorNormalized, lineIndex: lines.count,
                                                     lengths: [crlf ? 2 : 1]))
                }
                guard lines.count < options.maxSegments else {
                    throw HL7ParseError.limitExceeded(.segments, HL7Path())
                }
                lines.append(Data(bytes[start..<index]))
                index += crlf ? 2 : 1
                start = index
            } else { index += 1 }
        }
        if start < bytes.count {
            guard lines.count < options.maxSegments else { throw HL7ParseError.limitExceeded(.segments, HL7Path()) }
            lines.append(Data(bytes[start...]))
        }
        return lines
    }

    private func parseSegment(_ line: String, encoding: HL7EncodingCharacters, charset: HL7Charset,
                              lineIndex: Int, isHeader: Bool, diagnostics: inout [HL7Diagnostic]) throws -> HL7Segment {
        let prefix = String(line.prefix(3))
        let path = HL7Path(segment: prefix)
        guard HL7Path.validName(prefix), line.count == 3 || line.dropFirst(3).first == encoding.field,
              !line.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              (prefix != "MSH" || isHeader) else {
            throw HL7ParseError.malformed(path, lineIndex: lineIndex)
        }
        var fields: [HL7Field] = []
        var rawFields: [String] = []
        if isHeader {
            fields = [HL7Field(.text(String(encoding.field))), HL7Field(.text(encoding.msh2))]
            rawFields = try split(String(line.dropFirst(5 + encoding.msh2.count)), separator: encoding.field,
                encoding: encoding, limit: options.maxFieldsPerSegment - 2, kind: .fields, path: path)
        } else if line.count > 3 {
            rawFields = try split(String(line.dropFirst(4)), separator: encoding.field, encoding: encoding,
                                 limit: options.maxFieldsPerSegment, kind: .fields, path: path)
        }
        for rawField in rawFields {
            let fieldIndex = fields.count + 1
            let fieldPath = HL7Path(segment: prefix, field: fieldIndex)
            let rawRepetitions = try split(rawField, separator: encoding.repetition, encoding: encoding,
                                          limit: options.maxRepetitions, kind: .repetitions, path: fieldPath)
            var repetitions: [HL7Repetition] = []
            for (repIndex, rawRepetition) in rawRepetitions.enumerated() {
                let rawComponents = try split(rawRepetition, separator: encoding.component, encoding: encoding,
                                              path: fieldPath)
                if options.maxComponentDepth < 1 || (rawComponents.count > 1 && options.maxComponentDepth < 2) {
                    throw HL7ParseError.limitExceeded(.componentDepth,
                        HL7Path(segment: prefix, field: fieldIndex, component: 1, repetition: repIndex + 1))
                }
                var components: [HL7Component] = []
                for (componentIndex, rawComponent) in rawComponents.enumerated() {
                    let rawValues = try split(rawComponent, separator: encoding.subcomponent, encoding: encoding,
                                              path: fieldPath)
                    if rawValues.count > 1 && options.maxComponentDepth < 3 {
                        throw HL7ParseError.limitExceeded(.componentDepth,
                            HL7Path(segment: prefix, field: fieldIndex, component: componentIndex + 1,
                                    subcomponent: 1, repetition: repIndex + 1))
                    }
                    var values: [HL7Value] = []
                    for (valueIndex, rawValue) in rawValues.enumerated() {
                        if rawValue.isEmpty { values.append(.empty) }
                        else if rawValue == "\"\"" { values.append(.null) }
                        else {
                            let valuePath = HL7Path(segment: prefix, field: fieldIndex, component: componentIndex + 1,
                                                    subcomponent: valueIndex + 1, repetition: repIndex + 1)
                            let result = HL7Escape.unescape(rawValue, encoding: encoding, charset: charset, path: valuePath)
                            values.append(.text(result.text))
                            diagnostics += result.diagnostics
                        }
                    }
                    var component = HL7Component(subcomponents: values)
                    component.raw = rawValues
                    component.original = values
                    components.append(component)
                }
                repetitions.append(HL7Repetition(components: components))
            }
            fields.append(HL7Field(repetitions: repetitions))
        }
        return HL7Segment(name: prefix, fields: fields, originalLineIndex: lineIndex)
    }

    /// Delimiters inside closed opaque escapes are data, not structure.
    private func split(_ text: String, separator: Character, encoding: HL7EncodingCharacters,
                       limit: Int = Int.max, kind: HL7ParseError.Limit = .fields, path: HL7Path) throws -> [String] {
        guard limit > 0 else { throw HL7ParseError.limitExceeded(kind, path) }
        var result: [String] = []
        var start = text.startIndex
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor] == encoding.escape,
               let end = text[text.index(after: cursor)...].firstIndex(of: encoding.escape) {
                cursor = text.index(after: end)
                continue
            }
            if text[cursor] == separator {
                guard result.count + 1 < limit else { throw HL7ParseError.limitExceeded(kind, path) }
                result.append(String(text[start..<cursor]))
                start = text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        result.append(String(text[start...]))
        return result
    }
}
