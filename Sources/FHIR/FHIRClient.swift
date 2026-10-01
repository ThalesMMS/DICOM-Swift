import DicomCore
import Foundation
import HL7v3Transport

public enum FHIRWireFormat: String, Sendable {
    case json, xml
    public var mimeType: String { self == .json ? "application/fhir+json" : "application/fhir+xml" }
}

/// Client configuration: base URL, transport policy (timeouts, size bounds, TLS trust, https-only),
/// wire format and the bounds applied to paging and reference/attachment fetches.
public struct FHIRClientConfiguration: Sendable {
    public var baseURL: URL
    public var policy: HL7v3TransportPolicy
    public var limits: FHIRLimits
    public var format: FHIRWireFormat
    /// `Prefer: return=...` sent with writes; nil sends no preference.
    public var preferReturn: String?
    /// Maximum number of pages followed by `collect`; `next` links must stay on an allowed origin.
    public var maxPages: Int
    public var maxCollectedResources: Int
    /// Additional hosts (scheme://host[:port]) whose absolute links and attachments may be fetched.
    public var allowedOrigins: Set<String>

    public init(baseURL: URL, policy: HL7v3TransportPolicy = .init(), limits: FHIRLimits = FHIRLimits(),
                format: FHIRWireFormat = .json, preferReturn: String? = "representation",
                maxPages: Int = 20, maxCollectedResources: Int = 5_000, allowedOrigins: Set<String> = []) {
        self.baseURL = baseURL
        self.policy = policy
        self.limits = limits
        self.format = format
        self.preferReturn = preferReturn
        self.maxPages = maxPages
        self.maxCollectedResources = maxCollectedResources
        self.allowedOrigins = allowedOrigins
    }

    public func isAllowedOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        let origin = scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        let base = (baseURL.scheme?.lowercased() ?? "") + "://" + (baseURL.host?.lowercased() ?? "") + (baseURL.port.map { ":\($0)" } ?? "")
        return origin == base || allowedOrigins.contains(origin)
    }
}

public enum FHIRFailureReason: Equatable, Sendable {
    case status, network, redirectNotAllowed, malformedResponse, responseTooLarge, originNotAllowed, invalidRequest, pageLimit
}

/// A failed interaction. `uncertain` is true when the request may have been applied by the server
/// (write sent, no conclusive answer); reads are never uncertain because they are safe to repeat.
public struct FHIRFailure: Error, Sendable {
    public let reason: FHIRFailureReason
    public let status: Int?
    public let outcome: FHIROperationOutcome?
    public let uncertain: Bool
    public let message: String

    public init(reason: FHIRFailureReason, status: Int? = nil, outcome: FHIROperationOutcome? = nil, uncertain: Bool = false, message: String) {
        self.reason = reason
        self.status = status
        self.outcome = outcome
        self.uncertain = uncertain
        self.message = message
    }

    public var isVersionConflict: Bool { status == 412 || status == 409 }
    public var isNotFound: Bool { status == 404 || status == 410 }
}

public struct FHIRResponseMetadata: Sendable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }

    public func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    public var etag: String? { header("ETag") }
    public var lastModified: String? { header("Last-Modified") }
    public var location: String? { header("Location") }
    public var contentType: String? { header("Content-Type") }
    /// Version from a weak ETag `W/"3"` or the `_history/3` suffix of Location.
    public var versionId: String? {
        if let etag {
            let trimmed = etag.replacingOccurrences(of: "W/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !trimmed.isEmpty { return trimmed }
        }
        if let location, let range = location.range(of: "/_history/") { return String(location[range.upperBound...]) }
        return nil
    }
}

public enum FHIRResult<Value: Sendable>: Sendable {
    case success(Value, FHIRResponseMetadata)
    case failure(FHIRFailure)

    public var value: Value? { if case .success(let value, _) = self { return value } else { return nil } }
    public var failure: FHIRFailure? { if case .failure(let failure) = self { return failure } else { return nil } }
    public var metadata: FHIRResponseMetadata? { if case .success(_, let metadata) = self { return metadata } else { return nil } }
    public func get() throws -> Value {
        switch self {
        case .success(let value, _): return value
        case .failure(let failure): throw failure
        }
    }
}

/// FHIR R4 REST client over an injected HTTP transport. No interaction is retried automatically;
/// redirects are never followed; responses are bounded and parsed with the safe parsers.
public struct FHIRClient: Sendable {
    public let configuration: FHIRClientConfiguration
    private let transport: any DicomWebHTTPTransport
    private let additionalHeaders: @Sendable () async throws -> [String: String]

