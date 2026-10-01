import Foundation

/// Authenticated, bounded, cancellable stateless JPIP transport over HTTP or HTTPS.
///
/// Complete entities remain the default. JPP/JPT require explicit per-request opt-in.
public struct DicomJPIPHTTPTransport: DicomJPIPTransport {
    private let configuration: DicomJPIPTransportConfiguration
    private let httpClient: any DicomJPIPHTTPClient
    private let authorizationProvider: (any DicomJPIPAuthorizationProviding)?

    /// Creates a transport with explicit origin, response, redirect, and authorization policy.
    public init(
        configuration: DicomJPIPTransportConfiguration = DicomJPIPTransportConfiguration(),
        httpClient: (any DicomJPIPHTTPClient)? = nil,
        authorizationProvider: (any DicomJPIPAuthorizationProviding)? = nil
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.httpClient = httpClient ?? URLSessionDicomJPIPHTTPClient()
        self.authorizationProvider = authorizationProvider
    }

    /// Creates a single-pass sequence that performs one bounded request per iterator pull.
    public func payloads(
        for request: DicomJPIPRequest
    ) -> DicomJPIPPayloadSequence {
        let cursor = Cursor(
            request: request,
            configuration: configuration,
            httpClient: httpClient,
            authorizationProvider: authorizationProvider
        )
        return DicomJPIPPayloadSequence(unfolding: {
            try await cursor.next()
        })
    }

    private static func validate(_ configuration: DicomJPIPTransportConfiguration) throws {
        guard configuration.defaultLayerCount > 0,
              configuration.maximumLayerCount > 0,
              configuration.defaultLayerCount <= configuration.maximumLayerCount else {
            throw DicomJPIPTransportError.invalidConfiguration("layer limits")
        }
        guard configuration.maximumResponseBytes > 0,
              configuration.maximumTotalBytes > 0, configuration.maximumMessageLength > 0,
              configuration.maximumCacheBytes > 0, configuration.maximumDatabins > 0 else {
            throw DicomJPIPTransportError.invalidConfiguration("byte limits")
        }
        guard configuration.requestTimeout > 0,
              configuration.requestTimeout.isFinite,
              configuration.resourceTimeout > 0,
              configuration.resourceTimeout.isFinite else {
            throw DicomJPIPTransportError.invalidConfiguration("timeouts")
        }
        let supportedMediaTypes = Set(["image/jp2", "image/jph", "image/jphc", "image/jpp-stream", "image/jpt-stream"])
        guard !configuration.allowedResponseMediaTypes.isEmpty,
              configuration.allowedResponseMediaTypes.isSubset(of: supportedMediaTypes) else {
            throw DicomJPIPTransportError.invalidConfiguration("accepted media types")
        }
        if case .sameOrigin(let maximumHops) = configuration.redirectPolicy, maximumHops < 0 {
            throw DicomJPIPTransportError.invalidConfiguration("redirect limit")
        }
    }
}

