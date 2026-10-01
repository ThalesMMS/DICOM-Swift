import Foundation

/// Deterministic text, HTML and JSON renderings of an SR content tree. HTML escapes every value and
/// never emits links or scripts; JSON mirrors the tree with value-type specific fields only.
public enum DicomStructuredReportRenderer {
    public struct Node: Codable, Equatable, Sendable {
        public let relationship: String?
        public let valueType: String
        public let concept: String?
        public let conceptCode: String?
        public let conceptScheme: String?
        public let text: String?
        public let code: String?
        public let codeMeaning: String?
        public let numeric: Double?
        public let units: String?
        public let dateTime: String?
        public let uid: String?
        public let personName: String?
        public let referencedSOPInstanceUIDs: [String]
        public let graphicType: String?
        public let children: [Node]
    }

    public struct Document: Codable, Equatable, Sendable {
        public let sopClassUID: String?
        public let sopInstanceUID: String?
        public let completionFlag: String?
        public let verificationFlag: String?
        public let templateIdentifier: String?
        public let evidenceStudyUIDs: [String]
        public let root: Node
        public let contentItemCount: Int
    }

    public static func node(_ item: DicomSRContentItem) -> Node {
        Node(relationship: item.relationshipType, valueType: item.valueType, concept: item.conceptName?.codeMeaning,
             conceptCode: item.conceptName?.codeValue, conceptScheme: item.conceptName?.codingSchemeDesignator,
             text: item.textValue, code: item.codeValue?.codeValue, codeMeaning: item.codeValue?.codeMeaning,
             numeric: item.numericValue, units: item.measurementUnits?.codeValue,
             dateTime: item.dateTimeValue?.rawValue ?? item.dateValue?.rawValue ?? item.timeValue?.rawValue,
             uid: item.uidValue, personName: item.personNameValue?.rawValue,
             referencedSOPInstanceUIDs: item.referencedSOPs.compactMap(\.referencedSOPInstanceUID),
             graphicType: item.graphicType, children: item.children.map(node))
    }

    public static func document(_ document: DicomSRDocument) -> Document {
        let root = node(document.root)
        func count(_ node: Node) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
        return Document(sopClassUID: document.sopClassUID, sopInstanceUID: document.sopInstanceUID, completionFlag: document.completionFlag,
                        verificationFlag: document.verificationFlag, templateIdentifier: document.templateIdentifier,
                        evidenceStudyUIDs: Array(Set(document.evidenceReferences.compactMap(\.studyInstanceUID))).sorted(),
                        root: root, contentItemCount: count(root))
    }

    static func valueText(_ node: Node) -> String {
        switch node.valueType {
        case "TEXT": return node.text ?? ""
        case "NUM":
            guard let numeric = node.numeric else { return "" }
            let formatted = Int(exactly: numeric).map(String.init) ?? String(numeric)
            return formatted + (node.units.map { " " + $0 } ?? "")
        case "CODE": return [node.codeMeaning, node.code.map { "(" + $0 + ")" }].compactMap { $0 }.joined(separator: " ")
        case "DATETIME", "DATE", "TIME": return node.dateTime ?? ""
        case "UIDREF": return node.uid ?? ""
        case "PNAME": return node.personName ?? ""
        case "IMAGE", "COMPOSITE", "WAVEFORM": return node.referencedSOPInstanceUIDs.joined(separator: ", ")
        case "SCOORD", "SCOORD3D", "TCOORD": return node.graphicType ?? node.valueType
        case "CONTAINER": return ""
        default: return node.text ?? ""
        }
    }

    public static func text(_ document: DicomSRDocument) -> String {
        var lines: [String] = []
        func walk(_ node: Node, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let label = node.concept ?? node.valueType
            let value = valueText(node)
            lines.append(indent + (node.relationship.map { $0 + " " } ?? "") + node.valueType + " " + label + (value.isEmpty ? "" : ": " + value))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(node(document.root), depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func html(_ document: DicomSRDocument) -> String {
        var output = "<section class=\"dicom-sr\">"
        func walk(_ node: Node) {
            let label = escape(node.concept ?? node.valueType)
            let value = escape(valueText(node))
            output += "<li><span class=\"vt\">" + escape(node.valueType) + "</span> <b>" + label + "</b>" + (value.isEmpty ? "" : ": " + value)
            if !node.children.isEmpty {
                output += "<ul>"
                for child in node.children { walk(child) }
                output += "</ul>"
            }
            output += "</li>"
        }
        output += "<ul>"
        walk(node(document.root))
        output += "</ul></section>"
        return output
    }

    public static func jsonData(_ document: DicomSRDocument, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(Self.document(document))
    }
}
