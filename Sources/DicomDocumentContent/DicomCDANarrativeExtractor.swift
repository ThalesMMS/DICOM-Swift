import Foundation

public enum DicomCDANarrativeExtractor {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024

    private static func extract(_ data: Data) throws -> DicomCDANarrative {
        guard !data.isEmpty else {
            throw DicomCDAContentError.malformedXML
        }
        guard data.count <= maximumDocumentBytes else {
            throw DicomCDAContentError.documentTooLarge
        }
        guard !containsForbiddenXMLDeclaration(in: data) else {
            throw DicomCDAContentError.unsafeXML
        }

        let delegate = DicomCDANarrativeDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        guard parser.parse() else {
            throw delegate.failure ?? DicomCDAContentError.malformedXML
        }
        if let failure = delegate.failure {
            throw failure
        }
        guard delegate.foundClinicalDocument else {
            throw DicomCDAContentError.malformedXML
        }
        return DicomCDANarrative(title: delegate.documentTitle.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                                 sections: delegate.sections.sorted { $0.id < $1.id },
                                 hasStructuredBody: delegate.hasStructuredBody)
    }

    /// Narrative extraction, not CDA R2 validation. No resources or external entities are loaded.
    public static func parse(_ data: Data) -> DicomDocumentContentResult<DicomCDANarrative> {
        let limitations = ["Narrative extraction, not CDA R2 validation.", "Embedded media, links, styles and non-narrative entries are not interpreted."]
        do { return .init(value: try extract(data), limitations: limitations) }
        catch { return .init(value: nil, diagnostics: [.init(code: String(describing: error), reason: error.localizedDescription)], limitations: limitations) }
    }

    private static func containsForbiddenXMLDeclaration(in data: Data) -> Bool {
        var normalizedASCII: [UInt8] = []
        normalizedASCII.reserveCapacity(min(data.count, 65_536))
        for byte in data where byte != 0 {
            if byte >= 65, byte <= 90 {
                normalizedASCII.append(byte + 32)
            } else {
                normalizedASCII.append(byte)
            }
        }

        let normalized = Data(normalizedASCII)
        return normalized.range(of: Data("<!doctype".utf8)) != nil ||
            normalized.range(of: Data("<!entity".utf8)) != nil
    }
}