private extension DicomJPIPHTTPTransport {
    actor Cursor {
        private let request: DicomJPIPRequest
        private let configuration: DicomJPIPTransportConfiguration
        private let httpClient: any DicomJPIPHTTPClient
        private let authorizationProvider: (any DicomJPIPAuthorizationProviding)?
        private var layerIndices: [Int]?
        private var position = 0
        private var totalBytes = 0
        private var isCancelled = false
        private var cache: DicomJPIPDatabinCache

        init(
            request: DicomJPIPRequest,
            configuration: DicomJPIPTransportConfiguration,
            httpClient: any DicomJPIPHTTPClient,
            authorizationProvider: (any DicomJPIPAuthorizationProviding)?
        ) {
            self.request = request
            self.configuration = configuration
            self.httpClient = httpClient
            self.authorizationProvider = authorizationProvider
            self.cache = DicomJPIPDatabinCache(maximumBytes: configuration.maximumCacheBytes,
                                              maximumBins: configuration.maximumDatabins)
        }

        func next() async throws -> DicomJPIPLayerPayload? {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            let indices = try resolvedLayerIndices()
            guard position < indices.count else { return nil }
            let layerIndex = indices[position]
            let urlRequest = try await makeURLRequest(layerIndex: layerIndex)
            let response: DicomJPIPHTTPResponse
            if request.streamMode != .completeEntity, let streaming = httpClient as? any DicomJPIPStreamingHTTPClient {
                let accumulator = DicomJPIPResponseAccumulator(configuration: configuration,
                    acceptedMediaTypes: try acceptedMediaTypes())
                do {
                    response = try await streaming.response(for: urlRequest, maximumBytes: responseBudget,
                        resourceTimeout: configuration.resourceTimeout, redirectPolicy: configuration.redirectPolicy) {
                            try accumulator.receive($0, data: $1)
                        }
                } catch {
                    let partial = accumulator.snapshot()
                    totalBytes += partial.receivedBytes
                    let codestream = requestedCodestream(messages: partial.messages)
                    if let session = request.session {
                        try await session.accept(channelHeader: partial.metadata?.header(named: "JPIP-cnew"),
                            window: request.window, codestream: codestream) { cid in try await self.close(channelID: cid) }
                        cache = try await session.receive(partial.messages)
                        await session.interrupted()
                    } else {
                        try cache.activate(window: request.window, codestream: codestream)
                        for message in partial.messages { try cache.insert(message) }
                    }
                    throw error
                }
            } else {
                response = try await httpClient.response(for: urlRequest, maximumBytes: responseBudget,
                    resourceTimeout: configuration.resourceTimeout, redirectPolicy: configuration.redirectPolicy)
            }
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            try validate(response)

            let (updatedTotalBytes, overflowedTotalBytes) = totalBytes.addingReportingOverflow(response.body.count)
            guard !overflowedTotalBytes, updatedTotalBytes <= configuration.maximumTotalBytes else {
                throw DicomJPIPTransportError.totalResponseTooLarge(limit: configuration.maximumTotalBytes)
            }
            totalBytes = updatedTotalBytes
            let mediaType = normalizedMediaType(response.header(named: "Content-Type"))
            var data = response.body
            var reconstructionInfo: DicomJPIPReconstructionInfo?
            var isFinal = position == indices.count - 1
            if mediaType == "image/jpp-stream" || mediaType == "image/jpt-stream" {
                var parser = DicomJPIPMessageParser(maximumMessageLength: configuration.maximumMessageLength,
                    maximumBins: configuration.maximumDatabins, maximumTotalBytes: configuration.maximumResponseBytes)
                let messages = try parser.feed(response.body)
                try parser.finish()
                let codestream = requestedCodestream(messages: messages)
                if let session = request.session {
                    try await session.accept(channelHeader: response.header(named: "JPIP-cnew"),
                                             window: request.window, codestream: codestream) { cid in
                        try await self.close(channelID: cid)
                    }
                    cache = try await session.receive(messages)
                } else {
                    try cache.activate(window: request.window, codestream: codestream)
                    for message in messages { try cache.insert(message) }
                }
                var reconstruction = try DicomJPIPCodestreamReconstructor(
                    maximumOutputBytes: configuration.maximumCacheBytes).reconstruct(cache, codestream: codestream, window: request.window)
                if let session = request.session, await session.needsRecovery,
                   parser.endOfResponse?.windowDone == true, reconstruction.info.completeness == .partial {
                    // A server may have advanced its channel cache before the interrupted bytes arrived.
                    // A stateless repair advertises the actual local cache; retain the original channel.
                    let repairRequest = try await makeURLRequest(layerIndex: layerIndex, statelessRepair: true)
                    let repair = try await httpClient.response(for: repairRequest, maximumBytes: responseBudget,
                        resourceTimeout: configuration.resourceTimeout, redirectPolicy: configuration.redirectPolicy)
                    try validate(repair)
                    guard repair.body.count <= configuration.maximumTotalBytes - totalBytes else {
                        throw DicomJPIPTransportError.totalResponseTooLarge(limit: configuration.maximumTotalBytes)
                    }
                    totalBytes += repair.body.count
                    guard normalizedMediaType(repair.header(named: "Content-Type")) == mediaType else {
                        throw DicomJPIPTransportError.invalidResponseHeader("Content-Type")
                    }
                    var repairParser = DicomJPIPMessageParser(maximumMessageLength: configuration.maximumMessageLength,
                        maximumBins: configuration.maximumDatabins, maximumTotalBytes: responseBudget)
                    let repairMessages = try repairParser.feed(repair.body)
                    try repairParser.finish()
                    cache = try await session.receive(repairMessages)
                    reconstruction = try DicomJPIPCodestreamReconstructor(maximumOutputBytes: configuration.maximumCacheBytes)
                        .reconstruct(cache, codestream: codestream, window: request.window)
                    await session.recovered()
                }
                data = reconstruction.data
                reconstructionInfo = reconstruction.info
                isFinal = parser.endOfResponse?.windowDone == true && reconstruction.info.completeness == .full
            }
            let quality: DicomProgressiveUpdateQuality = if position == 0 && !isFinal {
                .preview
            } else if isFinal {
                .final
            } else {
                .refinement
            }
            let payload = DicomJPIPLayerPayload(
                layer: DicomProgressiveLayer(
                    index: layerIndex,
                    totalLayerCount: indices.count,
                    quality: quality,
                    byteRange: 0..<data.count,
                    fractionComplete: reconstructionInfo?.fractionComplete ?? (Double(position + 1) / Double(indices.count)),
                    isFinal: isFinal
                ),
                data: data,
                mediaType: mediaType,
                reconstructionInfo: reconstructionInfo
            )
            await request.session?.record(isFinal: isFinal)
            position += 1
            return payload
        }

        private func requestedCodestream(messages: [DicomJPIPMessage]) -> Int {
            if let stream = request.window?.stream { return stream - 1 }
            if case let .frame(index) = request.resource { return index }
            return messages.first(where: { $0.classID != 8 })?.codestream ?? cache.activeCodestream
        }

        private func resolvedLayerIndices() throws -> [Int] {
            if let layerIndices { return layerIndices }
            let range = request.requestedLayerRange ?? request.window?.layers.map { ($0 - 1)..<$0 } ?? 0..<configuration.defaultLayerCount
            guard !range.isEmpty, range.lowerBound >= 0 else {
                throw DicomJPIPTransportError.invalidLayerRange
            }
            guard range.count <= configuration.maximumLayerCount,
                  range.upperBound <= configuration.maximumLayerCount else {
                throw DicomJPIPTransportError.layerLimitExceeded(
                    limit: configuration.maximumLayerCount,
                    requested: range.upperBound
                )
            }
            let resolved = Array(range)
            layerIndices = resolved
            return resolved
        }

        private var responseBudget: Int {
            min(configuration.maximumResponseBytes, configuration.maximumTotalBytes - totalBytes,
                request.window?.len ?? configuration.maximumResponseBytes)
        }

        private func close(channelID: String) async throws {
            var closing = try await makeURLRequest(layerIndex: 0, closing: true)
            guard var components = URLComponents(url: request.pixelDataProviderURL, resolvingAgainstBaseURL: false) else {
                throw DicomJPIPTransportError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "cclose", value: channelID)]
            closing.url = components.url
            let response = try await httpClient.response(for: closing, maximumBytes: configuration.maximumResponseBytes,
                resourceTimeout: configuration.resourceTimeout, redirectPolicy: configuration.redirectPolicy)
            guard (200..<300).contains(response.statusCode) else {
                throw DicomJPIPTransportError.unexpectedHTTPStatus(response.statusCode)
            }
        }

