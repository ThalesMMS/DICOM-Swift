import Foundation
import XCTest
@testable import HL7v3CDA

final class CDAVersioningTests: CDATestCase {
    func test_lineageGapsAndEqualVersions_preserveAllParentsInStableOrder() throws {
        var document = try CDAFixtures.document("ccd-minimal")
        document.versionNumber = try INT("10")
        let parents: [(String, String?)] = [("first", "8"), ("older", "3"), ("second", "8"), ("unknown", nil)]
        document.relatedDocuments = parents.map { identifier, version in
            var children = [Node("id", attributes: ["root": "2.25.2362", "extension": identifier])]
            if let version { children.append(Node("versionNumber", attributes: ["value": version])) }
            return RelatedDocument(node: Node("relatedDocument", attributes: ["typeCode": "RPLC"], children: [
                Node("parentDocument", children: children)
            ]))
        }
        let lineage = try CDADocumentVersioning.lineage(from: document)
        XCTAssertEqual(lineage.map(\.versionNumber), [10, 8, 8, 3, nil])
        XCTAssertEqual(lineage.dropFirst().map(\.documentIDExtension), ["first", "second", "older", "unknown"])
    }

    func test_explicitParent_controlsReplacementVersionAndLineage() throws {
        var document = try CDAFixtures.document("ccd-minimal")
        document.versionNumber = try INT("2")
        var parent = document
        parent.versionNumber = try INT("9")
        let replacement = try CDADocumentVersioning.newVersion(of: document, replacing: parent)
        XCTAssertEqual(replacement.versionNumber?.value, "10")
        XCTAssertEqual(try CDADocumentVersioning.lineage(from: replacement).map(\.versionNumber), [10, 9])
        parent.versionNumber = try INT("-1")
        XCTAssertThrowsError(try CDADocumentVersioning.newVersion(of: document, replacing: parent)) {
            XCTAssertEqual($0 as? CDAVersioningError, .invalidVersionNumber)
        }
    }

    func test_replacementAndAppendix_preserveSetIDAndIncrementVersion() throws {
        let base = try CDAFixtures.document("ccd-minimal")
        let replacement = try CDADocumentVersioning.newVersion(of: base)
        XCTAssertEqual(replacement.setId?.root, base.setId?.root)
        XCTAssertEqual(replacement.versionNumber?.value, "2")
        XCTAssertEqual(replacement.relatedDocuments.last?.node[attribute: "typeCode"], "RPLC")
        let appendix = try CDADocumentVersioning.appendix(of: replacement)
        XCTAssertEqual(appendix.versionNumber?.value, "3")
        XCTAssertEqual(appendix.relatedDocuments.last?.node[attribute: "typeCode"], "APND")
        XCTAssertEqual(try CDADocumentVersioning.lineage(from: appendix).count, 3)
    }

    func test_lineageCycle_isRejected() throws {
        var document = try CDAFixtures.document()
        let related = RelatedDocument(node: XMLNode("relatedDocument", attributes: ["typeCode": "RPLC"], children: [
            XMLNode("parentDocument", children: [XMLNode("id", attributes: ["root": document.id?.root ?? "2.25.2362", "extension": document.id?.extension ?? "synthetic"]),
                                                   XMLNode("versionNumber", attributes: ["value": "1"])])
        ]))
        document.relatedDocuments = [related]
        XCTAssertThrowsError(try CDADocumentVersioning.lineage(from: document))
    }
}
