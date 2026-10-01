import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DicomAuditMessageJSON {
    public static func encode(_ event: DicomAuditEvent) throws -> Data {
        try DicomWebhookCanonicalJSON.encode(DicomAuditPHIMinimizer.minimize(event))
    }
    public static func decode(_ data: Data) throws -> DicomAuditEvent {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return DicomAuditPHIMinimizer.minimize(try decoder.decode(DicomAuditEvent.self, from: data))
    }

}

public enum DicomAuditMessageXML {
    public enum ValidationError: Error { case invalidStructure }
    public static func serialize(_ input: DicomAuditEvent) -> String {
        let event = DicomAuditPHIMinimizer.minimize(input)
        func escape(_ value: String) -> String {
            let valid = String(value.unicodeScalars.filter {
                $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                    || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
            })
            return valid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;").replacingOccurrences(of: "\n", with: "&#10;")
                .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\t", with: "&#9;")
        }
        func element(_ name: String, _ attributes: [(String, String?)], _ body: String = "") -> String {
            let attrs = attributes.compactMap { key, value in value.map { " \(key)=\"\(escape($0))\"" } }.joined()
            return body.isEmpty ? "<\(name)\(attrs)/>" : "<\(name)\(attrs)>\(body)</\(name)>"
        }
        func code(_ name: String, _ code: DicomAuditCode) -> String {
            element(name, [("csd-code", code.code), ("codeSystemName", code.codeSystem),
                           ("originalText", code.displayName)])
        }
        let identification = event.eventIdentification
        var body = element("EventIdentification", [("EventActionCode", identification.eventActionCode.rawValue),
            ("EventDateTime", ISO8601DateFormatter().string(from: identification.eventDateTime)),
            ("EventOutcomeIndicator", String(identification.eventOutcomeIndicator.rawValue))],
            code("EventID", identification.eventID) + identification.eventTypeCode.map { code("EventTypeCode", $0) }.joined())
        for participant in event.activeParticipants {
            body += element("ActiveParticipant", [("UserID", participant.userID),
                ("AlternativeUserID", participant.alternativeUserID), ("UserIsRequestor", String(participant.userIsRequestor)),
                ("NetworkAccessPointID", participant.networkAccessPointID),
                ("NetworkAccessPointTypeCode", participant.networkAccessPointTypeCode.map(String.init))],
                participant.roleIDCode.map { code("RoleIDCode", $0) }.joined())
        }
        body += element("AuditSourceIdentification", [("AuditSourceID", event.auditSource.auditSourceID),
            ("AuditEnterpriseSiteID", event.auditSource.enterpriseSiteID)],
            event.auditSource.typeCode.map { code("AuditSourceTypeCode", $0) }.joined())
        for object in event.participantObjects {
            var contents = code("ParticipantObjectIDTypeCode", object.idTypeCode)
            // The schema requires Name OR Query. An empty Name satisfies it without retaining a patient's name.
            contents += object.objectQuery.map { element("ParticipantObjectQuery", [], $0.base64EncodedString()) }
                ?? element("ParticipantObjectName", [])
            for detail in object.objectDetail {
                contents += element("ParticipantObjectDetail", [("type", detail.type), ("value", detail.value.base64EncodedString())])
            }
            body += element("ParticipantObjectIdentification", [("ParticipantObjectID", object.objectID),
                ("ParticipantObjectTypeCode", String(object.typeCode)),
                ("ParticipantObjectTypeCodeRole", String(object.typeCodeRole))], contents)
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + element("AuditMessage", [], body) + "\n"
    }

    /// Structural validation of the supported PS3.15 model, not a general-purpose Relax NG validator.
    public static func validate(_ data: Data) throws { _ = try parse(data) }
    public static func parse(_ data: Data) throws -> DicomAuditEvent {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw ValidationError.invalidStructure
        }
        let delegate = AuditXMLReader()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root else { throw ValidationError.invalidStructure }
        return try delegate.event(root)
    }
}

private final class AuditXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [AuditXMLNode] = []
    var text = ""
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func required(_ name: String) throws -> String {
        guard let value = attributes[name], !value.isEmpty else { throw DicomAuditMessageXML.ValidationError.invalidStructure }
        return value
    }
    func check(attributes allowed: Set<String>, children names: Set<String>, textAllowed: Bool = false) throws {
        guard Set(attributes.keys).isSubset(of: allowed), children.allSatisfy({ names.contains($0.name) }),
              textAllowed || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomAuditMessageXML.ValidationError.invalidStructure
        }
    }
}

