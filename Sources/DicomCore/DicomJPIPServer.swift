import Foundation

public struct DicomJPIPServerConfiguration: Sendable {
    public var maximumIndexBytes = 128 * 1_024 * 1_024
    public var maximumTargets = 16
    public var maximumResponseBytes = 32 * 1_024 * 1_024
    public var maximumChannelBytes = 256 * 1_024 * 1_024
    public var maximumChannels = 64
    public var idleTimeout: TimeInterval = 120
    public var maximumRequestBytes = 16_384
    public var maximumParameters = 64
    public init() {}
}

/// Transport-neutral origin. The response iterator produces one bounded message per consumer pull.
public actor DicomJPIPServer {
    public let configuration: DicomJPIPServerConfiguration
    public let sessions: DicomJPIPServerSessions
    private let authorizer: (any DicomAuthorizing)?
    private let principals: (any DicomWebPrincipalResolving)?
    private let audit: DicomAuditRecorder?
    private let resourceResolver: (@Sendable (String) async -> DicomResourceRef?)?
    private let provider: any DicomJPIPTargetProviding
    private let authentication: (any DicomWebAuthenticating)?
    private struct Cached {
        let tid: String
        let indices: [DicomJPIPCodestreamIndex]
        let bytes: Int
        var access: UInt64
    }
    private var cache: [String: Cached] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    // Reserve the entire indexing workspace before awaiting an external provider.
    private var loading = false
    public init(provider: any DicomJPIPTargetProviding, configuration: DicomJPIPServerConfiguration = .init(),
                authentication: (any DicomWebAuthenticating)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                principals: (any DicomWebPrincipalResolving)? = nil,
                authorizer: (any DicomAuthorizing)? = nil, audit: DicomAuditRecorder? = nil,
                resourceResolver: (@Sendable (String) async -> DicomResourceRef?)? = nil) {
        self.principals = principals; self.authorizer = authorizer; self.audit = audit
        self.resourceResolver = resourceResolver
        self.provider = provider; self.configuration = configuration; self.authentication = authentication
        sessions = .init(maximumChannels: configuration.maximumChannels, maximumBytes: configuration.maximumChannelBytes,
                         idleTimeout: configuration.idleTimeout, now: now)
    }
    public func invalidateTargets() { cache.removeAll(); cacheBytes = 0 }
    private func indexed(_ name: String) async throws -> Cached {
        access &+= 1
        if var cached = cache[name] { cached.access = access; cache[name] = cached; return cached }
        guard !loading, configuration.maximumTargets > 0, configuration.maximumIndexBytes > 0 else {
            throw DicomJPIPServerError.limitExceeded
        }
        loading = true
        defer { loading = false }
        // Evict before allocating. Concurrent responses retain their immutable indices independently.
        cache.removeAll(); cacheBytes = 0
        let target = try await provider.target(named: name, maximumBytes: configuration.maximumIndexBytes)
        guard !target.codestreams.isEmpty, target.codestreams.count <= 1024 else { throw DicomJPIPServerError.limitExceeded }
        var indices: [DicomJPIPCodestreamIndex] = [], bytes = 0
        for data in target.codestreams {
            let index = try DicomJPIPCodestreamIndexer(maximumIndexBytes: configuration.maximumIndexBytes - bytes).index(data)
            bytes += index.estimatedBytes; indices.append(index)
        }
        let result = Cached(tid: target.identifier, indices: indices, bytes: bytes, access: access)
        cache[name] = result; cacheBytes = bytes
        return result
    }
    public func handle(_ request: DicomWebHTTPRequest) async -> DicomWebHTTPStreamedResponse {
        do {
            if let authentication, case let .deny(status, challenge) = await authentication.authenticate(request) {
                return Self.response(status: status, headers: challenge.map { ["WWW-Authenticate": $0] } ?? [:], data: Data("Access denied".utf8))
            }
            guard request.method == .get else { return Self.response(status: 405, headers: ["Allow": "GET"], data: Data()) }
            let parsed = try DicomJPIPRequestParser(maximumRequestBytes: configuration.maximumRequestBytes,
                                                   maximumParameters: configuration.maximumParameters).parse(request.url)
            guard configuration.maximumResponseBytes >= 3 else { throw DicomJPIPServerError.limitExceeded }
            if !parsed.closeChannels.isEmpty {
                let closed = await sessions.close(parsed.closeChannels)
                if parsed.target == nil && parsed.channelID == nil {
                    return Self.response(status: 200, headers: ["Content-Type": "image/jpp-stream", "JPIP-cclose": closed.joined(separator: ",")],
                                         data: try DicomJPIPMessageWriter().endOfResponse(reason: 2))
                }
            }
            let name: String
            if let target = parsed.target { name = target }
            else if let cid = parsed.channelID { name = try await sessions.target(for: cid) }
            else { throw DicomJPIPServerError.malformedRequest }
            guard parsed.subtarget == nil else { throw DicomJPIPServerError.unsupportedCodestream }
            let inherited = DicomRequestAuthorization.current
            let access: DicomEnforcement
            if let inherited { access = inherited }
            else {
                access = .init(principal: await principals?.principal(for: request), authorizer: authorizer,
                    audit: audit, context: .init(protocol: .jpip))
            }
            let resource = await resourceResolver?(name)
            if access.authorizer != nil {
                guard let resource, resource.sourceObject.kind == .instance else {
                    throw DicomWebServerFailure(403, "Unresolved JPIP source.")
                }
                _ = try await access.check(.readBytes, resource.sourceObject)
            }
            let target = try await indexed(name)
            if let tid = parsed.window.tid, tid != "0", tid != target.tid { throw DicomJPIPServerError.malformedRequest }
            let streams = parsed.streams.isEmpty ? [1...1] : parsed.streams
            guard streams.allSatisfy({ $0.upperBound <= target.indices.count }) else { throw DicomJPIPServerError.malformedRequest }
            let selected = target.indices.indices.filter { i in streams.contains { $0.contains(i + 1) } }
            var bins: [DeliveryBin] = [], headers: [String: String] = [:], full = true
            for stream in selected {
                let selection = try Self.select(target.indices[stream], stream: stream, window: parsed.window)
                bins += selection.bins; headers = selection.headers; full = full && selection.full
            }
            let lease = try await sessions.begin(id: parsed.channelID, create: parsed.newChannel, target: name, tid: target.tid)
            headers["JPIP-tid"] = target.tid
            headers["JPIP-stream"] = selected.map { String($0 + 1) }.joined(separator: ",")
            if parsed.newChannel, let lease { headers["JPIP-cnew"] = "cid=\(lease.id),transport=http" }
            if !parsed.closeChannels.isEmpty { headers["JPIP-cclose"] = parsed.closeChannels.joined(separator: ",") }
            headers["Content-Type"] = parsed.window.type == .jptStream ? "image/jpt-stream" : "image/jpp-stream"
            headers["Cache-Control"] = "no-store"
            let delivery = try Delivery(bins: bins, request: parsed, configuration: configuration,
                                        sessions: sessions, lease: lease, full: full)
            return .init(statusCode: 200, headers: headers,
                         body: AsyncThrowingStream(unfolding: {
                             if let resource { try await access.recheck(.readBytes, resource.sourceObject) }
                             return try await delivery.next()
                         }),
                         cancel: { Task { await delivery.cancel() } })
        } catch let error as DicomWebServerFailure {
            return Self.response(status: error.status, data: Data(error.message.utf8))
        } catch is DicomAuditError {
            return Self.response(status: 503, data: Data("Audit unavailable".utf8))
        } catch let error as DicomJPIPServerError {
            return Self.response(status: error.statusCode, data: Data(String(describing: error).utf8))
        } catch {
            return Self.response(status: 422, data: Data("Target unavailable".utf8))
        }
    }
    static func response(status: Int, headers: [String: String] = [:], data: Data) -> DicomWebHTTPStreamedResponse {
        .init(statusCode: status, headers: ["Content-Type": "text/plain"].merging(headers) { _, b in b },
              body: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}
