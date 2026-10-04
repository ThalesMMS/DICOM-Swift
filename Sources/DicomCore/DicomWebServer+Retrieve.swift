import Foundation

extension DicomWebServer {
    func retrieve(_ request: DicomWebHTTPRequest, path: [String]) async throws -> DicomWebHTTPStreamedResponse {
        guard path.count >= 2, path[0] == "studies" else { return streamed(notFound()) }
        let study = path[1]
        var series: String?, instance: String?
        var index = 2
        if path.count >= 4, path[2] == "series" { series = path[3]; index = 4 }
        if path.count >= 6, index == 4, path[4] == "instances" { instance = path[5]; index = 6 }
        let suffix = Array(path.dropFirst(index))
        if suffix == ["metadata"] {
            var sets = try await storage.metadata(study: study, series: series, instance: instance)
            if let access = DicomRequestAuthorization.current {
                var allowed: [DicomDataSet] = []
                for set in sets {
                    guard let resource = DicomResourceRef.dataSet(set) else {
                        if access.authorizer == nil { allowed.append(set) }; continue
                    }
                    if try await access.check(.readMetadata, resource, filtering: true) { allowed.append(set) }
                }
                sets = allowed
            }
            if sets.isEmpty {
                return streamed(DicomRequestAuthorization.current?.authorizer == nil
                    ? notFound() : try encode([], request: request))
            }
            // Only server-owned opaque routes are emitted; the provider receives a logical key, never a filesystem path.
            let root = baseURL(request)
            var response = DicomWebHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/dicom+json"])
            var encoded: [DicomDataSet] = []
            for set in sets {
                guard set.string(for: .studyInstanceUID) != nil, set.string(for: .seriesInstanceUID) != nil,
                      set.string(for: .sopInstanceUID) != nil else { throw DicomWebServerFailure(500, "Metadata lacks identity.") }
                encoded.append(set)
            }
            // Encode separately to keep each instance's bulk references associated with its identity.
            let requestedType = request.headers.dicomWebHeaderValue("Accept")
            let metadataAccept = requestedType == "application/dicom+xml"
                ? "multipart/related; type=\"application/dicom+xml\"" : requestedType
            let selection = try DicomWebMediaTypeNegotiator.select(accept: metadataAccept, resource: .metadata,
                available: [.init("application/dicom+json"), .init("application/dicom+xml", multipart: true)]
                    .filter { configuration.supportedMediaTypes.contains($0.mediaType) })
            var documents: [Data] = []
            for set in encoded {
                let identity = [set.string(for: .studyInstanceUID)!, set.string(for: .seriesInstanceUID)!,
                                set.string(for: .sopInstanceUID)!].joined(separator: "/")
                let threshold = configuration.inlineBinaryThresholdBytes
                let options = DicomDataSetRepresentation.EncodingOptions(binary: .reference { path, element in
                    let alwaysBulk = [0x7FE00010, 0x7FE00008, 0x7FE00009, 0x56000020, 0x54001010, 0x00420011].contains(element.tag)
                        || (element.tag & 0xFFE1FFFF) == 0x60003000
                    guard alwaysBulk || (try? DicomDataSetRepresentation.binaryValueBytes(of: element).count).map({ $0 > threshold }) == true else { return nil }
                    let components = path.map { component -> String in
                        switch component {
                        case .tag(let tag): return String(format: "%08X", tag)
                        case .item(let index): return String(index)
                        case .frame(let index): return String(index)
                        }
                    }
                    return root.appendingPathComponent("bulkdata")
                        .appendingPathComponent(Self.token(identity + "/" + components.joined(separator: "/"))).absoluteString
                })
                if selection.multipart { documents += try DicomNativeXMLCodec.encodeDocuments([set], options: options) }
                else { documents.append(try DicomJSONCodec.encode([set], options: options)) }
            }
            if selection.multipart { response = try multipart(documents.map { ("application/dicom+xml", nil, $0) }) }
            else {
                let objects = try documents.flatMap { try JSONSerialization.jsonObject(with: $0) as! [Any] }
                response.body = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
            }
            return streamed(response)
        }
        if suffix == ["thumbnail"] || suffix == ["rendered"] || suffix.first == "frames" {
            let stored: DicomWebStoredInstance
            if let series, let instance { stored = try await storage.frames(study: study, series: series, instance: instance) }
            else {
                guard suffix == ["thumbnail"], let set = try await storage.metadata(study: study, series: series, instance: nil).first,
                      let r = set.string(for: .seriesInstanceUID), let i = set.string(for: .sopInstanceUID) else { return streamed(notFound()) }
                stored = try await storage.frames(study: study, series: r, instance: i)
            }
            _ = try await DicomRequestAuthorization.current?.check(.readBytes,
                .instance(study: stored.studyInstanceUID, series: stored.seriesInstanceUID, instance: stored.sopInstanceUID))
            let isRaw = suffix.count == 2 && suffix[0] == "frames"
            guard isRaw || suffix == ["thumbnail"] || suffix == ["rendered"]
                || (suffix.count == 3 && suffix[0] == "frames" && suffix[2] == "rendered") else { return streamed(notFound()) }
            let handler = DicomWebFrameRouteHandler(configuration: configuration, instance: stored)
            // Frame parts echo the requested URL as Content-Location, so it has to be the public one.
            var request = request
            request.url = publicURL(request)
            let list = suffix.first == "frames" ? suffix[1] : "1"
            var response = isRaw ? handler.retrieveRaw(studyInstanceUID: study, seriesInstanceUID: stored.seriesInstanceUID,
                sopInstanceUID: stored.sopInstanceUID, frameList: list, request: request)
                : handler.retrieveRendered(studyInstanceUID: study, seriesInstanceUID: stored.seriesInstanceUID,
                    sopInstanceUID: stored.sopInstanceUID, frameList: list, request: request)
            if let type = response.headers["Content-Type"], let media = try? DicomWebMediaType(type),
               response.statusCode == 200, !configuration.supportedMediaTypes.contains(media.parameters["type"] ?? media.type) {
                response = error(406, "Media type disabled by configuration.")
            }
            if !isRaw, response.statusCode == 422 { response.statusCode = 406 }
            return streamed(response)
        }
        guard suffix.isEmpty else { return streamed(notFound()) }
        let sets = try await storage.metadata(study: study, series: series, instance: instance)
        guard !sets.isEmpty else { throw DicomWebServerFailure(404, "Resource not found.") }
        var parts: [DicomWebInstancePlan] = []
        for set in sets {
            guard let r = set.string(for: .seriesInstanceUID), let i = set.string(for: .sopInstanceUID) else {
                throw DicomWebServerFailure(500, "Metadata lacks identity.")
            }
            let resource = DicomResourceRef.instance(study: set.string(for: .studyInstanceUID) ?? study, series: r, instance: i)
            _ = try await DicomRequestAuthorization.current?.check(.readBytes, resource)
            let stored = try await storage.instance(study: study, series: r, instance: i)
            if let resolver = representationResolver,
               let archive = try await resolver.representations(for: i) {
                guard archive.original.contentSHA256 == DicomArchiveRepresentation.hash(stored.part10Data) else {
                    throw DicomRepresentationRefusal.sourceChanged
                }
                let storedRepresentations = archive.representations.filter {
                    guard case .stored = $0.availability, $0.kind != .lossyDerived else { return false }
                    return configuration.supportedMediaTypes.contains("application/dicom")
                }
                let available = storedRepresentations.map {
                    DicomWebMediaTypeNegotiator.Representation("application/dicom",
                        transferSyntaxUID: $0.transferSyntax.rawValue, multipart: true)
                }
                if let representation = try? DicomWebMediaTypeNegotiator.select(
                    accept: request.headers.dicomWebHeaderValue("Accept"), resource: .instance,
                    available: available, storedSyntaxUID: stored.transferSyntax.rawValue,
                    storedSyntaxUIDs: Set(storedRepresentations.map { $0.transferSyntax.rawValue })),
                   let syntax = representation.transferSyntaxUID.flatMap(DicomTransferSyntax.init(rawValue:)) {
                    let decision = try DicomRepresentationSelector.select(set: archive,
                        peer: .init(acceptedTransferSyntaxes: [syntax]), policy: .losslessEquivalents)
                    guard let selected = storedRepresentations.first(where: {
                        $0.contentSHA256 == decision.chosenRepresentation.contentSHA256
                    }) else { throw DicomRepresentationRefusal.missingBytes }
                    if let access = DicomRequestAuthorization.current, let authorizer = access.authorizer {
                        let authorized = DicomAuthorizedRepresentationAccess(representationID: selected.contentSHA256,
                            instance: resource)
                        let decision = await authorized.decide(principal: access.principal, authorizer: authorizer,
                                                               context: access.context)
                        guard decision.outcome == .allow else { throw DicomWebServerFailure(403, "Access denied.") }
                    }
                    parts.append(.init(study: study, series: r, instance: i, syntax: selected.transferSyntax.rawValue,
                                       archiveRepresentation: selected))
                    continue
                }
            }
            let available = ([stored.transferSyntax.rawValue] + (transcoding?.transferSyntaxUIDs ?? [])).map {
                DicomWebMediaTypeNegotiator.Representation("application/dicom", transferSyntaxUID: $0, multipart: true)
            }.filter { configuration.supportedMediaTypes.contains($0.mediaType) }
            let representation = try DicomWebMediaTypeNegotiator.select(accept: request.headers.dicomWebHeaderValue("Accept"),
                resource: .instance, available: available, storedSyntaxUID: stored.transferSyntax.rawValue, transcoding: transcoding)
            parts.append(.init(study: study, series: r, instance: i, syntax: representation.transferSyntaxUID!))
        }
        // Preflight the entire aggregate. PS3.18 2026c does not assign 206 to an incomplete set of instances.
        let producer = try DicomWebInstanceResponse(parts: parts, base: baseURL(request), storage: storage, transcoder: transcoding, resolver: representationResolver, access: DicomRequestAuthorization.current)
        return .init(statusCode: 200, headers: ["Content-Type": producer.contentType],
                     body: AsyncThrowingStream(unfolding: { try await producer.next() }))
    }