private final class AuditXMLReader: NSObject, XMLParserDelegate {
    var root: AuditXMLNode?
    var stack: [AuditXMLNode] = []
    var failed = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 8 else { failed = true; parser.abortParsing(); return }
        let node = AuditXMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node } else { failed = true; parser.abortParsing() }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func event(_ root: AuditXMLNode) throws -> DicomAuditEvent {
        let invalid = DicomAuditMessageXML.ValidationError.invalidStructure
        try root.check(attributes: [], children: ["EventIdentification", "ActiveParticipant", "AuditSourceIdentification", "ParticipantObjectIdentification"])
        guard root.name == "AuditMessage", root.children.first?.name == "EventIdentification" else { throw invalid }
        let events = root.children.filter { $0.name == "EventIdentification" }
        let participants = root.children.filter { $0.name == "ActiveParticipant" }
        let sources = root.children.filter { $0.name == "AuditSourceIdentification" }
        let objects = root.children.filter { $0.name == "ParticipantObjectIdentification" }
        guard events.count == 1, !participants.isEmpty, sources.count == 1,
              root.children.map(\.name) == ["EventIdentification"] + participants.map(\.name) + sources.map(\.name) + objects.map(\.name) else { throw invalid }
        let e = events[0]
        try e.check(attributes: ["EventActionCode", "EventDateTime", "EventOutcomeIndicator"], children: ["EventID", "EventTypeCode"])
        guard let action = DicomAuditEvent.Action(rawValue: try e.required("EventActionCode")),
              let date = ISO8601DateFormatter().date(from: try e.required("EventDateTime")),
              let outcomeNumber = Int(try e.required("EventOutcomeIndicator")),
              let outcome = DicomAuditEvent.Outcome(rawValue: outcomeNumber),
              let id = e.children.first, id.name == "EventID", e.children.dropFirst().allSatisfy({ $0.name == "EventTypeCode" }) else { throw invalid }
        let s = sources[0]
        try s.check(attributes: ["AuditSourceID", "AuditEnterpriseSiteID"], children: ["AuditSourceTypeCode"])
        return try .init(eventIdentification: .init(eventID: code(id), eventActionCode: action, eventDateTime: date,
            eventOutcomeIndicator: outcome, eventTypeCode: e.children.dropFirst().map(code)),
            activeParticipants: participants.map { p in
                try p.check(attributes: ["UserID", "AlternativeUserID", "UserIsRequestor", "NetworkAccessPointID", "NetworkAccessPointTypeCode"], children: ["RoleIDCode"])
                let requestor = try p.required("UserIsRequestor")
                guard ["true", "false", "1", "0"].contains(requestor) else { throw invalid }
                var networkType: Int?
                if let raw = p.attributes["NetworkAccessPointTypeCode"] {
                    guard let number = Int(raw), (1...5).contains(number) else { throw invalid }; networkType = number
                }
                return .init(userID: try p.required("UserID"), alternativeUserID: p.attributes["AlternativeUserID"],
                    userIsRequestor: ["true", "1"].contains(requestor), roleIDCode: try p.children.map(code),
                    networkAccessPointID: p.attributes["NetworkAccessPointID"], networkAccessPointTypeCode: networkType)
            }, auditSource: .init(auditSourceID: s.required("AuditSourceID"), enterpriseSiteID: s.attributes["AuditEnterpriseSiteID"],
                                 typeCode: s.children.map(code)), participantObjects: objects.map { o in
                try o.check(attributes: ["ParticipantObjectID", "ParticipantObjectTypeCode", "ParticipantObjectTypeCodeRole"],
                    children: ["ParticipantObjectIDTypeCode", "ParticipantObjectName", "ParticipantObjectQuery", "ParticipantObjectDetail"])
                guard let type = Int(try o.required("ParticipantObjectTypeCode")), (1...4).contains(type),
                      let role = Int(try o.required("ParticipantObjectTypeCodeRole")), (1...26).contains(role),
                      o.children.count >= 2, o.children[0].name == "ParticipantObjectIDTypeCode",
                      ["ParticipantObjectName", "ParticipantObjectQuery"].contains(o.children[1].name),
                      o.children.dropFirst(2).allSatisfy({ $0.name == "ParticipantObjectDetail" }) else { throw invalid }
                let content = o.children[1]; try content.check(attributes: [], children: [], textAllowed: true)
                let query = content.name == "ParticipantObjectQuery" ? Data(base64Encoded: content.text) : nil
                if content.name == "ParticipantObjectQuery" && query == nil { throw invalid }
                return .init(objectID: try o.required("ParticipantObjectID"), typeCode: type, typeCodeRole: role,
                    idTypeCode: try code(o.children[0]), objectName: content.name == "ParticipantObjectName" && !content.text.isEmpty ? content.text : nil,
                    objectQuery: query, objectDetail: try o.children.dropFirst(2).map { d in
                        try d.check(attributes: ["type", "value"], children: [])
                        guard let raw = d.attributes["value"], let value = Data(base64Encoded: raw) else { throw invalid }
                        return .init(type: try d.required("type"), value: value)
                    })
            })
    }
    private func code(_ node: AuditXMLNode) throws -> DicomAuditCode {
        try node.check(attributes: ["csd-code", "codeSystemName", "originalText", "displayName"], children: [])
        return try .init(node.required("csd-code"), node.required("codeSystemName"), node.required("originalText"))
    }
}
