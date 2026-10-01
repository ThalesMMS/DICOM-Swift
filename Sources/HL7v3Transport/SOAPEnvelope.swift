import Foundation
import HL7v3CDA

/// SOAP 1.1 (RFC-less W3C Note) and SOAP 1.2 envelope namespaces and media types.
public enum SOAPVersion: String, Codable, CaseIterable, Sendable {
    case v1_1 = "1.1"
    case v1_2 = "1.2"

    public var namespace: String {
        switch self {
        case .v1_1: return "http://schemas.xmlsoap.org/soap/envelope/"
        case .v1_2: return "http://www.w3.org/2003/05/soap-envelope"
        }
    }

    /// SOAP 1.1 carries the action in the `SOAPAction` header; SOAP 1.2 carries it in the media type.
    public func contentType(action: String?) -> String {
        switch self {
        case .v1_1: return "text/xml; charset=utf-8"
        case .v1_2:
            guard let action, !action.isEmpty else { return "application/soap+xml; charset=utf-8" }
            return "application/soap+xml; charset=utf-8; action=\"\(action.replacingOccurrences(of: "\"", with: ""))\""
        }
    }

    static func detect(namespace: String) -> SOAPVersion? {
        allCases.first { $0.namespace == namespace }
    }
}

public enum SOAPEnvelopeError: Error, Equatable, Sendable {
    case notAnEnvelope
    case missingBody
    /// The body must carry exactly one payload element; `count` elements were present.
    case bodyPayloadCount(Int)
    case malformedFault
}

/// A SOAP fault in either version, normalized to code/reason plus the untouched detail subtree.
public struct SOAPFault: Equatable, Sendable {
    public var code: String
    public var reason: String
    public var detail: HL7v3CDA.XMLNode?

    public init(code: String, reason: String, detail: HL7v3CDA.XMLNode? = nil) {
        self.code = code
        self.reason = reason
        self.detail = detail
    }

    /// Serializes as a `Fault` element in the given version's namespace.
    public func node(version: SOAPVersion) -> HL7v3CDA.XMLNode {
        let ns = version.namespace
        switch version {
        case .v1_1:
            var children = [HL7v3CDA.XMLNode("faultcode", namespaceURI: "", text: code),
                            HL7v3CDA.XMLNode("faultstring", namespaceURI: "", text: reason)]
            if let detail { children.append(HL7v3CDA.XMLNode("detail", namespaceURI: "", children: [detail])) }
            return HL7v3CDA.XMLNode("Fault", namespaceURI: ns, prefix: "soap", children: children)
        case .v1_2:
            var text = HL7v3CDA.XMLNode("Text", namespaceURI: ns, prefix: "soap", text: reason)
            text.attributes[XMLName("lang", namespaceURI: CDANamespace.xml, prefix: "xml")] = "en"
            var children = [
                HL7v3CDA.XMLNode("Code", namespaceURI: ns, prefix: "soap", children: [HL7v3CDA.XMLNode("Value", namespaceURI: ns, prefix: "soap", text: code)]),
                HL7v3CDA.XMLNode("Reason", namespaceURI: ns, prefix: "soap", children: [text])
            ]
            if let detail { children.append(HL7v3CDA.XMLNode("Detail", namespaceURI: ns, prefix: "soap", children: [detail])) }
            return HL7v3CDA.XMLNode("Fault", namespaceURI: ns, prefix: "soap", children: children)
        }
    }

    static func parse(_ node: HL7v3CDA.XMLNode, version: SOAPVersion) throws -> SOAPFault {
        switch version {
        case .v1_1:
            guard let code = node.elements("faultcode", namespaceURI: "").first?.textContent,
                  let reason = node.elements("faultstring", namespaceURI: "").first?.textContent else {
                throw SOAPEnvelopeError.malformedFault
            }
            let detail = node.elements("detail", namespaceURI: "").first?.children.first
            return .init(code: code.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason, detail: detail)
        case .v1_2:
            let ns = version.namespace
            guard let code = node.elements("Code", namespaceURI: ns).first?.elements("Value", namespaceURI: ns).first?.textContent,
                  let reason = node.elements("Reason", namespaceURI: ns).first?.elements("Text", namespaceURI: ns).first?.textContent else {
                throw SOAPEnvelopeError.malformedFault
            }
            let detail = node.elements("Detail", namespaceURI: ns).first?.children.first
            return .init(code: code.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason, detail: detail)
        }
    }
}

/// A SOAP envelope holding optional header elements and exactly one body payload element.
/// Parsing goes through `SafeXMLParser`: no DTD, no external entities, bounded depth/size.
public struct SOAPEnvelope: Equatable, Sendable {
    public var version: SOAPVersion
    public var headerElements: [HL7v3CDA.XMLNode]
    public var body: HL7v3CDA.XMLNode

    public init(version: SOAPVersion = .v1_2, headerElements: [HL7v3CDA.XMLNode] = [], body: HL7v3CDA.XMLNode) {
        self.version = version
        self.headerElements = headerElements
        self.body = body
    }

    /// The body payload interpreted as a fault, when it is one.
    public var fault: SOAPFault? {
        guard body.name.localName == "Fault", body.name.namespaceURI == version.namespace else { return nil }
        return try? SOAPFault.parse(body, version: version)
    }

    public func node() -> HL7v3CDA.XMLNode {
        let ns = version.namespace
        var children: [HL7v3CDA.XMLNode] = []
        if !headerElements.isEmpty {
            children.append(HL7v3CDA.XMLNode("Header", namespaceURI: ns, prefix: "soap", children: headerElements))
        }
        children.append(HL7v3CDA.XMLNode("Body", namespaceURI: ns, prefix: "soap", children: [body]))
        return HL7v3CDA.XMLNode("Envelope", namespaceURI: ns, prefix: "soap", children: children)
    }

    public func serialize() throws -> Data {
        try XMLSerializer().serialize(node())
    }

    public static func parse(_ data: Data, limits: XMLLimits = XMLLimits()) throws -> SOAPEnvelope {
        let root = try SafeXMLParser(limits: limits).parse(data)
        guard root.name.localName == "Envelope", let version = SOAPVersion.detect(namespace: root.name.namespaceURI) else {
            throw SOAPEnvelopeError.notAnEnvelope
        }
        let ns = version.namespace
        let headers = root.elements("Header", namespaceURI: ns).first?.children ?? []
        guard let bodyElement = root.elements("Body", namespaceURI: ns).first else { throw SOAPEnvelopeError.missingBody }
        let payloads = bodyElement.children
        guard payloads.count == 1, let payload = payloads.first else { throw SOAPEnvelopeError.bodyPayloadCount(payloads.count) }
        if payload.name.localName == "Fault", payload.name.namespaceURI == ns {
            _ = try SOAPFault.parse(payload, version: version)
        }
        return .init(version: version, headerElements: headers, body: payload)
    }
}
