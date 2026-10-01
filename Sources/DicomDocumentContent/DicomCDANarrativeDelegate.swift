import Foundation

final class DicomCDANarrativeDelegate: NSObject, XMLParserDelegate {
    private struct SectionAccumulator {
        let id: Int
        var title = ""
        var text = ""
        var titleDepth = 0
        var textDepth = 0
    }

    private static let maximumSections = 512
    private static let maximumCharacters = 2_000_000
    private static let suppressedElements: Set<String> = [
        "embed", "iframe", "image", "img", "link", "linkhtml", "object",
        "rendermultimedia", "script", "style"
    ]
    private static let narrativeBreakElements: Set<String> = [
        "br", "caption", "item", "list", "paragraph", "tbody", "td", "tfoot",
        "th", "thead", "tr"
    ]

    private(set) var documentTitle = ""
    private(set) var hasStructuredBody = false
    private var documentTitleDepth = 0
    private var depth = 0
    private var accumulators: [SectionAccumulator] = []
    private var suppressedDepth = 0
    private var characterCount = 0
    private var hasSeenRootElement = false
    private var nextSectionID = 0

    private(set) var sections: [DicomCDASection] = []
    private(set) var failure: DicomCDAContentError?
    private(set) var foundClinicalDocument = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes _: [String: String] = [:]
    ) {
        depth += 1
        let name = elementName.lowercased()
        if !hasSeenRootElement {
            hasSeenRootElement = true
            foundClinicalDocument = name == "clinicaldocument"
        }

        if name == "structuredbody" { hasStructuredBody = true }
        if name == "title", depth == 2 { documentTitleDepth = depth }
        if suppressedDepth > 0 {
            suppressedDepth += 1
            return
        }
        if Self.suppressedElements.contains(name) {
            suppressedDepth = 1
            return
        }
        if name == "section" {
            guard nextSectionID < Self.maximumSections else {
                fail(.documentTooLarge, parser: parser)
                return
            }
            accumulators.append(SectionAccumulator(id: nextSectionID))
            nextSectionID += 1
            return
        }
        guard !accumulators.isEmpty else { return }

        if name == "title" {
            accumulators[accumulators.count - 1].titleDepth += 1
        }
        if name == "text" {
            accumulators[accumulators.count - 1].textDepth += 1
        } else if accumulators[accumulators.count - 1].textDepth > 0,
                  Self.narrativeBreakElements.contains(name) {
            appendNarrativeBreak()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if documentTitleDepth == depth { documentTitleDepth = 0 }
        depth -= 1
        if suppressedDepth > 0 {
            suppressedDepth -= 1
            return
        }

        let name = elementName.lowercased()
        guard !accumulators.isEmpty else { return }
        if name == "section" {
            let accumulator = accumulators.removeLast()
            let title = normalizedInlineText(accumulator.title)
            let text = normalizedNarrativeText(accumulator.text)
            if !text.isEmpty {
                sections.append(DicomCDASection(
                    id: accumulator.id,
                    title: title.isEmpty ? nil : title,
                    text: text
                ))
            }
            return
        }
        if name == "title" {
            accumulators[accumulators.count - 1].titleDepth = max(
                0,
                accumulators[accumulators.count - 1].titleDepth - 1
            )
        }
        if name == "text" {
            accumulators[accumulators.count - 1].textDepth = max(
                0,
                accumulators[accumulators.count - 1].textDepth - 1
            )
        } else if accumulators[accumulators.count - 1].textDepth > 0,
                  Self.narrativeBreakElements.contains(name) {
            appendNarrativeBreak()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard suppressedDepth == 0 else { return }
        characterCount += string.count
        guard characterCount <= Self.maximumCharacters else {
            fail(.documentTooLarge, parser: parser)
            return
        }

        if documentTitleDepth > 0 { documentTitle.append(string) }
        guard !accumulators.isEmpty else { return }
        let index = accumulators.count - 1
        if accumulators[index].titleDepth > 0 {
            accumulators[index].title.append(string)
        } else if accumulators[index].textDepth > 0 {
            accumulators[index].text.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName _: String,
        publicID _: String?,
        systemID _: String?
    ) {
        fail(.unsafeXML, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName _: String,
        value _: String?
    ) {
        fail(.unsafeXML, parser: parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName _: String, systemID _: String?) -> Data? {
        fail(.unsafeXML, parser: parser)
        return nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred _: Error) {
        if failure == nil {
            failure = .malformedXML
        }
        parser.abortParsing()
    }

    private func appendNarrativeBreak() {
        let index = accumulators.count - 1
        if !accumulators[index].text.hasSuffix("\n") {
            accumulators[index].text.append("\n")
        }
    }

    private func fail(_ error: DicomCDAContentError, parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }

    private func normalizedInlineText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func normalizedNarrativeText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizedInlineText(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
