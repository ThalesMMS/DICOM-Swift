import Foundation

extension DicomWebServer {
    func capabilities(_ request: DicomWebHTTPRequest) throws -> DicomWebHTTPResponse {
        let accept = request.headers.dicomWebHeaderValue("Accept") ?? "application/json"
        let choices = DicomWebMediaType.split(accept, separator: ",").compactMap { try? DicomWebMediaType($0) }
            .sorted { (Double($0.parameters["q"] ?? "1") ?? 0) > (Double($1.parameters["q"] ?? "1") ?? 0) }
        let selected = choices.first { ["application/json", "application/vnd.sun.wadl+xml", "text/markdown", "text/plain", "*/*"].contains($0.type)
            && (Double($0.parameters["q"] ?? "1") ?? 0) > 0 }?.type
        guard let selected else { throw DicomWebError(kind: .notAcceptable) }
        if selected.hasPrefix("text/") {
            return .init(statusCode: 200, headers: ["Content-Type": "text/markdown"], body: Data(conformanceStatement.markdown.utf8))
        }
        var routes: [(String, [String])] = [
            ("studies", ["GET", "POST"]), ("studies/{study}", ["GET", "POST"]),
            ("series", ["GET"]), ("instances", ["GET"]), ("studies/{study}/series", ["GET"]),
            ("studies/{study}/instances", ["GET"]), ("studies/{study}/series/{series}", ["GET"]),
            ("studies/{study}/series/{series}/instances", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}", ["GET"]),
            ("studies/{study}/metadata", ["GET"]), ("studies/{study}/series/{series}/metadata", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}/metadata", ["GET"]),
            ("studies/{study}/thumbnail", ["GET"]), ("studies/{study}/series/{series}/thumbnail", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}/thumbnail", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}/rendered", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}/frames/{frames}", ["GET"]),
            ("studies/{study}/series/{series}/instances/{instance}/frames/{frames}/rendered", ["GET"]),
            ("bulkdata/{token}", ["GET"]), ("wado", ["GET"])
        ]
        if jpip != nil { routes.append(("jpip", ["GET"])) }
        if unifiedProcedureSteps != nil {
            routes += [
                ("workitems", ["GET", "POST"]), ("workitems/{workitem}", ["GET", "POST"]),
                ("workitems/{workitem}/state", ["PUT"]), ("workitems/{workitem}/cancelrequest", ["POST"])
            ]
            if notifications != nil {
                routes += [
                    ("workitems/{workitem}/subscribers/{subscriber}", ["POST", "DELETE"]),
                    ("workitems/1.2.840.10008.5.1.4.34.5/subscribers/{subscriber}/suspend", ["POST"]),
                    ("workitems/1.2.840.10008.5.1.4.34.5.1/subscribers/{subscriber}/suspend", ["POST"]),
                    ("subscribers/{requester}", ["GET"])
                ]
            }
        }
        let base = baseURL(request).absoluteString
        if selected == "application/vnd.sun.wadl+xml" {
            let resources = routes.map { path, methods in
                "<resource path=\"\(path)\">" + methods.map { "<method name=\"\($0)\"/>" }.joined() + "</resource>"
            }.joined()
            let xml = "<?xml version=\"1.0\"?><application xmlns=\"http://wadl.dev.java.net/2009/02\"><resources base=\"\(base.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;"))\">\(resources)</resources></application>"
            return .init(statusCode: 200, headers: ["Content-Type": selected], body: Data(xml.utf8))
        }
        var object: [String: Any] = ["application": ["resources": ["base": base,
            "resource": routes.map { ["path": $0.0, "method": $0.1.map { ["name": $0] }] }]],
            "mediaTypes": configuration.supportedMediaTypes, "fuzzyMatching": false,
            "maximumSearchResults": configuration.maximumSearchResults,
            "maximumRequestBodyBytes": configuration.maximumRequestBodyBytes]
        if unifiedProcedureSteps != nil, notifications != nil {
            object["notificationConnection"] = notificationURL(request, ae: "{requester}").absoluteString.replacingOccurrences(of: "%7B", with: "{").replacingOccurrences(of: "%7D", with: "}")
            object["notificationEncoding"] = "One application/dicom+json object per WebSocket text frame"
        }
        return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
