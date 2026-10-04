import Foundation

/// QIDO-RS attributes: any standard data element keyword or eight-digit hexadecimal tag from the dictionary.
enum DicomWebSearchAttributes {
    /// Query parameters with a meaning of their own; every other name is an attribute.
    static let reservedNames: Set<String> = ["limit", "offset", "includefield", "fuzzymatching"]
    /// Value representations that attribute value matching cannot compare.
    private static let unmatchable: Set<DicomVR> = [.SQ, .OB, .OD, .OF, .OL, .OV, .OW, .UN]

    static func tag(_ attribute: String) -> Int? {
        if attribute.count == 8, attribute.allSatisfy(\.isHexDigit) { return Int(attribute, radix: 16) }
        return DCMDictionary().tag(forKeyword: attribute)
    }
    static func vr(_ attribute: String) -> DicomVR? {
        guard let tag = tag(attribute), let code = DCMDictionary().vrCode(forTag: tag) else { return nil }
        return DicomVR(code: code)
    }
    /// Whether the attribute can be a matching key; sequences and binary values cannot.
    static func isMatchable(_ attribute: String) -> Bool {
        vr(attribute).map { !unmatchable.contains($0) } ?? false
    }
}

extension DicomWebServer {
    /// Parses a QIDO-RS request. Parameters naming no attribute this server can match are left out of the
    /// search and returned as `ignored`, so the response can report them with Warning 299, as PS3.18 asks.
    func searchParameters(_ request: DicomWebHTTPRequest,
                          path: [String]) throws -> (parameters: DicomWebSearchParameters, ignored: [String])? {
        let level: DicomWebSearchParameters.Level
        var study: String?, series: String?
        switch path {
        case ["studies"]: level = .study
        case ["series"]: level = .series
        case ["instances"]: level = .instance
        default:
            if path.count == 3, path[0] == "studies", ["series", "instances"].contains(path[2]) {
                study = path[1]; level = path[2] == "series" ? .series : .instance
            } else if path.count == 5, path[0] == "studies", path[2] == "series", path[4] == "instances" {
                study = path[1]; series = path[3]; level = .instance
            } else { return nil }
        }
        var items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var ignored: [String] = []
        items.removeAll { item in
            guard !DicomWebSearchAttributes.reservedNames.contains(item.name),
                  !DicomWebSearchAttributes.isMatchable(item.name) else { return false }
            if !ignored.contains(item.name) { ignored.append(item.name) }
            return true
        }
        var parameters = try DicomWebSearchParameters.parse(queryItems: items, level: level, studyInstanceUID: study,
                                                            seriesInstanceUID: series,
                                                            vrForAttribute: DicomWebSearchAttributes.vr)
        parameters.includeFields.removeAll { field in
            guard field != "all", DicomWebSearchAttributes.tag(field) == nil else { return false }
            if !ignored.contains(field) { ignored.append(field) }
            return true
        }
        return (parameters, ignored)
    }

    func search(_ request: DicomWebHTTPRequest, parameters: DicomWebSearchParameters,
                ignored: [String] = []) async throws -> DicomWebHTTPResponse {
        if parameters.fuzzyMatching == true, configuration.rejectUnsupportedFuzzyMatching {
            throw DicomWebServerFailure(400, "Fuzzy matching is not supported.")
        }
        if let access = DicomRequestAuthorization.current {
            try await access.audit?.record(DicomAuditMessages.queryPerformed(principal: access.principal,
                context: access.context))
        }
        let page = try await searchPage(parameters)
        var selected = page.sets
        let remaining = page.hasMore ? 1 : 0
        if !parameters.includeFields.contains("all") {
            var tags: Set<Int> = [0x00080005, 0x00080020, 0x00080030, 0x00080050, 0x00080061,
                                  0x00080090, 0x00100010, 0x00100020, 0x00100030, 0x00100040,
                                  0x0020000D, 0x00200010, 0x00201206, 0x00201208]
            if parameters.level != .study { tags.formUnion([0x00080060, 0x0020000E, 0x00200011, 0x00201209]) }
            if parameters.level == .instance { tags.formUnion([0x00080016, 0x00080018, 0x00200013, 0x00280010, 0x00280011]) }
            for attribute in parameters.includeFields + parameters.matches.map(\.attribute) {
                if let tag = DicomWebSearchAttributes.tag(attribute) { tags.insert(tag) }
            }
            selected = selected.map { DicomDataSet(elements: $0.elements.filter { tags.contains($0.tag) }) }
        }
        let cacheKey = request.url.absoluteString + String(describing: request.headers.sorted { $0.key < $1.key })
        if configuration.cacheEnabled, let cached = searchCache.get(cacheKey, sets: selected, remaining: remaining) { return cached }
        var response = try encode(selected, request: request)
        // The Search status table of PS3.18 answers a search without matches with 204 and no body,
        // whichever representation was negotiated.
        if selected.isEmpty { response = .init(statusCode: 204, body: Data()) }
        var warnings: [String] = []
        if page.hasMore { warnings.append("There are additional results that can be requested") }
        if parameters.fuzzyMatching == true {
            warnings.append("The fuzzymatching parameter is not supported. Only literal matching has been performed.")
        }
        for name in ignored {
            // Only short printable names are echoed; anything else could not travel safely in a quoted header value.
            let printable = name.count <= 64 && name.unicodeScalars.allSatisfy {
                (0x20..<0x7F).contains($0.value) && $0 != "\"" && $0 != "\\"
            }
            warnings.append(printable ? "Unsupported query parameter ignored: \(name)" : "An unsupported query parameter was ignored.")
        }
        if !warnings.isEmpty { response.headers["Warning"] = warnings.map { "299 \(baseURL(request).absoluteString) \"\($0)\"" }.joined(separator: ", ") }
        if configuration.cacheEnabled { searchCache.put(cacheKey, sets: selected, remaining: remaining, response: response) }
        return response
    }

