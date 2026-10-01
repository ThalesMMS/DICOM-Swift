import Foundation

/// Bounded recursive-descent JSON parser producing the lossless `FHIRJSON` tree.
/// Rejects duplicate keys (FHIR JSON forbids them), NaN/Infinity, control characters and lone
/// surrogates; never allocates a string larger than `maxStringBytes` and never nests deeper
/// than `maxDepth`.
public struct FHIRJSONParser: Sendable {
    public var limits: FHIRLimits
    public init(limits: FHIRLimits = FHIRLimits()) { self.limits = limits }

    public func parse(_ data: Data) throws -> FHIRJSON {
        guard data.count <= limits.maxBytes else { throw FHIRJSONError.byteLimit }
        var scanner = Scanner(bytes: [UInt8](data), limits: limits)
        scanner.skipWhitespace()
        let value = try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw FHIRJSONError.syntax(offset: scanner.offset) }
        return value
    }

    public func parseObject(_ data: Data) throws -> FHIRJSONObject {
        guard let object = try parse(data).object else { throw FHIRJSONError.notAnObject }
        return object
    }

    private struct Scanner {
        let bytes: [UInt8]
        let limits: FHIRLimits
        var offset = 0
        var nodes = 0

        init(bytes: [UInt8], limits: FHIRLimits) {
            self.bytes = bytes
            self.limits = limits
        }

        var atEnd: Bool { offset >= bytes.count }
        var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { offset += 1 }
        }

        mutating func countNode() throws {
            nodes += 1
            guard nodes <= limits.maxNodes else { throw FHIRJSONError.nodeLimit }
        }

        mutating func parseValue(depth: Int) throws -> FHIRJSON {
            // Root value at depth 0: `maxDepth` nesting levels are allowed in total.
            guard depth < limits.maxDepth else { throw FHIRJSONError.depthLimit }
            try countNode()
            guard let byte = current else { throw FHIRJSONError.syntax(offset: offset) }
            switch byte {
            case UInt8(ascii: "{"): return .object(try parseObject(depth: depth))
            case UInt8(ascii: "["): return .array(try parseArray(depth: depth))
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw FHIRJSONError.syntax(offset: offset)
            }
        }

        mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard offset + expected.count <= bytes.count, Array(bytes[offset..<offset + expected.count]) == expected else {
                throw FHIRJSONError.syntax(offset: offset)
            }
            offset += expected.count
        }

        mutating func parseObject(depth: Int) throws -> FHIRJSONObject {
            offset += 1
            var object = FHIRJSONObject()
            skipWhitespace()
            if current == UInt8(ascii: "}") { offset += 1; return object }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw FHIRJSONError.syntax(offset: offset) }
                let key = try parseString()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { throw FHIRJSONError.syntax(offset: offset) }
                offset += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                guard object[key] == nil else { throw FHIRJSONError.duplicateKey(key) }
                object[key] = value
                skipWhitespace()
                guard let byte = current else { throw FHIRJSONError.syntax(offset: offset) }
                offset += 1
                if byte == UInt8(ascii: "}") { return object }
                guard byte == UInt8(ascii: ",") else { throw FHIRJSONError.syntax(offset: offset - 1) }
            }
        }

        mutating func parseArray(depth: Int) throws -> [FHIRJSON] {
            offset += 1
            var items: [FHIRJSON] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") { offset += 1; return items }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard let byte = current else { throw FHIRJSONError.syntax(offset: offset) }
                offset += 1
                if byte == UInt8(ascii: "]") { return items }
                guard byte == UInt8(ascii: ",") else { throw FHIRJSONError.syntax(offset: offset - 1) }
            }
        }

        mutating func parseNumber() throws -> FHIRNumber {
            let start = offset
            while let byte = current, byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") ||
                byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                offset += 1
            }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard FHIRNumber.isValidLexical(text) else { throw FHIRJSONError.syntax(offset: start) }
            return FHIRNumber(lexical: text)
        }

        mutating func parseString() throws -> String {
            offset += 1
            var output: [UInt8] = []
            while true {
                guard let byte = current else { throw FHIRJSONError.syntax(offset: offset) }
                offset += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: output, encoding: .utf8) else { throw FHIRJSONError.invalidUTF8 }
                    return text
                case UInt8(ascii: "\\"):
                    guard let escaped = current else { throw FHIRJSONError.syntax(offset: offset) }
                    offset += 1
                    switch escaped {
                    case UInt8(ascii: "\""): output.append(0x22)
                    case UInt8(ascii: "\\"): output.append(0x5C)
                    case UInt8(ascii: "/"): output.append(0x2F)
                    case UInt8(ascii: "b"): output.append(0x08)
                    case UInt8(ascii: "f"): output.append(0x0C)
                    case UInt8(ascii: "n"): output.append(0x0A)
                    case UInt8(ascii: "r"): output.append(0x0D)
                    case UInt8(ascii: "t"): output.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try parseHex4()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard current == UInt8(ascii: "\\"), offset + 1 < bytes.count, bytes[offset + 1] == UInt8(ascii: "u") else {
                                throw FHIRJSONError.syntax(offset: offset)
                            }
                            offset += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw FHIRJSONError.syntax(offset: offset) }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw FHIRJSONError.syntax(offset: offset)
                        }
                        guard let unicode = Unicode.Scalar(scalar) else { throw FHIRJSONError.syntax(offset: offset) }
                        output.append(contentsOf: Array(String(Character(unicode)).utf8))
                    default: throw FHIRJSONError.syntax(offset: offset - 1)
                    }
                case 0x00...0x1F: throw FHIRJSONError.syntax(offset: offset - 1)
                default: output.append(byte)
                }
                guard output.count <= limits.maxStringBytes else { throw FHIRJSONError.stringLimit }
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw FHIRJSONError.syntax(offset: offset) }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw FHIRJSONError.syntax(offset: offset)
                }
                value = value * 16 + digit
                offset += 1
            }
            return value
        }
    }
}

