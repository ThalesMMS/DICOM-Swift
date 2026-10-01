import Foundation

public enum DicomExposureMode: String, Codable, Sendable { case localOnly, intranetLab, external }
public struct DicomExposureFinding: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable { case tlsRequired, authenticationRequired, loopbackRequired, labOptIn, ephemeralPortNotPinned }
    public let code: Code
    public let isError: Bool
    public init(code: Code, isError: Bool = true) { self.code = code; self.isError = isError }
}
public struct DicomExposureValidationError: Error, Equatable, Sendable {
    public let findings: [DicomExposureFinding]
}
public struct DicomExposurePolicy: Codable, Equatable, Sendable {
    public let mode: DicomExposureMode
    public let requireTLS: Bool
    public let requireAuthentication: Bool
    public let allowUnauthorizedIntranetLab: Bool
    public let allowAnonymousQuery: Bool
    public init(mode: DicomExposureMode, requireTLS: Bool, requireAuthentication: Bool, allowAnonymousQuery: Bool = false, allowUnauthorizedIntranetLab: Bool = false) {
        self.mode = mode; self.requireTLS = requireTLS; self.requireAuthentication = requireAuthentication
        self.allowAnonymousQuery = allowAnonymousQuery
        self.allowUnauthorizedIntranetLab = allowUnauthorizedIntranetLab
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decode(DicomExposureMode.self, forKey: .mode),
            requireTLS: try values.decode(Bool.self, forKey: .requireTLS),
            requireAuthentication: try values.decode(Bool.self, forKey: .requireAuthentication),
            allowAnonymousQuery: try values.decodeIfPresent(Bool.self, forKey: .allowAnonymousQuery) ?? false,
            allowUnauthorizedIntranetLab: try values.decodeIfPresent(Bool.self, forKey: .allowUnauthorizedIntranetLab) ?? false)
    }
    public static func defaults(for mode: DicomExposureMode) -> Self {
        .init(mode: mode, requireTLS: mode == .external, requireAuthentication: true, allowAnonymousQuery: false)
    }
    public func validate(bindAddress: String, tlsEnabled: Bool,
                         authenticationConfigured: Bool) throws -> [DicomExposureFinding] {
        var findings: [DicomExposureFinding] = []
        if (requireTLS || mode == .external), !tlsEnabled { findings.append(.init(code: .tlsRequired)) }
        let labOptIn = mode == .intranetLab && allowUnauthorizedIntranetLab
        if labOptIn { findings.append(.init(code: .labOptIn, isError: false)) }
        if (requireAuthentication || mode != .localOnly), !authenticationConfigured, !labOptIn {
            findings.append(.init(code: .authenticationRequired))
        }
        // Accept numeric loopback only; DNS names are not evidence of loopback binding.
        let ipv4 = bindAddress.split(separator: ".", omittingEmptySubsequences: false)
        let loopback = bindAddress == "::1" || (ipv4.count == 4 && ipv4.first == "127"
            && ipv4.allSatisfy { UInt8($0) != nil })
        if mode == .localOnly && !loopback { findings.append(.init(code: .loopbackRequired)) }
        if findings.contains(where: \.isError) { throw DicomExposureValidationError(findings: findings) }
        return findings
    }
}
