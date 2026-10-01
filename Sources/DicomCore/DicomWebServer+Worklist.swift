import Foundation
import CryptoKit

extension DicomWebServer {
    func worklist(_ request: DicomWebHTTPRequest, path: [String],
                  body: AsyncThrowingStream<Data, Error>) async throws -> DicomWebHTTPResponse {
        guard let service = unifiedProcedureSteps else { return notFound() }
        if path.first == "subscribers" { return notificationHandshake(request, path: path) }
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path == ["workitems"], request.method == .get { return try await worklistSearch(request, service: service, items: items) }
        var query: [String: String] = [:]
        for item in items {
            guard let value = item.value, query[item.name] == nil else { return error(400, "Invalid query parameters.") }
            query[item.name] = value
        }
        let uid = path.count > 1 ? path[1] : query["workitem"] ?? DicomDataSetWriter.makeUID()
        if !path.contains("subscribers") {
            _ = try await DicomRequestAuthorization.current?.check(request.method == .get ? .readMetadata : .workitemChange,
                .init(kind: .workitem, id: uid))
        }
        guard Self.workitemUIDIsValid(uid) else { return error(400, "Invalid Workitem UID.") }
        if path.count >= 3, path[2] == "subscribers" {
            return try await worklistSubscription(request, path: path, query: query, service: service)
        }
        if path.count == 2, request.method == .get {
            let result = try service.get(sopInstanceUID: uid)
            guard let dataSet = result.dataSet else { return try worklistMissing(request, uid: uid, service: service) }
            var response = try encode([dataSet], request: request)
            response.headers["Content-Location"] = baseURL(request).appendingPathComponent("workitems").appendingPathComponent(uid).absoluteString
            return response
        }
        let creating = path.count == 1 && request.method == .post
        let updating = path.count == 2 && request.method == .post
        let changing = path.count == 3 && path[2] == "state" && request.method == .put
        let canceling = path.count == 3 && path[2] == "cancelrequest" && request.method == .post
        guard creating || updating || changing || canceling else { return notFound() }
        let allowed = Set(creating ? ["workitem"] : updating ? ["transaction-uid"] : ["requester"])
        guard Set(query.keys).isSubset(of: allowed.union(["accept", "charset"])) else { return error(400, "Invalid query parameter.") }
        var bytes = Data()
        for try await chunk in body {
            guard chunk.count <= configuration.maximumRequestBodyBytes - bytes.count else { return error(413, "Payload too large.") }
            bytes.append(chunk)
        }
        var dataSet: DicomDataSet
        do { dataSet = try worklistPayload(bytes, request: request, optional: canceling) }
        catch let failure as DicomWebServerFailure { return error(failure.status, failure.message) }
        catch { return self.error(400, "Invalid Workitem payload.") }
        if !creating, try service.webWasDeleted(uid) { return try worklistMissing(request, uid: uid, service: service) }
        let supportedTags = Set(DicomUnifiedProcedureStepAttribute.table.filter { $0.path.count == 1 }.map(\.tag))
        let unsupportedAttributes = updating && dataSet.elements.contains { !supportedTags.contains($0.tag) }
        if unsupportedAttributes { dataSet = .init(elements: dataSet.elements.filter { supportedTags.contains($0.tag) }) }
        let result: DicomUnifiedProcedureStepTransition
        let operation: String
        var transactionUID: String?
        if creating {
            guard service.webCreateViolations(dataSet).isEmpty else { return error(400, "Missing required Type 2 Workitem attributes.") }
            guard dataSet[0x00080018] == nil, dataSet[0x00001000] == nil else { return error(400, "Affected SOP Instance UID shall not be present.") }
            result = try await service.create(sopInstanceUID: uid, attributes: dataSet)
            var response = worklistStatus(result.status, operation: "create", request: request)
            if response.statusCode == 201 {
                response.headers["Location"] = baseURL(request).appendingPathComponent("workitems").appendingPathComponent(uid).absoluteString
                if !upsValued(dataSet[0x00741202]) { response.headers["Warning"] = worklistWarning("The Workitem was created with modifications.", request) }
            }
            return response
        } else if updating {
            guard dataSet[0x00081195] == nil else { return error(400, "Transaction UID belongs in the query parameter.") }
            transactionUID = query["transaction-uid"]
            if let transactionUID { dataSet.set(upsString(0x00081195, transactionUID, .UI)) }
            result = try await service.set(sopInstanceUID: uid, attributes: dataSet)
            operation = "update"
        } else if changing {
            guard let state = DicomUnifiedProcedureStepState(rawValue: dataSet.string(for: 0x00741000) ?? ""),
                  dataSet.elements.allSatisfy({ [0x00081195, 0x00741000].contains($0.tag) }) else { return error(400, "Invalid change state payload.") }
            transactionUID = dataSet.string(for: 0x00081195)
            result = try await DicomWebWorklistContext.$requester.withValue(query["requester"]) {
                try await service.changeState(sopInstanceUID: uid, to: state, transactionUID: transactionUID)
            }
            operation = "state"
        } else {
            guard dataSet.elements.allSatisfy({ [0x00741238, 0x0074100A, 0x0074100C, 0x0074100E].contains($0.tag) }) else { return error(400, "Invalid cancellation payload.") }
            result = try await service.requestCancel(sopInstanceUID: uid, requestingAE: query["requester"] ?? "DICOMWEB", information: dataSet)
            operation = "cancel"
        }
        if result.status == 0xC307 { return try worklistMissing(request, uid: uid, service: service) }
        var status = result.status
        if updating && status == 0 {
            if unsupportedAttributes { status = 1 }
            else if dataSet.elements.contains(where: { $0.tag != 0x00081195 && result.record?.attributes[$0.tag] != $0 }) { status = 0xB300 }
        }
        return worklistStatus(status, operation: operation, request: request, transactionUID: transactionUID)
    }