    public init(configuration: FHIRClientConfiguration, transport: (any DicomWebHTTPTransport)? = nil,
                additionalHeaders: @escaping @Sendable () async throws -> [String: String] = { [:] }) {
        self.configuration = configuration
        self.transport = transport ?? HL7v3URLSessionTransport(maximumResponseBytes: configuration.policy.maximumResponseBytes,
                                                                trust: configuration.policy.trust, serverName: configuration.policy.serverName)
        self.additionalHeaders = additionalHeaders
    }

    public init(baseURL: URL, policy: HL7v3TransportPolicy = .init(), transport: (any DicomWebHTTPTransport)? = nil,
                additionalHeaders: @escaping @Sendable () async throws -> [String: String] = { [:] }) {
        self.init(configuration: .init(baseURL: baseURL, policy: policy), transport: transport, additionalHeaders: additionalHeaders)
    }

    // MARK: URLs

    public func url(type: String? = nil, id: String? = nil, version: String? = nil, suffix: String? = nil) -> URL {
        var url = configuration.baseURL
        if let type { url.appendPathComponent(type) }
        if let id { url.appendPathComponent(id) }
        if let version { url.appendPathComponent("_history"); url.appendPathComponent(version) }
        if let suffix { url.appendPathComponent(suffix) }
        return url
    }

    // MARK: Interactions

    public func capabilities() async throws -> FHIRResult<FHIRCapabilityStatement> {
        try await resourceResult(await send(.get, url: url(suffix: "metadata")), write: false) { $0.as(FHIRCapabilityStatement.self) }
    }

    /// `read`; a 304 for `ifNoneMatch`/`ifModifiedSince` yields `.success(nil, ...)`.
    public func read(_ type: String, id: String, ifNoneMatch: String? = nil, ifModifiedSince: String? = nil) async throws -> FHIRResult<FHIRResource?> {
        var headers: [String: String] = [:]
        if let ifNoneMatch { headers["If-None-Match"] = ifNoneMatch }
        if let ifModifiedSince { headers["If-Modified-Since"] = ifModifiedSince }
        let response = try await send(.get, url: url(type: type, id: id), headers: headers)
        if case .success(let http, let metadata) = response, http.statusCode == 304 { return .success(nil, metadata) }
        return try optionalResourceResult(response, write: false)
    }

    public func vread(_ type: String, id: String, version: String) async throws -> FHIRResult<FHIRResource> {
        try await resourceResult(await send(.get, url: url(type: type, id: id, version: version)), write: false) { $0 }
    }

