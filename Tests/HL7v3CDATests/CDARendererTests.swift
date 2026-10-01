import DicomDocumentContent
import Foundation
import XCTest
@testable import HL7v3CDA

final class CDARendererTests: CDATestCase {
    private func document(narrative: String) throws -> ClinicalDocument {
        let source = try String(decoding: CDAFixtures.data("ccd-minimal"), as: UTF8.self)
        let range = try XCTUnwrap(source.range(of: "<text>"))
        let end = try XCTUnwrap(source.range(of: "</text>", range: range.upperBound..<source.endIndex))
        let replaced = source.replacingCharacters(in: range.lowerBound..<end.upperBound, with: "<text>" + narrative + "</text>")
        return try CDADocumentParser().parse(Data(replaced.utf8))
    }

    func test_html_whitelistsNarrativeElementsAndEscapesText() throws {
        let narrative = """
        <paragraph>A &amp; B &lt;tag&gt; <content styleCode="Bold">bold</content></paragraph>\
        <list><item>one</item><item>two</item></list>\
        <table><thead><tr><th>h</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>\
        <linkHtml href="http://example.test/x">link text</linkHtml>\
        <renderMultiMedia referencedObject="m1"/><br/>\
        <script>alert(1)</script><style>body{}</style><iframe src="http://example.test"/>
        """
        let html = CDARenderer.renderHTML(try document(narrative: narrative))
        XCTAssertTrue(html.contains("<p>A &amp; B &lt;tag&gt; <span>bold</span></p>"), html)
        XCTAssertTrue(html.contains("<ul><li>one</li><li>two</li></ul>"))
        XCTAssertTrue(html.contains("<table><thead><tr><th>h</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>"))
        XCTAssertTrue(html.contains("link text"))
        XCTAssertTrue(html.contains("[embedded media]"))
        XCTAssertTrue(html.contains("<br/>"))
        for forbidden in ["<script", "alert(1)", "<style", "body{}", "<iframe", "href=", "src=", "http://example.test", "styleCode"] {
            XCTAssertFalse(html.contains(forbidden), forbidden)
        }
        XCTAssertTrue(html.hasPrefix("<section>"))
    }

    func test_text_isDeterministicAndDropsUntrustedMarkup() throws {
        let doc = try document(narrative: "<paragraph>First &amp; second</paragraph><script>alert(1)</script><table><tbody><tr><td>a</td><td>b</td></tr></tbody></table>")
        let text = CDARenderer.renderText(doc)
        XCTAssertTrue(text.contains("First & second"))
        XCTAssertTrue(text.contains("a\tb"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("<"))
        XCTAssertEqual(text, CDARenderer.renderText(doc))
        XCTAssertEqual(CDARenderer.renderText(try CDAFixtures.document("discharge-summary-structured")).isEmpty, false)
    }

    func test_mixedInlineContent_preservesSubtreeBoundaryWhitespace() throws {
        let doc = try document(narrative: "<paragraph>Before<content> nested<content> deep </content>text </content>after</paragraph>")
        let section = try XCTUnwrap(CDAFixtures.sections(doc).first)
        XCTAssertEqual(CDARenderer.renderText(section), "Before nested deep text after")
        let text = CDARenderer.renderText(doc)
        XCTAssertTrue(text.contains("Before nested deep text after"), text)
    }

    func test_nestedSections_renderInDocumentOrder() throws {
        var doc = try document(narrative: "Parent body")
        var parent = Section(); parent.title = ST("Parent"); parent.narrative = Node("text", text: "Parent body")
        var child = Section(); child.title = ST("Child"); child.narrative = Node("text", text: "Child body")
        var grandchild = Section(); grandchild.narrative = Node("text", text: "Grandchild body")
        child.sections = [Section(), grandchild]
        parent.sections = [child]
        var sibling = Section(); sibling.title = ST("Sibling")
        var body = StructuredBody(); body.sections = [parent, sibling]
        doc.body = .structured(body)
        XCTAssertEqual(CDARenderer.renderText(doc), "Parent\nParent body\n\nChild\nChild body\n\nGrandchild body\n\nSibling")
        XCTAssertEqual(CDARenderer.renderHTML(doc), "<section><h2>Parent</h2>Parent body</section><section><h2>Child</h2>Child body</section><section></section><section>Grandchild body</section><section><h2>Sibling</h2></section>")
    }

    func test_adapter_exposesFullModelAndKeepsNarrativeExtractorBehaviour() throws {
        let data = try CDAFixtures.data("discharge-summary-structured")
        let full = CDADocumentContentAdapter.extract(data: data)
        XCTAssertNotNil(full.value)
        XCTAssertTrue(full.diagnostics.isEmpty)
        XCTAssertEqual(CDADocumentContentAdapter.extractNarrative(data: data).value, DicomCDANarrativeExtractor.parse(data).value)
        let expectedSections = try CDAFixtures.sections(try XCTUnwrap(full.value)).count
        XCTAssertEqual(DicomCDANarrativeExtractor.parse(data).value?.sections.count, expectedSections)
        let broken = CDADocumentContentAdapter.extract(data: Data("<!DOCTYPE x><ClinicalDocument/>".utf8))
        XCTAssertNil(broken.value)
        XCTAssertFalse(broken.diagnostics.isEmpty)
        XCTAssertFalse(broken.diagnostics.contains { $0.reason.contains("DOCTYPE") })
    }
}
