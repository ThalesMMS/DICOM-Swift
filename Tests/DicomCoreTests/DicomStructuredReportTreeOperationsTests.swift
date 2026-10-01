import XCTest
@testable import DicomCore

final class DicomStructuredReportTreeOperationsTests: XCTestCase {
    func test_parserContentItem_deepDataSet_preservesEveryNodeWithoutRecursiveStackGrowth() throws {
        let depth = 5_000
        var dataSet = contentDataSet(valueType: "TEXT", textValue: "leaf")
        for index in 1..<depth {
            dataSet = contentDataSet(
                valueType: "CONTAINER",
                textValue: "node-\(index)",
                children: [dataSet]
            )
        }

        let parsed = try XCTUnwrap(DicomSRParser.contentItem(from: dataSet))

        let summary = singleChildChainSummary(parsed)
        XCTAssertEqual(summary.count, depth)
        XCTAssertEqual(summary.firstTextValue, "node-4999")
        XCTAssertEqual(summary.lastTextValue, "leaf")
    }

    func test_parserContentItem_invalidChildren_omitsInvalidLeavesAndPreservesSiblingOrder() throws {
        let invalidLeaf = DicomDataSet()
        let validNestedChild = contentDataSet(valueType: "TEXT", textValue: "nested")
        let emptyParentWithValidChild = contentDataSet(children: [invalidLeaf, validNestedChild])
        let rootDataSet = contentDataSet(
            valueType: "CONTAINER",
            children: [
                contentDataSet(valueType: "TEXT", textValue: "first"),
                invalidLeaf,
                emptyParentWithValidChild,
                contentDataSet(valueType: "TEXT", textValue: "last")
            ]
        )

        let parsed = try XCTUnwrap(DicomSRParser.contentItem(from: rootDataSet))

        XCTAssertEqual(parsed.children.map(\.textValue), ["first", nil, "last"])
        XCTAssertEqual(parsed.children.map(\.valueType), ["TEXT", "CONTAINER", "TEXT"])
        XCTAssertEqual(parsed.children[1].children.map(\.textValue), ["nested"])
    }

    func test_builder_deepTree_preservesParentChildOrderWithoutRecursiveStackGrowth() throws {
        let depth = 5_000
        let document = report(root: reportRoot(children: [deepItem(depth: depth, leafText: "leaf")]))

        let dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.100",
            seriesInstanceUID: "2.25.200",
            sopInstanceUID: "2.25.300"
        )

