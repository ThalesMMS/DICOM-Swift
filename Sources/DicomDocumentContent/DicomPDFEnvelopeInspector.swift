import Foundation

/// Bounded byte inspection, with no rendering, decompression or PDF object graph validation.
public enum DicomPDFEnvelopeInspector {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public struct Inspection: Equatable, Sendable {
        public let headerVersion: String?
        public let hasXref: Bool
        public let hasTrailer: Bool
        public let pageCountHeuristic: Int
    }

    public static func inspect(_ data: Data) -> DicomDocumentContentResult<Inspection> {
        let limitations = ["No rendering or PDF conformance validation.",
                           "Page count is a lexical /Type /Page object heuristic; streams, encryption and incremental updates may hide or duplicate pages."]
        guard data.count <= maximumDocumentBytes else {
            return .init(value: nil, diagnostics: [.init(code: "byteLimit", reason: "PDF byte budget exceeded.")], limitations: limitations)
        }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        let header = try! NSRegularExpression(pattern: #"^%PDF-([0-9]+\.[0-9]+)"#)
        let match = header.firstMatch(in: text, range: range)
        let version = match.flatMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        let markers = try! NSRegularExpression(pattern: #"\b[0-9]+\s+[0-9]+\s+obj\s*<<|(endobj)|(/Type\s*/Page\b)"#)
        var inObject = false
        var pageCount = 0
        markers.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                inObject = false
            } else if match.range(at: 2).location != NSNotFound {
                if inObject { pageCount += 1 }
                inObject = false
            } else {
                inObject = true
            }
        }
        let inspection = Inspection(headerVersion: version, hasXref: text.contains("xref") || text.contains("/Type /XRef"),
                                    hasTrailer: text.contains("trailer"),
                                    pageCountHeuristic: pageCount)
        var diagnostics: [DicomDocumentContentDiagnostic] = []
        if version == nil { diagnostics.append(.init(code: "missingHeader", reason: "No PDF header version.")) }
        if !inspection.hasXref { diagnostics.append(.init(code: "missingXref", reason: "No lexical xref marker.")) }
        if !inspection.hasTrailer { diagnostics.append(.init(code: "missingTrailer", reason: "No lexical trailer marker (xref streams may omit it).")) }
        return .init(value: inspection, diagnostics: diagnostics, limitations: limitations)
    }
}
