import Foundation

/// PS3.19 Annex A.1 Native DICOM Model XML ↔ `DicomDataSet`: one `NativeDicomModel` document per data set
/// in the `http://dicom.nema.org/PS3.19/models/NativeDICOM` namespace, with `DicomAttribute` keyword and
/// private creator attributes, numbered `Value`/`Item`/`PersonName` children, `InlineBinary` and
/// `BulkData uri`. Parsing disables DTDs and external entities and enforces byte and depth limits.
public enum DicomNativeXMLCodec {
    public typealias Options = DicomDataSetRepresentation.EncodingOptions
    public typealias DecodingOptions = DicomDataSetRepresentation.DecodingOptions
    public typealias Decoded = DicomDataSetRepresentation.Decoded
    public typealias Error = DicomDataSetRepresentation.Error
    private typealias Values = DicomDataSetRepresentation.Values
    private typealias Path = DicomDataSetRepresentation.Path

    public static let namespace = "http://dicom.nema.org/PS3.19/models/NativeDICOM"

    // MARK: - Encoding

    /// One standard document for one data set.
    public static func encode(_ dataSet: DicomDataSet, options: Options = .init()) throws -> Data {
        let dictionary = DicomStandardDictionary.shared
        var options = options
        if options.transferSyntax == nil {
            options.transferSyntax = dataSet.string(for: .transferSyntaxUID).flatMap(DicomTransferSyntax.init(uid:))
        }
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<NativeDicomModel xmlns=\"\(namespace)\" xml:space=\"preserve\">"
        text += try attributes(of: dataSet, path: [], options: options, dictionary: dictionary)
        text += "</NativeDicomModel>\n"
        return Data(text.utf8)
    }

    /// One document per data set, for multipart/related responses (`application/dicom+xml` parts).
    public static func encodeDocuments(_ dataSets: [DicomDataSet], options: Options = .init()) throws -> [Data] {
        try dataSets.map { try encode($0, options: options) }
    }

