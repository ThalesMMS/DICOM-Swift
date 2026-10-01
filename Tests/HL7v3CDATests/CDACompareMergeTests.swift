import Foundation
import XCTest
@testable import HL7v3CDA

final class CDACompareMergeTests: CDATestCase {
    func test_identicalRepeatedChildren_haveNoSpuriousDiff() {
        let document = ClinicalDocument(node: Node("ClinicalDocument", children: [
            Node("templateId", attributes: ["root": "2.25.1"]),
            Node("templateId", attributes: ["root": "2.25.2"]),
            Node("templateId", attributes: ["root": "2.25.3"])
        ]))
        XCTAssertTrue(CDADocumentComparator.compare(document, document).isEmpty)
    }

    func test_mergeTextConflict_preservesPreferredTextSegmentsOnce() throws {
        var baseTitle = Node("title")
        baseTitle.content = [.text("Base "), .comment("separator"), .text("title")]
        var incomingTitle = Node("title")
        incomingTitle.content = [.text("Incoming "), .comment("separator"), .text("title")]
        let base = ClinicalDocument(node: Node("ClinicalDocument", children: [baseTitle]))
        let incoming = ClinicalDocument(node: Node("ClinicalDocument", children: [incomingTitle]))
        for (policy, expected) in [(CDAMergePolicy.preferBase, baseTitle), (.preferIncoming, incomingTitle)] {
            let result = CDADocumentMerger.merge(base: base, incoming: incoming, policy: policy)
            let title = try XCTUnwrap(result.document.node.first("title"))
            XCTAssertEqual(title.content, expected.content)
            XCTAssertEqual(title.textContent, expected.textContent)
            XCTAssertEqual(result.conflicts.count, 1)
        }
    }

    func test_compare_detectsNarrativeAndHeaderChanges() throws {
        let base = try CDAFixtures.document("ccd-minimal")
        var changed = base
        changed.title = ST("Changed")
        let diff = CDADocumentComparator.compare(a: base, b: changed)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(diff.changed.contains { $0.path.contains("title") })
    }

    func test_unionEntriesByID_keepsBothNarrativesAndReportsConflicts() throws {
        let base = try CDAFixtures.document("ccd-minimal")
        var incoming = base
        guard case .structured(var body) = incoming.body, var section = body.sections.first else { return XCTFail("missing section") }
        section.title = ST("Incoming")
        var sections = body.sections
        sections[0] = section
        body.sections = sections
        incoming.body = .structured(body)
        let result = CDADocumentMerger.merge(base: base, incoming: incoming, policy: .unionEntriesByID)
        XCTAssertFalse(result.conflicts.isEmpty)
        XCTAssertTrue(result.droppedNodes.isEmpty)
        XCTAssertFalse(result.document.validateLinks().contains { $0.kind == .dangling })
    }
}
