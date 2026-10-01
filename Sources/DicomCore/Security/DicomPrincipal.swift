import Foundation

/// An assertion issued by a trusted authentication adapter after credential verification.
/// Constructing or decoding this value does not authenticate credentials. Never accept it from a peer as proof.
public struct DicomPrincipal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case localUser, serviceAccount, peerApplication, anonymous }
    public enum Source: String, Codable, Sendable {
        case local, userIdentityNegotiation, oidc, bearer, basic, mutualTLS, ldap, none
    }
    public let id: String
    public let kind: Kind
    public let source: Source
    public let displayHint: String?
    public let scopes: Set<String>
    public let roles: Set<String>
    public let sessionID: String
    public let authenticatedAt: Date
    public let expiresAt: Date?
    public let policyVersion: Int64
    public let evidence: [String: String]

    public init(id: String, kind: Kind, source: Source, displayHint: String? = nil,
                scopes: Set<String> = [], roles: Set<String> = [], sessionID: String,
                authenticatedAt: Date, expiresAt: Date? = nil, policyVersion: Int64,
                evidence: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.source = source; self.displayHint = displayHint
        self.scopes = scopes; self.roles = roles; self.sessionID = sessionID
        self.authenticatedAt = authenticatedAt; self.expiresAt = expiresAt; self.policyVersion = policyVersion
        // Only non-secret verification metadata is permitted; arbitrary credential dictionaries are not retained.
        self.evidence = evidence.filter { ["issuer", "kid"].contains($0.key) }.mapValues {
            DicomAuditPHIMinimizer.error($0)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
            source: try c.decode(Source.self, forKey: .source),
            displayHint: try c.decodeIfPresent(String.self, forKey: .displayHint),
            scopes: try c.decode(Set<String>.self, forKey: .scopes), roles: try c.decode(Set<String>.self, forKey: .roles),
            sessionID: try c.decode(String.self, forKey: .sessionID),
            authenticatedAt: try c.decode(Date.self, forKey: .authenticatedAt),
            expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
            policyVersion: try c.decode(Int64.self, forKey: .policyVersion),
            evidence: try c.decode([String: String].self, forKey: .evidence))
    }

    public static let anonymous = DicomPrincipal(id: "anonymous", kind: .anonymous, source: .none,
        sessionID: "", authenticatedAt: .distantPast, policyVersion: 0)
}

public struct DicomAccessContext: Equatable, Sendable {
    public enum AccessProtocol: String, Codable, Sendable { case dimse, dicomweb, jpip, local, webhook, cli, mllp }
    public var callingAETitle: String?
    public var calledAETitle: String?
    public var peerAddress: String?
    public var peerPort: UInt16?
    public var transportSecured: Bool
    public var `protocol`: AccessProtocol
    public var requestID: String
    public var at: Date
    public init(callingAETitle: String? = nil, calledAETitle: String? = nil, peerAddress: String? = nil,
                peerPort: UInt16? = nil, transportSecured: Bool = false, protocol: AccessProtocol,
                requestID: String = UUID().uuidString, at: Date = Date()) {
        self.callingAETitle = callingAETitle; self.calledAETitle = calledAETitle
        self.peerAddress = peerAddress; self.peerPort = peerPort; self.transportSecured = transportSecured
        self.protocol = `protocol`; self.requestID = requestID; self.at = at
    }
}