    private func searchPage(_ parameters: DicomWebSearchParameters) async throws -> (sets: [DicomDataSet], hasMore: Bool) {
        let limit = max(0, min(parameters.limit ?? configuration.maximumSearchResults, configuration.maximumSearchResults))
        guard limit > 0 else { return ([], false) }
        let budget = configuration.maximumSearchCandidates
        var offset = max(0, parameters.offset ?? 0)
        let exhausted = DicomWebServerFailure(413, "Search exceeds the configured evaluation limit. Refine the query.")
        guard offset < budget else { throw exhausted }
        let access = DicomRequestAuthorization.current
        var selected: [DicomDataSet] = []
        var scanned = 0
        while scanned < budget {
            try Task.checkCancellation()
            var providerParameters = parameters
            // One authorized lookahead row proves that another page exists without counting every match.
            let pageSize = min(min(limit, 127) + 1, budget - scanned)
            providerParameters.limit = pageSize
            providerParameters.offset = scanned
            let candidates: [DicomDataSet]
            switch parameters.level {
            case .study: candidates = try await storage.searchStudies(parameters: providerParameters)
            case .series: candidates = try await storage.searchSeries(parameters: providerParameters)
            case .instance: candidates = try await storage.searchInstances(parameters: providerParameters)
            }
            guard candidates.count <= pageSize else {
                throw DicomWebServerFailure(503, "Search provider exceeded the requested page limit.")
            }
            scanned += candidates.count
            for set in candidates {
                try Task.checkCancellation()
                if let access {
                    if let resource = DicomResourceRef.dataSet(set) {
                        if try await !access.check(.query, resource, filtering: true) { continue }
                    } else if access.authorizer != nil { continue }
                }
                if offset > 0 { offset -= 1; continue }
                if selected.count == limit { return (selected, true) }
                selected.append(set)
            }
            if candidates.count < pageSize { return (selected, false) }
        }
        throw exhausted
    }

    func encode(_ sets: [DicomDataSet], request: DicomWebHTTPRequest,
                options: DicomDataSetRepresentation.EncodingOptions = .init(binary: .omit([0x7FE00010]))) throws -> DicomWebHTTPResponse {
        let selection = try DicomWebMediaTypeNegotiator.select(accept: request.headers.dicomWebHeaderValue("Accept"),
            resource: .metadata, available: [.init("application/dicom+json"), .init("application/dicom+xml", multipart: true)]
                .filter { configuration.supportedMediaTypes.contains($0.mediaType) })
        if selection.mediaType == "application/dicom+json" {
            var options = options
            options.decimals = configuration.jsonDecimals
            return .init(statusCode: 200, headers: ["Content-Type": selection.contentType], body: try DicomJSONCodec.encode(sets, options: options))
        }
        guard !sets.isEmpty else { return .init(statusCode: 204, body: Data()) }
        let documents = try DicomNativeXMLCodec.encodeDocuments(sets, options: options)
        return try multipart(documents.map { ("application/dicom+xml", nil, $0) })
    }

    func multipart(_ parts: [(String, String?, Data)]) throws -> DicomWebHTTPResponse {
        let boundary = "dicomweb-\(UUID().uuidString)"
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary)
        var body = Data()
        for (type, location, bytes) in parts {
            var headers = [("Content-Type", type)]
            if let location { headers.append(("Content-Location", location)) }
            try writer.beginPart(headers: headers, contentLength: bytes.count) { body.append($0) }
            try writer.payload(bytes) { body.append($0) }
            try writer.endPart { body.append($0) }
        }
        try writer.finish { body.append($0) }
        let type = parts.first?.0.components(separatedBy: ";").first ?? "application/dicom"
        return .init(statusCode: 200, headers: ["Content-Type": "multipart/related; type=\"\(type)\"; boundary=\(boundary)",
                                               "Content-Length": String(body.count)], body: body)
    }
}

final class DicomWebSearchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ([DicomDataSet], Int, DicomWebHTTPResponse)] = [:]
    func get(_ key: String, sets: [DicomDataSet], remaining: Int) -> DicomWebHTTPResponse? {
        lock.withLock {
            guard let entry = entries[key], entry.0 == sets, entry.1 == remaining else { return nil }
            var response = entry.2; response.headers["X-DICOMweb-Cache"] = "HIT"; return response
        }
    }
    func put(_ key: String, sets: [DicomDataSet], remaining: Int, response: DicomWebHTTPResponse) {
        lock.withLock { if entries.count >= 32 { entries.removeAll() }; entries[key] = (sets, remaining, response) }
    }
}