    static func token(_ key: String) -> String {
        Data(key.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func bulkData(_ request: DicomWebHTTPRequest, path: [String]) async throws -> DicomWebHTTPResponse {
        guard path.count == 2 else { return notFound() }
        var value = path[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: value), let key = String(data: bytes, encoding: .utf8), Self.token(key) == path[1] else { return notFound() }
        let components = key.split(separator: "/")
        guard components.count >= 4, components.count.isMultiple(of: 2), components.prefix(3).allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }),
              components.dropFirst(3).enumerated().allSatisfy({ index, value in
                  index.isMultiple(of: 2) ? value.count == 8 && Int(value, radix: 16) != nil
                    : !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
              }) else { return notFound() }
        let selection = try DicomWebMediaTypeNegotiator.select(accept: request.headers.dicomWebHeaderValue("Accept"), resource: .bulkdata,
            available: [.init("application/octet-stream"), .init("application/octet-stream", multipart: true)]
                .filter { configuration.supportedMediaTypes.contains($0.mediaType) })
        _ = try await DicomRequestAuthorization.current?.check(.readBytes,
            .instance(study: String(components[0]), series: String(components[1]), instance: String(components[2])))
        let data = try await storage.bulkData(uri: key)
        guard data.count <= configuration.multipartLimits.maximumPartBytes else {
            throw DicomWebServerFailure(413, "Bulk data exceeds the configured part limit.")
        }
        if selection.multipart { return try multipart([("application/octet-stream", publicURL(request).absoluteString, data)]) }
        return .init(statusCode: 200, headers: ["Content-Type": selection.contentType], body: data)
    }

