import Foundation
import DicomData
import Synchronization

public enum DicomWebHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct DicomWebHTTPRequest: Sendable {
    public var method: DicomWebHTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var bodyFileURL: URL?
    /// A body sent from its segments, by a `DicomWebStreamedBodyTransport`; other transports never receive one.
    public var streamedBody: DicomWebHTTPRequestBody? = nil
    public var originPolicy: DicomWebOriginPolicy?
    /// When set, a transport must connect to this numeric address while preserving the URL's Host and TLS identity,
    /// or reject the request. Resolving the URL's hostname again would invalidate the caller's address policy.
    public var connectAddress: String? = nil
    public var credentialHeaderNames: Set<String> = []
    /// Inactivity timeout: the longest wait for the next bytes.
    public var timeout: TimeInterval
    /// When set, the whole exchange, body included, must end by then or fail with `URLError(.timedOut)` (#2893).
    public var deadline: Date? = nil
    /// False refuses every redirect; true follows those the origin policy allows.
    public var followsRedirects = true

    public init(method: DicomWebHTTPMethod,
                url: URL,
                headers: [String: String] = [:],
                body: Data? = nil,
                timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct DicomWebHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol DicomWebHTTPTransport: Sendable {
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse
    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse
}

public final class URLSessionDicomWebHTTPTransport: DicomWebHTTPTransport {
    public static let shared = URLSessionDicomWebHTTPTransport()

    let session: URLSession
    /// A request whose origin policy adds server trust or a client certificate goes through a session of its own,
    /// made with `session`'s configuration, so that a connection opened under one choice never carries a request
    /// made under another.
    private let tlsSessions = Mutex<[DicomWebTLSChoice: URLSession]>([:])

    public init(session: URLSession = .shared) {
        self.session = session
    }

    deinit {
        tlsSessions.withLock { $0.values.forEach { $0.finishTasksAndInvalidate() } }
    }

    func session(for policy: DicomWebOriginPolicy) -> URLSession {
        let choice = DicomWebTLSChoice(serverTrust: policy.serverTrust, clientIdentity: policy.clientIdentity)
        guard choice != DicomWebTLSChoice(serverTrust: .system, clientIdentity: nil) else { return session }
        return tlsSessions.withLock { sessions in
            if let existing = sessions[choice] { return existing }
            let created = URLSession(configuration: session.configuration)
            sessions[choice] = created
            return created
        }
    }

    public func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let response = try await stream(request)
        defer { response.cancel() }
        var body = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= 128 * 1024 * 1024 - body.count else { throw DicomWebError(kind: .tooLarge) }
            body.append(chunk)
        }
        return .init(statusCode: response.statusCode, headers: response.headers, body: body)
    }
}

public struct DicomWebClientConfiguration: Equatable, Sendable {
    /// Default maximum complete in-memory STOW multipart request size (128 MiB).
    public static let defaultMaximumSTOWRequestBodyBytes = 128 * 1_024 * 1_024
    /// Default maximum size of one file sent by a file-backed STOW-RS (4 GiB).
    public static let defaultMaximumSTOWInstanceBytes = 4 * 1_024 * 1_024 * 1_024

    public var allowedOrigins: Set<URL> = []
    public var multipartLimits = DicomWebMultipartLimits()
    public var maximumMetadataBytes = 64 * 1024 * 1024
    public var originPolicy: DicomWebOriginPolicy {
        var policy = DicomWebOriginPolicy(configuredURL: baseURL,
                                          allowedOrigins: allowedOrigins.union(allowedBulkDataOrigins))
        policy.serverTrust = serverTrust
        policy.clientIdentity = clientIdentity
        return policy
    }
    /// How HTTPS servers are trusted: the system's evaluation by default, optionally with an added anchor or the
    /// server certificate's SHA-256, which only add trust and keep the host name check. It covers the base URL's
    /// origin and the allowed origins.
    public var serverTrust = DicomWebServerTrust.system
    /// The certificate presented when the base URL's origin asks for one (mutual TLS). No other origin receives it.
    public var clientIdentity: DicomWebClientIdentity? = nil
    public var baseURL: URL
    /// Headers scoped to the configured origin; foreign BulkDataURI hosts do not receive them.
    public var headers: [String: String]
    /// Inactivity timeout of every request: the longest wait for the next bytes.
    public var timeout: TimeInterval
    /// Total time allowed for one request, response body included; nil for none (#2893).
    public var totalDeadline: TimeInterval? = nil
    /// False refuses every redirect; true follows those the origin policy allows.
    public var followsRedirects = true
    /// Which failed requests are repeated, and how long to wait between attempts. The default never repeats.
    public var retryPolicy = DicomWebRetryPolicy.none
    /// Maximum complete STOW multipart body size, including MIME framing and payloads, for a body the client holds in
    /// memory or writes to a temporary file: instances given as data or data sets, and stored files sent through a
    /// transport that is not a `DicomWebStreamedBodyTransport`.
    public var maximumSTOWRequestBodyBytes: Int
    /// Maximum size of one stored file sent by `storeInstances(files:)` or `storeFiles`. Files streamed straight from
    /// disk are bounded only by this limit, not by `maximumSTOWRequestBodyBytes`.
    public var maximumSTOWInstanceBytes = Self.defaultMaximumSTOWInstanceBytes
    /// Additional BulkDataURI origins. Scheme, host and effective port must match; headers stay on the base origin.
    public var allowedBulkDataOrigins: [URL]

    public init(baseURL: URL,
                headers: [String: String] = [:],
                timeout: TimeInterval = 30,
                maximumSTOWRequestBodyBytes: Int = Self.defaultMaximumSTOWRequestBodyBytes,
                allowedBulkDataOrigins: [URL] = []) {
        self.baseURL = baseURL
        self.headers = headers
        self.timeout = timeout
        self.maximumSTOWRequestBodyBytes = maximumSTOWRequestBodyBytes
        self.allowedBulkDataOrigins = allowedBulkDataOrigins
    }

    public init(baseURL: URL,
                bearerToken: String?,
                timeout: TimeInterval = 30,
                maximumSTOWRequestBodyBytes: Int = Self.defaultMaximumSTOWRequestBodyBytes,
                allowedBulkDataOrigins: [URL] = []) {
        var headers: [String: String] = [:]
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        self.init(baseURL: baseURL,
                  headers: headers,
                  timeout: timeout,
                  maximumSTOWRequestBodyBytes: maximumSTOWRequestBodyBytes,
                  allowedBulkDataOrigins: allowedBulkDataOrigins)
    }
}

public struct DicomWebQuery: Equatable, Sendable {
    public var patientName: String?
    public var patientID: String?
    public var accessionNumber: String?
    public var studyDate: String?
    public var studyDescription: String?
    public var referringPhysicianName: String?
    public var institutionName: String?
    public var studyInstanceUID: String?
    public var modality: String?
    public var limit: Int?
    public var offset: Int?
    public var includeAllFields: Bool

