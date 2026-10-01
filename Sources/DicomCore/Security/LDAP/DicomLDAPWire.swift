import Foundation

enum DicomLDAPWire {
    struct Entry: Equatable, Sendable {
        let dn: String
        let attributes: [String: [String]]
    }
    enum Response: Equatable, Sendable { case bind, entry(Entry), done }

    static func field(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        var length = bytes.count
        var prefix: [UInt8] = []
        repeat { prefix.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return [tag] + (bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(prefix.count)] + prefix) + bytes
    }
    static func text(_ value: String) -> [UInt8] { field(4, Array(value.utf8)) }
    static func integer(_ value: Int, tag: UInt8 = 2) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 } while value > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return field(tag, bytes)
    }
    static func message(_ id: Int, operation: [UInt8]) -> Data { Data(field(0x30, integer(id) + operation)) }
    static func bind(_ id: Int, dn: String, password: Data) -> Data {
        message(id, operation: field(0x60, integer(3) + text(dn) + field(0x80, Array(password))))
    }
    static func search(_ id: Int, base: String, filter: DicomLDAPEqualityFilter,
                       attributes: [String], limit: Int, seconds: Int) -> Data {
        let scope = integer(2, tag: 0x0a) + integer(0, tag: 0x0a) // subtree, never dereference aliases
        let limits = integer(limit) + integer(seconds) + field(1, [0])
        let assertion = field(0xa3, text(filter.attribute) + text(filter.value))
        return message(id, operation: field(0x63, text(base) + scope + limits + assertion
            + field(0x30, attributes.flatMap(text))))
    }

    /// Reads only the bounded length prefix, so a peer cannot force allocation from an advertised size.
    static func frameLength(_ data: Data, maximum: Int) throws -> Int? {
        let prefix = Array(data.prefix(6))
        guard let first = prefix.first else { return nil }
        guard first == 0x30 else { throw DicomLDAPError.malformedResponse }
        guard prefix.count >= 2 else { return nil }
        let count = Int(prefix[1] & 0x7f)
        let header: Int
        let length: Int
        if prefix[1] < 128 { header = 2; length = Int(prefix[1]) }
        else {
            guard (1...4).contains(count) else { throw DicomLDAPError.malformedResponse }
            guard prefix.count >= 2 + count else { return nil }
            header = 2 + count
            length = prefix[2..<header].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard length <= maximum - header else { throw DicomLDAPError.responseLimit }
        return header + length
    }

    static func parse(_ data: Data, expectedID: Int, maximum: Int) throws -> Response {
        guard try frameLength(data, maximum: maximum) == data.count else { throw DicomLDAPError.truncatedResponse }
        var envelope = Reader(bytes: Array(data))
        var body = try envelope.nested(0x30)
        guard try body.number(2) == expectedID, expectedID > 0 else { throw DicomLDAPError.malformedResponse }
        let operation = try body.next()
        guard body.isEmpty else { throw DicomLDAPError.unsupportedResponse } // no requested controls
        var payload = Reader(bytes: operation.bytes)
        switch operation.tag {
        case 0x61, 0x65:
            let code = try payload.number(0x0a)
            _ = try payload.string(); _ = try payload.string() // never retain server diagnostics
            guard payload.isEmpty else { throw DicomLDAPError.unsupportedResponse }
            guard code == 0 else { throw code == 49 ? DicomLDAPError.invalidCredentials : .serverResult(code) }
            return operation.tag == 0x61 ? .bind : .done
        case 0x64:
            let dn = try payload.string()
            guard DicomLDAPConfiguration.validDN(dn) else { throw DicomLDAPError.malformedResponse }
            var list = try payload.nested(0x30)
            var attributes: [String: [String]] = [:]
            while !list.isEmpty {
                guard attributes.count < 32 else { throw DicomLDAPError.responseLimit }
                var attribute = try list.nested(0x30)
                let name = try attribute.string().lowercased()
                guard DicomLDAPConfiguration.validAttribute(name), attributes[name] == nil else {
                    throw DicomLDAPError.malformedResponse
                }
                var values = try attribute.nested(0x31)
                var strings: [String] = []
                while !values.isEmpty {
                    guard strings.count < 256 else { throw DicomLDAPError.responseLimit }
                    strings.append(try values.string())
                }
                guard attribute.isEmpty else { throw DicomLDAPError.malformedResponse }
                attributes[name] = strings
            }
            guard payload.isEmpty else { throw DicomLDAPError.malformedResponse }
            return .entry(.init(dn: dn, attributes: attributes))
        default: throw DicomLDAPError.unsupportedResponse // includes referrals, SASL and unsolicited messages
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var isEmpty: Bool { offset == bytes.count }
        mutating func next() throws -> (tag: UInt8, bytes: [UInt8]) {
            guard bytes.count - offset >= 2 else { throw DicomLDAPError.truncatedResponse }
            let tag = bytes[offset]; let first = bytes[offset + 1]; offset += 2
            var length = Int(first)
            if first >= 128 {
                let count = Int(first & 0x7f)
                guard (1...4).contains(count), bytes.count - offset >= count else {
                    throw DicomLDAPError.malformedResponse
                }
                length = bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }; offset += count
            }
            guard length <= bytes.count - offset else { throw DicomLDAPError.truncatedResponse }
            defer { offset += length }
            return (tag, Array(bytes[offset..<(offset + length)]))
        }
        mutating func nested(_ tag: UInt8) throws -> Reader {
            let item = try next()
            guard item.tag == tag else { throw DicomLDAPError.malformedResponse }
            return Reader(bytes: item.bytes)
        }
        mutating func number(_ tag: UInt8) throws -> Int {
            let item = try next()
            guard item.tag == tag, (1...4).contains(item.bytes.count), item.bytes[0] < 128 else {
                throw DicomLDAPError.malformedResponse
            }
            return item.bytes.reduce(0) { ($0 << 8) | Int($1) }
        }
        mutating func string() throws -> String {
            let item = try next()
            guard item.tag == 4, item.bytes.count <= 4096, let text = String(bytes: item.bytes, encoding: .utf8) else {
                throw DicomLDAPError.malformedResponse
            }
            return text
        }
    }
}
