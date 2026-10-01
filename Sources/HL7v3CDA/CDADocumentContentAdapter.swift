import Foundation
import DicomDocumentContent

/// Opt-in full-model adapter for callers that already use the
/// `DicomDocumentContent` result seam.  The existing narrative extractor is
/// intentionally untouched; this adapter simply adds the parsed CDA model.
public enum CDADocumentContentAdapter {
    public static func extract(data: Data) -> DicomDocumentContentResult<ClinicalDocument> {
        do {
            let document = try CDADocumentParser().parse(data)
            return .init(value: document,
                         diagnostics: [],
                         limitations: [
                            "Full CDA XML model parsed; template validation remains opt-in.",
                            "Narrative rendering is available through CDARenderer and does not interpret external resources."
                         ])
        } catch let error as CDAError {
            return .init(value: nil,
                         diagnostics: [.init(code: String(describing: error), reason: error.localizedDescription)],
                         limitations: ["Full CDA XML model could not be parsed."])
        } catch {
            return .init(value: nil,
                         diagnostics: [.init(code: "parseError", reason: "CDA payload could not be parsed")],
                         limitations: ["Full CDA XML model could not be parsed."])
        }
    }

    /// Explicit narrative compatibility path for clients that want the exact
    /// value type returned by `DicomCDANarrativeExtractor`.
    public static func extractNarrative(data: Data) -> DicomDocumentContentResult<DicomCDANarrative> {
        DicomCDANarrativeExtractor.parse(data)
    }
}

