import Foundation
import DicomData

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

    public init(session: URLSession = .shared) {
        self.session = session
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

    public var allowedOrigins: Set<URL> = []
    public var multipartLimits = DicomWebMultipartLimits()
    public var maximumMetadataBytes = 64 * 1024 * 1024
    public var originPolicy: DicomWebOriginPolicy {
        .init(configuredURL: baseURL, allowedOrigins: allowedOrigins.union(allowedBulkDataOrigins))
    }
    public var baseURL: URL
    /// Headers scoped to the configured origin; foreign BulkDataURI hosts do not receive them.
    public var headers: [String: String]
    /// Inactivity timeout of every request: the longest wait for the next bytes.
    public var timeout: TimeInterval
    /// Total time allowed for one request, response body included; nil for none (#2893).
    public var totalDeadline: TimeInterval? = nil
    /// False refuses every redirect; true follows those the origin policy allows.
    public var followsRedirects = true
    /// Maximum complete STOW multipart body size, including MIME framing and payloads.
    public var maximumSTOWRequestBodyBytes: Int
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
    private let transport: any DicomWebHTTPTransport

    public init(configuration: DicomWebClientConfiguration,
                transport: any DicomWebHTTPTransport = URLSessionDicomWebHTTPTransport.shared) {
        self.configuration = configuration
        self.transport = transport
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
        let response = try await boundedResponse(url: endpoint(path), accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata))
        return try DicomWebJSONParser.decoded(from: response.body)
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

    private func retrieveBuffered(url: URL, accept: String) async throws -> DicomWebRetrievedObject {
        let sink = DicomWebMemoryRetrieveSink(maximumBytes: configuration.multipartLimits.maximumPartBytes)
        let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
        try await consume(response, sink: sink)
        return .init(statusCode: response.statusCode, contentType: response.headers.dicomWebHeaderValue("Content-Type"),
                     parts: await sink.result())
    }

    private func retrieve(url: URL, accept: String, sink: any DicomWebRetrieveSink) async throws -> Int {
        let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
        try await consume(response, sink: sink)
        return response.statusCode
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
                               body: Data? = nil, bodyFileURL: URL? = nil,
                               acceptedStatuses: Set<Int> = []) async throws -> DicomWebHTTPStreamedResponse {
        try Task.checkCancellation()
        try configuration.originPolicy.validate(url)
        var allHeaders = configuration.originPolicy.forwardsCredentials(to: url) ? configuration.headers : [:]
        for (name, value) in headers { allHeaders[name] = value }
        var request = DicomWebHTTPRequest(method: method, url: url, headers: allHeaders, body: body, timeout: configuration.timeout)
        request.deadline = configuration.totalDeadline.map { Date().addingTimeInterval($0) }
        request.followsRedirects = configuration.followsRedirects
        request.originPolicy = configuration.originPolicy
        request.credentialHeaderNames = Set(configuration.headers.keys.map { $0.lowercased() })
        request.bodyFileURL = bodyFileURL
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.statusCode) || acceptedStatuses.contains(response.statusCode) else {
            response.cancel()
            throw DicomWebError(statusCode: response.statusCode, code: response.headers.dicomWebHeaderValue("X-DICOMweb-Error-Code"))
        }
        return response
    }

    private func boundedResponse(url: URL, accept: String) async throws -> DicomWebHTTPResponse {
        let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
        return try await collect(response, maximumBytes: configuration.maximumMetadataBytes)
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
        let response = try await send(
            .get,
            url: endpoint(["studies", studyInstanceUID, "metadata"]),
            headers: ["Accept": DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata)]
        )
        return try DicomWebJSONParser.decoded(from: response.body)
    }

    /// Fetches every bulk-data reference of a decoded representation through this client's transport, origin
    /// policy and limits, and stores the value fields in the returned data set.
    public func resolveBulkData(in decoded: DicomDataSetRepresentation.Decoded,
                                limits: DicomDataSetRepresentation.BulkDataLimits = .init(),
                                relativeTo requestBase: URL? = nil) async throws -> DicomDataSetRepresentation.Decoded {
        var boundedClient = self
        boundedClient.configuration.multipartLimits.maximumPartBytes = min(configuration.multipartLimits.maximumPartBytes,
                                                                           limits.maximumBytesPerReference)
        try Task.checkCancellation()
        return try await DicomDataSetRepresentation.resolvingBulkData(decoded,
            using: DicomWebBulkDataResolver(client: boundedClient, requestBase: requestBase), limits: limits)
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
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID) { writer, sink in
            for instance in prepared {
                let type = instance.contentType + (instance.transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: instance.data.count, sink: sink)
                try writer.payload(instance.data, sink: sink)
                try writer.endPart(sink: sink)
            }
        }
    }

    public func storeInstances(dataSets: [DicomDataSet], studyInstanceUID: String? = nil,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) async throws -> DicomWebStoreResult {
        guard !dataSets.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID) { writer, sink in
            for dataSet in dataSets {
                try Task.checkCancellation()
                let payload = try DicomDataSetWriter.part10Data(from: dataSet,
                    options: DicomPart10WriterOptions(transferSyntax: transferSyntax))
                try writer.beginPart(headers: [("Content-Type", "application/dicom; transfer-syntax=\(transferSyntax.rawValue)")],
                                     contentLength: payload.count, sink: sink)
                try writer.payload(payload, sink: sink)
                try writer.endPart(sink: sink)
            }
        }
    }

    public func storeInstances(files: [URL], studyInstanceUID: String? = nil) async throws -> DicomWebStoreResult {
        guard !files.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID) { writer, sink in
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard let length = Int(exactly: size), length <= configuration.maximumSTOWRequestBodyBytes else {
                    throw DicomWebClientError.storeRequestBodyTooLarge(byteCount: Int(clamping: size),
                                                                     limit: configuration.maximumSTOWRequestBodyBytes)
                }
                let prefix = try Self.fileMetaPrefix(of: handle, length: length, instanceIndex: index)
                let prepared = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: [.init(data: prefix, transferSyntax: nil)])
                let type = "application/dicom" + (prepared[0].transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try handle.seek(toOffset: 0)
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: length, sink: sink)
                try writer.payload(file: handle, sink: sink)
                try writer.endPart(sink: sink)
            }
        }
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

    private func storeMultipart(boundary: String, studyInstanceUID: String?,
                                write: (inout DicomWebMultipartStreamWriter, DicomWebByteSink) throws -> Void) async throws -> DicomWebStoreResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-stow-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw DicomWebError(kind: .server) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary, maximumBytes: configuration.maximumSTOWRequestBodyBytes)
        try write(&writer) { try handle.write(contentsOf: $0) }
        try writer.finish { try handle.write(contentsOf: $0) }
        let length = try handle.offset()
        try handle.close()
        let streamed = try await streamRequest(.post,
            url: endpoint(studyInstanceUID.map { ["studies", $0] } ?? ["studies"]),
            headers: ["Content-Type": "multipart/related; type=\"application/dicom\"; boundary=\(boundary)",
                      "Content-Length": String(length), "Accept": DicomWebMediaTypeNegotiator.storeResponseAcceptHeader],
            bodyFileURL: file, acceptedStatuses: [409])
        let response = try await collect(streamed, maximumBytes: configuration.maximumMetadataBytes)
        let contentType = response.headers.dicomWebHeaderValue("Content-Type")
        let parts = try multipartPartsIfNeeded(body: response.body, contentType: contentType)
        let decoded: DicomWebStoreResponse
        if let first = parts.first(where: \.isRoot) ?? parts.first {
            decoded = try DicomWebStoreResponse.decode(first.body, contentType: first.contentType)
        } else {
            decoded = try DicomWebStoreResponse.decode(response.body, contentType: contentType)
        }
        return DicomWebStoreResult(statusCode: response.statusCode, responseData: response.body,
                                   responseParts: parts, storeResponse: decoded)
    }

    package func send(_ method: DicomWebHTTPMethod,
                      url: URL,
                      headers: [String: String],
                      body: Data? = nil) async throws -> DicomWebHTTPResponse {
        let streamed: DicomWebHTTPStreamedResponse
        do {
            streamed = try await streamRequest(method, url: url, headers: headers, body: body)
        } catch let error as DicomWebError {
            throw DicomWebClientError.httpStatus(statusCode: error.statusCode, method: method.rawValue,
                                                url: "", bodyPreview: "")
        }
        return try await collect(streamed, maximumBytes: configuration.maximumMetadataBytes)
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

    private func bulkDataURL(_ uri: String) throws -> URL {
        do { return try configuration.originPolicy.resolve(uri, relativeTo: relativeBulkDataBaseURL()) }
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

    func data(for reference: DicomDataSetRepresentation.BulkDataReference) async throws -> Data {
        let sink = DicomWebMemoryRetrieveSink(maximumBytes: client.configuration.multipartLimits.maximumPartBytes)
        try await client.retrieveBulkData(uri: reference.uri, relativeTo: requestBase, sink: sink)
        let parts = await sink.result()
        guard let payload = (parts.first(where: \.isRoot) ?? parts.first)?.body else {
            throw DicomDataSetRepresentation.Error.bulkDataUnresolved(tag: String(format: "%08X", reference.tag))
        }
        return payload
    }
}
