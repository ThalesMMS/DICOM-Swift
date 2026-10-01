import Foundation

public struct XMLSerializer: Sendable {
    public var indentation: Int?
    public var limits: XMLLimits
    public init(indentation: Int? = nil, limits: XMLLimits = XMLLimits()) {
        self.indentation = indentation
        self.limits = limits
    }

    public func serialize(_ root: XMLNode) throws -> Data {
        var output = ""
        var count = 0
        let limits = self.limits
        func append(_ text: String) throws {
            guard output.utf8.count + text.utf8.count <= limits.maxBytes else { throw CDAError.byteLimit }
            output += text
        }
        func escape(_ value: String, attribute: Bool = false) throws -> String {
            guard value.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 10 || $0.value == 13 ||
                (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
                (0x10000...0x10FFFF).contains($0.value) }) else { throw CDAError.invalidXMLTree }
            var text = value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\r", with: "&#13;")
            if attribute {
                text = text.replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;")
            }
            return text
        }
        func validName(_ name: String) -> Bool {
            name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
        }
        func emit(_ node: XMLNode, scope inherited: [String: String], depth: Int) throws {
            count += 1
            guard count <= limits.maxElements else { throw CDAError.elementLimit }
            guard depth < limits.maxDepth else { throw CDAError.depthLimit }
            guard validName(node.name.localName), node.name.prefix.isEmpty || validName(node.name.prefix) else {
                throw CDAError.invalidXMLTree
            }
            var scope = inherited
            var declarations = node.namespaces
            for (prefix, uri) in node.inheritedNamespaces where scope[prefix] == nil && declarations[prefix] == nil {
                declarations[prefix] = uri
            }
            let elementPrefix = node.name.prefix
            if (declarations[elementPrefix] ?? scope[elementPrefix] ?? "") != node.name.namespaceURI {
                declarations[elementPrefix] = node.name.namespaceURI
            }
            for name in node.attributes.keys where !name.namespaceURI.isEmpty {
                guard !name.prefix.isEmpty,
                      name.prefix != elementPrefix || name.namespaceURI == node.name.namespaceURI else { throw CDAError.invalidXMLTree }
                if (declarations[name.prefix] ?? scope[name.prefix]) != name.namespaceURI {
                    guard declarations[name.prefix] == nil else { throw CDAError.invalidXMLTree }
                    declarations[name.prefix] = name.namespaceURI
                }
            }
            scope.merge(declarations) { _, new in new }
            try append("<" + node.name.qualifiedName)
            for prefix in declarations.keys.sorted() {
                guard prefix.isEmpty || validName(prefix), prefix != "xmlns" else { throw CDAError.invalidXMLTree }
                let uri = declarations[prefix] ?? ""
                guard uri.utf8.count <= limits.maxAttributeLength else { throw CDAError.attributeLimit }
                try append(" " + (prefix.isEmpty ? "xmlns" : "xmlns:" + prefix) + "=\"" + escape(uri, attribute: true) + "\"")
            }
            for name in node.attributes.keys.sorted(by: { ($0.namespaceURI, $0.localName, $0.prefix) < ($1.namespaceURI, $1.localName, $1.prefix) }) {
                guard validName(name.localName), name.prefix.isEmpty || validName(name.prefix) else { throw CDAError.invalidXMLTree }
                let value = node.attributes[name] ?? ""
                guard value.utf8.count <= limits.maxAttributeLength else { throw CDAError.attributeLimit }
                try append(" " + name.qualifiedName + "=\"" + escape(value, attribute: true) + "\"")
            }
            if node.content.isEmpty { try append("/>"); return }
            try append(">")
            // Never indent mixed content, including narrative and datatype text.
            let pretty = indentation != nil && node.name.localName != "text" &&
                (CDAInspection.orders[node.name.localName] != nil || node.name.localName == "component") && node.content.allSatisfy { if case .element = $0 { true } else { false } }
            for item in node.content {
                if pretty { try append("\n" + String(repeating: " ", count: min(max(indentation ?? 0, 0), 8) * (depth + 1))) }
                switch item {
                case .element(let child): try emit(child, scope: scope, depth: depth + 1)
                case .text(let text):
                    guard text.utf8.count <= limits.maxTextLength else { throw CDAError.textLimit }
                    try append(escape(text))
                case .comment(let comment):
                    guard !comment.contains("--"), !comment.hasSuffix("-") else { throw CDAError.invalidXMLTree }
                    _ = try escape(comment)
                    try append("<!--" + comment + "-->")
                case .processingInstruction(let target, let text):
                    guard validName(target), target.lowercased() != "xml", !text.contains("?>") else { throw CDAError.invalidXMLTree }
                    _ = try escape(text)
                    try append("<?" + target + (text.isEmpty ? "" : " " + text) + "?>")
                }
            }
            if pretty { try append("\n" + String(repeating: " ", count: min(max(indentation ?? 0, 0), 8) * depth)) }
            try append("</" + node.name.qualifiedName + ">")
        }
        try emit(root, scope: ["xml": CDANamespace.xml], depth: 0)
        return Data(output.utf8)
    }
}
