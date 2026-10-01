import CryptoKit
import Foundation
import HL7v3CDA

/// WS-Security 1.0 header *serialization* (UsernameToken, Timestamp, BinarySecurityToken).
///
/// Only token serialization is implemented, matching what the reference actually ships.
/// No XML Signature, XML Encryption, SAML or Kerberos profiles are provided, and a
/// UsernameToken is not evidence of authentication: hosts must combine these headers
/// with TLS and their own authorization policy.
public enum WSSecurityNamespace {
    public static let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
    public static let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    public static let passwordText = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText"
    public static let passwordDigest = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
    public static let base64Binary = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary"
    public static let x509v3 = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-x509-token-profile-1.0#X509v3"
}

public enum WSSecurityPasswordType: String, Codable, Sendable {
    /// Clear text password: only acceptable over TLS.
    case text
    /// `Base64(SHA-1(nonce + created + password))` per the UsernameToken profile 1.0 (SHA-1 is mandated by that profile).
    case digest
}

public struct WSSecurityUsernameToken: Equatable, Sendable {
    public var username: String
    public var password: String
    public var passwordType: WSSecurityPasswordType
    /// Random nonce; generated per header when nil and the type is digest.
    public var nonce: Data?

    public init(username: String, password: String, passwordType: WSSecurityPasswordType = .digest, nonce: Data? = nil) {
        self.username = username
        self.password = password
        self.passwordType = passwordType
        self.nonce = nonce
    }

    /// Digest computed as in the profile: the nonce bytes, the created string bytes and the password bytes, in that order.
    public static func digest(nonce: Data, created: String, password: String) -> String {
        var input = Data()
        input.append(nonce)
        input.append(Data(created.utf8))
        input.append(Data(password.utf8))
        return Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
    }

    func node(created: Date) -> HL7v3CDA.XMLNode {
        let createdText = WSSecurityHeader.timestampString(created)
        var children = [HL7v3CDA.XMLNode("Username", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse", text: username)]
        switch passwordType {
        case .text:
            children.append(HL7v3CDA.XMLNode("Password", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse",
                                    attributes: ["Type": WSSecurityNamespace.passwordText], text: password))
        case .digest:
            let nonce = nonce ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            children.append(HL7v3CDA.XMLNode("Password", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse",
                                    attributes: ["Type": WSSecurityNamespace.passwordDigest],
                                    text: Self.digest(nonce: nonce, created: createdText, password: password)))
            children.append(HL7v3CDA.XMLNode("Nonce", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse",
                                    attributes: ["EncodingType": WSSecurityNamespace.base64Binary],
                                    text: nonce.base64EncodedString()))
            children.append(HL7v3CDA.XMLNode("Created", namespaceURI: WSSecurityNamespace.wsu, prefix: "wsu", text: createdText))
        }
        return HL7v3CDA.XMLNode("UsernameToken", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse", children: children)
    }
}

public struct WSSecurityTimestamp: Equatable, Sendable {
    public var created: Date
    public var expires: Date

    public init(created: Date, expires: Date) {
        self.created = created
        self.expires = expires
    }

    public init(created: Date = Date(), lifetime: TimeInterval = 300) {
        self.init(created: created, expires: created.addingTimeInterval(lifetime))
    }

    public var isValid: Bool { expires > created }

    func node() -> HL7v3CDA.XMLNode {
        HL7v3CDA.XMLNode("Timestamp", namespaceURI: WSSecurityNamespace.wsu, prefix: "wsu", children: [
            HL7v3CDA.XMLNode("Created", namespaceURI: WSSecurityNamespace.wsu, prefix: "wsu",
                    text: WSSecurityHeader.timestampString(created)),
            HL7v3CDA.XMLNode("Expires", namespaceURI: WSSecurityNamespace.wsu, prefix: "wsu",
                    text: WSSecurityHeader.timestampString(expires))
        ])
    }
}

public struct WSSecurityBinaryToken: Equatable, Sendable {
    /// Base64 token value supplied by the host (for example a DER X.509 certificate).
    public var value: String
    public var valueType: String
    public var encodingType: String

    public init(value: String, valueType: String = WSSecurityNamespace.x509v3,
                encodingType: String = WSSecurityNamespace.base64Binary) {
        self.value = value
        self.valueType = valueType
        self.encodingType = encodingType
    }

    func node() -> HL7v3CDA.XMLNode {
        HL7v3CDA.XMLNode("BinarySecurityToken", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse",
                attributes: ["ValueType": valueType, "EncodingType": encodingType], text: value)
    }
}

public struct WSSecurityHeader: Equatable, Sendable {
    public var usernameToken: WSSecurityUsernameToken?
    public var timestamp: WSSecurityTimestamp?
    public var binaryToken: WSSecurityBinaryToken?
    public var mustUnderstand: Bool

    public init(usernameToken: WSSecurityUsernameToken? = nil, timestamp: WSSecurityTimestamp? = nil,
                binaryToken: WSSecurityBinaryToken? = nil, mustUnderstand: Bool = true) {
        self.usernameToken = usernameToken
        self.timestamp = timestamp
        self.binaryToken = binaryToken
        self.mustUnderstand = mustUnderstand
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` in UTC, as WS-Security utility timestamps expect.
    static func timestampString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).timeSeparator(.colon)
            .time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }

    /// Builds the `wsse:Security` header element for the given envelope version.
    public func node(version: SOAPVersion, now: Date = Date()) -> HL7v3CDA.XMLNode {
        var children: [HL7v3CDA.XMLNode] = []
        if let timestamp { children.append(timestamp.node()) }
        if let binaryToken { children.append(binaryToken.node()) }
        if let usernameToken { children.append(usernameToken.node(created: now)) }
        var security = HL7v3CDA.XMLNode("Security", namespaceURI: WSSecurityNamespace.wsse, prefix: "wsse", children: children)
        if mustUnderstand {
            security.attributes[XMLName("mustUnderstand", namespaceURI: version.namespace, prefix: "soap")] = version == .v1_1 ? "1" : "true"
        }
        security.namespaces["wsu"] = WSSecurityNamespace.wsu
        return security
    }
}
