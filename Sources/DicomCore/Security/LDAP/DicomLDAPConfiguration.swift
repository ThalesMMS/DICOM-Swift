import Foundation

/// Credentials are supplied per call, never serialized with directory configuration.
public struct DicomLDAPConfiguration: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable { case ldaps, loopbackPlaintext }
    public var host: String
    public var port: UInt16
    public var transport: Transport
    public var trustStorePath: String?
    public var userBaseDN: String
    public var userAttribute: String
    public var groupBaseDN: String
    public var groupMemberAttribute: String
    public var searchBindDN: String?
    public var timeout: TimeInterval
    public var maximumResponseBytes: Int
    public var maximumGroups: Int

    public init(host: String, port: UInt16 = 636, transport: Transport = .ldaps,
                trustStorePath: String? = nil, userBaseDN: String, userAttribute: String = "uid",
                groupBaseDN: String, groupMemberAttribute: String = "member", searchBindDN: String? = nil,
                timeout: TimeInterval = 10, maximumResponseBytes: Int = 1_048_576, maximumGroups: Int = 128) {
        self.host = host; self.port = port; self.transport = transport; self.trustStorePath = trustStorePath
        self.userBaseDN = userBaseDN; self.userAttribute = userAttribute; self.groupBaseDN = groupBaseDN
        self.groupMemberAttribute = groupMemberAttribute; self.searchBindDN = searchBindDN
        self.timeout = timeout; self.maximumResponseBytes = maximumResponseBytes; self.maximumGroups = maximumGroups
    }

    public func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 58].contains($0) }),
              Self.validDN(userBaseDN), Self.validDN(groupBaseDN), searchBindDN.map(Self.validDN) ?? true,
              Self.validAttribute(userAttribute), Self.validAttribute(groupMemberAttribute),
              timeout.isFinite, timeout > 0, timeout <= 60,
              (256...4_194_304).contains(maximumResponseBytes), (1...256).contains(maximumGroups),
              trustStorePath.map({ !$0.isEmpty }) ?? true else { throw DicomLDAPError.invalidConfiguration }
        if transport == .loopbackPlaintext {
            guard trustStorePath == nil,
                  (try? DicomExposurePolicy.defaults(for: .localOnly).validate(bindAddress: host,
                      tlsEnabled: false, authenticationConfigured: true)) != nil else {
                throw DicomLDAPError.insecureTransport
            }
        }
    }

    static func validDN(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0)
    }

    // A bounded descriptor profile, without attribute options or arbitrary filter fragments.
    static func validAttribute(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, bytes.count <= 64, (65...90).contains(first) || (97...122).contains(first) else {
            return false
        }
        return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || $0 == 45 }
    }
}
