import Foundation

public enum DicomWebUPSSupport: String, Sendable {
    case notConfigured = "not configured"
    case worklist = "UPS-RS worklist"
    case worklistAndNotifications = "UPS-RS worklist and WebSocket notifications"
}

/// Stable server-side error identifiers exposed in `X-DICOMweb-Error-Code`.
public enum DicomWebServerErrorCode: String, Sendable {
    case invalidWorkitem = "DICOMWEB_INVALID_WORKITEM"
    case workitemConflict = "DICOMWEB_WORKITEM_CONFLICT"
    case workitemNotFound = "DICOMWEB_WORKITEM_NOT_FOUND"
    case workitemDeleted = "DICOMWEB_WORKITEM_DELETED"
    case frameRetrievalUnsupported = "DICOMWEB_FRAME_RETRIEVAL_UNSUPPORTED"
    case renderedFrameUnsupported = "DICOMWEB_RENDERED_FRAME_UNSUPPORTED"
    case invalidFrameList = "DICOMWEB_INVALID_FRAME_LIST"
    case frameNotFound = "DICOMWEB_FRAME_NOT_FOUND"
    case mediaTypeNotAcceptable = "DICOMWEB_MEDIA_TYPE_NOT_ACCEPTABLE"
    case frameResponseTooLarge = "DICOMWEB_FRAME_RESPONSE_TOO_LARGE"
    case invalidRenderParameter = "DICOMWEB_INVALID_RENDER_PARAMETER"
    case malformedPixelData = "DICOMWEB_MALFORMED_PIXEL_DATA"
    case renderingFailed = "DICOMWEB_RENDERING_FAILED"
    case routeNotFound = "DICOMWEB_ROUTE_NOT_FOUND"
}

/// One row in the DICOMweb helper conformance matrix.
public struct DicomWebConformanceRow: Equatable, Sendable {
    /// The DICOMweb feature or responsibility being described.
    public var feature: String
    /// The client-side support level.
    public var client: String
    /// The server-side support level.
    public var server: String
    /// The component or caller that owns the behavior.
    public var responsibility: String
    /// Additional scope notes and limitations.
    public var notes: String

    /// Creates a conformance row for one DICOMweb feature.
    public init(feature: String,
                client: String,
                server: String,
                responsibility: String,
                notes: String) {
        self.feature = feature
        self.client = client
        self.server = server
        self.responsibility = responsibility
        self.notes = notes
    }
}

/// Explicit support matrix for the package DICOMweb helper APIs.
public struct DicomWebConformanceMatrix: Equatable, Sendable {
    /// Ordered feature rows emitted by the conformance endpoint and docs.
    public var rows: [DicomWebConformanceRow]

    /// Creates a matrix from precomputed feature rows.
    public init(rows: [DicomWebConformanceRow]) {
        self.rows = rows
    }

