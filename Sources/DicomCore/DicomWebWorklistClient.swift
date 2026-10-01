import Foundation

public struct DicomWebWorkitemResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let workitems: [DicomDataSet]
    public var location: URL? { headers.dicomWebHeaderValue("Location").flatMap(URL.init(string:)) }
    public var warning: String? { headers.dicomWebHeaderValue("Warning") }
}

public struct DicomWebSubscriptionResponse: Sendable {
    public let statusCode: Int
    public let notificationURL: URL
    public let warning: String?
}

extension DicomWebClient {
    public func createWorkitem(_ attributes: DicomDataSet, workitemUID: String? = nil) async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.post, path: ["workitems"], query: workitemUID.map { [.init(name: "workitem", value: $0)] } ?? [], attributes: attributes)
    }
    public func retrieveWorkitem(_ uid: String, accept: String = "application/dicom+json") async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.get, path: ["workitems", uid], accept: accept)
    }
    public func updateWorkitem(_ uid: String, attributes: DicomDataSet, transactionUID: String? = nil) async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.post, path: ["workitems", uid], query: transactionUID.map { [.init(name: "transaction-uid", value: $0)] } ?? [], attributes: attributes)
    }
    public func changeWorkitemState(_ uid: String, to state: DicomUnifiedProcedureStepState,
                                   transactionUID: String, requester: String? = nil) async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.put, path: ["workitems", uid, "state"], query: requester.map { [.init(name: "requester", value: $0)] } ?? [],
            attributes: .init(elements: [upsString(0x00081195, transactionUID, .UI), upsString(0x00741000, state.rawValue)]))
    }
    public func requestWorkitemCancellation(_ uid: String, information: DicomDataSet = .init(),
                                           requester: String? = nil) async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.post, path: ["workitems", uid, "cancelrequest"], query: requester.map { [.init(name: "requester", value: $0)] } ?? [], attributes: information)
    }
    public func searchWorkitems(_ parameters: DicomWebSearchParameters = .init()) async throws -> DicomWebWorkitemResponse {
        try await worklistRequest(.get, path: ["workitems"], query: parameters.queryItems())
    }
    public func subscribe(_ uid: String, subscriber: String, deletionLock: Bool = false,
                          filter: String? = nil) async throws -> DicomWebSubscriptionResponse {
        var query = [URLQueryItem(name: "deletionlock", value: String(deletionLock))]
        if let filter { query.append(.init(name: "filter", value: filter)) }
        let response = try await worklistRequest(.post, path: ["workitems", uid, "subscribers", subscriber], query: query)
        guard let location = response.headers.dicomWebHeaderValue("Content-Location"),
              let url = URL(string: location, relativeTo: configuration.baseURL)?.absoluteURL,
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else { throw DicomWebError(kind: .badRequest) }
        return .init(statusCode: response.statusCode, notificationURL: url, warning: response.warning)
    }
    public func unsubscribe(_ uid: String, subscriber: String) async throws -> DicomWebSubscriptionResponse {
        let response = try await worklistRequest(.delete, path: ["workitems", uid, "subscribers", subscriber])
        return .init(statusCode: response.statusCode, notificationURL: worklistNotificationURL(subscriber), warning: response.warning)
    }
    public func suspendWorklistSubscription(subscriber: String, filtered: Bool = false) async throws -> DicomWebSubscriptionResponse {
        let uid = filtered ? DicomUnifiedProcedureStepService.filteredUID : DicomUnifiedProcedureStepService.globalUID
        let response = try await worklistRequest(.post, path: ["workitems", uid, "subscribers", subscriber, "suspend"])
        return .init(statusCode: response.statusCode, notificationURL: worklistNotificationURL(subscriber), warning: response.warning)
    }
    private func worklistNotificationURL(_ ae: String) -> URL {
        var parts = URLComponents(url: configuration.baseURL.appendingPathComponent("subscribers").appendingPathComponent(ae), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        return parts.url!
    }
    private func worklistRequest(_ method: DicomWebHTTPMethod, path: [String], query: [URLQueryItem] = [],
                                 attributes: DicomDataSet? = nil, accept: String = "application/dicom+json") async throws -> DicomWebWorkitemResponse {
        var url = configuration.baseURL
        for component in path { url.appendPathComponent(component) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var headers = ["Accept": accept]
        if attributes != nil { headers["Content-Type"] = "application/dicom+json" }
        let response = try await send(method, url: parts.url!, headers: headers, body: attributes.map { try DicomJSONCodec.encode([$0]) })
        var sets: [DicomDataSet] = []
        if !response.body.isEmpty {
            let type = response.headers.dicomWebHeaderValue("Content-Type") ?? ""
            let mediaType = type.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
            if mediaType == "application/dicom+json" { sets = try DicomJSONCodec.decode(response.body).map(\.dataSet) }
            else if mediaType == "multipart/related" {
                sets = try DicomWebMultipartStreamParser.parts(from: response.body, contentType: type, limits: configuration.multipartLimits).map {
                    try DicomNativeXMLCodec.decode($0.body).dataSet
                }
            }
        }
        return .init(statusCode: response.statusCode, headers: response.headers, workitems: sets)
    }
}
