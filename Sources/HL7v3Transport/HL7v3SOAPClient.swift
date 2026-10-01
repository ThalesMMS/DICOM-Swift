import DicomCore
import Foundation
import HL7v3CDA

/// Sends one HL7 v3 payload per SOAP envelope over an injected HTTP transport.
///
/// The client never follows redirects, never retries, bounds request and response sizes, parses
/// responses through the safe XML parser and reports uncertainty explicitly. Credentials are
/// injected: a WS-Security header, and/or HTTP headers produced by `additionalHeaders`
/// (for example a bearer token), which are marked as credential headers on the request.
public struct HL7v3SOAPClient: Sendable {
    public let endpoint: URL
    public let version: SOAPVersion
    public let policy: HL7v3TransportPolicy
    public let security: WSSecurityHeader?
    private let transport: any DicomWebHTTPTransport
    private let additionalHeaders: @Sendable () async throws -> [String: String]

    public init(endpoint: URL,
                version: SOAPVersion = .v1_2,
                policy: HL7v3TransportPolicy = .init(),
                security: WSSecurityHeader? = nil,
                transport: (any DicomWebHTTPTransport)? = nil,
                additionalHeaders: @escaping @Sendable () async throws -> [String: String] = { [:] }) {
        self.endpoint = endpoint
        self.version = version
        self.policy = policy
        self.security = security
        self.transport = transport ?? HL7v3URLSessionTransport(maximumResponseBytes: policy.maximumResponseBytes,
                                                                trust: policy.trust, serverName: policy.serverName)
        self.additionalHeaders = additionalHeaders
    }

    /// Throws only for local policy/configuration problems before any byte is sent; delivery results are outcomes.
    public func send(_ payload: HL7v3CDA.XMLNode, action: String? = nil, headerElements: [HL7v3CDA.XMLNode] = []) async throws -> HL7v3DeliveryOutcome {
        try policy.validate(endpoint)
        var headers = headerElements
        if let security { headers.insert(security.node(version: version), at: 0) }
        let envelope = SOAPEnvelope(version: version, headerElements: headers, body: payload)
        let body = try envelope.serialize()
        guard body.count <= policy.maximumRequestBytes else { throw HL7v3TransportError.requestTooLarge }
        var httpHeaders = try await additionalHeaders()
        let credentialNames = Set(httpHeaders.keys)
        httpHeaders["Content-Type"] = version.contentType(action: action)
        httpHeaders["Accept"] = "application/soap+xml, text/xml"
        if version == .v1_1 { httpHeaders["SOAPAction"] = "\"" + (action ?? "").replacingOccurrences(of: "\"", with: "") + "\"" }
        var request = DicomWebHTTPRequest(method: .post, url: endpoint, headers: httpHeaders, body: body, timeout: policy.timeout)
        request.credentialHeaderNames = credentialNames
        let response: DicomWebHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HL7v3TransportError {
            return Self.outcome(for: error)
        } catch let error as DicomWebhookTransportError {
            switch error {
            case .beforeSend: return .rejected(.network, status: nil)
            case .responseTooLarge: return .uncertain("response exceeded the configured limit")
            case .afterBodySent, .unknownProgress: return .uncertain("transport failure after the request started")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .uncertain("transport failure with unknown progress")
        }
        return Self.outcome(status: response.statusCode, headers: response.headers, body: response.body, limits: policy.xmlLimits)
    }

    static func outcome(for error: HL7v3TransportError) -> HL7v3DeliveryOutcome {
        switch error {
        case .beforeSend, .tlsTrustRejected: return .rejected(.network, status: nil)
        case .responseTooLarge: return .uncertain("response exceeded the configured limit")
        case .afterBodySent, .unknownProgress: return .uncertain("transport failure after the request started")
        case .invalidConfiguration, .invalidEndpoint, .insecureEndpoint, .requestTooLarge:
            return .rejected(.network, status: nil)
        }
    }

    static func outcome(status: Int, headers: [String: String], body: Data, limits: XMLLimits) -> HL7v3DeliveryOutcome {
        if (300...399).contains(status) { return .rejected(.redirectNotAllowed, status: status) }
        guard !body.isEmpty, let envelope = try? SOAPEnvelope.parse(body, limits: limits) else {
            return (200...299).contains(status) ? .rejected(.malformedResponse, status: status) : .rejected(.status, status: status)
        }
        if let fault = envelope.fault { return .fault(fault, status: status) }
        guard (200...299).contains(status) else { return .rejected(.status, status: status) }
        return .accepted(.init(status: status, headers: headers, envelope: envelope))
    }
}