    func wadoURI(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        guard value("requestType") == "WADO", let s = value("studyUID"), let r = value("seriesUID"), let i = value("objectUID") else {
            throw DicomWebServerFailure(400, "Invalid WADO-URI request.")
        }
        _ = try await DicomRequestAuthorization.current?.check(.readBytes, .instance(study: s, series: r, instance: i))
        let stored = try await storage.instance(study: s, series: r, instance: i)
        let type = value("contentType") ?? "image/jpeg"
        guard configuration.supportedMediaTypes.contains(type) else { throw DicomWebServerFailure(406, "Media type disabled.") }
        switch type {
        case "application/dicom": return .init(statusCode: 200, headers: ["Content-Type": "application/dicom"], body: stored.part10Data)
        case "image/jpeg":
            var rendered = request
            rendered.headers["Accept"] = "image/jpeg"
            // WADO-URI parameters are not rendered-RS parameters.
            rendered.url = baseURL(request).appendingPathComponent("studies/\(s)/series/\(r)/instances/\(i)/rendered")
            let handler = DicomWebFrameRouteHandler(configuration: configuration, instance: stored)
            var response = handler.retrieveRendered(studyInstanceUID: s, seriesInstanceUID: r, sopInstanceUID: i, frameList: "1", request: rendered)
            if response.statusCode == 422 { response.statusCode = 406 }
            return response
        default: throw DicomWebServerFailure(406, "Unsupported WADO-URI contentType.")
        }
    }
}