        private func makeURLRequest(layerIndex: Int, closing: Bool = false, statelessRepair: Bool = false) async throws -> URLRequest {
            guard closing || responseBudget > 0 else {
                throw DicomJPIPTransportError.totalResponseTooLarge(limit: configuration.maximumTotalBytes)
            }
            let providerURL = request.pixelDataProviderURL
            guard providerURL.user == nil, providerURL.password == nil, providerURL.fragment == nil,
                  let scheme = providerURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  providerURL.host?.isEmpty == false else {
                throw DicomJPIPTransportError.invalidURL
            }
            guard scheme == "https" || configuration.allowsInsecureHTTP else {
                throw DicomJPIPTransportError.insecureTransportRejected
            }
            guard let origin = DicomJPIPOrigin(url: providerURL),
                  configuration.allowedOrigins.contains(origin) else {
                throw DicomJPIPTransportError.originNotAllowed
            }
            guard var components = URLComponents(url: providerURL, resolvingAgainstBaseURL: false) else {
                throw DicomJPIPTransportError.invalidURL
            }
            var managedNames = Set(["layers", "len", "stream", "type"])
            if request.streamMode != .completeEntity {
                managedNames.formUnion(["fsiz", "rsiz", "roff", "comps", "quality", "cid", "cnew", "cclose", "tid", "metareq", "model", "tpmodel", "need"])
            }
            let originalItems = components.queryItems ?? []
            if let conflict = originalItems.first(where: { managedNames.contains($0.name.lowercased()) }) {
                throw DicomJPIPTransportError.conflictingQueryParameter(conflict.name)
            }
            let (layerNumber, overflowedLayerNumber) = layerIndex.addingReportingOverflow(1)
            guard !overflowedLayerNumber else {
                throw DicomJPIPTransportError.invalidLayerRange
            }
            var appendedItems = [
                URLQueryItem(name: "layers", value: String(layerNumber)),
                URLQueryItem(name: "len", value: String(responseBudget))
            ]
            appendedItems += request.window?.queryItems ?? []
            if let model = request.cacheModel {
                guard model.need == nil || request.session?.usesHTTPChannel != true else {
                    throw DicomJPIPTransportError.invalidWindow
                }
                try cache.importCacheModel(model)
                try await request.session?.importCacheModel(model)
            }
            if let session = request.session {
                if session.usesHTTPChannel && !statelessRepair {
                    let channel = await session.channelID
                    appendedItems.append(URLQueryItem(name: channel == nil ? "cnew" : "cid", value: channel ?? "http"))
                    if await session.needsRecovery && session.supportsCacheModel && request.cacheModel == nil { appendedItems += DicomJPIPCacheModel(cache: await session.cache).queryItems }
                } else if session.supportsCacheModel && request.cacheModel == nil {
                    appendedItems += DicomJPIPCacheModel(cache: await session.cache).queryItems
                }
            } else if request.streamMode != .completeEntity && request.cacheModel == nil {
                appendedItems += DicomJPIPCacheModel(cache: cache).queryItems
            }
            appendedItems += request.cacheModel?.queryItems ?? []
            switch request.resource {
            case .frame(let index):
                guard index >= 0 else { throw DicomJPIPTransportError.invalidFrameIndex(index) }
                let (streamNumber, overflowedStreamNumber) = index.addingReportingOverflow(1)
                guard !overflowedStreamNumber else {
                    throw DicomJPIPTransportError.invalidFrameIndex(index)
                }
                if let stream = request.window?.stream, stream != streamNumber {
                    throw DicomJPIPTransportError.invalidWindow
                }
                if request.window?.stream == nil {
                    appendedItems.append(URLQueryItem(name: "stream", value: String(streamNumber)))
                }
            case .volume:
                break
            }
            let mediaTypes = try acceptedMediaTypes()
            appendedItems.append(
                URLQueryItem(name: "type", value: orderedMediaTypes(mediaTypes).map { $0.hasSuffix("-stream") ? String($0.dropFirst(6)) : $0 }.joined(separator: ","))
            )
            var appendedComponents = URLComponents()
            appendedComponents.queryItems = appendedItems
            let appendedQuery = appendedComponents.percentEncodedQuery ?? ""
            components.percentEncodedQuery = [components.percentEncodedQuery, appendedQuery]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "&")
            guard let url = components.url else { throw DicomJPIPTransportError.invalidURL }