    func worklistPayload(_ bytes: Data, request: DicomWebHTTPRequest, optional: Bool) throws -> DicomDataSet {
        if optional && bytes.isEmpty { return .init() }
        guard let header = request.headers.dicomWebHeaderValue("Content-Type"),
              let type = try? DicomWebMediaType(header) else { throw DicomWebServerFailure(415, "Unsupported Content-Type.") }
        let sets: [DicomDataSet]
        if type.type == "application/dicom+json" {
            let decoded = try DicomJSONCodec.decode(bytes)
            guard decoded.allSatisfy({ $0.bulkData.isEmpty }) else { throw DicomWebError(kind: .badRequest) }
            sets = decoded.map(\.dataSet)
        } else if type.type == "multipart/related", type.parameters["type"] == "application/dicom+xml" {
            let parts = try DicomWebMultipartStreamParser.parts(from: bytes, contentType: header, limits: configuration.multipartLimits)
            guard parts.count == 1, try DicomWebMediaType(parts[0].contentType ?? "").type == "application/dicom+xml" else { throw DicomWebError(kind: .badRequest) }
            let decoded = try DicomNativeXMLCodec.decode(parts[0].body)
            guard decoded.bulkData.isEmpty else { throw DicomWebError(kind: .badRequest) }
            sets = [decoded.dataSet]
        } else { throw DicomWebServerFailure(415, "Unsupported Content-Type.") }
        guard sets.count == 1 else { throw DicomWebError(kind: .badRequest) }
        return sets[0]
    }

    func worklistWarning(_ text: String, _ request: DicomWebHTTPRequest) -> String {
        "299 \(baseURL(request).absoluteString): \(text)"
    }

    func worklistStatus(_ status: UInt16, operation: String, request: DicomWebHTTPRequest,
                        transactionUID: String? = nil) -> DicomWebHTTPResponse {
        let success = operation == "create" || operation == "subscribe" ? 201 : operation == "cancel" ? 202 : 200
        var code = success
        var warning: String?
        switch status {
        case 0: break
        case 0xB300: warning = "The Workitem was \(operation == "create" ? "created" : "updated") with modifications."
        case 1: warning = "Requested optional Attributes are not supported."
        case 0xB301: warning = "Deletion Lock not granted."
        case 0xB304: warning = "The UPS is already in the requested state of CANCELED."
        case 0xB306: warning = "The UPS is already in the requested state of COMPLETED."
        case 0x0111: code = 409
        case 0xC307: code = 404
        case 0xC308, 0xC315: code = 403
        case 0xC301:
            code = 400
            warning = transactionUID?.isEmpty == false ? "The Transaction UID is incorrect." : "The Transaction UID is missing."
        case 0xC300, 0xC302, 0xC303, 0xC304, 0xC310, 0xC311, 0xC312, 0xC313:
            code = operation == "update" && status == 0xC300 ? 400 : 409
            warning = status == 0xC310 ? "The Target URI did not reference a claimed Workitem." : "The submitted request is inconsistent with the current state of the Workitem."
        default: code = 400
        }
        var response = DicomWebHTTPResponse(statusCode: code)
        if let warning { response.headers["Warning"] = worklistWarning(warning, request) }
        if code >= 400 {
            response.headers["X-DICOMweb-Error-Code"] = (code == 404 ? DicomWebServerErrorCode.workitemNotFound : code == 409 ? .workitemConflict : .invalidWorkitem).rawValue
        }
        return response
    }