private struct DicomWebInstancePlan: Sendable {
    let study: String
    let series: String
    let instance: String
    let syntax: String
    var archiveRepresentation: DicomArchiveRepresentation? = nil
}

private actor DicomWebInstanceResponse {
    nonisolated let contentType: String
    private let parts: [DicomWebInstancePlan]
    private let storage: any DicomWebStorageProviding
    private let base: URL
    private let transcoder: (any DicomWebServerTranscoding)?
    private let resolver: (any DicomRepresentationResolving)?
    private var writer: DicomWebMultipartStreamWriter
    private var index = 0
    private var pending: [Data] = []
    private var finished = false
    private let access: DicomEnforcement?
    private var activeResource: DicomResourceRef?
    init(parts: [DicomWebInstancePlan], base: URL, storage: any DicomWebStorageProviding, transcoder: (any DicomWebServerTranscoding)?, resolver: (any DicomRepresentationResolving)?, access: DicomEnforcement? = nil) throws {
        self.access = access
        self.resolver = resolver
        self.parts = parts; self.base = base; self.storage = storage; self.transcoder = transcoder
        let boundary = "dicomweb-\(UUID().uuidString)"
        contentType = "multipart/related; type=\"application/dicom\"; boundary=\(boundary)"
        writer = try .init(boundary: boundary)
    }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        if !pending.isEmpty {
            if let activeResource { try await access?.recheck(.readBytes, activeResource) }
            return pending.removeFirst()
        }
        if finished { return nil }
        var output: [Data] = []
        if index < parts.count {
            let plan = parts[index]
            let resource = DicomResourceRef.instance(study: plan.study, series: plan.series, instance: plan.instance)
            activeResource = resource
            try await access?.recheck(.readBytes, resource)
            let instance = try await storage.instance(study: plan.study, series: plan.series, instance: plan.instance)
            let syntax = plan.syntax
            let data: Data
            if let representation = plan.archiveRepresentation, let resolver {
                guard let current = try await resolver.representations(for: instance.sopInstanceUID),
                      current.original.contentSHA256 == DicomArchiveRepresentation.hash(instance.part10Data),
                      current.representations.contains(representation) else { throw DicomRepresentationRefusal.sourceChanged }
                data = try await resolver.bytes(for: representation)
                guard DicomArchiveRepresentation.hash(data) == representation.contentSHA256 else {
                    throw DicomRepresentationRefusal.sourceChanged
                }
            } else if syntax == instance.transferSyntax.rawValue {
                data = instance.part10Data
            } else {
                guard let transcoder else {
                    throw DicomWebServerFailure(500, "Provider representation changed after negotiation.")
                }
                data = try await transcoder.transcode(instance, to: syntax)
            }
            let meta = try DicomPart10FileMetaParser.parse(data)
            guard meta.transferSyntaxUID == syntax, meta.mediaStorageSOPInstanceUID == instance.sopInstanceUID,
                  meta.mediaStorageSOPClassUID == instance.sopClassUID else {
                throw DicomWebServerFailure(500, "Provider representation contradicts its declared identity or syntax.")
            }
            try await access?.recheck(.readBytes, resource)
            try await access?.transferred(resource)
            let location = base.appendingPathComponent("studies/\(instance.studyInstanceUID)/series/\(instance.seriesInstanceUID)/instances/\(instance.sopInstanceUID)")
            try writer.beginPart(headers: [("Content-Type", "application/dicom; transfer-syntax=\(syntax)"),
                                           ("Content-Location", location.absoluteString)], contentLength: data.count) { output.append($0) }
            try writer.payload(data) { output.append($0) }
            try writer.endPart { output.append($0) }
            index += 1
        } else { try writer.finish { output.append($0) }; finished = true }
        pending = output
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}