/// Deterministic JSON writer: key order as stored, numbers verbatim, minimal escaping (ASCII-safe optional).
public struct FHIRJSONWriter: Sendable {
    public var pretty: Bool
    public var asciiOnly: Bool
    public init(pretty: Bool = false, asciiOnly: Bool = false) {
        self.pretty = pretty
        self.asciiOnly = asciiOnly
    }

    public func write(_ value: FHIRJSON) -> Data {
        var output = ""
        emit(value, into: &output, depth: 0)
        if pretty { output += "\n" }
        return Data(output.utf8)
    }

    public func write(_ object: FHIRJSONObject) -> Data { write(.object(object)) }

    private func emit(_ value: FHIRJSON, into output: inout String, depth: Int) {
        switch value {
        case .object(let object):
            if object.isEmpty { output += "{}"; return }
            output += "{"
            for (index, pair) in object.pairs.enumerated() {
                if index > 0 { output += "," }
                newline(&output, depth: depth + 1)
                output += quote(pair.key) + (pretty ? ": " : ":")
                emit(pair.value, into: &output, depth: depth + 1)
            }
            newline(&output, depth: depth)
            output += "}"
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                newline(&output, depth: depth + 1)
                emit(item, into: &output, depth: depth + 1)
            }
            newline(&output, depth: depth)
            output += "]"
        case .string(let text): output += quote(text)
        case .number(let number): output += number.lexical
        case .bool(let flag): output += flag ? "true" : "false"
        case .null: output += "null"
        }
    }

    private func newline(_ output: inout String, depth: Int) {
        guard pretty else { return }
        output += "\n" + String(repeating: "  ", count: depth)
    }

    private func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 || (asciiOnly && scalar.value > 0x7E) {
                    if scalar.value > 0xFFFF {
                        let value = scalar.value - 0x10000
                        result += String(format: "\\u%04X\\u%04X", 0xD800 + (value >> 10), 0xDC00 + (value & 0x3FF))
                    } else {
                        result += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
