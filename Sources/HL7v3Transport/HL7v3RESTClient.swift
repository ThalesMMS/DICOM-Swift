import DicomCore
import Foundation
import HL7v3CDA

public enum HL7v3RESTOutcome: Sendable {
    case accepted(status: Int, headers: [String: String], body: HL7v3CDA.XMLNode?)
    case rejected(HL7v3RejectReason, status: Int?)
    case uncertain(String)
}

/// Plain HTTP exchange of HL7 v3 XML payloads (no SOAP envelope) with the same bounded, redirect-free,
/// non-retrying semantics as `HL7v3SOAPClient`. Only `GET` and `DELETE` are considered safe to repeat
/// by `HL7v3RetryAdvice`; POST/PUT uncertainty needs host reconciliation.
public struct HL7v3RESTClient: Sendable {
    public let baseURL: URL
    public let policy: HL7v3TransportPolicy
    private let transport: any DicomWebHTTPTransport
    private let additionalHeaders: @Sendable () async throws -> [String: String]

    public init(baseURL: URL, policy: HL7v3TransportPolicy = .init(), transport: (any DicomWebHTTPTransport)? = nil,
                additionalHeaders: @escaping @Sendable () async throws -> [String: String] = { [:] }) {
        self.baseURL = baseURL
        self.policy = policy
        self.transport = transport ?? HL7v3URLSessionTransport(maximumResponseBytes: policy.maximumResponseBytes,
                                                                trust: policy.trust, serverName: policy.serverName)
        self.additionalHeaders = additionalHeaders
    }

    public func send(_ method: DicomWebHTTPMethod, path: String = "", body: HL7v3CDA.XMLNode? = nil) async throws -> HL7v3RESTOutcome {
        let url = path.isEmpty ? baseURL : baseURL.appendingPathComponent(path)
        try policy.validate(url)
        var data: Data?
        if let body {
            data = try XMLSerializer().serialize(body)
            guard data!.count <= policy.maximumRequestBytes else { throw HL7v3TransportError.requestTooLarge }
        }
        var httpHeaders = try await additionalHeaders()
        let credentialNames = Set(httpHeaders.keys)
        httpHeaders["Accept"] = "application/xml, text/xml"
        if data != nil { httpHeaders["Content-Type"] = "application/xml; charset=utf-8" }
        var request = DicomWebHTTPRequest(method: method, url: url, headers: httpHeaders, body: data, timeout: policy.timeout)
        request.credentialHeaderNames = credentialNames
        let response: DicomWebHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HL7v3TransportError {
            switch HL7v3SOAPClient.outcome(for: error) {
            case .rejected(let reason, let status): return .rejected(reason, status: status)
            case .uncertain(let text): return .uncertain(text)
            case .accepted, .fault: return .uncertain("unexpected transport state")
            }
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
        if (300...399).contains(response.statusCode) { return .rejected(.redirectNotAllowed, status: response.statusCode) }
        guard (200...299).contains(response.statusCode) else { return .rejected(.status, status: response.statusCode) }
        if response.body.isEmpty { return .accepted(status: response.statusCode, headers: response.headers, body: nil) }
        guard let node = try? SafeXMLParser(limits: policy.xmlLimits).parse(response.body) else {
            return .rejected(.malformedResponse, status: response.statusCode)
        }
        return .accepted(status: response.statusCode, headers: response.headers, body: node)
    }
}
