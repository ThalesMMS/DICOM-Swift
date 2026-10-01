import Foundation
import XCTest
@testable import HL7v3CDA

final class XMLSafetyTests: CDATestCase {
    private func reject(_ data: Data, _ error: CDAError, limits: XMLLimits = XMLLimits(), file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertThrowsError(try SafeXMLParser(limits: limits).parse(data), file: file, line: line) {
            XCTAssertEqual($0 as? CDAError, error, file: file, line: line)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, file: file, line: line)
    }
    func test_billionLaughs_rejectedBeforeExpansion() throws {
        reject(try CDAFixtures.data("malicious/billion-laughs"), .forbiddenDTD)
    }
    func test_externalEntity_neverResolved() throws {
        reject(try CDAFixtures.data("malicious/external-entity"), .forbiddenDTD)
    }
    func test_utf16DTD_rejectedBeforeExpansion() {
        let xml = "<!DOCTYPE x [<!ENTITY a 'test'>]><x>&a;</x>"
        reject(xml.data(using: .utf16)!, .forbiddenDTD)
    }
    func test_declarationTextInCommentsCDATAAndProcessingInstructions_isAccepted() throws {
        let text = "<!DOCTYPE x> <!ENTITY a 'test'>"
        let xml = "<x><!--\(text)--><![CDATA[\(text)]]><?note \(text)?></x>"
        for encoding in [String.Encoding.utf8, .utf16] {
            let root = try SafeXMLParser().parse(try XCTUnwrap(xml.data(using: encoding)))
            XCTAssertEqual(root.textContent, text)
        }
    }
    func test_realDeclarationAfterComment_isStillRejected() {
        let xml = "<!-- <!DOCTYPE harmless> --><!DOCTYPE x [<!ENTITY a 'test'>]><x>&a;</x>"
        reject(Data(xml.utf8), .forbiddenDTD)
    }
    func test_deepNesting_hitsDepthLimit() {
        reject(Data((String(repeating: "<x>", count: 65) + String(repeating: "</x>", count: 65)).utf8), .depthLimit)
    }
    func test_hugeAttribute_hitsAttributeLimit() {
        reject(Data(("<x a=\"" + String(repeating: "x", count: 65_537) + "\"/>").utf8), .attributeLimit)
    }
    func test_namespaceDeclaration_hitsAttributeLimit() {
        reject(Data(("<x xmlns:v=\"urn:" + String(repeating: "x", count: 65_537) + "\"/>").utf8), .attributeLimit)
    }
    func test_textAcrossCDATA_hitsCombinedLimit() {
        var limits = XMLLimits(); limits.maxTextLength = 8
        reject(Data("<x>12345<![CDATA[67890]]></x>".utf8), .textLimit, limits: limits)
    }
    func test_hugeText_hitsDefaultLimit() {
        reject(Data(("<x>" + String(repeating: "x", count: 4 * 1024 * 1024 + 1) + "</x>").utf8), .textLimit)
    }
    func test_elementCount_boundsTreeMemory() {
        var limits = XMLLimits(); limits.maxElements = 1000
        reject(Data(("<x>" + String(repeating: "<y/>", count: 1000) + "</x>").utf8), .elementLimit, limits: limits)
    }
    func test_bytesLimit_appliesToDataAndURL() throws {
        var limits = XMLLimits(); limits.maxBytes = 8
        let data = Data("<x>too long</x>".utf8)
        reject(data, .byteLimit, limits: limits)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SafeXMLParser(limits: limits).parse(url)) { XCTAssertEqual($0 as? CDAError, .byteLimit) }
    }
    func test_cyclicIDREF_rejectedWithoutTraversalLoop() throws {
        reject(try CDAFixtures.data("malicious/cyclic-idref"), .cyclicReferences)
    }
    func test_malformedXML_doesNotExposeContent() {
        reject(Data("<x>private-test</y>".utf8), .malformedXML)
    }
    func test_predefinedEntitiesAndNamespaceScopes_preserved() throws {
        let data = Data("<h:x xmlns:h='urn:hl7-org:v3' xmlns:v='urn:test' v:a='1'><v:y xmlns:v='urn:inner'>A &amp; B</v:y></h:x>".utf8)
        let root = try SafeXMLParser().parse(data)
        XCTAssertEqual(root.name.namespaceURI, CDANamespace.hl7)
        XCTAssertEqual(root.attributes[XMLName("a", namespaceURI: "urn:test", prefix: "v")], "1")
        XCTAssertEqual(root.children.first?.name.namespaceURI, "urn:inner")
        XCTAssertEqual(root.textContent, "A & B")
        XCTAssertEqual(try SafeXMLParser().parse(XMLSerializer().serialize(root)), root)
    }
}