    public init(patientName: String? = nil,
                patientID: String? = nil,
                accessionNumber: String? = nil,
                studyDate: String? = nil,
                studyDescription: String? = nil,
                referringPhysicianName: String? = nil,
                institutionName: String? = nil,
                studyInstanceUID: String? = nil,
                modality: String? = nil,
                limit: Int? = nil,
                offset: Int? = nil,
                includeAllFields: Bool = true) {
        self.patientName = patientName
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.studyDate = studyDate
        self.studyDescription = studyDescription
        self.referringPhysicianName = referringPhysicianName
        self.institutionName = institutionName
        self.studyInstanceUID = studyInstanceUID
        self.modality = modality
        self.limit = limit
        self.offset = offset
        self.includeAllFields = includeAllFields
    }
}

public struct DicomWebStudySummary: Equatable, Sendable, Identifiable {
    public var id: String { studyInstanceUID }
    public var dataSet: DicomDataSet
    public var patientName: String
    public var patientID: String
    public var studyDate: String
    public var studyDescription: String
    public var studyInstanceUID: String

    public init(dataSet: DicomDataSet) {
        self.dataSet = dataSet
        self.patientName = dataSet.string(for: .patientName) ?? "Unknown"
        self.patientID = dataSet.string(for: .patientID) ?? ""
        self.studyDate = dataSet.string(for: .studyDate) ?? ""
        self.studyDescription = dataSet.string(for: .studyDescription) ?? ""
        self.studyInstanceUID = dataSet.string(for: .studyInstanceUID) ?? ""
    }
}

public struct DicomWebMultipartPart: Equatable, Sendable {
    public var isRoot: Bool = false
    public var headers: [String: String]
    public var body: Data

    public var contentType: String? {
        headers.dicomWebHeaderValue("Content-Type")
    }

    public init(headers: [String: String] = [:], body: Data) {
        self.headers = headers
        self.body = body
    }
}

public struct DicomWebRetrievedObject: Equatable, Sendable {
    public var statusCode: Int
    public var contentType: String?
    public var parts: [DicomWebMultipartPart]

    public var firstPayload: Data? {
        (parts.first(where: \.isRoot) ?? parts.first)?.body
    }

    public init(statusCode: Int, contentType: String?, parts: [DicomWebMultipartPart]) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.parts = parts
    }
}

public struct DicomWebStoreInstance: Equatable, Sendable {
    public var data: Data
    public var contentType: String
    public var transferSyntax: String?

    /// Creates one STOW-RS multipart item. A `nil` transfer syntax is derived from
    /// Part 10 File Meta Information, or omitted when `data` is not a Part 10 file.
    public init(data: Data,
                contentType: String = "application/dicom",
                transferSyntax: String? = DicomTransferSyntax.explicitVRLittleEndian.rawValue) {
        self.data = data
        self.contentType = contentType
        self.transferSyntax = transferSyntax
    }
}

public struct DicomWebStoreResult: Equatable, Sendable {
    public var statusCode: Int
    public var responseData: Data
    public var responseParts: [DicomWebMultipartPart]
    public var storeResponse: DicomWebStoreResponse?
    /// The response's `Warning` header.
    public var warning: String? = nil
    public var acceptedInstanceCount: Int { storeResponse?.acceptedInstanceCount ?? 0 }
    @available(*, deprecated, renamed: "acceptedInstanceCount")
    public var storedInstanceCount: Int {
        get { acceptedInstanceCount }
        set { /* A submitted count cannot establish storage outcomes. */ }
    }

    public init(statusCode: Int, responseData: Data, responseParts: [DicomWebMultipartPart] = [],
                storeResponse: DicomWebStoreResponse) {
        self.statusCode = statusCode
        self.responseData = responseData
        self.responseParts = responseParts
        self.storeResponse = storeResponse
    }

    @available(*, deprecated, message: "Use the initializer with decoded storeResponse; submitted counts cannot confirm storage.")
    public init(statusCode: Int,
                responseData: Data,
                responseParts: [DicomWebMultipartPart] = [],
                storedInstanceCount: Int) {
        self.statusCode = statusCode
        self.responseData = responseData
        self.responseParts = responseParts
        self.storeResponse = nil
    }
}

public enum DicomWebClientError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case unsupportedConnectAddress
    case invalidBaseURL(URL)
    /// The supplied DICOMweb `BulkDataURI` could not be resolved against the client base URL.
    case invalidBulkDataURI(String)
    case httpStatus(statusCode: Int, method: String, url: String, bodyPreview: String)
    case invalidJSONResponse
    case malformedDICOMJSONElement(String)
    case unsupportedDICOMJSONValue(tag: String, vr: String)
    case missingMultipartBoundary(contentType: String?)
    case malformedMultipartBody
    case emptyStoreRequest
    case invalidStoreContentType(instanceIndex: Int)
    case invalidStoreTransferSyntaxUID(instanceIndex: Int)
    case invalidStorePart10FileMeta(instanceIndex: Int)
    case storeTransferSyntaxMismatch(instanceIndex: Int)
    case storeRequestBodyTooLarge(byteCount: Int, limit: Int)
    case multipartBodyTooLarge
}

extension DicomWebClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedConnectAddress:
            return "DICOMweb transport does not support a separate connection address."
        case .invalidHTTPResponse:
            return "DICOMweb response was not an HTTP response."
        case .invalidBaseURL:
            return "Invalid DICOMweb base URL."
        case .invalidBulkDataURI:
            return "DICOMweb BulkDataURI is invalid or disallowed by the origin policy."
        case .httpStatus(let statusCode, let method, let url, let bodyPreview):
            let suffix = bodyPreview.isEmpty ? "" : " Body: \(bodyPreview)"
            return "DICOMweb \(method) \(url) failed with HTTP \(statusCode).\(suffix)"
        case .invalidJSONResponse:
            return "DICOMweb response did not contain valid DICOM JSON."
        case .malformedDICOMJSONElement(let tag):
            return "DICOMweb JSON element \(tag) is malformed."
        case .unsupportedDICOMJSONValue(let tag, let vr):
            return "DICOMweb JSON element \(tag) with VR \(vr) is not supported."
        case .missingMultipartBoundary(let contentType):
            return "DICOMweb multipart response is missing a boundary in Content-Type \(contentType ?? "<none>")."
        case .malformedMultipartBody:
            return "DICOMweb multipart response is malformed."
        case .emptyStoreRequest:
            return "DICOMweb STOW request must include at least one DICOM instance."
        case .invalidStoreContentType(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has an invalid Content-Type."
        case .invalidStoreTransferSyntaxUID(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has an invalid transfer syntax UID."
        case .invalidStorePart10FileMeta(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has invalid Part 10 File Meta Information."
        case .storeTransferSyntaxMismatch(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) declares a transfer syntax that does not " +
                "match its Part 10 File Meta Information."
        case .storeRequestBodyTooLarge(let byteCount, let limit):
            return "DICOMweb STOW multipart body requires \(byteCount) bytes, exceeding the \(limit)-byte limit."
        case .multipartBodyTooLarge:
            return "DICOMweb STOW multipart body exceeds the addressable in-memory size."
        }
    }
}

public struct DicomWebClient: Sendable {
    public var configuration: DicomWebClientConfiguration
    /// Credential headers asked for before each request to the configured origin, added to `configuration.headers`
    /// and taking precedence over them; renewed once after a 401. Nil sends only `configuration.headers`.
    public var authorizationProvider: (any DicomWebAuthorizationProvider)?
    private let transport: any DicomWebHTTPTransport

    public init(configuration: DicomWebClientConfiguration,
                transport: any DicomWebHTTPTransport = URLSessionDicomWebHTTPTransport.shared) {
        self.configuration = configuration
        self.transport = transport
    }

