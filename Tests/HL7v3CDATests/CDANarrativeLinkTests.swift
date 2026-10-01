import Foundation
import XCTest
@testable import HL7v3CDA

final class CDANarrativeLinkTests: CDATestCase {
    func test_narrativeReferences_resolveWithinSection() throws {
        let section = try CDAFixtures.sections(CDAFixtures.document("narrative-links"))[0]
        XCTAssertEqual(section.referencedNarrativeNodes(for: section.entries[0]).map { $0[attribute: "ID"] }, ["finding"])
        XCTAssertTrue(section.referencedNarrativeNodes(for: section.entries[1]).isEmpty)
        XCTAssertEqual(section.validateLinks().filter { $0.kind == .dangling }.count, 1)
    }
    func test_duplicateIDs_areReportedWithoutLeakingIdentifier() {
        let node = Node("ClinicalDocument", children: [Node("content", attributes: ["ID": "sensitive-id"]), Node("content", attributes: ["ID": "sensitive-id"])])
        let findings = ClinicalDocument(node: node).validateLinks()
        XCTAssertEqual(findings.map(\.kind), [.duplicateID])
        XCTAssertFalse(findings[0].path.contains("sensitive-id"))
    }
    func test_cycles_areReportedInConstructedModelAndRejectedOnSerialization() {
        let node = Node("ClinicalDocument", children: [Node("content", attributes: ["ID": "a", "IDREF": "b"]), Node("content", attributes: ["ID": "b", "IDREF": "a"])])
        let doc = ClinicalDocument(node: node)
        XCTAssertTrue(doc.validateLinks().contains { $0.kind == .cycle })
        XCTAssertThrowsError(try CDADocumentSerializer().serialize(doc)) { XCTAssertEqual($0 as? CDAError, .cyclicReferences) }
    }
    func test_longAcyclicGraph_isResolvedIteratively() throws {
        let children = (0..<2000).map { index -> Node in
            var node = Node("content", attributes: ["ID": "n\(index)"])
            if index < 1999 { node[attribute: "IDREF"] = "n\(index + 1)" }
            return node
        }
        XCTAssertTrue(ClinicalDocument(node: Node("ClinicalDocument", children: children)).validateLinks().isEmpty)
    }
    func test_descendantReference_contributesEdgeFromContainingID() {
        let root = Node("text", children: [Node("content", attributes: ["ID": "a"], children: [Node("linkHtml", attributes: ["href": "#b"])]), Node("content", attributes: ["ID": "b"], children: [Node("linkHtml", attributes: ["href": "#a"])])])
        XCTAssertTrue(CDALinks.findings(in: root).contains { $0.kind == .cycle })
    }
}
