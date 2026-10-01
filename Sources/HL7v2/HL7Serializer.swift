import Foundation

public struct HL7SerializerOptions: Equatable, Sendable {
    public var trimTrailingEmpty = false
    /// Unrepresentable scalars are emitted as UTF-8 hex bytes. This is an explicit wire-byte
    /// fallback, not a charset switch: consumers must agree on how to interpret these bytes.
    public var escapeUnrepresentable = false
    public init() {}
}

public struct HL7Serializer: Sendable {
    public let options: HL7SerializerOptions
    public init(options: HL7SerializerOptions = HL7SerializerOptions()) { self.options = options }

    public func serialize(_ message: HL7Message) throws -> Data {
        let encoding = message.encoding
        let charset = message.effectiveCharset
        guard message.segments.first?.name == "MSH" else { throw failure(.malformedContent, HL7Path(segment: "MSH")) }
        var lines: [String] = []
        for (segmentIndex, segment) in message.segments.enumerated() {
            guard HL7Path.validName(segment.name), segment.name != "MSH" || segmentIndex == 0 else {
                throw failure(.malformedContent, HL7Path())
            }
            var fields: [String] = []
            for (fieldIndex, field) in segment.fields.enumerated() {
                let path = HL7Path(segment: segment.name, field: fieldIndex + 1)
                if segment.name == "MSH" && fieldIndex < 2 {
                    let expected = fieldIndex == 0 ? String(encoding.field) : encoding.msh2
                    guard field == HL7Field(.text(expected)) else { throw failure(.encodingCharacterConflict, path) }
                    continue
                }
                if !field.isPresent {
                    guard segment.fields[(fieldIndex + 1)...].allSatisfy({ !$0.isPresent }) else {
                        throw failure(.malformedContent, path)
                    }
                    break
                }
                var repetitions: [String] = []
                for (repIndex, repetition) in field.repetitions.enumerated() {
                    var components: [String] = []
                    for (componentIndex, component) in repetition.components.enumerated() {
                        var values: [String] = []
                        for (valueIndex, value) in component.subcomponents.enumerated() {
                            let leafPath = HL7Path(segment: segment.name, field: fieldIndex + 1,
                                component: componentIndex + 1, subcomponent: valueIndex + 1, repetition: repIndex + 1)
                            if valueIndex < component.original.count, valueIndex < component.raw.count,
                               component.original[valueIndex] == value {
                                guard safeRaw(component.raw[valueIndex], encoding: encoding) else {
                                    throw failure(.malformedContent, leafPath)
                                }
                                values.append(component.raw[valueIndex])
                            } else {
                                switch value {
                                case .absent:
                                    throw failure(.malformedContent, leafPath)
                                case .empty: values.append("")
                                case .null: values.append("\"\"")
                                case .text(let text):
                                    var escaped = HL7Escape.escape(text, encoding: encoding, charset: charset)
                                    // Keep a literal pair of quotes distinct from the HL7 null sentinel.
                                    if escaped == "\"\"" { escaped = HL7Escape.hex(Data([34, 34]), encoding: encoding) }
                                    if charset.encode(escaped) == nil {
                                        guard options.escapeUnrepresentable else {
                                            throw failure(.unrepresentableCharacter, leafPath)
                                        }
                                        escaped = escaped.unicodeScalars.map { scalar in
                                            let part = String(scalar)
                                            return charset.encode(part) == nil ?
                                                HL7Escape.hex(Data(part.utf8), encoding: encoding) : part
                                        }.joined()
                                    }
                                    values.append(escaped)
                                }
                            }
                        }
                        trim(&values)
                        components.append(values.joined(separator: String(encoding.subcomponent)))
                    }
                    trim(&components)
                    repetitions.append(components.joined(separator: String(encoding.component)))
                }
                fields.append(repetitions.joined(separator: String(encoding.repetition)))
            }
            trim(&fields)
            var line = segment.name
            if segment.name == "MSH" {
                guard segment.fields.count >= 2 else { throw failure(.encodingCharacterConflict, HL7Path(segment: "MSH")) }
                line += String(encoding.field) + encoding.msh2
            }
            if !fields.isEmpty { line += String(encoding.field) + fields.joined(separator: String(encoding.field)) }
            lines.append(line)
        }
        let text = lines.joined(separator: "\r") + (message.hasTrailingTerminator ? "\r" : "")
        guard let bytes = charset.encode(text) else { throw failure(.unrepresentableCharacter, HL7Path()) }
        return bytes
    }

    private func safeRaw(_ text: String, encoding: HL7EncodingCharacters) -> Bool {
        guard !text.utf8.contains(13), !text.utf8.contains(10) else { return false }
        let separators: Set<Character> = [encoding.field, encoding.repetition, encoding.component, encoding.subcomponent]
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == encoding.escape,
               let end = text[text.index(after: cursor)...].firstIndex(of: encoding.escape) {
                cursor = text.index(after: end)
                continue
            }
            if separators.contains(text[cursor]) { return false }
            cursor = text.index(after: cursor)
        }
        return true
    }

    private func trim(_ values: inout [String]) {
        if options.trimTrailingEmpty { while values.last?.isEmpty == true { values.removeLast() } }
    }
    private func failure(_ code: HL7Diagnostic.Code, _ path: HL7Path) -> HL7SerializationError {
        HL7SerializationError(diagnostic: HL7Diagnostic(code: code, path: path, severity: .error))
    }
}
