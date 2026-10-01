import Foundation
import HL7v3CDA

/// Server trust policy for the HTTP transport. Certificate material is injected by the host.
public enum HL7v3TransportTrust: Equatable, Sendable {
    /// The platform trust store.
    case system
    /// Only chains anchored at one of these DER-encoded root/intermediate certificates are accepted.
    case pinnedRoots([Data])

    /// Reads every `CERTIFICATE` block of a PEM file into DER data.
    public static func pinnedRoots(pemFileAtPath path: String) throws -> HL7v3TransportTrust {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var blocks: [Data] = []
        var current: [String] = []
        var inside = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("-----BEGIN CERTIFICATE-----") { inside = true; current = []; continue }
            if line.hasPrefix("-----END CERTIFICATE-----") {
                inside = false
                guard let der = Data(base64Encoded: current.joined()) else { throw HL7v3TransportError.invalidConfiguration("PEM") }
                blocks.append(der)
                continue
            }
            if inside { current.append(line.trimmingCharacters(in: .whitespaces)) }
        }
        guard !blocks.isEmpty else { throw HL7v3TransportError.invalidConfiguration("PEM") }
        return .pinnedRoots(blocks)
    }
}

/// Bounded, explicit delivery policy for HL7 v3 SOAP/REST exchanges.
public struct HL7v3TransportPolicy: Equatable, Sendable {
    public var timeout: TimeInterval
    public var maximumRequestBytes: Int
    public var maximumResponseBytes: Int
    /// Plain `http` is refused unless the host is listed here (loopback labs, tests).
    public var allowInsecureForHosts: Set<String>
    public var trust: HL7v3TransportTrust
    /// Host name used for TLS server-name verification when pinning; defaults to the URL host.
    public var serverName: String?
    public var xmlLimits: XMLLimits

    public init(timeout: TimeInterval = 30,
                maximumRequestBytes: Int = 16 * 1024 * 1024,
                maximumResponseBytes: Int = 16 * 1024 * 1024,
                allowInsecureForHosts: Set<String> = [],
                trust: HL7v3TransportTrust = .system,
                serverName: String? = nil,
                xmlLimits: XMLLimits = XMLLimits()) {
        self.timeout = timeout
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.allowInsecureForHosts = allowInsecureForHosts
        self.trust = trust
        self.serverName = serverName
        self.xmlLimits = xmlLimits
    }

    public static func == (lhs: HL7v3TransportPolicy, rhs: HL7v3TransportPolicy) -> Bool {
        lhs.timeout == rhs.timeout && lhs.maximumRequestBytes == rhs.maximumRequestBytes &&
            lhs.maximumResponseBytes == rhs.maximumResponseBytes && lhs.allowInsecureForHosts == rhs.allowInsecureForHosts &&
            lhs.trust == rhs.trust && lhs.serverName == rhs.serverName &&
            lhs.xmlLimits == rhs.xmlLimits
    }

    /// Validates the endpoint before any bytes are sent.
    public func validate(_ url: URL) throws {
        guard timeout.isFinite, timeout > 0, maximumRequestBytes > 0, maximumResponseBytes > 0 else {
            throw HL7v3TransportError.invalidConfiguration("limits")
        }
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw HL7v3TransportError.invalidEndpoint
        }
        switch scheme {
        case "https": return
        case "http":
            guard allowInsecureForHosts.contains(host.lowercased()) else { throw HL7v3TransportError.insecureEndpoint }
        default: throw HL7v3TransportError.invalidEndpoint
        }
    }
}

public enum HL7v3TransportError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidEndpoint
    case insecureEndpoint
    case requestTooLarge
    case responseTooLarge
    /// Failure before any request byte reached the peer (connect/DNS refusal): safe to retry.
    case beforeSend
    /// Failure after the request body was completely sent: delivery is uncertain.
    case afterBodySent(String)
    /// Failure with unknown send progress: treated as uncertain.
    case unknownProgress(String)
    case tlsTrustRejected
}

public enum HL7v3RejectReason: Equatable, Sendable {
    case status
    case redirectNotAllowed
    case malformedResponse
    /// Failure before send, never after: the request was not delivered.
    case network
}

public struct HL7v3TransportResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var envelope: SOAPEnvelope

    public init(status: Int, headers: [String: String], envelope: SOAPEnvelope) {
        self.status = status
        self.headers = headers
        self.envelope = envelope
    }
}

/// Delivery outcome with explicit uncertainty: nothing here is ever retried automatically.
public enum HL7v3DeliveryOutcome: Sendable {
    case accepted(HL7v3TransportResponse)
    case fault(SOAPFault, status: Int)
    case rejected(HL7v3RejectReason, status: Int?)
    /// The request may have been processed by the peer (timeout, oversize or drop after the body was sent).
    case uncertain(String)

    public var isAccepted: Bool { if case .accepted = self { return true } else { return false } }
}

public enum HL7v3RetryAdvice: Equatable, Sendable {
    case safeToRetry
    case requiresReconciliation
    case doNotRetry

    /// Only failures proven to precede sending are safe to retry; uncertainty needs host reconciliation.
    public static func classify(_ outcome: HL7v3DeliveryOutcome) -> HL7v3RetryAdvice {
        switch outcome {
        case .accepted, .fault: return .doNotRetry
        case .rejected(let reason, _): return reason == .network ? .safeToRetry : .doNotRetry
        case .uncertain: return .requiresReconciliation
        }
    }
}
