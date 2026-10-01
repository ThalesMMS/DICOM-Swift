import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum CDAError: Error, Equatable, Sendable {
    case byteLimit, depthLimit, elementLimit, attributeLimit, textLimit
    case forbiddenDTD, malformedXML, unsupportedEncoding, cyclicReferences
    case invalidDocument, invalidDataType(String), nullFlavorConflict(String)
    case invalidXMLTree
}

public struct XMLLimits: Equatable, Sendable {
    public var maxBytes: Int = 32 * 1024 * 1024
    public var maxDepth: Int = 64
    public var maxElements: Int = 500_000
    public var maxAttributeLength: Int = 64 * 1024
    public var maxTextLength: Int = 4 * 1024 * 1024
    public init() {}
}

public struct SafeXMLParser: Sendable {
    public var limits: XMLLimits
    public init(limits: XMLLimits = XMLLimits()) { self.limits = limits }

    public func parse(_ url: URL) throws -> XMLNode {
        guard url.isFileURL, let stream = InputStream(url: url) else { throw CDAError.malformedXML }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw CDAError.malformedXML }
            if count == 0 { break }
            guard count <= limits.maxBytes - data.count else { throw CDAError.byteLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try parse(data)
    }

    public func parse(_ data: Data) throws -> XMLNode {
        guard data.count <= limits.maxBytes else { throw CDAError.byteLimit }
        // Decode before invoking libxml so entity declarations can never allocate expansion buffers.
        let bytes = Array(data.prefix(4))
        let encoding: String.Encoding
        if bytes.starts(with: [0xFF, 0xFE, 0, 0]) || bytes.starts(with: [0, 0, 0xFE, 0xFF]) {
            throw CDAError.unsupportedEncoding
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0x3C, 0, 0x3F, 0]) {
            encoding = .utf16LittleEndian
        } else if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0, 0x3C, 0, 0x3F]) {
            encoding = .utf16BigEndian
        } else { encoding = .utf8 }
        guard let source = String(data: data, encoding: encoding), !source.contains("\0") else {
            throw CDAError.unsupportedEncoding
        }
        try rejectDeclarations(in: source)
        let delegate = XMLTreeDelegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw delegate.failure ?? CDAError.malformedXML }
        if CDALinks.findings(in: root).contains(where: { $0.kind == .cycle }) { throw CDAError.cyclicReferences }
        return root
    }

    private func rejectDeclarations(in source: String) throws {
        var index = source.startIndex
        while let opening = source.range(of: "<", range: index..<source.endIndex) {
            let remaining = source[opening.lowerBound...]
            let terminator: String?
            if remaining.hasPrefix("<!--") { terminator = "-->" }
            else if remaining.hasPrefix("<![CDATA[") { terminator = "]]>" }
            else if remaining.hasPrefix("<?") { terminator = "?>" }
            else {
                if remaining.hasPrefix("<!DOCTYPE") || remaining.hasPrefix("<!ENTITY") { throw CDAError.forbiddenDTD }
                terminator = nil
            }
            if let terminator {
                guard let end = source.range(of: terminator, range: opening.upperBound..<source.endIndex) else {
                    throw CDAError.malformedXML
                }
                index = end.upperBound
            } else { index = opening.upperBound }
        }
    }
}

private final class XMLTreeDelegate: NSObject, XMLParserDelegate {
    let limits: XMLLimits
    var stack: [XMLNode] = []
    var scopes: [[String: String]] = [["xml": CDANamespace.xml]]
    var pendingNamespaces: [String: String] = [:]
    var textBytes: [Int] = []
    var count = 0
    var root: XMLNode?
    var failure: CDAError?
    init(limits: XMLLimits) { self.limits = limits }

    func fail(_ error: CDAError, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        guard namespaceURI.utf8.count <= limits.maxAttributeLength,
              prefix.utf8.count <= limits.maxAttributeLength else { fail(.attributeLimit, parser); return }
        pendingNamespaces[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard failure == nil else { return }
        count += 1
        guard count <= limits.maxElements else { fail(.elementLimit, parser); return }
        guard stack.count < limits.maxDepth else { fail(.depthLimit, parser); return }
        var scope = scopes.last ?? [:]
        scope.merge(pendingNamespaces) { _, new in new }
        let qualified = qName ?? elementName
        let prefix = qualified.contains(":") ? String(qualified.split(separator: ":")[0]) : ""
        var node = XMLNode(elementName, namespaceURI: namespaceURI ?? "", prefix: prefix)
        node.inheritedNamespaces = scopes.last ?? [:]
        node.namespaces = pendingNamespaces
        pendingNamespaces = [:]
        for (key, value) in attributeDict {
            guard value.utf8.count <= limits.maxAttributeLength, key.utf8.count <= limits.maxAttributeLength else {
                fail(.attributeLimit, parser); return
            }
            let pieces = key.split(separator: ":", maxSplits: 1).map(String.init)
            let attributePrefix = pieces.count == 2 ? pieces[0] : ""
            node.attributes[XMLName(pieces.last ?? key, namespaceURI: attributePrefix.isEmpty ? "" : scope[attributePrefix] ?? "",
                                    prefix: attributePrefix)] = value
        }
        if !textBytes.isEmpty { textBytes[textBytes.count - 1] = 0 }
        scopes.append(scope)
        stack.append(node)
        textBytes.append(0)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil, !stack.isEmpty else { return }
        let index = stack.count - 1
        textBytes[index] += string.utf8.count
        guard textBytes[index] <= limits.maxTextLength else { fail(.textLimit, parser); return }
        if case .text(let previous) = stack[index].content.last {
            stack[index].content[stack[index].content.count - 1] = .text(previous + string)
        } else { stack[index].content.append(.text(string)) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { fail(.malformedXML, parser); return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        guard comment.utf8.count <= limits.maxTextLength else { fail(.textLimit, parser); return }
        guard !stack.isEmpty, failure == nil else { return }
        stack[stack.count - 1].content.append(.comment(comment))
        textBytes[textBytes.count - 1] = 0
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        guard (data ?? "").utf8.count <= limits.maxTextLength else { fail(.textLimit, parser); return }
        guard !stack.isEmpty, failure == nil else { return }
        stack[stack.count - 1].content.append(.processingInstruction(target, data ?? ""))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil, let node = stack.popLast() else { return }
        scopes.removeLast()
        textBytes.removeLast()
        if stack.isEmpty { root = node } else { stack[stack.count - 1].content.append(.element(node)) }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(.forbiddenDTD, parser)
        return nil
    }
}
