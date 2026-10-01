import Foundation
import Network
import Security

/// A single HTTP/1.1 exchange to a policy-approved numeric endpoint. No proxy, DNS retry or redirect hop.
struct DicomWebhookPinnedConnection {
    static func send(_ request: DicomWebHTTPRequest, address: String,
                     maxResponseBytes: Int) async throws -> DicomWebHTTPResponse {
        guard let host = request.url.host, let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let port = UInt16(exactly: request.url.port ?? (request.url.scheme?.lowercased() == "https" ? 443 : 80)), port > 0 else {
            throw DicomWebhookDeliveryError.invalidConfiguration
        }
        let endpoint: NWEndpoint.Host
        if let ip = IPv4Address(address) { endpoint = .ipv4(ip) }
        else if let ip = IPv6Address(address) { endpoint = .ipv6(ip) }
        else { throw DicomWebhookDeliveryError.invalidConfiguration }
        let queue = DispatchQueue(label: "DicomWebhook.pinned")
        let parameters = NWParameters(tls: request.url.scheme?.lowercased() == "https" ? tlsOptions(host: host, queue: queue) : nil,
                                      tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        let connection = NWConnection(host: endpoint, port: .init(rawValue: port)!, using: parameters)
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let authority = host + (request.url.port.map { ":\($0)" } ?? "")
        let body = request.body ?? Data()
        var message = "\(request.method.rawValue) \(path) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in request.headers {
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) && !"()<>@,;:\\\"/[]?={} ".utf8.contains($0) }),
                  value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
                  !["host", "content-length", "transfer-encoding", "connection"].contains(name.lowercased()) else {
                throw DicomWebhookDeliveryError.invalidHeaderValue
            }
            message += "\(name): \(value)\r\n"
        }
        var bytes = Data((message + "\r\n").utf8)
        bytes.append(body)
        let ready = AsyncThrowingStream<Void, any Error>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.continuation.yield(()); ready.continuation.finish()
            case .failed(let error): ready.continuation.finish(throwing: error)
            case .cancelled: ready.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        let deadline = DispatchWorkItem { connection.cancel() }
        defer {
            deadline.cancel()
            connection.cancel()
            connection.stateUpdateHandler = nil
        }
        return try await withTaskCancellationHandler {
            var submitted = false
            do {
                try Task.checkCancellation()
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + request.timeout, execute: deadline)
                var iterator = ready.stream.makeAsyncIterator()
                guard try await iterator.next() != nil else { throw DicomWebhookTransportError.beforeSend }
                try Task.checkCancellation()
                submitted = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
                var reader = DicomWebhookHTTPResponseReader(connection: connection, maximumBodyBytes: maxResponseBytes)
                return try await reader.response()
            } catch DicomWebhookTransportError.responseTooLarge {
                throw DicomWebhookTransportError.responseTooLarge
            } catch {
                if submitted { throw DicomWebhookTransportError.unknownProgress("\(error)") }
                throw DicomWebhookTransportError.beforeSend
            }
        } onCancel: { connection.cancel() }
    }

    private static func tlsOptions(host: String, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        name.withCString { sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, $0) }
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, peer, complete in
            let trust = sec_trust_copy_ref(peer).takeRetainedValue()
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, name as CFString)) == errSecSuccess else {
                complete(false); return
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        return options
    }
}