    public func history(_ type: String? = nil, id: String? = nil, count: Int? = nil, since: String? = nil) async throws -> FHIRResult<FHIRBundle> {
        var url = url(type: type, id: id, suffix: "_history")
        var items: [URLQueryItem] = []
        if let count { items.append(URLQueryItem(name: "_count", value: String(count))) }
        if let since { items.append(URLQueryItem(name: "_since", value: since)) }
        if !items.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = items
            url = components.url ?? url
        }
        return try await resourceResult(await send(.get, url: url), write: false) { $0.as(FHIRBundle.self) }
    }

    /// `create`; `ifNoneExist` carries the search criteria for a conditional create (`200` when one exists).
    public func create(_ resource: FHIRResource, ifNoneExist: String? = nil) async throws -> FHIRResult<FHIRResource?> {
        var headers: [String: String] = [:]
        if let ifNoneExist { headers["If-None-Exist"] = ifNoneExist }
        return try optionalResourceResult(await send(.post, url: url(type: resource.resourceType), headers: headers, body: try encode(resource)), write: true)
    }

    /// `update` with optional optimistic locking (`If-Match`); `412` surfaces as a version conflict failure.
    public func update(_ resource: FHIRResource, ifMatch: String? = nil) async throws -> FHIRResult<FHIRResource?> {
        guard let id = resource.id else { return .failure(.init(reason: .invalidRequest, message: "update needs a resource id")) }
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        return try optionalResourceResult(await send(.put, url: url(type: resource.resourceType, id: id), headers: headers, body: try encode(resource)), write: true)
    }

    public func delete(_ type: String, id: String) async throws -> FHIRResult<FHIROperationOutcome?> {
        let response = try await send(.delete, url: url(type: type, id: id))
        switch response {
        case .failure(let failure): return .failure(failure)
        case .success(let http, let metadata):
            guard (200...299).contains(http.statusCode) else { return .failure(failure(from: http, write: true)) }
            return .success(try? parse(http)?.as(FHIROperationOutcome.self), metadata)
        }
    }

    public func search(_ query: FHIRSearchQuery) async throws -> FHIRResult<FHIRSearchPage> {
        try await search(url: query.url(baseURL: configuration.baseURL))
    }

    /// `POST [type]/_search` for queries too long for a URL.
    public func searchByPost(_ query: FHIRSearchQuery) async throws -> FHIRResult<FHIRSearchPage> {
        let target = url(type: query.resourceType, suffix: "_search")
        let response = try await send(.post, url: target, headers: ["Content-Type": "application/x-www-form-urlencoded"], body: query.formBody)
        return try resourceResult(response, write: false) { $0.as(FHIRBundle.self).map { FHIRSearchPage(bundle: $0, url: target) } }
    }

    /// Fetches one page by URL (used for `next` links); the origin must be the base or an allowed origin.
    public func search(url: URL) async throws -> FHIRResult<FHIRSearchPage> {
        guard configuration.isAllowedOrigin(url) else {
            return .failure(.init(reason: .originNotAllowed, message: "search link outside the allowed origins"))
        }
        return try resourceResult(await send(.get, url: url), write: false) { $0.as(FHIRBundle.self).map { FHIRSearchPage(bundle: $0, url: url) } }
    }

    public func nextPage(_ page: FHIRSearchPage) async throws -> FHIRResult<FHIRSearchPage>? {
        guard let next = page.nextURL else { return nil }
        return try await search(url: next)
    }

    /// Follows `next` links up to `maxPages`/`maxCollectedResources`; exceeding either is a `pageLimit` failure.
    public func collect(_ query: FHIRSearchQuery) async throws -> FHIRResult<[FHIRSearchPage]> {
        var pages: [FHIRSearchPage] = []
        var result = try await search(query)
        var resources = 0
        while true {
            guard case .success(let page, _) = result else { return .failure(result.failure!) }
            pages.append(page)
            resources += page.bundle.entries.count
            guard resources <= configuration.maxCollectedResources else {
                return .failure(.init(reason: .pageLimit, message: "collected resources exceed the configured bound"))
            }
            guard page.nextURL != nil else { return .success(pages, result.metadata!) }
            guard pages.count < configuration.maxPages else {
                return .failure(.init(reason: .pageLimit, message: "page count exceeds the configured bound"))
            }
            guard let next = try await nextPage(page) else { return .success(pages, result.metadata!) }
            result = next
        }
    }

    public func transaction(_ bundle: FHIRBundle) async throws -> FHIRResult<FHIRBundle> {
        guard bundle.type == "transaction" || bundle.type == "batch" else {
            return .failure(.init(reason: .invalidRequest, message: "bundle type must be transaction or batch"))
        }
        return try await resourceResult(await send(.post, url: configuration.baseURL, body: try encode(bundle.resource)), write: true) { $0.as(FHIRBundle.self) }
    }

    /// `$operation` at system, type or instance level; GET when no parameters are supplied.
    public func operation(_ name: String, type: String? = nil, id: String? = nil, parameters: FHIRParameters? = nil) async throws -> FHIRResult<FHIRResource> {
        let target = url(type: type, id: id, suffix: "$" + name)
        let response: FHIRResult<DicomWebHTTPResponse>
        if let parameters {
            response = try await send(.post, url: target, body: try encode(parameters.resource))
        } else {
            response = try await send(.get, url: target)
        }
        return try resourceResult(response, write: parameters != nil) { $0 }
    }

    /// Bounded raw fetch for Binary content or attachments; only allowed origins, no redirects.
    public func fetch(url: URL, accept: String = "*/*") async throws -> FHIRResult<Data> {
        guard configuration.isAllowedOrigin(url) else {
            return .failure(.init(reason: .originNotAllowed, message: "attachment outside the allowed origins"))
        }
        switch try await send(.get, url: url, headers: ["Accept": accept]) {
        case .failure(let failure): return .failure(failure)
        case .success(let http, let metadata):
            guard (200...299).contains(http.statusCode) else { return .failure(failure(from: http, write: false)) }
            return .success(http.body, metadata)
        }
    }

    // MARK: Transport

    private func encode(_ resource: FHIRResource) throws -> Data {
        switch configuration.format {
        case .json: return resource.jsonData()
        case .xml: return try resource.xmlData()
        }
    }

    func parse(_ response: DicomWebHTTPResponse) throws -> FHIRResource? {
        guard !response.body.isEmpty else { return nil }
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.contains("xml") { return try FHIRResource(xmlData: response.body, limits: configuration.limits) }
        return try FHIRResource(jsonData: response.body, limits: configuration.limits)
    }

    private func send(_ method: DicomWebHTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> FHIRResult<DicomWebHTTPResponse> {
        do { try configuration.policy.validate(url) } catch {
            return .failure(.init(reason: .invalidRequest, message: "endpoint refused by policy"))
        }
        if let body, body.count > configuration.policy.maximumRequestBytes {
            return .failure(.init(reason: .invalidRequest, message: "request exceeds the configured size"))
        }
        var httpHeaders = try await additionalHeaders()
        let credentialNames = Set(httpHeaders.keys)
        httpHeaders["Accept"] = headers["Accept"] ?? configuration.format.mimeType
        if body != nil, headers["Content-Type"] == nil { httpHeaders["Content-Type"] = configuration.format.mimeType + "; charset=utf-8" }
        if method != .get, method != .delete, let prefer = configuration.preferReturn { httpHeaders["Prefer"] = "return=" + prefer }
        for (key, value) in headers { httpHeaders[key] = value }
        var request = DicomWebHTTPRequest(method: method, url: url, headers: httpHeaders, body: body, timeout: configuration.policy.timeout)
        request.credentialHeaderNames = credentialNames
        let write = method == .post || method == .put || method == .delete
        do {
            let response = try await transport.send(request)
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                return .failure(.init(reason: .redirectNotAllowed, status: response.statusCode, message: "redirects are not followed"))
            }
            return .success(response, .init(status: response.statusCode, headers: response.headers))
        } catch let error as HL7v3TransportError {
            switch error {
            case .beforeSend, .tlsTrustRejected:
                return .failure(.init(reason: .network, uncertain: false, message: "request not sent"))
            case .responseTooLarge:
                return .failure(.init(reason: .responseTooLarge, uncertain: write, message: "response exceeds the configured size"))
            case .afterBodySent, .unknownProgress:
                return .failure(.init(reason: .network, uncertain: write, message: "transport failure after the request started"))
            default:
                return .failure(.init(reason: .invalidRequest, message: "transport configuration refused"))
            }
        } catch let error as DicomWebhookTransportError {
            switch error {
            case .beforeSend: return .failure(.init(reason: .network, message: "request not sent"))
            case .responseTooLarge: return .failure(.init(reason: .responseTooLarge, uncertain: write, message: "response exceeds the configured size"))
            case .afterBodySent, .unknownProgress: return .failure(.init(reason: .network, uncertain: write, message: "transport failure after the request started"))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(.init(reason: .network, uncertain: write, message: "transport failure with unknown progress"))
        }
    }

    private func failure(from response: DicomWebHTTPResponse, write: Bool) -> FHIRFailure {
        let outcome = (try? parse(response))??.as(FHIROperationOutcome.self)
        return .init(reason: .status, status: response.statusCode, outcome: outcome,
                     uncertain: write && (500...599).contains(response.statusCode), message: "HTTP \(response.statusCode)")
    }

    private func resourceResult<T: Sendable>(_ response: FHIRResult<DicomWebHTTPResponse>, write: Bool,
                                             _ transform: (FHIRResource) -> T?) throws -> FHIRResult<T> {
        switch response {
        case .failure(let failure): return .failure(failure)
        case .success(let http, let metadata):
            guard (200...299).contains(http.statusCode) else { return .failure(failure(from: http, write: write)) }
            guard let resource = try? parse(http), let value = transform(resource) else {
                return .failure(.init(reason: .malformedResponse, status: http.statusCode, message: "response body is not the expected resource"))
            }
            return .success(value, metadata)
        }
    }

    private func optionalResourceResult(_ response: FHIRResult<DicomWebHTTPResponse>, write: Bool) throws -> FHIRResult<FHIRResource?> {
        switch response {
        case .failure(let failure): return .failure(failure)
        case .success(let http, let metadata):
            guard (200...299).contains(http.statusCode) else { return .failure(failure(from: http, write: write)) }
            if http.body.isEmpty { return .success(nil, metadata) }
            guard let resource = try? parse(http) else {
                return .failure(.init(reason: .malformedResponse, status: http.statusCode, message: "response body is not a resource"))
            }
            if let outcome = resource.as(FHIROperationOutcome.self), write { return .success(nil, metadata).withOutcome(outcome) }
            return .success(resource, metadata)
        }
    }
}

private extension FHIRResult where Value == FHIRResource? {
    /// A `Prefer: return=OperationOutcome` body is informational, not the created resource.
    func withOutcome(_ outcome: FHIROperationOutcome) -> FHIRResult<FHIRResource?> { self }
}
