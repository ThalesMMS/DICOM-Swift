import Foundation

/// Equality is encoded as an ASN.1 assertion, never by interpolating filter syntax.
public struct DicomLDAPEqualityFilter: Equatable, Sendable {
    public let attribute: String
    public let value: String
    public init(attribute: String, value: String) throws {
        guard DicomLDAPConfiguration.validAttribute(attribute), value.utf8.count <= 4096 else {
            throw DicomLDAPError.invalidConfiguration
        }
        self.attribute = attribute; self.value = value
    }
    /// RFC 4515 representation for callers that need a textual filter. The wire uses the original octets.
    public var stringRepresentation: String {
        let escaped = value.utf8.map { byte in
            (32...126).contains(byte) && ![40, 41, 42, 92].contains(byte)
                ? String(UnicodeScalar(byte)) : String(format: "\\%02x", byte)
        }.joined()
        return "(\(attribute)=\(escaped))"
    }
}
