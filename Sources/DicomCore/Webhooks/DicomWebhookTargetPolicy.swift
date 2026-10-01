import Foundation
import Darwin

public enum DicomWebhookTargetError: Error, Equatable {
    case schemeNotAllowed, credentialsInURL, hostNotAllowed(String), addressNotAllowed(String)
    case portNotAllowed, resolutionFailed
}

public struct DicomWebhookTargetPolicy: Sendable {
    public var requireHTTPS: Bool
    public var allowLoopback: Bool
    public var allowPrivateNetworks: Bool
    public var allowedHosts: Set<String>
    public var allowInsecureForHosts: Set<String>
    public var allowRedirects: Bool
    public var maxRedirects: Int
    public var timeout: TimeInterval
    public var maxResponseBytes: Int
    private let resolve: @Sendable (String) throws -> [String]

    public init(requireHTTPS: Bool = true, allowLoopback: Bool = false, allowPrivateNetworks: Bool = false,
                allowedHosts: Set<String> = [], allowInsecureForHosts: Set<String> = [],
                allowRedirects: Bool = false, maxRedirects: Int = 0, timeout: TimeInterval = 15,
                maxResponseBytes: Int = 64 * 1024,
                resolve: @escaping @Sendable (String) throws -> [String] = Self.resolveHost) {
        self.requireHTTPS = requireHTTPS
        self.allowLoopback = allowLoopback
        self.allowPrivateNetworks = allowPrivateNetworks
        self.allowedHosts = allowedHosts
        self.allowInsecureForHosts = allowInsecureForHosts
        self.allowRedirects = allowRedirects
        self.maxRedirects = maxRedirects
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
        self.resolve = resolve
    }

    public func validate(_ url: URL) throws { _ = try validatedAddresses(url) }

    /// All returned addresses passed the policy; the transport must use one without another DNS lookup.
    public func validatedAddresses(_ url: URL) throws -> [String] {
        guard url.user == nil, url.password == nil else { throw DicomWebhookTargetError.credentialsInURL }
        guard let rawHost = url.host, !rawHost.isEmpty else { throw DicomWebhookTargetError.hostNotAllowed("") }
        let host = Self.normalize(rawHost)
        guard !host.contains("%"), !host.contains("\0") else { throw DicomWebhookTargetError.hostNotAllowed(host) }
        let insecure = Set(allowInsecureForHosts.map(Self.normalize))
        guard url.scheme?.lowercased() == "https" ||
                (url.scheme?.lowercased() == "http" && (!requireHTTPS || insecure.contains(host))) else {
            throw DicomWebhookTargetError.schemeNotAllowed
        }
        if let port = url.port, !(1...65535).contains(port) { throw DicomWebhookTargetError.portNotAllowed }
        let addresses: [String]
        if Self.addressClass(host) != nil { addresses = [host] }
        else {
            do { addresses = try resolve(host) }
            catch { throw DicomWebhookTargetError.resolutionFailed }
        }
        guard !addresses.isEmpty else { throw DicomWebhookTargetError.resolutionFailed }
        let allowlisted = Set(allowedHosts.map(Self.normalize)).contains(host)
        for address in addresses {
            guard let category = Self.addressClass(address) else { throw DicomWebhookTargetError.resolutionFailed }
            if allowlisted { continue }
            switch category {
            case .publicAddress: continue
            case .loopback where allowLoopback: continue
            case .privateAddress where allowPrivateNetworks: continue
            default: throw DicomWebhookTargetError.addressNotAllowed(address)
            }
        }
        return addresses.map(Self.normalize)
    }

    private static func normalize(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private enum AddressClass { case publicAddress, loopback, privateAddress, forbidden }
    private static func classifyIPv4(_ bytes: [UInt8]) -> AddressClass {
        if bytes[0] == 127 { return .loopback }
        if bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) { return .privateAddress }
        if bytes[0] == 0 || bytes[0] >= 224 || (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 100 && (64...127).contains(bytes[1])) { return .forbidden }
        return .publicAddress
    }

    private static func addressClass(_ string: String) -> AddressClass? {
        let string = normalize(string)
        var v4 = in_addr()
        if string.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { classifyIPv4(Array($0)) }
        }
        var v6 = in6_addr()
        guard string.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            return classifyIPv4(Array(bytes.suffix(4)))
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .forbidden }
        if bytes[0] & 0xfe == 0xfc { return .privateAddress }
        if bytes[0] == 0xff || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return .forbidden }
        // Reject IPv4-compatible, translation and tunnelling forms rather than bypass IPv4 checks.
        if bytes.prefix(12).allSatisfy({ $0 == 0 }) ||
            (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b) ||
            (bytes[0] == 0x20 && bytes[1] == 0x02) ||
            (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0) { return .forbidden }
        return .publicAddress
    }

    public static func resolveHost(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw DicomWebhookTargetError.resolutionFailed
        }
        defer { freeaddrinfo(first) }
        var addresses = [String]()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            cursor = node.pointee.ai_next
        }
        guard !addresses.isEmpty else { throw DicomWebhookTargetError.resolutionFailed }
        return addresses
    }
}
