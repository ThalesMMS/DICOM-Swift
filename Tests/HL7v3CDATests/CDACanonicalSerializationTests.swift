import Foundation
import XCTest
@testable import HL7v3CDA

final class CDACanonicalSerializationTests: CDATestCase {
    func test_ownSerializer_isByteIdempotentForEntireCorpus() throws {
        for name in CDAFixtures.all {
            let first = try CDADocumentSerializer().serialize(CDAFixtures.document(name))
            let second = try CDADocumentSerializer().serialize(CDADocumentParser().parse(first))
            XCTAssertEqual(first, second, name)
        }
    }
    func test_attributeOrder_isDeterministic() throws {
        var first = Node("x", attributes: ["z": "1", "a": "2", "m": "3"])
        first.namespaces[""] = CDANamespace.hl7
        let second = Node("x", attributes: ["m": "3", "a": "2", "z": "1"])
        let output = try XMLSerializer().serialize(first)
        XCTAssertEqual(output, try XMLSerializer().serialize(second))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "<x xmlns=\"urn:hl7-org:v3\" a=\"2\" m=\"3\" z=\"1\"/>")
    }
    func test_mixedContentCommentsAndEscaping_arePreserved() throws {
        var node = Node("text", attributes: ["ID": "test", "title": "<&\"\n\t\r"])
        node.namespaces[""] = CDANamespace.hl7
        node.content = [.text("Before "), .comment("keep"), .element(Node("content", text: "A & B")), .text(" after.")]
        let data = try XMLSerializer(indentation: 2).serialize(node)
        XCTAssertEqual(try SafeXMLParser().parse(data), node)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Before <!--keep--><content>A &amp; B</content> after."))
    }
    func test_optionalIndentation_doesNotChangeNarrative() throws {
        let doc = try CDAFixtures.document("narrative-links")
        let original = try CDAFixtures.sections(doc)[0].narrative
        let output = try CDADocumentSerializer(indentation: 2).serialize(doc)
        let parsed = try CDADocumentParser().parse(output)
        XCTAssertEqual(try CDAFixtures.sections(parsed)[0].narrative, original)
        try CDAFixtures.validateXSD(output)
    }
    func test_headerOrder_isCanonicalWhenConstructedOutOfOrder() throws {
        var doc = try CDAFixtures.document()
        doc.node.children.reverse()
        let data = try CDADocumentSerializer().serialize(doc)
        try CDAFixtures.validateXSD(data)
        XCTAssertEqual(try CDADocumentParser().parse(data).id?.root, "2.25.2362")
    }
    func test_invalidConstructedXML_failsInsteadOfEmittingMarkup() {
        XCTAssertThrowsError(try XMLSerializer().serialize(Node("x><evil")))
        var node = Node("x"); node.content = [.comment("--bad")]
        XCTAssertThrowsError(try XMLSerializer().serialize(node))
        XCTAssertThrowsError(try XMLSerializer().serialize(Node("x", text: "\0")))
    }
}