    /// A client whose requests carry the headers `authorizationProvider` gives for each of them.
    public init(configuration: DicomWebClientConfiguration,
                transport: any DicomWebHTTPTransport = URLSessionDicomWebHTTPTransport.shared,
                authorizationProvider: any DicomWebAuthorizationProvider) {
        self.init(configuration: configuration, transport: transport)
        self.authorizationProvider = authorizationProvider
    }

    public func retrieveCapabilities() async throws -> DicomWebCapabilities {
        let response = try await boundedResponse(url: configuration.baseURL, accept: "application/json")
        return try JSONDecoder().decode(DicomWebCapabilities.self, from: response.body)
    }

    @discardableResult
    public func retrieveStudy(studyInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveSeries(studyInstanceUID: String, seriesInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveInstance(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveFrames(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String, frames: DicomWebFrameList,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID, "frames", frames.pathComponent]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveBulkData(uri: String, relativeTo requestBase: URL? = nil,
                                 accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieveBulkData(uri: uri, relativeTo: requestBase, sink: sink, accept: accept.headerValue)
    }

    /// Retrieves a study asking for `accept`'s ranges in order, and again without the first ones after a fallback
    /// status (`DicomWebAcceptList`).
    @discardableResult
    public func retrieveStudy(studyInstanceUID: String,
                              accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID]), accept: accept, sink: sink)
    }