        let firstItem = try XCTUnwrap(dataSet.sequenceItems(for: .contentSequence).first?.dataSet)
        let summary = singleChildDataSetChainSummary(firstItem)
        XCTAssertEqual(summary.count, depth)
        XCTAssertEqual(summary.firstTextValue, "node-4999")
        XCTAssertEqual(summary.lastTextValue, "leaf")
    }

    func test_builder_wideTree_preservesSequenceItemOrder() {
        let width = 5_000
        let children = (0..<width).map { index in
            DicomSRContentItem(valueType: "TEXT", textValue: "child-\(index)")
        }
        let document = report(root: reportRoot(children: children))

        let dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.100",
            seriesInstanceUID: "2.25.200",
            sopInstanceUID: "2.25.300"
        )

        let items = dataSet.sequenceItems(for: .contentSequence)
        XCTAssertEqual(items.count, width)
        XCTAssertEqual(items.first?.dataSet.string(for: .textValue), "child-0")
        XCTAssertEqual(items[width / 2].dataSet.string(for: .textValue), "child-2500")
        XCTAssertEqual(items.last?.dataSet.string(for: .textValue), "child-4999")
    }

    func test_contentItemEquality_equalDeepTrees_comparesWithoutRecursiveStackGrowth() {
        let left = deepItem(depth: 5_000, leafText: "same-leaf")
        let right = deepItem(depth: 5_000, leafText: "same-leaf")

        XCTAssertTrue(left == right)
    }

    func test_contentItemEquality_deepLeafMismatch_returnsFalseWithoutReflectingTrees() {
        let left = deepItem(depth: 5_000, leafText: "left-leaf")
        let right = deepItem(depth: 5_000, leafText: "right-leaf")

        XCTAssertFalse(left == right)
    }

    func test_contentItemEquality_wideTrees_detectsLateMismatchAndPreservesOrderSensitivity() {
        let width = 5_000
        let left = wideItem(width: width)
        let equal = wideItem(width: width)
        let lateMismatch = wideItem(width: width, replacementText: "different", at: width - 1)

        XCTAssertTrue(left == equal)
        XCTAssertFalse(left == lateMismatch)
    }

    func test_contentItemEquality_fullyPopulatedShallowItems_comparesEveryStoredProperty() {
        let baseline = fullyPopulatedItem()
        let variants: [(field: String, item: DicomSRContentItem)] = [
            ("relationshipType", fullyPopulatedItem(relationshipType: "HAS PROPERTIES")),
            ("valueType", fullyPopulatedItem(valueType: "CODE")),
            ("conceptName", fullyPopulatedItem(conceptName: codedConcept(index: 2))),
            ("continuityOfContent", fullyPopulatedItem(continuityOfContent: "CONTINUOUS")),
            ("textValue", fullyPopulatedItem(textValue: "different text")),
            ("codeValue", fullyPopulatedItem(codeValue: codedConcept(index: 3))),
            ("numericValue", fullyPopulatedItem(numericValue: 43.5)),
            ("measurementUnits", fullyPopulatedItem(measurementUnits: codedConcept(index: 4))),
            ("dateTimeValue", fullyPopulatedItem(dateTimeValue: DicomDateTime("20260831123456-0300"))),
            ("dateValue", fullyPopulatedItem(dateValue: DicomDate("20260831"))),
            ("timeValue", fullyPopulatedItem(timeValue: DicomTime("133456.25"))),
            ("personNameValue", fullyPopulatedItem(personNameValue: DicomPersonName("Reader^Two"))),
            ("uidValue", fullyPopulatedItem(uidValue: "2.25.999")),
            ("referencedSOPs", fullyPopulatedItem(referencedSOPs: [sourceReference(index: 2)])),
            ("graphicType", fullyPopulatedItem(graphicType: "CIRCLE")),
            ("graphicData", fullyPopulatedItem(graphicData: [9, 8, 7, 6])),
            ("trackingID", fullyPopulatedItem(trackingID: "different-tracking-id")),
            ("trackingUID", fullyPopulatedItem(trackingUID: "2.25.998")),
            ("children", fullyPopulatedItem(children: [DicomSRContentItem(valueType: "CODE")]))
        ]

        XCTAssertTrue(baseline == fullyPopulatedItem())
        for variant in variants {
            XCTAssertFalse(baseline == variant.item, "Equality ignored \(variant.field)")
        }

        XCTAssertFalse(
            fullyPopulatedItem(numericValue: .nan) == fullyPopulatedItem(numericValue: .nan),
            "Double.nan must retain native non-reflexive equality"
        )
        XCTAssertTrue(
            fullyPopulatedItem(numericValue: -0.0) == fullyPopulatedItem(numericValue: 0.0),
            "Signed zero must retain native Double equality"
        )
    }

    func test_extraction_deepCADMeasurementAndROI_isStackSafeAndDeduplicatesReferences() throws {
        let firstReference = sourceReference(index: 1)
        let secondReference = sourceReference(index: 2)
        let image = DicomSRContentItem(
            relationshipType: "SELECTED FROM",
            valueType: "IMAGE",
            referencedSOPs: [secondReference, firstReference]
        )
        var branch = DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            referencedSOPs: [firstReference, firstReference],
            graphicType: "POLYLINE",
            graphicData: [1, 2, 3, 4],
            children: [image]
        )
        for _ in 0..<4_996 {
            branch = DicomSRContentItem(valueType: "CONTAINER", children: [branch])
        }
        let measurementItem = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            numericValue: 42.5,
            children: [branch]
        )
        let cadRoot = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: cadFindingConcept,
            trackingID: "deep-cad",
            children: [measurementItem]
        )
        let document = report(root: cadRoot)

        let measurement = try XCTUnwrap(document.measurements.first)
        let finding = try XCTUnwrap(document.cadFindings.first)

        XCTAssertEqual(document.measurements.count, 1)
        XCTAssertEqual(measurement.value, 42.5)
        XCTAssertEqual(measurement.sourceImageReferences, [firstReference, secondReference])
        XCTAssertEqual(measurement.roi?.graphicType, "POLYLINE")
        XCTAssertEqual(measurement.roi?.graphicData, [1, 2, 3, 4])
        XCTAssertEqual(measurement.roi?.sourceImageReferences, [firstReference, secondReference])
        XCTAssertEqual(document.cadFindings.count, 1)
        XCTAssertEqual(finding.trackingID, "deep-cad")
        XCTAssertEqual(finding.measurements.map(\.value), [42.5])
        XCTAssertEqual(finding.sourceImageReferences, [firstReference, secondReference])
    }

    func test_extraction_nestedCADFindings_scopesMeasurementsAndPreservesPreorder() {
        let nestedFinding = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: cadFindingConcept,
            trackingID: "nested",
            children: [measurement(value: 2)]
        )
        let outerFinding = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: cadFindingConcept,
            trackingID: "outer",
            children: [measurement(value: 1), nestedFinding]
        )
        let document = report(root: outerFinding)

        let findings = document.cadFindings

        XCTAssertEqual(document.measurements.map(\.value), [1, 2])
        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings.map(\.trackingID), ["outer", "nested"])
        XCTAssertEqual(findings[0].measurements.map(\.value), [1, 2])
        XCTAssertEqual(findings[1].measurements.map(\.value), [2])
    }

    func test_extraction_multipleSCOORDs_usesFirstRegionAndStableReferenceDeduplication() throws {
        let firstReference = sourceReference(index: 1)
        let secondReference = sourceReference(index: 2)
        let laterReference = sourceReference(index: 3)
        let firstRegion = DicomSRContentItem(
            valueType: "SCOORD",
            referencedSOPs: [firstReference, firstReference],
            graphicType: "POLYLINE",
            graphicData: [1, 2, 3, 4],
            children: [
                DicomSRContentItem(
                    valueType: "IMAGE",
                    referencedSOPs: [secondReference, firstReference]
                )
            ]
        )
        let laterRegion = DicomSRContentItem(
            valueType: "SCOORD",
            referencedSOPs: [laterReference, secondReference],
            graphicType: "CIRCLE",
            graphicData: [10, 20, 30, 40]
        )
        let finding = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: cadFindingConcept,
            children: [measurement(value: 7, children: [firstRegion, laterRegion])]
        )
        let document = report(root: finding)

        let extracted = try XCTUnwrap(document.measurements.first)
        let cadFinding = try XCTUnwrap(document.cadFindings.first)

        XCTAssertEqual(extracted.sourceImageReferences, [firstReference, secondReference, laterReference])
        XCTAssertEqual(extracted.roi?.graphicType, "POLYLINE")
        XCTAssertEqual(extracted.roi?.graphicData, [1, 2, 3, 4])
        XCTAssertEqual(extracted.roi?.sourceImageReferences, [firstReference, secondReference])
        XCTAssertEqual(cadFinding.sourceImageReferences, [firstReference, secondReference, laterReference])
    }

    private var reportTitleConcept: DicomCodedConcept {
        DicomCodedConcept(
            codeValue: "126000",
            codingSchemeDesignator: "DCM",
            codeMeaning: "Imaging Measurement Report"
        )
    }

    private var cadFindingConcept: DicomCodedConcept {
        DicomCodedConcept(
            codeValue: "CAD-FINDING",
            codingSchemeDesignator: "99TEST",
            codeMeaning: "CAD Finding"
        )
    }

    private func report(root: DicomSRContentItem) -> DicomSRDocument {
        DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            sopInstanceUID: "2.25.300",
            root: root
        )
    }

    private func reportRoot(children: [DicomSRContentItem]) -> DicomSRContentItem {
        DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: reportTitleConcept,
            children: children
        )
    }

    private func deepItem(depth: Int, leafText: String) -> DicomSRContentItem {
        precondition(depth >= 1)
        var item = DicomSRContentItem(valueType: "TEXT", textValue: leafText)
        for index in 1..<depth {
            item = DicomSRContentItem(
                valueType: "CONTAINER",
                textValue: "node-\(index)",
                children: [item]
            )
        }
        return item
    }

    private func wideItem(width: Int, replacementText: String? = nil, at replacementIndex: Int? = nil)
        -> DicomSRContentItem {
        DicomSRContentItem(
            valueType: "CONTAINER",
            children: (0..<width).map { index in
                DicomSRContentItem(
                    valueType: "TEXT",
                    textValue: index == replacementIndex ? replacementText : "child-\(index)"
                )
            }
        )
    }

    private func measurement(
        value: Double,
        children: [DicomSRContentItem] = []
    ) -> DicomSRContentItem {
        DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            numericValue: value,
            children: children
        )
    }

    private func sourceReference(index: Int) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.source-\(index)",
            referencedFrameNumbers: [index]
        )
    }

    private func codedConcept(index: Int) -> DicomCodedConcept {
        DicomCodedConcept(
            codeValue: "code-\(index)",
            codingSchemeDesignator: "99TEST",
            codeMeaning: "Concept \(index)"
        )
    }

    private func fullyPopulatedItem(
        relationshipType: String? = "CONTAINS",
        valueType: String = "NUM",
        conceptName: DicomCodedConcept? = DicomCodedConcept(
            codeValue: "code-1",
            codingSchemeDesignator: "99TEST",
            codeMeaning: "Concept 1"
        ),
        continuityOfContent: String? = "SEPARATE",
        textValue: String? = "baseline text",
        codeValue: DicomCodedConcept? = DicomCodedConcept(
            codeValue: "code-value",
            codingSchemeDesignator: "99TEST",
            codeMeaning: "Code value"
        ),
        numericValue: Double? = 42.5,
        measurementUnits: DicomCodedConcept? = DicomCodedConcept(
            codeValue: "mm",
            codingSchemeDesignator: "UCUM",
            codeMeaning: "millimeter"
        ),
        dateTimeValue: DicomDateTime? = DicomDateTime("20260830123456-0300"),
        dateValue: DicomDate? = DicomDate("20260830"),
        timeValue: DicomTime? = DicomTime("123456.25"),
        personNameValue: DicomPersonName? = DicomPersonName("Reader^One"),
        uidValue: String? = "2.25.301",
        referencedSOPs: [DicomSourceImageReference] = [DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.source-1",
            referencedFrameNumbers: [1]
        )],
        graphicType: String? = "POLYLINE",
        graphicData: [Double] = [1, 2, 3, 4],
        trackingID: String? = "tracking-id",
        trackingUID: String? = "2.25.302",
        children: [DicomSRContentItem] = [DicomSRContentItem(valueType: "TEXT", textValue: "child")]
    ) -> DicomSRContentItem {
        DicomSRContentItem(
            relationshipType: relationshipType,
            valueType: valueType,
            conceptName: conceptName,
            continuityOfContent: continuityOfContent,
            textValue: textValue,
            codeValue: codeValue,
            numericValue: numericValue,
            measurementUnits: measurementUnits,
            dateTimeValue: dateTimeValue,
            dateValue: dateValue,
            timeValue: timeValue,
            personNameValue: personNameValue,
            uidValue: uidValue,
            referencedSOPs: referencedSOPs,
            graphicType: graphicType,
            graphicData: graphicData,
            trackingID: trackingID,
            trackingUID: trackingUID,
            children: children
        )
    }

    private func contentDataSet(
        valueType: String? = nil,
        textValue: String? = nil,
        children: [DicomDataSet] = []
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let valueType {
            elements.append(DicomStructuredReportBuilder.string(.valueType, vr: .CS, valueType))
        }
        if let textValue {
            elements.append(DicomStructuredReportBuilder.string(.textValue, vr: .UT, textValue))
        }
        if !children.isEmpty {
            elements.append(DicomStructuredReportBuilder.sequence(.contentSequence, children))
        }
        return DicomDataSet(elements: elements)
    }

    private func singleChildChainSummary(_ root: DicomSRContentItem)
        -> (count: Int, firstTextValue: String?, lastTextValue: String?) {
        var count = 0
        var firstTextValue: String?
        var lastTextValue: String?
        var pending: DicomSRContentItem? = root
        while let item = pending {
            if count == 0 {
                firstTextValue = item.textValue
            }
            count += 1
            lastTextValue = item.textValue
            XCTAssertLessThanOrEqual(item.children.count, 1)
            pending = item.children.first
        }
        return (count, firstTextValue, lastTextValue)
    }

    private func singleChildDataSetChainSummary(_ root: DicomDataSet)
        -> (count: Int, firstTextValue: String?, lastTextValue: String?) {
        var count = 0
        var firstTextValue: String?
        var lastTextValue: String?
        var pending: DicomDataSet? = root
        while let dataSet = pending {
            if count == 0 {
                firstTextValue = dataSet.string(for: .textValue)
            }
            count += 1
            lastTextValue = dataSet.string(for: .textValue)
            let children = dataSet.sequenceItems(for: .contentSequence)
            XCTAssertLessThanOrEqual(children.count, 1)
            pending = children.first?.dataSet
        }
        return (count, firstTextValue, lastTextValue)
    }
}
