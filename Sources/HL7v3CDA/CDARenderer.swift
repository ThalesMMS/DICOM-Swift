import Foundation

/// A deliberately small, safe narrative renderer.  It renders only CDA
/// narrative elements and never copies attributes such as `href`, `src`, or
/// inline style into generated HTML.
public enum CDARenderer {
    public static func renderText(_ document: ClinicalDocument) -> String {
        let sections = document.body.flatMap { body -> [Section]? in
            guard case .structured(let structured) = body else { return nil }
            return structured.sections
        } ?? []
        return sections.flatMap(sectionsInDocumentOrder).map { section in
            let title = section.title?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = renderText(section)
            if title.isEmpty { return body }
            return body.isEmpty ? title : title + "\n" + body
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func renderHTML(_ document: ClinicalDocument) -> String {
        let sections = document.body.flatMap { body -> [Section]? in
            guard case .structured(let structured) = body else { return nil }
            return structured.sections
        } ?? []
        let rendered = sections.flatMap(sectionsInDocumentOrder).map { section -> String in
            let title = section.title?.text.map(escapeHTML) ?? ""
            let narrative = section.narrative.map { renderHTMLNode($0, context: .root) } ?? ""
            return "<section>" + (title.isEmpty ? "" : "<h2>\(title)</h2>") + narrative + "</section>"
        }.joined()
        return rendered
    }

    /// Rendering a section is useful to document-content adapters and keeps
    /// the filtering policy identical to document rendering.
    public static func renderText(_ section: Section) -> String { section.narrative.map { normalizeWhitespace(renderPlain($0)) } ?? "" }
    public static func renderHTML(_ section: Section) -> String { section.narrative.map { renderHTMLNode($0, context: .root) } ?? "" }

    private static func sectionsInDocumentOrder(_ section: Section) -> [Section] {
        [section] + section.sections.flatMap(sectionsInDocumentOrder)
    }

    private enum HTMLContext { case root, block, inline }

    private static func renderPlain(_ node: XMLNode) -> String {
        var output = ""
        for item in node.content {
            switch item {
            case .text(let value): output += value
            case .comment, .processingInstruction: break
            case .element(let child):
                switch child.name.localName {
                case "br": output += "\n"
                case "paragraph": output += renderPlain(child) + "\n"
                case "table": output += renderPlain(child) + "\n"
                case "tr": output += renderPlain(child) + "\n"
                case "th", "td": output += renderPlain(child) + "\t"
                case "list", "listItem", "item", "content", "text", "thead", "tbody": output += renderPlain(child)
                case "linkHtml": output += renderPlain(child)
                case "renderMultiMedia": output += "[embedded media]"
                default: break
                }
            }
        }
        return output
    }

    private static func renderHTMLNode(_ node: XMLNode, context: HTMLContext) -> String {
        var output = ""
        for item in node.content {
            switch item {
            case .text(let value): output += escapeHTML(value)
            case .comment, .processingInstruction: break
            case .element(let child):
                guard child.name.namespaceURI == CDANamespace.hl7 || child.name.namespaceURI.isEmpty else { continue }
                let name = child.name.localName
                switch name {
                case "text": output += renderHTMLNode(child, context: .root)
                case "paragraph": output += "<p>" + renderHTMLNode(child, context: .block) + "</p>"
                case "content": output += "<span>" + renderHTMLNode(child, context: .inline) + "</span>"
                case "table": output += "<table>" + renderHTMLNode(child, context: .block) + "</table>"
                case "thead": output += "<thead>" + renderHTMLNode(child, context: .block) + "</thead>"
                case "tbody": output += "<tbody>" + renderHTMLNode(child, context: .block) + "</tbody>"
                case "tr": output += "<tr>" + renderHTMLNode(child, context: .block) + "</tr>"
                case "th": output += "<th>" + renderHTMLNode(child, context: .inline) + "</th>"
                case "td": output += "<td>" + renderHTMLNode(child, context: .inline) + "</td>"
                case "list": output += "<ul>" + renderHTMLNode(child, context: .block) + "</ul>"
                case "listItem", "item": output += "<li>" + renderHTMLNode(child, context: .block) + "</li>"
                case "br": output += "<br/>"
                case "linkHtml": output += renderHTMLNode(child, context: .inline)
                case "renderMultiMedia": output += "<span>[embedded media]</span>"
                default:
                    // Unknown narrative elements are not emitted.  Their text
                    // is not trusted markup and is intentionally not promoted
                    // into HTML; this is the whitelist boundary.
                    break
                }
            }
        }
        return output
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