    /// The default matrix for `DicomWebClient` and `DicomWebServer`.
    public static let packageDefault = DicomWebConformanceMatrix(rows: [
        DicomWebConformanceRow(feature: "QIDO-RS",
                               client: "supported",
                               server: "study, series and instance searches",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Injected search providers use PS3.4 matching, projection, limit/offset and Warning 299."),
        DicomWebConformanceRow(feature: "WADO-RS metadata",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Metadata at all three levels is JSON or multipart XML, with server-owned BulkDataURI references."),
        DicomWebConformanceRow(feature: "WADO-RS instance",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Instance retrieval labels the stored transfer syntax and uses exact entity/part lengths plus part Content-Location."),
        DicomWebConformanceRow(feature: "WADO-RS frame",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Strict ascending frame lists return bounded native or compressed multipart representations."),
        DicomWebConformanceRow(feature: "WADO-RS rendered frame",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Native grayscale and color frames render as JPEG, PNG, or GIF with bounded output."),
        DicomWebConformanceRow(feature: "WADO-URI",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Object retrieval is covered by package HTTP serialization tests."),
        DicomWebConformanceRow(feature: "STOW-RS",
                               client: "supported",
                               server: "supported for Part 10 payloads",
                               responsibility: "DicomWebClient/DicomWebServer",
                               notes: "Streaming STOW validates Part 10 identity and transfer syntax and returns the Annex I response module."),
        DicomWebConformanceRow(feature: "UPS-RS",
                               client: "supported",
                               server: "A1 engine-backed worklist and notifications",
                               responsibility: "DicomWebClient/DicomWebServer/DicomWebHTTP",
                               notes: "PS3.18 chapter 11; JSON and multipart XML; /subscribers/{requester} WebSocket text frames contain one DICOM JSON event object."),
        DicomWebConformanceRow(feature: "BulkDataURI",
                               client: "transport-injected",
                               server: "provider-backed opaque routes",
                               responsibility: "DicomWebClient or caller transport, DicomWebServer",
                               notes: "The client resolves absolute and relative references through the origin policy, optionally by byte range; the server references bulk payloads and binary values above inlineBinaryThresholdBytes through provider-backed routes."),
        DicomWebConformanceRow(feature: "JPIP",
                               client: "caller-supplied transport",
                               server: "conditional on an injected DicomJPIPServer",
                               responsibility: "DicomJPIPClient/DicomJPIPTransport/DicomJPIPServer",
                               notes: "An injected JPIP server handles progressive pixel delivery under the configured service path."),
        DicomWebConformanceRow(feature: "Multipart",
                               client: "supported",
                               server: "supported",
                               responsibility: "DicomWebMultipartStreamParser and STOW/WADO helpers",
                               notes: "Emitters use exact lengths and WADO resource locations. Parsing validates declared lengths and tolerates legacy missing length/location; incremental parsing supports start/Content-ID root selection."),
        DicomWebConformanceRow(feature: "Authentication",
                               client: "caller headers and per-request provider",
                               server: "injected bearer, Basic or JWT verifier",
                               responsibility: "Application security layer",
                               notes: "The client sends its headers to the base origin only and can ask a DicomWebAuthorizationProvider for credentials before each request, renewing them once after a 401. Applications own authorization and audit policy; optional DicomWebHTTP shares the package TLS policy."),
        DicomWebConformanceRow(feature: "Pagination",
                               client: "limit/offset query items and searchPages",
                               server: "limit/offset applied",
                               responsibility: "DicomWebSearchPager and DicomWebServer QIDO",
                               notes: "The server pages study, series and instance searches through the injected search providers, counts offset over authorized results, caps limit at maximumSearchResults and announces further results with Warning 299. The client pager stops on a repeated page or at DicomWebSearchPagingLimits."),
        DicomWebConformanceRow(feature: "Error semantics",
                               client: "stable typed errors and opt-in retries",
                               server: "stable HTTP status and error-code headers",
                               responsibility: "DicomWebError, DicomWebRetryPolicy and DicomWebServerErrorCode",
                               notes: "DicomWebError keeps the status, Retry-After and Warning; DicomWebRetryPolicy, off by default, repeats GETs on transient failures and STOW only on 429, 503 or a connection lost before any answer byte. Frame routes expose stable 400, 404, 406, 413, and 422 error-code headers; UPS-RS uses transaction-specific status and Warning headers."),
        DicomWebConformanceRow(feature: "Large payload streaming",
                               client: "streaming transport and bounded staging",
                               server: "incremental STOW and multipart instance output",
                               responsibility: "DicomWebServer and optional DicomWebHTTP",
                               notes: "STOW and aggregate retrieval materialize at most one instance payload at a time; send remains a buffered compatibility adapter.")
    ])

    /// Returns the row with the requested feature name, ignoring case.
    public func row(feature: String) -> DicomWebConformanceRow? {
        rows.first { $0.feature.caseInsensitiveCompare(feature) == .orderedSame }
    }

    /// Markdown table representation used by the server conformance endpoint.
    public var markdown: String {
        var lines = [
            "| Feature | Client | Server | Responsibility | Notes |",
            "| --- | --- | --- | --- | --- |"
        ]
        lines += rows.map { row in
            "| \(row.feature) | \(row.client) | \(row.server) | \(row.responsibility) | \(row.notes) |"
        }
        return lines.joined(separator: "\n")
    }
}

public struct DicomWebServerConfiguration: Equatable, Sendable {
    /// DICOMweb service path prefix.
    public var servicePath: String
    /// Bearer token required by the in-memory transport, or `nil` for no token check.
    public var requiredBearerToken: String?
    /// Whether bounded metadata and instance responses are cached in memory.
    public var cacheEnabled: Bool
    /// Name emitted by the conformance statement.
    public var serverName: String
    /// Maximum UTF-8 byte length accepted for a WADO-RS frame-list component.
    public var maximumFrameListLength: Int
    /// Maximum number of frames accepted by one WADO-RS frame request.
    public var maximumFramesPerRequest: Int
    /// Maximum encoded byte size of a raw frame response.
    public var maximumFrameResponseBytes: Int
    /// Maximum pixel count rendered for each requested frame.
    public var maximumRenderedPixels: Int
    /// Maximum encoded byte size of a rendered-frame response.
    public var maximumRenderedResponseBytes: Int

    /// Ordinary binary metadata up to this size remains inline; bulk payload tags are always references.
    public var inlineBinaryThresholdBytes: Int

    public var maximumRequestBodyBytes: Int = 1024 * 1024 * 1024
    public var multipartLimits: DicomWebMultipartLimits = .init()
    public var maximumSearchResults: Int = 1000
    /// Maximum provider rows examined by one QIDO request, including denied rows, offset and lookahead.
    /// Requests that cannot resolve their page within this budget return 413 and must be narrowed.
    public var maximumSearchCandidates: Int = 10_000
    public var supportsFilteredWorklistSubscriptions = true
    /// Unsupported fuzzy matching may be rejected, or performed literally with Warning 299.
    public var rejectUnsupportedFuzzyMatching: Bool = false
    /// Service root as clients reach it, for example `https://pacs.example/dicom-web` behind a reverse proxy.
    /// RetrieveURL, BulkDataURI, Location, Content-Location and Warning agents start with it.
    /// Nil derives the root from each request's scheme, Host and the service path.
    public var publicBaseURL: URL? = nil
    /// Lets `X-Forwarded-Proto` and `X-Forwarded-Host` replace the request's scheme and host when
    /// `publicBaseURL` is nil. Enable it only when every request arrives through a proxy that sets both.
    public var trustsForwardedHeaders: Bool = false
    /// How DICOM JSON responses write DS and IS: numbers when exact, as PS3.18 F.2.3 asks, or the stored text.
    public var jsonDecimals = DicomDataSetRepresentation.DecimalPolicy.numbersWhenExact
    public var supportedMediaTypes: [String] = ["application/dicom", "application/dicom+json",
        "application/dicom+xml", "application/octet-stream", "image/jpeg", "image/png", "image/gif",
        "image/jls", "image/jp2", "image/jphc", "image/dicom-rle", "image/jxl", "application/x-deflate"]

    /// Creates bounded in-memory DICOMweb server settings.
    public init(servicePath: String = "/dicom-web",
                requiredBearerToken: String? = nil,
                cacheEnabled: Bool = true,
                serverName: String = "DICOM-Swift DICOMweb",
                maximumFrameListLength: Int = 4_096,
                maximumFramesPerRequest: Int = 256,
                maximumFrameResponseBytes: Int = 128 * 1_024 * 1_024,
                maximumRenderedPixels: Int = 64 * 1_024 * 1_024,
                maximumRenderedResponseBytes: Int = 64 * 1_024 * 1_024,
                inlineBinaryThresholdBytes: Int = 64 * 1_024) {
        self.inlineBinaryThresholdBytes = inlineBinaryThresholdBytes
        self.servicePath = servicePath.hasPrefix("/") ? servicePath : "/\(servicePath)"
        self.requiredBearerToken = requiredBearerToken
        self.cacheEnabled = cacheEnabled
        self.serverName = serverName
        self.maximumFrameListLength = maximumFrameListLength
        self.maximumFramesPerRequest = maximumFramesPerRequest
        self.maximumFrameResponseBytes = maximumFrameResponseBytes
        self.maximumRenderedPixels = maximumRenderedPixels
        self.maximumRenderedResponseBytes = maximumRenderedResponseBytes
    }
}

public struct DicomWebConformanceStatement: Equatable, Sendable {
    public var serverName: String
    public var supportsQIDORS: Bool
    public var supportsWADORS: Bool
    public var supportsWADOURI: Bool
    public var supportsSTOWRS: Bool
    public var supportsJSON: Bool
    public var supportsXML: Bool
    public var supportsMultipart: Bool
    public var oauth2Optional: Bool
    public var upsSupport: DicomWebUPSSupport
    /// Route-backed DICOMweb helper capability matrix.
    public var matrix: DicomWebConformanceMatrix

    public init(serverName: String,
                supportsQIDORS: Bool = true,
                supportsWADORS: Bool = true,
                supportsWADOURI: Bool = true,
                supportsSTOWRS: Bool = true,
                supportsJSON: Bool = true,
                supportsXML: Bool = true,
                supportsMultipart: Bool = true,
                oauth2Optional: Bool = true,
                upsSupport: DicomWebUPSSupport = .worklistAndNotifications,
                matrix: DicomWebConformanceMatrix = .packageDefault) {
        self.serverName = serverName
        self.supportsQIDORS = supportsQIDORS
        self.supportsWADORS = supportsWADORS
        self.supportsWADOURI = supportsWADOURI
        self.supportsSTOWRS = supportsSTOWRS
        self.supportsJSON = supportsJSON
        self.supportsXML = supportsXML
        self.supportsMultipart = supportsMultipart
        self.oauth2Optional = oauth2Optional
        self.upsSupport = upsSupport
        self.matrix = matrix
    }

    public var markdown: String {
        """
        # \(serverName) Conformance Statement

        Supported services:
        - QIDO-RS study search: \(supportsQIDORS ? "yes" : "no")
        - WADO-RS metadata and instance retrieve: \(supportsWADORS ? "yes" : "no")
        - WADO-URI object retrieve: \(supportsWADOURI ? "yes" : "no")
        - STOW-RS instance store: \(supportsSTOWRS ? "yes" : "no")

        Representations:
        - DICOM JSON: \(supportsJSON ? "yes" : "no")
        - DICOM XML: \(supportsXML ? "yes" : "no")
        - multipart/related: \(supportsMultipart ? "yes" : "no")

        Security:
        - OAuth2 bearer token validation: \(oauth2Optional ? "optional" : "not configured")

        Workflows:
        - UPS: \(upsSupport.rawValue)

        DICOMweb support matrix:

        \(matrix.markdown)
        """
    }
}

public struct DicomWebStoredInstance: Equatable, Sendable {
    public var dataSet: DicomDataSet
    public var part10Data: Data
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    public var sopInstanceUID: String
    public var sopClassUID: String
    public var transferSyntax: DicomTransferSyntax

    public init(dataSet: DicomDataSet,
                part10Data: Data,
                studyInstanceUID: String,
                seriesInstanceUID: String,
                sopInstanceUID: String,
                sopClassUID: String,
                transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) {
        self.dataSet = dataSet
        self.part10Data = part10Data
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.sopClassUID = sopClassUID
        self.transferSyntax = transferSyntax
    }
}


public final class DicomWebServer: DicomWebHTTPTransport, Sendable {
    public let configuration: DicomWebServerConfiguration
    public let jpip: DicomJPIPServer?
    public let store: DicomWebInMemoryStore
    public let storage: any DicomWebStorageProviding
    public let principals: (any DicomWebPrincipalResolving)?
    public let authorizer: (any DicomAuthorizing)?
    public let audit: DicomAuditRecorder?
    /// Nil preserves legacy behavior without exposure validation. Hosts exposed beyond loopback MUST
    /// pass a policy; the product and dicomtool always supply one.
    public let exposure: DicomExposurePolicy?
    public let authentication: (any DicomWebAuthenticating)?
    public let transcoding: (any DicomWebServerTranscoding)?
    public let representationResolver: (any DicomRepresentationResolving)?
    public let conformanceStatement: DicomWebConformanceStatement
    let searchCache = DicomWebSearchCache()
    public let unifiedProcedureSteps: DicomUnifiedProcedureStepService?
    public let notifications: DicomWebNotificationHub?
    public let authorizeWorklistSubscription: @Sendable (String) -> Bool

    public init(configuration: DicomWebServerConfiguration = .init(), store: DicomWebInMemoryStore = .init(),
                storage: (any DicomWebStorageProviding)? = nil,
                authentication: (any DicomWebAuthenticating)? = nil,
                transcoding: (any DicomWebServerTranscoding)? = nil,
                representationResolver: (any DicomRepresentationResolving)? = nil,
                jpip: DicomJPIPServer? = nil,
                unifiedProcedureSteps: DicomUnifiedProcedureStepService? = nil,
                notifications: DicomWebNotificationHub? = nil,
                authorizeWorklistSubscription: @escaping @Sendable (String) -> Bool = { _ in true },
                principals: (any DicomWebPrincipalResolving)? = nil,
                authorizer: (any DicomAuthorizing)? = nil, audit: DicomAuditRecorder? = nil,
                exposure: DicomExposurePolicy? = nil) {
        self.unifiedProcedureSteps = unifiedProcedureSteps
        self.notifications = notifications
        self.authorizeWorklistSubscription = authorizeWorklistSubscription
        if let notifications { unifiedProcedureSteps?.installEventSinkIfAbsent(DicomWebNotificationEventSink(hub: notifications)) }
        self.configuration = configuration
        self.store = store
        self.storage = storage ?? store
        self.authentication = authentication ?? configuration.requiredBearerToken.map { DicomWebBearerAuthentication(token: $0) }
        self.principals = principals ?? (self.authentication as? any DicomWebPrincipalResolving)
        self.authorizer = authorizer; self.audit = audit; self.exposure = exposure
        self.transcoding = transcoding
        self.representationResolver = representationResolver
        self.jpip = jpip
        let upsSupport: DicomWebUPSSupport = unifiedProcedureSteps == nil ? .notConfigured :
            (notifications == nil ? .worklist : .worklistAndNotifications)
        var matrix = DicomWebConformanceMatrix.packageDefault
        if let index = matrix.rows.firstIndex(where: { $0.feature == "UPS-RS" }) {
            matrix.rows[index].server = upsSupport.rawValue
            if unifiedProcedureSteps == nil {
                matrix.rows[index].notes = "No UPS service is configured on this server."
            } else if notifications == nil {
                matrix.rows[index].notes = "PS3.18 chapter 11; JSON and multipart XML. WebSocket notifications are not configured."
            }
        }
        conformanceStatement = .init(serverName: configuration.serverName, upsSupport: upsSupport, matrix: matrix)
    }

    public func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let response = await handleStreaming(request, body: Self.body(for: request))
        var data = Data()
        do { for try await chunk in response.body { data.append(chunk) } }
        catch { response.cancel(); throw error }
        var headers = response.headers
        headers["Content-Length"] = String(data.count)
        return .init(statusCode: response.statusCode, headers: headers, body: data)
    }

    public func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        await handleStreaming(request, body: Self.body(for: request))
    }

    /// Compatibility entry point. It blocks its thread until the response is complete, so it is unavailable to
    /// async code, where a blocked cooperative thread can starve the task it waits for.
    @available(*, noasync, message: "Use send(_:) or handleStreaming(_:body:) from async code.")
    public func handle(_ request: DicomWebHTTPRequest) -> DicomWebHTTPResponse {
        let result = DicomWebSynchronousResult()
        Task.detached { result.complete((try? await self.send(request)) ?? self.error(500, "Request failed.")) }
        return result.wait()
    }

    public func handleStreaming(_ request: DicomWebHTTPRequest,
                                body: AsyncThrowingStream<Data, Error>) async -> DicomWebHTTPStreamedResponse {
        do {
            try Task.checkCancellation()
            if let authentication, case let .deny(status, challenge) = await authentication.authenticate(request) {
                try await audit?.record(DicomAuditMessages.userAuthentication(.failure, principal: nil,
                    context: .init(protocol: .dicomweb)))
                return streamed(error(status == 403 ? 403 : 401, "Access denied.",
                                      headers: challenge.map { ["WWW-Authenticate": $0] } ?? [:]))
            }
            let principal = await principals?.principal(for: request)
            let required = authorizer != nil || exposure.map {
                $0.mode != .localOnly && !($0.mode == .intranetLab && $0.allowUnauthorizedIntranetLab)
            } == true
            if required && (principal == nil || principal?.kind == .anonymous || principal?.source == DicomPrincipal.Source.none) {
                try await audit?.record(DicomAuditMessages.userAuthentication(.failure, principal: nil,
                    context: .init(protocol: .dicomweb)))
                return streamed(error(401, "Authentication required."))
            }
            let access = DicomEnforcement(principal: principal, authorizer: authorizer, audit: audit,
                context: .init(transportSecured: request.url.scheme == "https", protocol: .dicomweb))
            if let authorizer, await authorizer.policyVersion < 0 {
                throw DicomWebServerFailure(503, "Authorization unavailable.")
            }
            return try await DicomRequestAuthorization.$current.withValue(access) {
                try await dispatchAuthorized(request, body: body)
            }
        } catch let failure as DicomWebServerFailure {
            return streamed(error(failure.status, failure.message))
        } catch let failure as DicomWebError {
            return streamed(error(failure.kind == .notAcceptable ? 406 : 400, String(describing: failure)))
        } catch let failure as DicomWebHTTPBodyError {
            return streamed(error(failure == .payloadTooLarge ? 413 : 400, "Invalid request body."))
        } catch is DicomAuditError {
            return streamed(error(503, "Audit unavailable."))
        } catch is CancellationError {
            return streamed(error(499, "Request cancelled."))
        } catch { return streamed(self.error(500, "Request failed.")) }
    }

    private func dispatchAuthorized(_ request: DicomWebHTTPRequest,
                                    body: AsyncThrowingStream<Data, Error>) async throws -> DicomWebHTTPStreamedResponse {
            guard let path = path(request.url) else { return streamed(notFound()) }
            if let jpip, path.first == "jpip" {
                return await jpip.handle(request)
            }
            if request.method == .post, path == ["studies"] || (path.count == 2 && path[0] == "studies") {
                return streamed(try await stow(request, body: body, study: path.count == 2 ? path[1] : nil))
            }
            if path.first == "workitems" || path.first == "subscribers" {
                let resource = DicomResourceRef(kind: path.first == "subscribers" ? .subscription : .workitem,
                    id: path.dropFirst().first ?? "worklist")
                let operation: DicomAccessOperation = path.contains("subscribers") ? .subscribe
                    : request.method == .get ? .readMetadata : .workitemChange
                if path.first == "subscribers" || path.contains("subscribers") {
                    _ = try await DicomRequestAuthorization.current?.check(operation, resource)
                }
                var response = streamed(try await worklist(request, path: path, body: body))
                if response.statusCode == 101, let access = DicomRequestAuthorization.current {
                    response.authorizeNotification = { text in
                        try await access.recheck(.subscribe, resource)
                        guard let object = try DicomJSONCodec.decode(Data(("[" + text + "]").utf8)).first,
                              let uid = object.dataSet.string(for: 0x00001000) else {
                            throw DicomWebServerFailure(403, "Unresolved notification resource.")
                        }
                        try await access.recheck(.readMetadata, .init(kind: .workitem, id: uid))
                    }
                }
                return response
            }
            guard request.method == .get else {
                guard let allowed = Self.allowedMethods(path) else { return streamed(notFound()) }
                return streamed(error(405, "Method not allowed.", headers: ["Allow": allowed]))
            }
            if path.isEmpty || path == ["conformance"] { return streamed(try capabilities(request)) }
            if path == ["wado"] { return streamed(try await wadoURI(request)) }
            if path.first == "bulkdata" { return streamed(try await bulkData(request, path: path)) }
            if let query = try searchParameters(request, path: path) {
                return streamed(try await search(request, parameters: query.parameters, ignored: query.ignored))
            }
            return try await retrieve(request, path: path)
    }

    public func validateExposure(bindAddress: String, tlsEnabled: Bool, ephemeralPortNotPinned: Bool = false) async throws {
        guard let exposure else { return }
        // Local compatibility is permitted only on an actual numeric loopback bind.
        let local = exposure.mode == .localOnly
        if !local, !(exposure.mode == .intranetLab && exposure.allowUnauthorizedIntranetLab), !tlsEnabled {
            throw DicomExposureValidationError(findings: [.init(code: .tlsRequired)])
        }
        var findings = try exposure.validate(bindAddress: bindAddress, tlsEnabled: tlsEnabled,
            authenticationConfigured: local || (principals != nil && authorizer != nil))
        if ephemeralPortNotPinned { findings.append(.init(code: .ephemeralPortNotPinned, isError: false)) }
        try await audit?.record(DicomAuditMessages.exposureFindings(findings, principal: nil,
            context: .init(transportSecured: tlsEnabled, protocol: .dicomweb)))
    }

    func path(_ url: URL) -> [String]? {
        let prefix = configuration.servicePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let all = url.path.split(separator: "/").map(String.init)
        let base = prefix.split(separator: "/").map(String.init)
        guard Array(all.prefix(base.count)) == base else { return nil }
        return Array(all.dropFirst(base.count))
    }
    /// Methods served on a route outside UPS-RS and JPIP, or nil when the path names no resource.
    static func allowedMethods(_ path: [String]) -> String? {
        if path.isEmpty || path == ["conformance"] || path == ["wado"] { return "GET" }
        if path.count == 2, path[0] == "bulkdata" { return "GET" }
        if path == ["series"] || path == ["instances"] { return "GET" }
        if path == ["studies"] { return "GET, POST" }
        guard path.count >= 2, path[0] == "studies" else { return nil }
        var index = 2
        if path.count >= 4, path[2] == "series" { index = 4 }
        if path.count >= 6, index == 4, path[4] == "instances" { index = 6 }
        let suffix = Array(path.dropFirst(index))
        switch suffix {
        case []: return index == 2 ? "GET, POST" : "GET"
        case ["metadata"], ["thumbnail"], ["rendered"]: return "GET"
        case ["series"]: return index == 2 ? "GET" : nil
        case ["instances"]: return index < 6 ? "GET" : nil
        default:
            let frames = index == 6 && suffix.count >= 2 && suffix[0] == "frames"
                && (suffix.count == 2 || (suffix.count == 3 && ["rendered", "thumbnail"].contains(suffix[2])))
            return frames ? "GET" : nil
        }
    }
    func baseURL(_ request: DicomWebHTTPRequest) -> URL {
        if let publicBaseURL = configuration.publicBaseURL { return publicBaseURL }
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { return request.url }
        if configuration.trustsForwardedHeaders {
            // A proxy chain lists the client-facing value first.
            func forwarded(_ name: String) -> String? {
                request.headers.dicomWebHeaderValue(name)?.split(separator: ",").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if let scheme = forwarded("X-Forwarded-Proto")?.lowercased(), scheme == "http" || scheme == "https" {
                components.scheme = scheme
            }
            if let host = forwarded("X-Forwarded-Host"), let authority = URLComponents(string: "http://" + host),
               authority.percentEncodedHost?.isEmpty == false, authority.path.isEmpty, authority.user == nil,
               authority.password == nil, authority.query == nil, authority.fragment == nil {
                components.percentEncodedHost = authority.percentEncodedHost
                components.port = authority.port
            }
        }
        components.path = configuration.servicePath
        components.query = nil
        components.fragment = nil
        return components.url ?? request.url
    }
    /// The request URL rebased on `baseURL`, for Content-Location values that echo the requested resource.
    func publicURL(_ request: DicomWebHTTPRequest) -> URL {
        guard let path = path(request.url) else { return request.url }
        var url = baseURL(request)
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.percentEncodedQuery = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        return components.url ?? url
    }
    func error(_ status: Int, _ message: String, headers: [String: String] = [:]) -> DicomWebHTTPResponse {
        .init(statusCode: status, headers: ["Content-Type": "text/plain"].merging(headers) { _, new in new }, body: Data(message.utf8))
    }
    func notFound() -> DicomWebHTTPResponse {
        error(404, "DICOMweb route not found.", headers: ["X-DICOMweb-Error-Code": DicomWebServerErrorCode.routeNotFound.rawValue])
    }
    func streamed(_ response: DicomWebHTTPResponse) -> DicomWebHTTPStreamedResponse {
        .init(statusCode: response.statusCode, headers: response.headers, body: AsyncThrowingStream { continuation in
            continuation.yield(response.body); continuation.finish()
        })
    }
    static func body(for request: DicomWebHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        if let file = request.bodyFileURL {
            let reader = DicomWebServerFileReader(file)
            return AsyncThrowingStream(unfolding: { try await reader.next() })
        }
        return AsyncThrowingStream { continuation in
            if let data = request.body { continuation.yield(data) }
            continuation.finish()
        }
    }
}

private final class DicomWebSynchronousResult: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var response: DicomWebHTTPResponse?
    func complete(_ value: DicomWebHTTPResponse) { response = value; semaphore.signal() }
    func wait() -> DicomWebHTTPResponse { semaphore.wait(); return response! }
}

private actor DicomWebServerFileReader {
    let url: URL
    var handle: FileHandle?
    init(_ url: URL) { self.url = url }
    func next() throws -> Data? {
        try Task.checkCancellation()
        if handle == nil { handle = try FileHandle(forReadingFrom: url) }
        let data = try handle?.read(upToCount: 64 * 1024)
        return data?.isEmpty == false ? data : nil
    }
    deinit { try? handle?.close() }
}