    func worklistMissing(_ request: DicomWebHTTPRequest, uid: String,
                         service: DicomUnifiedProcedureStepService) throws -> DicomWebHTTPResponse {
        let deleted = try service.webWasDeleted(uid)
        return error(deleted ? 410 : 404, deleted ? "Workitem deleted." : "Unknown Workitem.",
                     headers: ["X-DICOMweb-Error-Code": (deleted ? DicomWebServerErrorCode.workitemDeleted : .workitemNotFound).rawValue])
    }

    static func workitemUIDIsValid(_ uid: String) -> Bool {
        !uid.isEmpty && uid.utf8.count <= 64 && uid.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0")
        }
    }

    func worklistSearch(_ request: DicomWebHTTPRequest, service: DicomUnifiedProcedureStepService,
                        items: [URLQueryItem]) async throws -> DicomWebHTTPResponse {
        let parameters = try DicomWebSearchParameters.parse(queryItems: items, vrForAttribute: Self.worklistVR)
        let keys = try Self.worklistKeys(parameters)
        var matches = try service.store.search(matching: keys)
        if let access = DicomRequestAuthorization.current {
            var permitted: Set<String> = []
            for record in matches {
                if try await access.check(.query, .init(kind: .workitem, id: record.sopInstanceUID), filtering: true) {
                    permitted.insert(record.sopInstanceUID)
                }
            }
            matches.removeAll { !permitted.contains($0.sopInstanceUID) }
        }
        let remaining = Array(matches.dropFirst(min(parameters.offset ?? 0, matches.count)))
        let selected = Array(remaining.prefix(parameters.limit ?? remaining.count))
        guard selected.count <= configuration.maximumSearchResults else { return error(413, "Worklist search exceeds the configured limit.") }
        var tags = Set(DicomUnifiedProcedureStepAttribute.table.filter { $0.path.count == 1 && ($0.returned.hasPrefix("1") || $0.returned.hasPrefix("2")) }.map(\.tag))
        for name in parameters.includeFields + parameters.matches.map(\.attribute) where name != "all" {
            guard let tag = Self.worklistTag(name) else { throw DicomWebError(kind: .badRequest) }
            tags.insert(tag)
        }
        let sets = selected.map { record in
            var result = DicomDataSet(elements: record.attributes.elements.filter {
                $0.tag != 0x00081195 && (parameters.includeFields.contains("all") || tags.contains($0.tag))
            })
            for row in DicomUnifiedProcedureStepAttribute.table where row.path.count == 1 && row.returned == "2" && result[row.tag] == nil {
                if let code = DCMDictionary().vrCode(forTag: row.tag), let vr = DicomVR(code: code) {
                    result.set(.init(tag: row.tag, vr: vr, value: .empty))
                }
            }
            return result
        }
        var response = try encode(sets, request: request)
        if parameters.fuzzyMatching == true {
            response.headers["Warning"] = worklistWarning("The fuzzymatching parameter is not supported. Only literal matching has been performed.", request)
        }
        return response
    }

    static func worklistTag(_ name: String) -> Int? {
        DicomWebSearchAttributes.tag(name) ?? DicomUnifiedProcedureStepAttribute.table.first {
            $0.name.filter { $0.isLetter || $0.isNumber } == name
        }?.tag
    }
    static func worklistVR(_ name: String) -> DicomVR? {
        guard let tag = worklistTag(name), tag != 0x00081195,
              let vr = DCMDictionary().vrCode(forTag: tag) else { return nil }
        return DicomVR(code: vr)
    }
    static func worklistKeys(_ parameters: DicomWebSearchParameters) throws -> DicomDataSet {
        try .init(elements: parameters.matches.map {
            guard let tag = worklistTag($0.attribute) else { throw DicomWebError(kind: .badRequest) }
            return .init(tag: tag, vr: $0.vr, value: .strings($0.values))
        })
    }

    func worklistSubscription(_ request: DicomWebHTTPRequest, path: [String], query: [String: String],
                              service: DicomUnifiedProcedureStepService) async throws -> DicomWebHTTPResponse {
        guard path.count == 4 || (path.count == 5 && path[4] == "suspend") else { return notFound() }
        let uid = path[1], ae = path[3]
        guard !ae.isEmpty, ae.utf8.count <= 16, !ae.contains("\\") else { return error(400, "Invalid AE Title.") }
        let global = uid == DicomUnifiedProcedureStepService.globalUID || uid == DicomUnifiedProcedureStepService.filteredUID
        let filtered = uid == DicomUnifiedProcedureStepService.filteredUID
        let result: DicomUnifiedProcedureStepTransition
        if request.method == .post && path.count == 4 {
            guard Set(query.keys).isSubset(of: ["deletionlock", "filter", "accept", "charset"]),
                  query["deletionlock"] == nil || ["true", "false"].contains(query["deletionlock"]!),
                  filtered || query["filter"] == nil else { return error(400, "Invalid subscription parameters.") }
            guard authorizeWorklistSubscription(ae) else { return error(403, "Subscription refused.") }
            if filtered && !configuration.supportsFilteredWorklistSubscriptions {
                return error(403, "Filtered subscriptions refused.", headers: ["Warning": worklistWarning("Filtered Worklist Subscriptions are not supported.", request)])
            }
            var keys: DicomDataSet?
            if filtered {
                guard let filter = query["filter"], !filter.isEmpty else { return error(400, "Missing filter.") }
                let items = try filter.components(separatedBy: ",").map { pair -> URLQueryItem in
                    let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard fields.count == 2 else { throw DicomWebError(kind: .badRequest) }
                    return .init(name: String(fields[0]), value: String(fields[1]))
                }
                keys = try Self.worklistKeys(.parse(queryItems: items, vrForAttribute: Self.worklistVR))
            }
            result = try await service.subscribe(sopInstanceUID: uid, receivingAE: ae, deletionLock: query["deletionlock"] == "true", matchingKeys: keys)
            var response = worklistStatus(result.status, operation: "subscribe", request: request)
            if response.statusCode == 201 { response.headers["Content-Location"] = notificationURL(request, ae: ae).absoluteString }
            return response
        }
        guard query.isEmpty else { return error(400, "Unexpected query parameters.") }
        guard service.webHasSubscription(uid, ae: ae) else { return error(404, "Unknown subscription.") }
        if request.method == .delete && path.count == 4 {
            result = try await service.unsubscribe(sopInstanceUID: uid, receivingAE: ae)
        } else if request.method == .post && path.count == 5 && global {
            result = try await service.suspend(receivingAE: ae)
        } else { return notFound() }
        return worklistStatus(result.status, operation: "unsubscribe", request: request)
    }

    func notificationURL(_ request: DicomWebHTTPRequest, ae: String) -> URL {
        var components = URLComponents(url: baseURL(request).appendingPathComponent("subscribers").appendingPathComponent(ae), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    func notificationHandshake(_ request: DicomWebHTTPRequest, path: [String]) -> DicomWebHTTPResponse {
        guard request.method == .get, path.count == 2, notifications != nil,
              !path[1].isEmpty, path[1].utf8.count <= 16, request.url.query == nil,
              request.body?.isEmpty != false,
              request.headers.dicomWebHeaderValue("Content-Length").map({ $0 == "0" }) ?? true,
              request.headers.dicomWebHeaderValue("Transfer-Encoding") == nil,
              request.headers.dicomWebHeaderValue("Content-Type")?.lowercased() == "application/dicom+json",
              let origin = request.headers.dicomWebHeaderValue("Origin"), URL(string: origin)?.host != nil,
              request.headers.dicomWebHeaderValue("Upgrade")?.lowercased() == "websocket",
              request.headers.dicomWebHeaderValue("Connection")?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              request.headers.dicomWebHeaderValue("Sec-WebSocket-Version") == "13",
              let key = request.headers.dicomWebHeaderValue("Sec-WebSocket-Key"), Data(base64Encoded: key)?.count == 16 else {
            return error(400, "Invalid WebSocket handshake.")
        }
        guard authorizeWorklistSubscription(path[1]) else { return error(403, "Subscription refused.") }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var headers = ["Upgrade": "websocket", "Connection": "Upgrade", "Sec-WebSocket-Accept": accept]
        if let origin = request.headers.dicomWebHeaderValue("Origin") { headers["Origin"] = origin }
        if let protocols = request.headers.dicomWebHeaderValue("Sec-WebSocket-Protocol") {
            guard protocols.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "dicom" }) else { return error(400, "Unsupported WebSocket subprotocol.") }
            headers["Sec-WebSocket-Protocol"] = "dicom"
        }
        return .init(statusCode: 101, headers: headers)
    }
}
