import XCTest
@testable import DicomCore

final class DicomStructuredReportByReferenceTests: XCTestCase {
    private let concept = DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM")

    private func document(_ children: [DicomSRContentItem], suffix: String = "33") -> DicomSRDocument {
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88." + suffix, templateIdentifier: "1500",
            root: .init(valueType: "CONTAINER", conceptName: concept, children: children))
    }

    private func reference(_ identifier: [Int], relationship: String = "INFERRED FROM") -> DicomSRContentItem {
        .init(relationshipType: relationship, valueType: "CONTAINER", referencedContentItemIdentifier: identifier)
    }

    private func text(_ children: [DicomSRContentItem] = []) -> DicomSRContentItem {
        .init(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: "Synthetic", children: children)
    }

    func test_byReference_roundTripsOnlyRelationshipAndIdentifier() throws {
        let item = reference([1, 2])
        let encoded = DicomStructuredReportBuilder.contentItemDataSet(item)
        XCTAssertEqual(Set(encoded.elements.map(\.tag)), [0x0040A010, 0x0040DB73])
        XCTAssertEqual(DicomSRParser.contentItem(from: encoded), item)
        XCTAssertTrue(item.isByReference)
        for suffix in ["33", "34"] {
            let report = document([text([item]), text()], suffix: suffix)
            XCTAssertTrue(report.semanticValidation.isValid, "\(report.semanticValidation.errors)")
            let dataSet = DicomStructuredReportBuilder.dataSet(from: report,
                studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3")
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("a1-reference-\(UUID().uuidString).dcm")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let parsed = try XCTUnwrap(DCMDecoder(contentsOf: url).structuredReport)
            XCTAssertEqual(parsed.root.children, report.root.children)
            XCTAssertTrue(parsed.parseDiagnostics.isEmpty)
            XCTAssertTrue(parsed.semanticValidation.isValid, "\(parsed.semanticValidation.errors)")
            XCTAssertTrue(DicomStructuredReportBuilder.transformationReport(for: report).entries.isEmpty)
        }
        XCTAssertTrue(document([text([item]), text()], suffix: "22").semanticValidation.errors.contains(
            .byReferenceNotPermitted(path: "root/0/0")))
    }

    func test_byReferenceWithChildren_recordsEverySkippedDescendant() {
        let dataSet = DicomDataSet(elements: [
            .init(tag: 0x0040A010, vr: .CS, value: .strings(["INFERRED FROM"])),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 2])),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([
                .init(dataSet: DicomStructuredReportBuilder.contentItemDataSet(text([text()])))
            ]))
        ])
        var diagnostics: [DicomSRParseDiagnostic] = []
        let parsed = DicomSRParser.contentItem(from: dataSet, diagnostics: &diagnostics)
        XCTAssertTrue(parsed?.isByReference == true)
        XCTAssertTrue(parsed?.children.isEmpty == true)
        XCTAssertEqual(Set(diagnostics.filter { $0.code == "itemSkipped" }.map(\.path)), [[0], [0, 0]])
    }

    func test_missingSelfAncestorAndReferenceTargets_reportStableErrors() {
        XCTAssertTrue(document([text([reference([1, 99])])]).semanticValidation.errors.contains(
            .byReferenceTargetMissing(path: "root/0/0", identifier: [1, 99])))
        XCTAssertTrue(document([text([reference([1, 1, 1])])]).semanticValidation.errors.contains(
            .byReferenceToSelfOrAncestor(path: "root/0/0")))
        XCTAssertTrue(document([text([reference([1, 1])])]).semanticValidation.errors.contains(
            .byReferenceToSelfOrAncestor(path: "root/0/0")))
        XCTAssertTrue(document([text([reference([1, 2, 1])]), text([reference([1, 1])])]).semanticValidation.errors.contains(
            .byReferenceTargetIsByReference(path: "root/0/0")))
        for relationship in ["CONTAINS", "HAS CONCEPT MOD"] {
            XCTAssertTrue(document([text([reference([1, 2], relationship: relationship)]), text()]).semanticValidation.errors.contains(
                .byReferenceNotPermitted(path: "root/0/0")))
        }
    }

    func test_twoItemCycles_reportCycleWithoutRecursion() {
        let report = document([text([reference([1, 2])]), text([reference([1, 1])])])
        XCTAssertTrue(report.semanticValidation.errors.contains(.byReferenceCycle(path: "root/0/0")))
        XCTAssertTrue(report.semanticValidation.errors.contains(.byReferenceCycle(path: "root/1/0")))
        let chain = document([reference([1, 2]), reference([1, 1])])
        XCTAssertTrue(chain.semanticValidation.errors.contains(.byReferenceCycle(path: "root/0")))
    }

    func test_scoord3D_requiresFrameOfReferenceAndPermittedSOPClass() {
        let item = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "SCOORD3D", conceptName: concept,
            graphicType: "POINT", graphicData: [1, 2, 3])
        XCTAssertTrue(document([item], suffix: "34").semanticValidation.errors.contains(.missingFrameOfReferenceUID(path: "root/0")))
        for suffix in ["22", "33"] {
            XCTAssertTrue(document([item], suffix: suffix).semanticValidation.errors.contains(
                .unsupportedValueType(path: "root/0", valueType: "SCOORD3D")))
            XCTAssertTrue(DicomStructuredReportBuilder.transformationReport(for: document([item], suffix: suffix)).entries.contains {
                $0.path == [0] && $0.kind == .valueTypeNotPermitted
            })
        }
    }

    func test_scoord3DPointCounts_validateEachGraphicType() {
        let cases: [(String, [Double], Bool)] = [
            ("POINT", [-1, 2, 3], true), ("POINT", [1, 2], false), ("MULTIPOINT", [1, 2, 3], true),
            ("POLYLINE", [1, 2, 3, 4, 5, 6], true), ("POLYLINE", [1, 2, 3], false),
            ("POLYGON", [0, 0, 0, 1, 1, 1, 0, 0, 0], true), ("POLYGON", Array(repeating: 1, count: 8), false),
            ("POLYGON", [0, 0, 0, 1, 1, 1, 2, 2, 2], false),
            ("ELLIPSE", Array(repeating: 1, count: 12), true), ("ELLIPSOID", Array(repeating: 1, count: 18), true),
            ("CIRCLE", [1, 2, 3, 4, 5, 6], false), ("POINT", [.infinity, 0, 0], false)
        ]
        for (type, data, valid) in cases {
            let item = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "SCOORD3D", conceptName: concept,
                graphicType: type, graphicData: data, frameOfReferenceUID: "2.25.1")
            XCTAssertEqual(document([item], suffix: "34").semanticValidation.isValid, valid, type)
        }
    }

    func test_invalidTemporalCoordinatesAndMissingWaveformSOP_reportErrors() {
        let cases: [DicomSRContentItem] = [
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept, temporalRangeType: "POINT"),
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept,
                temporalRangeType: "POINT", referencedSamplePositions: [1], referencedTimeOffsets: [1]),
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept,
                temporalRangeType: "INVALID", referencedTimeOffsets: [1])
        ]
        for item in cases {
            XCTAssertTrue(document([item]).semanticValidation.errors.contains(.invalidTemporalCoordinates(path: "root/0")))
        }
        XCTAssertTrue(document([.init(relationshipType: "CONTAINS", valueType: "WAVEFORM", conceptName: concept)])
            .semanticValidation.errors.contains(.missingReferencedSOP(path: "root/0")))
    }
}
