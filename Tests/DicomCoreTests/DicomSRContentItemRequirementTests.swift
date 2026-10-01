import XCTest
@testable import DicomCore

final class DicomSRContentItemRequirementTests: XCTestCase {
    func test_inapplicableScalarValue_failsAtOriginalContentPath() {
        let child = item("CODE").setting(text(0x0040A160, "SYNTHETIC", .UT))
        let report = DicomSRContentValidator.validate(root(child))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden &&
            $0.requirement == .type1C && $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A160)] })
    }

    func test_inapplicableTypedMacroRoots_areForbidden() {
        for element in [sequence(0x0040A300, [.init()]), sequence(0x00081199, [.init()]),
                        text(0x00700023, "POINT", .CS), text(0x0040A130, "POINT", .CS),
                        sequence(0x0040A801, [.init()])] {
            let report = DicomSRContentValidator.validate(root(item("TEXT").setting(text(0x0040A160, "SYNTHETIC", .UT)).setting(element)))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden && $0.path.last == .tag(element.tag) })
        }
    }

    func test_byReferenceItem_forbidsTemporalSpatialAndTableMacros() {
        let reference = DicomDataSet(elements: [.init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1])),
            text(0x0040A010, "INFERRED FROM", .CS)])
        for element in [text(0x0040A130, "POINT", .CS), text(0x30060024, "2.25.23219001", .UI),
                        text(0x00480301, "FRAME", .CS), sequence(0x0040A801, [.init()])] {
            let report = DicomSRContentValidator.validate(root(reference.setting(element)))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden &&
                $0.path == [.tag(0x0040A730), .item(0), .tag(element.tag)] })
        }
    }

    func test_valueAndRelationshipTypes_areEnumeratedAttributes() {
        let unknown = DicomSRContentValidator.validate(root(item("FUTURE")))
        XCTAssertTrue(unknown.diagnostics.contains { $0.code == .attributeValueNotAllowed && $0.path.last == .tag(0x0040A040) })
        let relationship = DicomSRContentValidator.validate(root(item("TEXT").setting(text(0x0040A010, "FUTURE", .CS))))
        XCTAssertTrue(relationship.diagnostics.contains { $0.code == .attributeValueNotAllowed && $0.path.last == .tag(0x0040A010) })
    }

    func test_contentConditions_preserveOriginalNestedItemPaths() throws {
        let image = item("IMAGE").removing(0x0040A043)
        let tree = item("CONTAINER").setting(text(0x0040A050, "SEPARATE", .CS)).setting(sequence(0x0040A730, [image, image]))
        let source = root(tree).setting(sequence(0x0040A730, [item("TEXT"), tree]))
        var facts = DicomSRContentItemMacro.Conditions()
        facts.referencePurposeInConceptName = .satisfied
        facts.observationTimeDiffers = .satisfied
        let report = DicomSRContentValidator.validate(source, contentConditions: [[1, 1]: facts])
        for tag in [0x0040A043, 0x0040A032] {
            let missing = report.diagnostics.filter { $0.code == .requiredAttributeMissing && $0.path.last == .tag(tag) }
            XCTAssertEqual(missing.count, 1)
            XCTAssertEqual(missing.first?.path, [.tag(0x0040A730), .item(1), .tag(0x0040A730), .item(1), .tag(tag)])
        }
    }

    private func root(_ child: DicomDataSet) -> DicomDataSet {
        item("CONTAINER").removing(0x0040A010).setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.88.33", .UI))
            .setting(text(0x0040A050, "SEPARATE", .CS)).setting(sequence(0x0040A730, [child]))
    }
    private func item(_ type: String) -> DicomDataSet {
        .init(elements: [text(0x0040A040, type, .CS), text(0x0040A010, "CONTAINS", .CS), sequence(0x0040A043, [
            .init(elements: [text(0x00080100, "126000", .SH), text(0x00080102, "DCM", .SH), text(0x00080104, "SYNTHETIC", .LO)])])])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