            var urlRequest = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
            urlRequest.httpMethod = "GET"
            if let authorizationProvider {
                guard let requestOrigin = DicomJPIPOrigin(url: url) else {
                    throw DicomJPIPTransportError.invalidURL
                }
                let authorization: String?
                do {
                    authorization = try await authorizationProvider.authorizationHeader(for: requestOrigin)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw DicomJPIPTransportError.authorizationFailed
                }
                try Task.checkCancellation()
                if let authorization {
                    guard !authorization.isEmpty,
                          !authorization.contains(where: \.isNewline) else {
                        throw DicomJPIPTransportError.authorizationFailed
                    }
                    guard scheme == "https" else {
                        throw DicomJPIPTransportError.insecureTransportRejected
                    }
                    urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
            }
            urlRequest.setValue(orderedMediaTypes(mediaTypes).joined(separator: ", "), forHTTPHeaderField: "Accept")
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            return urlRequest
        }

        private func validate(_ response: DicomJPIPHTTPResponse) throws {
            switch response.statusCode {
            case 200..<300:
                break
            case 401, 403:
                throw DicomJPIPTransportError.authenticationRequired(statusCode: response.statusCode)
            case 300..<400:
                throw DicomJPIPTransportError.redirectRejected
            default:
                throw DicomJPIPTransportError.unexpectedHTTPStatus(response.statusCode)
            }
            guard response.body.count <= configuration.maximumResponseBytes else {
                throw DicomJPIPTransportError.responseTooLarge(limit: configuration.maximumResponseBytes)
            }
            if let contentEncoding = response.header(named: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               contentEncoding != "identity" {
                throw DicomJPIPTransportError.unsupportedContentEncoding(contentEncoding)
            }
            let mediaType = normalizedMediaType(response.header(named: "Content-Type"))
            guard let mediaType, try acceptedMediaTypes().contains(mediaType) else {
                throw DicomJPIPTransportError.unsupportedMediaType(mediaType)
            }
            if let layersHeader = response.header(named: "JPIP-layers") {
                guard let layers = Int(layersHeader.trimmingCharacters(in: .whitespacesAndNewlines)), layers > 0 else {
                    throw DicomJPIPTransportError.invalidResponseHeader("JPIP-layers")
                }
                guard layers <= configuration.maximumLayerCount else {
                    throw DicomJPIPTransportError.layerLimitExceeded(
                        limit: configuration.maximumLayerCount,
                        requested: layers
                    )
                }
            }
        }

        private func normalizedMediaType(_ value: String?) -> String? {
            value?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        private func orderedMediaTypes(_ types: Set<String>) -> [String] {
            ["image/jpp-stream", "image/jpt-stream", "image/jp2", "image/jph", "image/jphc"].filter { types.contains($0) }
        }

        private func acceptedMediaTypes() throws -> Set<String> {
            var normative: Set<String>
            switch request.transferSyntax {
            case nil, .jpipReferenced, .jpipReferencedDeflate:
                normative = ["image/jp2"]
            case .jpipHTJ2KReferenced, .jpipHTJ2KReferencedDeflate:
                normative = ["image/jph", "image/jphc"]
            case .some(let syntax):
                throw DicomJPIPTransportError.unsupportedTransferSyntax(syntax.rawValue)
            }
            switch request.streamMode {
            case .completeEntity: break
            case .jppStream: normative = ["image/jpp-stream"]
            case .jptStream: normative = ["image/jpt-stream"]
            case .negotiated: normative.formUnion(["image/jpp-stream", "image/jpt-stream"])
            }
            let accepted = normative.intersection(configuration.allowedResponseMediaTypes)
            guard !accepted.isEmpty else {
                throw DicomJPIPTransportError.invalidConfiguration("accepted media types for transfer syntax")
            }
            return accepted
        }
    }
}