    private static func attributes(of dataSet: DicomDataSet, path: Path, options: Options, dictionary: DicomStandardDictionary) throws -> String {
        var text = ""
        for element in dataSet.elements where element.element != 0 {
            if case .omit(let tags) = options.binary, tags.contains(element.tag) { continue }
            let elementPath = path + [.tag(element.tag)]
            let key = String(format: "%08X", element.tag)
            var open = "<DicomAttribute tag=\"\(key)\" vr=\"\(Values.code(for: element.vr))\""
            if let keyword = dictionary.definition(for: element.tag)?.keyword, !keyword.isEmpty { open += " keyword=\"\(try escape(keyword))\"" }
            if let creator = Values.privateCreator(of: element, in: dataSet) { open += " privateCreator=\"\(try escape(creator))\"" }
            open += ">"
            var body = ""
            switch element.value {
            case .empty:
                break
            case .sequence(let items):
                for (index, item) in items.enumerated() {
                    body += "<Item number=\"\(index + 1)\">" + (try attributes(of: item.dataSet, path: elementPath + [.item(index)], options: options, dictionary: dictionary)) + "</Item>"
                }
            case .bytes(let data):
                guard !data.isEmpty else { break }
                if case .reference(let resolver) = options.binary, let uri = resolver(elementPath, element) {
                    body += "<BulkData uri=\"\(try escape(uri))\"/>"
                } else {
                    body += "<InlineBinary>\(Values.representationBytes(of: element, data, encapsulated: path.isEmpty && options.transferSyntax?.registryEntry.isEncapsulated == true).base64EncodedString())</InlineBinary>"
                }
            default:
                if Values.binaryVRs.contains(element.vr) {
                    let bytes = try Values.binaryBytes(of: element, tag: key)
                    if case .reference(let resolver) = options.binary, let uri = resolver(elementPath, element) {
                        body += "<BulkData uri=\"\(try escape(uri))\"/>"
                    } else if !bytes.isEmpty {
                        body += "<InlineBinary>\(bytes.base64EncodedString())</InlineBinary>"
                    }
                } else if element.vr == .PN {
                    for (index, raw) in element.stringValues.enumerated() { body += try personName(raw, number: index + 1) }
                } else {
                    let texts = try Values.texts(of: element)
                    for (index, value) in texts.enumerated() where !(texts.count == 1 && value.isEmpty) {
                        let preserve = value.first?.isWhitespace == true || value.last?.isWhitespace == true
                        body += "<Value number=\"\(index + 1)\"\(preserve ? " xml:space=\"preserve\"" : "")>\(try escape(value))</Value>"
                    }
                }
            }
            text += open + body + "</DicomAttribute>"
        }
        return text
    }

    private static func personName(_ raw: String, number: Int) throws -> String {
        let groups = Values.personNameGroups(raw)
        let fields = ["FamilyName", "GivenName", "MiddleName", "NamePrefix", "NameSuffix"]
        var text = "<PersonName number=\"\(number)\">"
        for (name, group) in zip(["Alphabetic", "Ideographic", "Phonetic"], groups) where !group.isEmpty {
            let components = group.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            text += "<\(name)>" + (try zip(fields, components).map { field, component in
                component.isEmpty ? "" : "<\(field)>\(try escape(component))</\(field)>"
            }).joined() + "</\(name)>"
        }
        return text + "</PersonName>"
    }

    private static func escape(_ value: String) throws -> String {
        var text = ""
        for scalar in value.unicodeScalars {
            guard [0x09, 0x0A, 0x0D].contains(scalar.value) || (0x20...0xD7FF).contains(scalar.value)
                || (0xE000...0xFFFD).contains(scalar.value) || (0x10000...0x10FFFF).contains(scalar.value) else {
                throw Error.invalidDocument("text contains a character prohibited by XML 1.0")
            }
            switch scalar {
            case "&": text += "&amp;"
            case "<": text += "&lt;"
            case ">": text += "&gt;"
            case "\"": text += "&quot;"
            case "'": text += "&apos;"
            default:
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }

    // MARK: - Decoding

    public static func decode(_ data: Data, options: DecodingOptions = .init()) throws -> Decoded {
        guard data.count <= options.maximumBytes else { throw Error.inputTooLarge(byteCount: data.count, limit: options.maximumBytes) }
        // A Native DICOM Model document never needs a DTD; refusing one up front closes entity expansion and external references.
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!doctype".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw Error.invalidDocument("DTD entity declarations are not accepted")
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let delegate = Delegate(options: options)
        parser.delegate = delegate
        let finished = parser.parse()
        if let error = delegate.failure { throw error }
        guard finished, let root = delegate.root else {
            throw Error.invalidDocument(parser.parserError.map { "\($0.localizedDescription)" } ?? "not a NativeDicomModel document")
        }
        var state = Delegate.DecodeState()
        let dataSet = try dataSet(from: root, path: [], state: &state)
        var decoded = Decoded(dataSet: dataSet, bulkData: state.bulkData, diagnostics: [], transferSyntax: options.transferSyntax)
        decoded.dataSet = Values.restoringPixelDelimiter(in: dataSet, transferSyntax: decoded.transferSyntax)
        return decoded
    }

    /// A minimal element tree; text is kept verbatim (whitespace handling follows `xml:space`).
    final class Node {
        let name: String
        let namespace: String?
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(name: String, namespace: String?, attributes: [String: String]) { self.name = name; self.namespace = namespace; self.attributes = attributes }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct DecodeState { var bulkData: [DicomDataSetRepresentation.BulkDataReference] = [] }
        let options: DecodingOptions
        var stack: [Node] = []
        var root: Node?
        var failure: Error?
        var depth = 0
        var itemDepth = 0

        init(options: DecodingOptions) { self.options = options }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard namespaceURI == DicomNativeXMLCodec.namespace else { fail(.invalidDocument("foreign namespace at \(name)"), parser); return }
            depth += 1
            // Sequence nesting is what the limit bounds: one Item level per nested data set.
            if name == "Item" { itemDepth += 1 }
            guard itemDepth < options.maximumDepth, depth <= options.maximumDepth * 4 + 8 else { fail(.depthExceeded(limit: options.maximumDepth), parser); return }
            var inheritedAttributes = attributes
            if inheritedAttributes["xml:space"] == nil {
                inheritedAttributes["xml:space"] = stack.last?.attributes["xml:space"]
            }
            let node = Node(name: name, namespace: namespaceURI, attributes: inheritedAttributes)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node } else { fail(.invalidDocument("multiple root elements"), parser) }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            if name == "Item" { itemDepth -= 1 }
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { fail(.invalidDocument("DTD entity declarations are not accepted"), parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(.invalidDocument("external entities are not accepted"), parser) }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { fail(.invalidDocument("DTD element declarations are not accepted"), parser) }
        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) {
            fail(.invalidDocument("DTD attribute declarations are not accepted"), parser)
        }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) {
            fail(.invalidDocument("unparsed entities are not accepted"), parser)
        }
        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { fail(.invalidDocument("notations are not accepted"), parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { fail(.invalidDocument("external entities are not accepted"), parser); return nil }

        private func fail(_ error: Error, _ parser: XMLParser) {
            if failure == nil { failure = error }
            parser.abortParsing()
        }
    }

    private static func dataSet(from node: Node, path: Path, state: inout Delegate.DecodeState) throws -> DicomDataSet {
        guard node.name == (path.isEmpty ? "NativeDicomModel" : "Item"), node.namespace == namespace else {
            throw Error.invalidDocument("expected \(path.isEmpty ? "NativeDicomModel" : "Item") in the PS3.19 namespace, found \(node.name)")
        }
        var elements: [DicomDataElement] = []
        for child in node.children {
            guard child.name == "DicomAttribute", child.namespace == namespace else { throw Error.invalidDocument("unexpected element \(child.name)") }
            guard let key = child.attributes["tag"], let tag = Values.tag(fromKey: key) else { throw Error.malformedTag(child.attributes["tag"] ?? "") }
            guard let code = child.attributes["vr"] else { throw Error.missingVR(tag: key) }
            guard let vr = Values.vr(fromCode: code) else { throw Error.unsupportedVR(tag: key, vr: code) }
            let elementPath = path + [.tag(tag)]
            let permitted: Set<String>
            if vr == .SQ { permitted = ["Item"] }
            else if vr == .PN { permitted = ["PersonName"] }
            else if Values.binaryVRs.contains(vr) { permitted = ["InlineBinary", "BulkData"] }
            else { permitted = Values.bulkCapableVRs.contains(vr) ? ["Value", "BulkData"] : ["Value"] }
            guard child.children.allSatisfy({ $0.namespace == namespace && permitted.contains($0.name) }) else {
                throw Error.invalidDocument("unexpected child of \(key) for \(code)")
            }
            for valueNode in child.children where valueNode.name != "Item" { try validateValueTree(valueNode) }
            let kinds = Set(child.children.map(\.name))
            guard kinds.count <= 1, kinds.isDisjoint(with: ["InlineBinary", "BulkData"]) || child.children.count == 1 else {
                throw Error.conflictingValueFields(tag: key)
            }
            let value: DicomDataValue
            if let inline = child.children.first(where: { $0.name == "InlineBinary" }) {
                guard let bytes = Data(base64Encoded: inline.text.filter { !$0.isWhitespace }, options: []) else { throw Error.invalidBase64(tag: key) }
                value = try Values.value(fromInlineBytes: bytes, vr: vr, tag: key)
            } else if let bulk = child.children.first(where: { $0.name == "BulkData" }) {
                guard let uri = bulk.attributes["uri"] ?? bulk.attributes["uuid"] else { throw Error.invalidDocument("BulkData of \(key) has no uri") }
                state.bulkData.append(.init(path: elementPath, tag: tag, vr: vr, uri: uri))
                value = .empty
            } else if vr == .SQ {
                let items = try numbered(child.children.filter { $0.name == "Item" }, tag: key)
                value = items.isEmpty ? .empty : .sequence(try items.enumerated().map { index, item in
                    DicomSequenceItem(dataSet: try dataSet(from: item, path: elementPath + [.item(index)], state: &state))
                })
            } else if vr == .PN {
                let names = try numbered(child.children.filter { $0.name == "PersonName" }, tag: key)
                let texts = names.map { name -> String in
                    func group(_ label: String) -> String? {
                        guard let node = name.children.first(where: { $0.name == label }) else { return nil }
                        let fields = ["FamilyName", "GivenName", "MiddleName", "NamePrefix", "NameSuffix"]
                        var components = fields.map { field in node.children.first { $0.name == field }?.text ?? "" }
                        while components.last?.isEmpty == true { components.removeLast() }
                        return components.joined(separator: "^")
                    }
                    return Values.personName(alphabetic: group("Alphabetic"), ideographic: group("Ideographic"), phonetic: group("Phonetic"))
                }
                value = try Values.value(fromTexts: texts, vr: vr, tag: key)
            } else {
                let nodes = try numbered(child.children.filter { $0.name == "Value" }, tag: key)
                let texts = nodes.map { $0.attributes["xml:space"] == "preserve" ? $0.text : $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                if Values.binaryVRs.contains(vr), !nodes.isEmpty { throw Error.invalidDocument("binary VR of \(key) uses Value instead of InlineBinary") }
                value = try Values.value(fromTexts: texts, vr: vr, tag: key)
            }
            elements.append(.init(tag: tag, vr: vr, value: value))
        }
        return DicomDataSet(elements: elements)
    }

    private static func validateValueTree(_ node: Node) throws {
        let permitted: Set<String>
        switch node.name {
        case "PersonName": permitted = ["Alphabetic", "Ideographic", "Phonetic"]
        case "Alphabetic", "Ideographic", "Phonetic": permitted = ["FamilyName", "GivenName", "MiddleName", "NamePrefix", "NameSuffix"]
        default: permitted = []
        }
        guard node.children.allSatisfy({ permitted.contains($0.name) }),
              Set(node.children.map(\.name)).count == node.children.count else {
            throw Error.invalidDocument("unexpected or duplicate child of \(node.name)")
        }
        for child in node.children { try validateValueTree(child) }
    }

    /// Children ordered by their `number` attribute, which must be 1…n without gaps.
    private static func numbered(_ nodes: [Node], tag key: String) throws -> [Node] {
        let numbered = try nodes.map { node -> (Int, Node) in
            guard let number = node.attributes["number"].flatMap(Int.init), number >= 1 else {
                throw Error.invalidDocument("\(node.name) of \(key) has no valid number")
            }
            return (number, node)
        }.sorted { $0.0 < $1.0 }
        guard numbered.isEmpty || numbered.map(\.0) == Array(1...numbered.count) else {
            throw Error.invalidDocument("\(key) numbering is not 1…n")
        }
        return numbered.map(\.1)
    }
}
