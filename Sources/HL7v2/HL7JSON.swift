import Foundation

/// Lossless model JSON includes values, explicit value states, and original escape spellings.
/// Use HL7Inspector.tree for a redacted JSON tree (JSONEncoder supports that tree directly).
public enum HL7JSON {
    private struct Segment: Codable {
        let name: String
        let fields: [HL7Field]
        let originalLineIndex: Int
    }
    private struct Document: Codable {
        let format: Int
        let fieldSeparator: String
        let encodingCharacters: String
        let charset: HL7Charset
        let effectiveCharset: HL7Charset
        let charsetDeclarations: [String]
        let hasTrailingTerminator: Bool
        let segments: [Segment]
    }
    public static func encode(_ message: HL7Message) throws -> Data {
        let document = Document(format: 1, fieldSeparator: String(message.encoding.field),
            encodingCharacters: message.encoding.msh2, charset: message.charset,
            effectiveCharset: message.effectiveCharset, charsetDeclarations: message.charsetDeclarations,
            hasTrailingTerminator: message.hasTrailingTerminator,
            segments: message.segments.map { Segment(name: $0.name, fields: $0.fields, originalLineIndex: $0.originalLineIndex) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
    public static func decode(_ data: Data) throws -> HL7Message {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format == 1, document.fieldSeparator.count == 1,
              document.segments.first?.name == "MSH",
              document.segments.allSatisfy({ HL7Path.validName($0.name) }) else {
            throw HL7ParseError.malformed(.init(), lineIndex: 0)
        }
        let encoding = try HL7EncodingCharacters(field: document.fieldSeparator.first!, msh2: document.encodingCharacters)
        return HL7Message(segments: document.segments.map {
            HL7Segment(name: $0.name, fields: $0.fields, originalLineIndex: $0.originalLineIndex)
        }, encoding: encoding, charset: document.charset, effectiveCharset: document.effectiveCharset,
           charsetDeclarations: document.charsetDeclarations, diagnostics: [],
           hasTrailingTerminator: document.hasTrailingTerminator)
    }
}