    /// Retrieves a series with `accept`'s ranges in order (`DicomWebAcceptList`).
    @discardableResult
    public func retrieveSeries(studyInstanceUID: String, seriesInstanceUID: String,
                               accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID]), accept: accept, sink: sink)
    }

    /// Retrieves an instance with `accept`'s ranges in order (`DicomWebAcceptList`).
    @discardableResult
    public func retrieveInstance(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                                 accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID]),
                           accept: accept, sink: sink)
    }

    /// Retrieves frames with `accept`'s ranges in order (`DicomWebAcceptList`).
    @discardableResult
    public func retrieveFrames(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String, frames: DicomWebFrameList,
                               accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID,
                                           "frames", frames.pathComponent]), accept: accept, sink: sink)
    }

    /// Retrieves bulk data with `accept`'s ranges in order (`DicomWebAcceptList`).
    @discardableResult
    public func retrieveBulkData(uri: String, relativeTo requestBase: URL? = nil,
                                 accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        let url = try configuration.originPolicy.resolve(uri, relativeTo: requestBase ?? relativeBulkDataBaseURL())
        return try await retrieve(url: url, accept: accept, sink: sink)
    }

    /// Streams a metadata representation or preview at its study/series/instance scope.
    @discardableResult
    public func retrieveRepresentation(studyInstanceUID: String, seriesInstanceUID: String? = nil,
                                       sopInstanceUID: String? = nil, resource: DicomWebMediaTypeNegotiator.ResourceKind,
                                       accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        guard [.metadata, .rendered, .thumbnail].contains(resource),
              sopInstanceUID == nil || seriesInstanceUID != nil,
              resource != .rendered || sopInstanceUID != nil else { throw DicomWebError(kind: .badRequest) }
        var path = ["studies", studyInstanceUID]
        if let seriesInstanceUID { path += ["series", seriesInstanceUID] }
        if let sopInstanceUID { path += ["instances", sopInstanceUID] }
        let suffix = resource == .metadata ? "metadata" : resource == .rendered ? "rendered" : "thumbnail"
        return try await retrieve(url: endpoint(path + [suffix]), accept: accept.headerValue, sink: sink)
    }

    /// Returns the bounded wire document, status and headers without dataset normalization.
    /// Hosts that need the original JSON shape can decode these bytes with their own representation policy.
    public func searchResponse(parameters: DicomWebSearchParameters) async throws -> DicomWebHTTPResponse {
        try await boundedResponse(url: parameters.url(relativeTo: configuration.baseURL),
                                  accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata))
    }

    public func search(parameters: DicomWebSearchParameters) async throws -> DicomWebSearchPage {
        let response = try await searchResponse(parameters: parameters)
        let sets = try Self.searchDataSets(from: response)
        return .init(dataSets: sets, statusCode: response.statusCode,
                     contentType: response.headers.dicomWebHeaderValue("Content-Type"),
                     warning: response.headers.dicomWebHeaderValue("Warning"),
                     offset: parameters.offset ?? 0, limit: parameters.limit)
    }

    /// QIDO accepts DICOM JSON and the application/json compatibility media type. A 204 needs no body or MIME.
    private static func searchDataSets(from response: DicomWebHTTPResponse) throws -> [DicomDataSet] {
        if response.statusCode == 204 { return [] }
        guard let contentType = response.headers.dicomWebHeaderValue("Content-Type"),
              let mediaType = try? DicomWebMediaType(contentType),
              ["application/dicom+json", "application/json"].contains(mediaType.type) else {
            throw DicomWebError(kind: .invalidResponse)
        }
        return try DicomWebJSONParser.dataSets(from: response.body)
    }

    public func searchPages(parameters: DicomWebSearchParameters, continuesOnFullPage: Bool = false) -> DicomWebSearchPager {
        .init(client: self, parameters: parameters, continuesOnFullPage: continuesOnFullPage)
    }

    public func searchPages(parameters: DicomWebSearchParameters, continuesOnFullPage: Bool = false,
                            limits: DicomWebSearchPagingLimits) -> DicomWebSearchPager {
        .init(client: self, parameters: parameters, continuesOnFullPage: continuesOnFullPage, limits: limits)
    }

    public func searchSeries(studyInstanceUID: String? = nil,
                             matches: [DicomWebSearchParameters.Match] = [], limit: Int? = nil,
                             offset: Int? = nil) async throws -> DicomWebSearchPage {
        try await search(parameters: .init(level: .series, studyInstanceUID: studyInstanceUID,
                                           matches: matches, limit: limit, offset: offset))
    }

    public func searchInstances(studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                                matches: [DicomWebSearchParameters.Match] = [], limit: Int? = nil,
                                offset: Int? = nil) async throws -> DicomWebSearchPage {
        try await search(parameters: .init(level: .instance, studyInstanceUID: studyInstanceUID,
                                           seriesInstanceUID: seriesInstanceUID, matches: matches, limit: limit, offset: offset))
    }

    public func retrieveSeriesMetadata(studyInstanceUID: String, seriesInstanceUID: String) async throws -> [DicomDataSetRepresentation.Decoded] {
        try await metadata(path: ["studies", studyInstanceUID, "series", seriesInstanceUID, "metadata"])
    }

    public func retrieveInstanceMetadata(studyInstanceUID: String, seriesInstanceUID: String,
                                         sopInstanceUID: String) async throws -> [DicomDataSetRepresentation.Decoded] {
        try await metadata(path: ["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID, "metadata"])
    }

    private func metadata(path: [String]) async throws -> [DicomDataSetRepresentation.Decoded] {
        let url = endpoint(path)
        let response = try await boundedResponse(url: url, accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata))
        return try Self.decodedMetadata(response.body, from: url)
    }

    /// Metadata whose relative `BulkDataURI` values resolve against `url`, the request that returned them.
    private static func decodedMetadata(_ body: Data, from url: URL) throws -> [DicomDataSetRepresentation.Decoded] {
        try DicomWebJSONParser.decoded(from: body).map { decoded in
            var decoded = decoded
            decoded.sourceURL = url
            return decoded
        }
    }

    @discardableResult
    public func retrieveStudy(studyInstanceUID: String, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID]),
                           accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .instance), sink: sink)
    }

    @discardableResult
    public func retrieveSeries(studyInstanceUID: String, seriesInstanceUID: String,
                               sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID]),
                           accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .instance), sink: sink)
    }

    @discardableResult
    public func retrieveInstance(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                                 sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID]),
                           accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .instance), sink: sink)
    }

    @discardableResult
    public func retrieveFrames(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                               frames: DicomWebFrameList, sink: any DicomWebRetrieveSink,
                               accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .frames)) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID,
                                           "frames", frames.pathComponent]), accept: accept, sink: sink)
    }

    @discardableResult
    public func retrieveBulkData(uri: String, relativeTo requestBase: URL? = nil,
                                 sink: any DicomWebRetrieveSink,
                                 accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .bulkdata)) async throws -> Int {
        let url = try configuration.originPolicy.resolve(uri, relativeTo: requestBase ?? relativeBulkDataBaseURL())
        return try await retrieve(url: url, accept: accept, sink: sink)
    }

    public func retrieveThumbnail(studyInstanceUID: String, seriesInstanceUID: String? = nil,
                                   sopInstanceUID: String? = nil) async throws -> DicomWebRetrievedObject {
        guard sopInstanceUID == nil || seriesInstanceUID != nil else { throw DicomWebError(kind: .badRequest) }
        var path = ["studies", studyInstanceUID]
        if let seriesInstanceUID { path += ["series", seriesInstanceUID] }
        if let sopInstanceUID { path += ["instances", sopInstanceUID] }
        return try await retrieveBuffered(url: endpoint(path + ["thumbnail"]),
                                          accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .thumbnail))
    }

    public func retrieveRenderedInstance(studyInstanceUID: String, seriesInstanceUID: String,
                                         sopInstanceUID: String) async throws -> DicomWebRetrievedObject {
        try await retrieveBuffered(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID,
                                                  "instances", sopInstanceUID, "rendered"]),
                                    accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .rendered))
    }

    /// Retrieves the rendered study, series, instance or frame list with `options` (PS3.18 10.4.1.1). The answer is
    /// one image, or a multipart with one image per part.
    public func retrieveRendered(studyInstanceUID: String, seriesInstanceUID: String? = nil, sopInstanceUID: String? = nil,
                                 frames: DicomWebFrameList? = nil,
                                 options: DicomWebRenderedOptions) async throws -> DicomWebRetrievedObject {
        try await retrieveImage("rendered", studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                                sopInstanceUID: sopInstanceUID, frames: frames, options: options)
    }

    /// Retrieves the thumbnail of a study, series, instance or frame list with `options` (PS3.18 10.4.1.2).
    public func retrieveThumbnail(studyInstanceUID: String, seriesInstanceUID: String? = nil, sopInstanceUID: String? = nil,
                                  frames: DicomWebFrameList? = nil,
                                  options: DicomWebRenderedOptions) async throws -> DicomWebRetrievedObject {
        try await retrieveImage("thumbnail", studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                                sopInstanceUID: sopInstanceUID, frames: frames, options: options)
    }

    private func retrieveImage(_ suffix: String, studyInstanceUID: String, seriesInstanceUID: String?,
                               sopInstanceUID: String?, frames: DicomWebFrameList?,
                               options: DicomWebRenderedOptions) async throws -> DicomWebRetrievedObject {
        guard options.isValid, sopInstanceUID == nil || seriesInstanceUID != nil,
              frames == nil || sopInstanceUID != nil else { throw DicomWebError(kind: .badRequest) }
        var path = ["studies", studyInstanceUID]
        if let seriesInstanceUID { path += ["series", seriesInstanceUID] }
        if let sopInstanceUID { path += ["instances", sopInstanceUID] }
        if let frames { path += ["frames", frames.pathComponent] }
        return try await retrieveBuffered(url: queryURL(path: path + [suffix], query: options.queryItems),
                                          accept: options.accept)
    }

    private func retrieveBuffered(url: URL, accept: String, range: ClosedRange<Int>? = nil) async throws -> DicomWebRetrievedObject {
        var headers = ["Accept": accept]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        // The whole answer is held here before the caller sees it, so a body that fails can be fetched again.
        return try await withRetries(.idempotent) {
            let sink = DicomWebMemoryRetrieveSink(maximumBytes: configuration.multipartLimits.maximumPartBytes)
            let response = try await streamRequest(.get, url: url, headers: headers)
            if let range, response.statusCode == 206,
               let contentRange = response.headers.dicomWebHeaderValue("Content-Range"),
               !Self.contentRange(contentRange, isWithin: range) {
                response.cancel()
                throw DicomWebError(kind: .invalidResponse)
            }
            try await consume(response, sink: sink)
            return .init(statusCode: response.statusCode, contentType: response.headers.dicomWebHeaderValue("Content-Type"),
                         parts: await sink.result())
        }
    }

    /// Whether a `Content-Range: bytes first-last/length` value starts at `range` and ends within it.
    private static func contentRange(_ value: String, isWithin range: ClosedRange<Int>) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes "),
              let span = trimmed.dropFirst(6).split(separator: "/").first?.split(separator: "-"), span.count == 2,
              let first = Int(span[0].trimmingCharacters(in: .whitespaces)),
              let last = Int(span[1].trimmingCharacters(in: .whitespaces)) else { return false }
        return first == range.lowerBound && first <= last && last <= range.upperBound
    }

    private func retrieve(url: URL, accept: String, sink: any DicomWebRetrieveSink) async throws -> Int {
        // Only the request is repeated: once the body reaches the caller's sink it is not fetched again.
        let response = try await withRetries(.idempotent) {
            try await streamRequest(.get, url: url, headers: ["Accept": accept])
        }
        try await consume(response, sink: sink)
        return response.statusCode
    }

    private func retrieve(url: URL, accept: DicomWebAcceptList, sink: any DicomWebRetrieveSink) async throws -> Int {
        let response = try await streamRequest(url: url, accept: accept)
        try await consume(response, sink: sink)
        return response.statusCode
    }

    /// The response to the first Accept of `accept` the server does not refuse with a fallback status. Only refused
    /// requests move to the next Accept: nothing has reached the sink yet.
    private func streamRequest(url: URL, accept: DicomWebAcceptList) async throws -> DicomWebHTTPStreamedResponse {
        var attempted: [String] = []
        while true {
            let header = accept.headerValue(droppingFirst: attempted.count)
            attempted.append(header)
            do {
                return try await withRetries(.idempotent) {
                    try await streamRequest(.get, url: url, headers: ["Accept": header])
                }
            } catch let error as DicomWebError where accept.fallbackStatuses.contains(error.statusCode) {
                guard attempted.count < accept.ranges.count else {
                    var error = error
                    error.attemptedAccepts = attempted
                    throw error
                }
            }
        }
    }

    private func consume(_ response: DicomWebHTTPStreamedResponse, sink: any DicomWebRetrieveSink) async throws {
        defer { response.cancel() }
        do {
            let contentType = response.headers.dicomWebHeaderValue("Content-Type") ?? "application/octet-stream"
            if contentType.lowercased().hasPrefix("multipart/") {
                var parser = try DicomWebMultipartStreamParser(contentType: contentType, limits: configuration.multipartLimits)
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    // Bound event batches even when an injected transport yields a large Data value.
                    for offset in stride(from: 0, to: chunk.count, by: 16 * 1024) {
                        let start = chunk.index(chunk.startIndex, offsetBy: offset)
                        let end = chunk.index(start, offsetBy: min(16 * 1024, chunk.count - offset))
                        for event in try Self.drainingAutoreleasedObjects({ try parser.feed(Data(chunk[start..<end])) }) {
                            try await sink.receive(event)
                        }
                    }
                }
                for event in try parser.finish() { try await sink.receive(event) }
            } else {
                try await sink.receive(.partHeaders(response.headers, isRoot: true))
                var total = 0
                let limit = min(configuration.multipartLimits.maximumPartBytes, configuration.multipartLimits.maximumTotalBytes)
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    guard chunk.count <= limit - total else { throw DicomWebError(kind: .tooLarge) }
                    total += chunk.count
                    try await sink.receive(.payload(chunk))
                }
                try await sink.receive(.partEnd)
            }
        } catch {
            if let file = sink as? DicomWebFileRetrieveSink { await file.discardIncompletePart() }
            throw error
        }
    }

    /// Runs one read step in its own autorelease pool where Foundation bridges to Objective-C, so a thread whose
    /// pool is never drained does not keep every read alive until the operation ends (#2890).
    private static func drainingAutoreleasedObjects<T>(_ body: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
        #else
        try body()
        #endif
    }

    private func streamRequest(_ method: DicomWebHTTPMethod, url: URL, headers: [String: String],
                               body: Data? = nil, bodyFileURL: URL? = nil, streamedBody: DicomWebHTTPRequestBody? = nil,
                               accepts: (DicomWebHTTPStreamedResponse) -> Bool = { _ in false })
        async throws -> DicomWebHTTPStreamedResponse {
        try Task.checkCancellation()
        try configuration.originPolicy.validate(url)
        let forwardsCredentials = configuration.originPolicy.forwardsCredentials(to: url)
        let provider = forwardsCredentials ? authorizationProvider : nil
        var provided = try await provider?.authorizationHeaders() ?? [:]
        func sendOnce(_ provided: [String: String]) async throws -> DicomWebHTTPStreamedResponse {
            var allHeaders = forwardsCredentials ? credentials(adding: provided) : [:]
            for (name, value) in headers { allHeaders[name] = value }
            var request = DicomWebHTTPRequest(method: method, url: url, headers: allHeaders, body: body,
                                              timeout: configuration.timeout)
            request.deadline = configuration.totalDeadline.map { Date().addingTimeInterval($0) }
            request.followsRedirects = configuration.followsRedirects
            request.originPolicy = configuration.originPolicy
            request.credentialHeaderNames = Set(credentials(adding: provided).keys.map { $0.lowercased() })
            request.bodyFileURL = bodyFileURL
            request.streamedBody = streamedBody
            return try await transport.stream(request)
        }
        var response = try await sendOnce(provided)
        // A 401 may mean the provider's token was revoked or rotated before it expired: renew once and repeat once.
        if response.statusCode == 401, let provider {
            let renewed: Bool
            do {
                renewed = try await provider.renewAuthorization(afterRejecting: provided)
            } catch {
                response.cancel()
                throw error
            }
            if renewed {
                response.cancel()
                provided = try await provider.authorizationHeaders()
                response = try await sendOnce(provided)
            }
        }
        guard (200..<300).contains(response.statusCode) || accepts(response) else {
            defer { response.cancel() }
            throw DicomWebError(statusCode: response.statusCode, headers: response.headers,
                                body: await Self.bodyPreview(of: response), credentials: credentials(adding: provided))
        }
        return response
    }

    /// `configuration.headers` with the provider's headers in place of any of the same name.
    private func credentials(adding provided: [String: String]) -> [String: String] {
        let replaced = Set(provided.keys.map { $0.lowercased() })
        var result = configuration.headers.filter { !replaced.contains($0.key.lowercased()) }
        for (name, value) in provided { result[name] = value }
        return result
    }

    /// The start of a refused response's body, for its error. A body that fails to arrive leaves what was read.
    private static func bodyPreview(of response: DicomWebHTTPStreamedResponse) async -> Data {
        var body = Data()
        do {
            for try await chunk in response.body {
                body.append(chunk.prefix(DicomWebError.bodyPreviewReadBytes - body.count))
                if body.count >= DicomWebError.bodyPreviewReadBytes { break }
            }
        } catch {}
        return body
    }

    /// Runs `attempt` until it succeeds or `configuration.retryPolicy` ends it, waiting between attempts.
    /// The wait is a task sleep, so cancellation ends it at once with `CancellationError`.
    private func withRetries<T>(_ request: DicomWebRetryPolicy.Request?,
                                _ attempt: () async throws -> T) async throws -> T {
        var attempts = 1
        while true {
            do {
                return try await attempt()
            } catch {
                guard let request,
                      let delay = configuration.retryPolicy.delay(after: error, attempt: attempts, for: request) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempts += 1
            }
        }
    }

    private func boundedResponse(url: URL, accept: String) async throws -> DicomWebHTTPResponse {
        try await withRetries(.idempotent) {
            let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
            return try await collect(response, maximumBytes: configuration.maximumMetadataBytes)
        }
    }

    private func collect(_ response: DicomWebHTTPStreamedResponse, maximumBytes: Int) async throws -> DicomWebHTTPResponse {
        defer { response.cancel() }
        var body = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - body.count else { throw DicomWebError(kind: .tooLarge) }
            body.append(chunk)
        }
        return .init(statusCode: response.statusCode, headers: response.headers, body: body)
    }

    public func searchStudies(_ query: DicomWebQuery = DicomWebQuery()) async throws -> [DicomWebStudySummary] {
        let response = try await send(
            .get,
            url: queryURL(path: ["studies"], query: studyQueryItems(query)),
            headers: ["Accept": DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata)]
        )
        let dataSets = try Self.searchDataSets(from: response)
        return dataSets.map(DicomWebStudySummary.init).filter { !$0.studyInstanceUID.isEmpty }
    }

    /// Study metadata as decoded representations: elements carried by `BulkDataURI` stay empty and are listed
    /// in `bulkData` until the caller resolves them explicitly (`resolveBulkData(in:)`).
    public func retrieveStudyMetadata(studyInstanceUID: String) async throws -> [DicomDataSetRepresentation.Decoded] {
        let url = endpoint(["studies", studyInstanceUID, "metadata"])
        let response = try await send(
            .get,
            url: url,
            headers: ["Accept": DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata)]
        )
        return try Self.decodedMetadata(response.body, from: url)
    }

    /// Fetches every bulk-data reference of a decoded representation through this client's transport, origin
    /// policy and limits, and stores the value fields in the returned data set. Relative references resolve against
    /// `requestBase`, else the representation's `sourceURL`, else the base URL. A reference answered in several parts
    /// fails instead of keeping only one.
    public func resolveBulkData(in decoded: DicomDataSetRepresentation.Decoded,
                                limits: DicomDataSetRepresentation.BulkDataLimits = .init(),
                                relativeTo requestBase: URL? = nil) async throws -> DicomDataSetRepresentation.Decoded {
        var boundedClient = self
        boundedClient.configuration.multipartLimits.maximumPartBytes = min(configuration.multipartLimits.maximumPartBytes,
                                                                           limits.maximumBytesPerReference)
        try Task.checkCancellation()
        return try await DicomDataSetRepresentation.resolvingBulkData(decoded,
            using: DicomWebBulkDataResolver(client: boundedClient, requestBase: requestBase ?? decoded.sourceURL),
            limits: limits)
    }

    public func retrieveInstance(studyInstanceUID: String,
                                 seriesInstanceUID: String,
                                 sopInstanceUID: String) async throws -> DicomWebRetrievedObject {
        return try await retrieveBuffered(
            url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID]),
            accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .instance)
        )
    }

    /// Retrieves one rendered WADO-RS frame through the configured HTTP transport.
    public func retrieveRenderedFrame(studyInstanceUID: String,
                                      seriesInstanceUID: String,
                                      sopInstanceUID: String,
                                      frameNumber: Int = 1,
                                      accept: String = DicomWebMediaTypeNegotiator.renderedFrameAcceptHeader(representationCount: 1)) async throws -> DicomWebRetrievedObject {
        try await retrieveRenderedFrames(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID,
            frames: DicomWebFrameList([frameNumber]),
            accept: accept
        )
    }

    /// Retrieves an ordered rendered WADO-RS frame list through the configured HTTP transport.
    public func retrieveRenderedFrames(studyInstanceUID: String,
                                       seriesInstanceUID: String,
                                       sopInstanceUID: String,
                                       frames: DicomWebFrameList,
                                       accept: String? = nil) async throws -> DicomWebRetrievedObject {
        let resolvedAccept = accept ?? DicomWebMediaTypeNegotiator.renderedFrameAcceptHeader(representationCount: frames.numbers.count)
        return try await retrieveBuffered(
            url: endpoint([
                "studies", studyInstanceUID,
                "series", seriesInstanceUID,
                "instances", sopInstanceUID,
                "frames", frames.pathComponent,
                "rendered"
            ]),
            accept: resolvedAccept
        )
    }

    /// Retrieves a single WADO-RS frame through the configured HTTP transport.
    public func retrieveFrame(studyInstanceUID: String,
                              seriesInstanceUID: String,
                              sopInstanceUID: String,
                              frameNumber: Int = 1,
                              accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .frames)) async throws -> DicomWebRetrievedObject {
        try await retrieveFrames(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID,
            frames: DicomWebFrameList([frameNumber]),
            accept: accept
        )
    }

    /// Retrieves a strictly increasing WADO-RS frame list through the configured HTTP transport.
    public func retrieveFrames(studyInstanceUID: String,
                               seriesInstanceUID: String,
                               sopInstanceUID: String,
                               frames: DicomWebFrameList,
                               accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .frames)) async throws -> DicomWebRetrievedObject {
        return try await retrieveBuffered(
            url: endpoint([
                "studies", studyInstanceUID,
                "series", seriesInstanceUID,
                "instances", sopInstanceUID,
                "frames", frames.pathComponent
            ]),
            accept: accept
        )
    }

    /// Retrieves a DICOM JSON `BulkDataURI` through the configured HTTP transport.
    public func retrieveBulkData(uri: String,
                                 accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .bulkdata)) async throws -> DicomWebRetrievedObject {
        return try await retrieveBuffered(
            url: try bulkDataURL(uri),
            accept: accept
        )
    }

    /// Retrieves the bytes `range` of a `BulkDataURI` with an HTTP `Range` request. A `206` brings that range; a
    /// server that ignores `Range` answers `200` with the whole value, which is returned whole. `statusCode` tells
    /// the two apart. A `206` whose `Content-Range` starts elsewhere or ends past `range` is refused.
    public func retrieveBulkData(uri: String, relativeTo requestBase: URL? = nil, range: ClosedRange<Int>,
                                 accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .bulkdata)) async throws -> DicomWebRetrievedObject {
        guard range.lowerBound >= 0 else { throw DicomWebError(kind: .badRequest) }
        return try await retrieveBuffered(url: try bulkDataURL(uri, relativeTo: requestBase), accept: accept, range: range)
    }

    public func retrieveWADOURIObject(studyInstanceUID: String,
                                      seriesInstanceUID: String,
                                      sopInstanceUID: String,
                                      contentType: String = "application/dicom") async throws -> DicomWebRetrievedObject {
        return try await retrieveBuffered(
            url: queryURL(path: ["wado"], query: [
                URLQueryItem(name: "requestType", value: "WADO"),
                URLQueryItem(name: "studyUID", value: studyInstanceUID),
                URLQueryItem(name: "seriesUID", value: seriesInstanceUID),
                URLQueryItem(name: "objectUID", value: sopInstanceUID),
                URLQueryItem(name: "contentType", value: contentType)
            ]),
            accept: contentType
        )
    }

    public func store(dataSet: DicomDataSet,
                      studyInstanceUID: String? = nil,
                      transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) async throws -> DicomWebStoreResult {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: transferSyntax)
        )
        let instance = DicomWebStoreInstance(data: data,
                                             transferSyntax: transferSyntax.rawValue)
        return try await storeInstances([instance],
                                        studyInstanceUID: studyInstanceUID ?? dataSet.string(for: .studyInstanceUID))
    }

    public func storeInstances(_ instances: [DicomWebStoreInstance],
                               studyInstanceUID: String? = nil) async throws -> DicomWebStoreResult {
        guard !instances.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        _ = try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
            instances: instances, boundary: boundary, maximumBytes: configuration.maximumSTOWRequestBodyBytes)
        let prepared = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: instances)
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID,
                                        maximumBytes: configuration.maximumSTOWRequestBodyBytes) { writer, body in
            for instance in prepared {
                let type = instance.contentType + (instance.transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: instance.data.count) { body.append($0) }
                try writer.payload(byteCount: instance.data.count)
                body.append(.data(instance.data))
                try writer.endPart { body.append($0) }
            }
        }
    }

    public func storeInstances(dataSets: [DicomDataSet], studyInstanceUID: String? = nil,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) async throws -> DicomWebStoreResult {
        guard !dataSets.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID,
                                        maximumBytes: configuration.maximumSTOWRequestBodyBytes) { writer, body in
            for dataSet in dataSets {
                try Task.checkCancellation()
                let payload = try DicomDataSetWriter.part10Data(from: dataSet,
                    options: DicomPart10WriterOptions(transferSyntax: transferSyntax))
                try writer.beginPart(headers: [("Content-Type", "application/dicom; transfer-syntax=\(transferSyntax.rawValue)")],
                                     contentLength: payload.count) { body.append($0) }
                try writer.payload(byteCount: payload.count)
                body.append(.data(payload))
                try writer.endPart { body.append($0) }
            }
        }
    }

    /// Sends `files` in one STOW-RS request. Through a `DicomWebStreamedBodyTransport` the body is read straight from
    /// the files, each at most `maximumSTOWInstanceBytes`; any other transport receives it staged in a temporary
    /// file, within `maximumSTOWRequestBodyBytes`.
    public func storeInstances(files: [URL], studyInstanceUID: String? = nil) async throws -> DicomWebStoreResult {
        guard !files.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        let streams = transport is any DicomWebStreamedBodyTransport
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID,
                                        maximumBytes: streams ? .max : configuration.maximumSTOWRequestBodyBytes) { writer, body in
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard let length = Int(exactly: size), length <= maximumStoreFileBytes else {
                    throw DicomWebClientError.storeRequestBodyTooLarge(byteCount: Int(clamping: size),
                                                                     limit: maximumStoreFileBytes)
                }
                let prefix = try Self.fileMetaPrefix(of: handle, length: length, instanceIndex: index)
                let prepared = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: [.init(data: prefix, transferSyntax: nil)])
                let type = "application/dicom" + (prepared[0].transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: length) { body.append($0) }
                try writer.payload(byteCount: length)
                body.append(.file(file, length: length))
                try writer.endPart { body.append($0) }
            }
        }
    }

    /// The largest stored file a file-backed STOW-RS sends: `maximumSTOWInstanceBytes`, and also
    /// `maximumSTOWRequestBodyBytes` when the transport needs the body staged in a temporary file.
    var maximumStoreFileBytes: Int {
        transport is any DicomWebStreamedBodyTransport ? configuration.maximumSTOWInstanceBytes
            : min(configuration.maximumSTOWInstanceBytes, configuration.maximumSTOWRequestBodyBytes)
    }

    /// Maximum bytes following the File Meta Information Group Length element, independent of the file/body size.
    static let maximumStoreFileMetaGroupLength = 64 * 1024

    /// Reads validated File Meta Information, plus up to eight bytes of the following dataset header.
    /// Rejects an excessive Group Length after reading only the fixed 144-byte Part 10 prefix.
    static func fileMetaPrefix(of handle: FileHandle, length: Int, instanceIndex index: Int) throws -> Data {
        try handle.seek(toOffset: 0)
        var prefix = try handle.read(upToCount: min(length, 144)) ?? Data()
        guard prefix.count == 144, DicomPart10FileMetaParser.hasPart10Prefix(prefix),
              Array(prefix[132..<140]) == [2, 0, 0, 0, 85, 76, 4, 0] else {
            throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
        }
        let groupLength = (0..<4).reduce(UInt32(0)) { $0 | UInt32(prefix[140 + $1]) << (8 * $1) }
        guard groupLength <= maximumStoreFileMetaGroupLength,
              let metaLength = Int(exactly: groupLength), metaLength <= length - 144 else {
            throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
        }
        let suffixLength = min(length - 144, metaLength + 8)
        prefix.append(try handle.read(upToCount: suffixLength) ?? Data())
        guard prefix.count == 144 + suffixLength,
              let meta = try? DicomPart10FileMetaParser.parse(prefix), meta.dataSetOffset == 144 + metaLength else {
            throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
        }
        return prefix
    }

    /// Sends the multipart body `write` describes. A `DicomWebStreamedBodyTransport` reads it from its segments on
    /// every attempt; any other transport gets it in a temporary file, opened again from its start on every attempt
    /// and removed after the last one. A 4xx answered with a DICOM JSON or XML store response (PS3.18 Annex I), such as
    /// a 400 whose Failed SOP Sequence gives each instance's Failure Reason, is returned as a result like a 409;
    /// 401, 403, 404 and 429 still throw, since they say nothing about the instances.
    private func storeMultipart(boundary: String, studyInstanceUID: String?, maximumBytes: Int,
                                write: (inout DicomWebMultipartStreamWriter, inout DicomWebHTTPRequestBody) throws -> Void)
        async throws -> DicomWebStoreResult {
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary, maximumBytes: maximumBytes)
        var body = DicomWebHTTPRequestBody()
        try write(&writer, &body)
        try writer.finish { body.append($0) }
        var file: URL?
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        if !(transport is any DicomWebStreamedBodyTransport) {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-stow-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: staged.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { throw DicomWebError(kind: .server) }
            file = staged
            try body.write(to: staged)
        }
        let headers = ["Content-Type": "multipart/related; type=\"application/dicom\"; boundary=\(boundary)",
                       "Content-Length": String(body.length), "Accept": DicomWebMediaTypeNegotiator.storeResponseAcceptHeader]
        let url = endpoint(studyInstanceUID.map { ["studies", $0] } ?? ["studies"])
        let streamed = try await withRetries(.store) {
            try await streamRequest(.post, url: url, headers: headers, bodyFileURL: file,
                                    streamedBody: file == nil ? body : nil, accepts: Self.isStoreAnswer)
        }
        let response = try await collect(streamed, maximumBytes: configuration.maximumMetadataBytes)
        let contentType = response.headers.dicomWebHeaderValue("Content-Type")
        let parts = try multipartPartsIfNeeded(body: response.body, contentType: contentType)
        let decoded: DicomWebStoreResponse
        if let first = parts.first(where: \.isRoot) ?? parts.first {
            decoded = try DicomWebStoreResponse.decode(first.body, contentType: first.contentType)
        } else {
            decoded = try DicomWebStoreResponse.decode(response.body, contentType: contentType)
        }
        var result = DicomWebStoreResult(statusCode: response.statusCode, responseData: response.body,
                                         responseParts: parts, storeResponse: decoded)
        result.warning = response.headers.dicomWebHeaderValue("Warning")
        return result
    }

    /// Whether a STOW-RS response that is not 2xx still carries the store outcome: 409, or another 4xx with a DICOM
    /// JSON or XML body, except the statuses that refuse the request itself.
    private static func isStoreAnswer(_ response: DicomWebHTTPStreamedResponse) -> Bool {
        let status = response.statusCode
        if status == 409 { return true }
        guard (400..<500).contains(status), ![401, 403, 404, 429].contains(status) else { return false }
        let type = response.headers.dicomWebHeaderValue("Content-Type")?.lowercased() ?? ""
        return type.contains("application/dicom+json") || type.contains("application/dicom+xml")
    }

    /// A buffered request whose refused status throws `DicomWebError` with the server's diagnostics. Only GET is
    /// repeated; the UPS-RS requests that change a workitem are sent once.
    package func send(_ method: DicomWebHTTPMethod,
                      url: URL,
                      headers: [String: String],
                      body: Data? = nil) async throws -> DicomWebHTTPResponse {
        try await withRetries(method == .get ? .idempotent : nil) {
            let streamed = try await streamRequest(method, url: url, headers: headers, body: body)
            return try await collect(streamed, maximumBytes: configuration.maximumMetadataBytes)
        }
    }

    private static func hasSameOrigin(_ url: URL, _ baseURL: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let configuredScheme = baseURL.scheme?.lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let configuredPort = baseURL.port ?? (configuredScheme == "https" ? 443 : 80)
        return scheme == configuredScheme && url.host?.lowercased() == baseURL.host?.lowercased()
            && port == configuredPort
    }

    private func retrievedObject(from response: DicomWebHTTPResponse) throws -> DicomWebRetrievedObject {
        let contentType = response.headers.dicomWebHeaderValue("Content-Type")
        let parts = try multipartPartsIfNeeded(body: response.body, contentType: contentType)
        if !parts.isEmpty {
            return DicomWebRetrievedObject(statusCode: response.statusCode,
                                           contentType: contentType,
                                           parts: parts)
        }
        return DicomWebRetrievedObject(statusCode: response.statusCode,
                                       contentType: contentType,
                                       parts: [DicomWebMultipartPart(headers: response.headers, body: response.body)])
    }

    private func multipartPartsIfNeeded(body: Data, contentType: String?) throws -> [DicomWebMultipartPart] {
        guard let contentType, contentType.lowercased().contains("multipart/related") else {
            return []
        }
        guard DicomWebMultipartParser.boundary(from: contentType) != nil else {
            throw DicomWebClientError.missingMultipartBoundary(contentType: contentType)
        }
        return try DicomWebMultipartStreamParser.parts(from: body, contentType: contentType, limits: configuration.multipartLimits)
    }

    private func endpoint(_ pathComponents: [String]) -> URL {
        var url = configuration.baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    private func queryURL(path: [String], query: [URLQueryItem]) -> URL {
        let url = endpoint(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? url
    }

    private func bulkDataURL(_ uri: String, relativeTo requestBase: URL? = nil) throws -> URL {
        do { return try configuration.originPolicy.resolve(uri, relativeTo: requestBase ?? relativeBulkDataBaseURL()) }
        catch { throw DicomWebClientError.invalidBulkDataURI(uri) }
    }

    private func relativeBulkDataBaseURL() -> URL {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            return configuration.baseURL
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url ?? configuration.baseURL
    }

    private func studyQueryItems(_ query: DicomWebQuery) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        appendQueryItem("PatientName", value: query.patientName, to: &items)
        appendQueryItem("PatientID", value: query.patientID, to: &items)
        appendQueryItem("AccessionNumber", value: query.accessionNumber, to: &items)
        appendQueryItem("StudyDate", value: query.studyDate, to: &items)
        appendQueryItem("StudyDescription", value: query.studyDescription, to: &items)
        appendQueryItem("ReferringPhysicianName", value: query.referringPhysicianName, to: &items)
        appendQueryItem("InstitutionName", value: query.institutionName, to: &items)
        appendQueryItem("StudyInstanceUID", value: query.studyInstanceUID, to: &items)
        appendQueryItem("ModalitiesInStudy", value: query.modality, to: &items)
        if let limit = query.limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let offset = query.offset {
            items.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if query.includeAllFields {
            items.append(URLQueryItem(name: "includefield", value: "all"))
        }
        return items
    }

    private func appendQueryItem(_ name: String, value: String?, to items: inout [URLQueryItem]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

}

/// DICOM JSON responses decode through the shared `DicomJSONCodec`; bulk-data references stay explicit.
enum DicomWebJSONParser {
    static func decoded(from data: Data) throws -> [DicomDataSetRepresentation.Decoded] {
        do {
            return try DicomJSONCodec.decode(data, options: .init(unknownVRs: .treatAsUnknown))
        } catch let error as DicomDataSetRepresentation.Error {
            switch error {
            case .invalidDocument, .inputTooLarge, .depthExceeded: throw DicomWebClientError.invalidJSONResponse
            case .malformedTag(let tag), .missingVR(let tag): throw DicomWebClientError.malformedDICOMJSONElement(tag)
            case .unsupportedVR(let tag, let vr): throw DicomWebClientError.unsupportedDICOMJSONValue(tag: tag, vr: vr)
            case .conflictingValueFields(let tag), .invalidBase64(let tag), .bulkDataUnresolved(let tag), .bulkDataTooLarge(let tag, _, _):
                throw DicomWebClientError.malformedDICOMJSONElement(tag)
            case .nullValue(let tag, _), .unrepresentableValue(let tag, _, _):
                throw DicomWebClientError.unsupportedDICOMJSONValue(tag: tag, vr: "")
            }
        }
    }

    static func dataSets(from data: Data) throws -> [DicomDataSet] {
        try decoded(from: data).map(\.dataSet)
    }
}

package enum DicomWebMultipartParser {
    package static func boundary(from contentType: String) -> String? {
        for component in contentType.components(separatedBy: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    package static func parts(from data: Data, boundary: String) throws -> [DicomWebMultipartPart] {
        do {
            return try DicomWebMultipartStreamParser.parts(
                from: data, contentType: "multipart/related; boundary=\"\(boundary)\"")
        } catch is CancellationError { throw CancellationError() }
        catch { throw DicomWebClientError.malformedMultipartBody }
    }

    private static func headers(from text: String) -> [String: String] {
        text.components(separatedBy: "\r\n").reduce(into: [String: String]()) { result, line in
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension DicomVR {
    static func dicomWebVR(for code: String) -> DicomVR {
        let upper = code.uppercased()
        guard upper.count == 2, let first = upper.utf8.first, let last = upper.utf8.last else {
            return .unknown
        }
        return DicomVR(rawValue: Int(first) << 8 | Int(last)) ?? .unknown
    }

    var dicomWebCode: String {
        guard self != .unknown else { return "UN" }
        let high = UInt8((rawValue >> 8) & 0xFF)
        let low = UInt8(rawValue & 0xFF)
        return String(bytes: [high, low], encoding: .ascii) ?? "UN"
    }
}

package extension Dictionary where Key == String, Value == String {
    func dicomWebHeaderValue(_ field: String) -> String? {
        first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }
}

private extension String {
    static func dicomWebPreview(_ data: Data) -> String {
        let prefix = data.prefix(512)
        return String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension Data {
    func hasBytes(_ bytes: [UInt8], at index: Data.Index) -> Bool {
        guard distance(from: index, to: endIndex) >= bytes.count else { return false }
        for (offset, byte) in bytes.enumerated() where self[index + offset] != byte {
            return false
        }
        return true
    }
}

private extension Data.SubSequence {
    func dicomWebStrippingTrailingCRLF() -> Data {
        guard distance(from: startIndex, to: endIndex) >= 2 else {
            return Data(self)
        }
        let previous = index(before: endIndex)
        let penultimate = index(before: previous)
        guard self[penultimate] == 13, self[previous] == 10 else {
            return Data(self)
        }
        return Data(self[startIndex..<penultimate])
    }
}

/// Resolves `BulkDataURI` references through `DicomWebClient.retrieveBulkData`, which applies the origin policy.
struct DicomWebBulkDataResolver: DicomDataSetRepresentation.BulkDataResolver {
    let client: DicomWebClient
    let requestBase: URL?

    /// Every part of the response, in order. A value can come in several parts, as encapsulated pixel data sent
    /// one frame per part.
    func parts(for reference: DicomDataSetRepresentation.BulkDataReference) async throws -> [Data] {
        let sink = DicomWebMemoryRetrieveSink(maximumBytes: client.configuration.multipartLimits.maximumPartBytes)
        try await client.retrieveBulkData(uri: reference.uri, relativeTo: requestBase, sink: sink)
        return await sink.result().map(\.body)
    }

    /// The one value of `reference`. A response in several parts is refused rather than cut to its first part.
    func data(for reference: DicomDataSetRepresentation.BulkDataReference) async throws -> Data {
        let parts = try await parts(for: reference)
        guard parts.count == 1 else {
            throw DicomDataSetRepresentation.Error.bulkDataUnresolved(tag: String(format: "%08X", reference.tag))
        }
        return parts[0]
    }
}
