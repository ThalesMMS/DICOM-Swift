import XCTest
@testable import DicomCore

final class DicomStructuredReportTests: XCTestCase {
    func test_normativeLanguageAndQualitativeConcepts_validate() throws {
        let document = try DicomSRMeasurementReportBuilder.build(DicomSRMeasurementReportBuilderTests.fullReport())
        XCTAssertTrue(document.semanticValidation.isValid, "\(document.semanticValidation.errors)")
    }

    /// Issue #2778: a measurement group names itself with its 112039/112040 items, not with the Segmentation
    /// attributes; the extracted measurements take their group's identity from those items.
    func test_measurements_takeTheirGroupsIdentity_fromTheTrackingItems() throws {
        let document = try DicomSRMeasurementReportBuilder.build(DicomSRMeasurementReportBuilderTests.fullReport())
        XCTAssertTrue(document.flattenedContentItems.allSatisfy { $0.trackingID == nil && $0.trackingUID == nil })

        let generic = document.measurements.filter { $0.trackingUID == "2.25.2345020" }
        XCTAssertFalse(generic.isEmpty)
        XCTAssertTrue(generic.allSatisfy { $0.trackingID == "PARITY-GENERIC" })
        let planar = document.measurements.filter { $0.trackingUID == "2.25.2345021" }
        XCTAssertFalse(planar.isEmpty)
        XCTAssertTrue(planar.allSatisfy { $0.trackingID == "PARITY-PLANAR" })

        let group = try XCTUnwrap(document.flattenedContentItems.first { $0.statedTrackingUID == "2.25.2345021" })
        XCTAssertEqual(group.valueType, "CONTAINER")
        XCTAssertEqual(group.statedTrackingID, "PARITY-PLANAR")
    }

    func test_segmentSelectedContent_matchesEvidenceWithoutLosingFrameScope() throws {
        let image = DicomSourceImageReference(referencedSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
            referencedSOPInstanceUID: "2.25.10", referencedFrameNumbers: [2], referencedSegmentNumbers: [3])
        let root = DicomSRContentItem(valueType: "CONTAINER",
            conceptName: .init(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report"),
            continuityOfContent: "SEPARATE", children: [
            .init(relationshipType: "CONTAINS", valueType: "IMAGE",
                conceptName: .init(codeValue: "121191", codingSchemeDesignator: "DCM", codeMeaning: "Referenced Segment"),
                referencedSOPs: [image])
        ])
        for frame in [2, 3] {
            let evidence = DicomKeyObjectReference(studyInstanceUID: "2.25.20", seriesInstanceUID: "2.25.21",
                referencedSOPClassUID: image.referencedSOPClassUID, referencedSOPInstanceUID: image.referencedSOPInstanceUID,
                referencedFrameNumbers: [frame])
            let document = DicomSRDocument(sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
                templateIdentifier: "1500", root: root, evidenceReferences: [evidence])
            if frame == 3 {
                XCTAssertThrowsError(try DicomStructuredReportBuilder.validatedDataSet(from: document,
                    studyInstanceUID: "2.25.20", seriesInstanceUID: "2.25.22")) {
                    XCTAssertEqual($0 as? DicomStructuredReportBuildError, .unrepresentedEvidenceFrames(index: 0))
                }
                continue
            }
            let dataSet = try DicomStructuredReportBuilder.validatedDataSet(from: document,
                studyInstanceUID: "2.25.20", seriesInstanceUID: "2.25.22")
            let study = try XCTUnwrap(dataSet.sequenceItems(for: .currentRequestedProcedureEvidenceSequence).first?.dataSet)
            let series = try XCTUnwrap(study.sequenceItems(for: .referencedSeriesSequence).first?.dataSet)
            let sop = try XCTUnwrap(series.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
            XCTAssertNil(sop[DicomTag.referencedFrameNumber.rawValue])
        }
    }

    func test_mixedEvidenceInputs_roundTripRetainsUngroupedReferences() throws {
        let root = try DicomSRMeasurementReportBuilder.build(DicomSRMeasurementReportBuilderTests.fullReport()).root
        let references = (1...3).map { index in
            DicomKeyObjectReference(studyInstanceUID: "2.25.20", seriesInstanceUID: "2.25.21",
                referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2", referencedSOPInstanceUID: "2.25.30\(index)")
        }
        let document = DicomSRDocument(sopClassUID: DicomSRDocument.comprehensive3DSRStorageSOPClassUID,
            templateIdentifier: "1500", root: root, evidenceReferences: [references[0], references[1]],
            currentRequestedProcedureEvidence: [references[1]], pertinentOtherEvidence: [references[2]])
        let parsed = try XCTUnwrap(try open(document: document).structuredReport)
        XCTAssertEqual(Set(parsed.evidenceReferences), Set(references))
        XCTAssertEqual(parsed.currentRequestedProcedureEvidence, [references[1], references[0]])
        XCTAssertEqual(parsed.pertinentOtherEvidence, [references[2]])
    }

    func test_extendedContentFields_roundTripWithoutLoss() throws {
        let concept = DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM",
            codeMeaning: "Imaging Measurement Report", codingSchemeVersion: "2026c")
        let units = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codingSchemeVersion: "2.2")
        let dateTime = try XCTUnwrap(DicomDateTime("20260910120000.123-0300"))
        let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.10", referencedFrameNumbers: [2], referencedSegmentNumbers: [3, 5])
        let waveform = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.9.1.1",
            referencedSOPInstanceUID: "2.25.11", referencedWaveformChannels: [1, 2, 1, 3])
        let children: [DicomSRContentItem] = [
            .init(relationshipType: "CONTAINS", valueType: "SCOORD3D", conceptName: concept,
                graphicType: "POINT", graphicData: [-1, 2, 3], frameOfReferenceUID: "2.25.12", fiducialUID: "2.25.13"),
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept,
                temporalRangeType: "POINT", referencedSamplePositions: [1]),
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept,
                temporalRangeType: "SEGMENT", referencedTimeOffsets: [0.25, 1.5]),
            .init(relationshipType: "CONTAINS", valueType: "TCOORD", conceptName: concept,
                temporalRangeType: "POINT", referencedDateTimes: [dateTime]),
            .init(relationshipType: "CONTAINS", valueType: "WAVEFORM", conceptName: concept, referencedSOPs: [waveform]),
            .init(relationshipType: "CONTAINS", valueType: "IMAGE", conceptName: concept, referencedSOPs: [reference]),
            .init(relationshipType: "CONTAINS", valueType: "NUM", conceptName: concept,
                numericValue: 1.5, measurementUnits: units, numericValueQualifier: concept, floatingPointValue: 1.5,
                rationalNumeratorValue: 3, rationalDenominatorValue: 2, observationDateTime: dateTime, observationUID: "2.25.14"),
            .init(relationshipType: "CONTAINS", valueType: "CONTAINER", conceptName: concept,
                continuityOfContent: "SEPARATE", contentTemplate: .init(mappingResource: "DCMR", templateIdentifier: "1501")),
            .init(relationshipType: "CONTAINS", valueType: "NUM", conceptName: concept,
                numericValueQualifier: concept)
        ]
        let current = DicomKeyObjectReference(studyInstanceUID: "2.25.20", seriesInstanceUID: "2.25.21",
            referencedSOPClassUID: reference.referencedSOPClassUID, referencedSOPInstanceUID: reference.referencedSOPInstanceUID)
        let other = DicomKeyObjectReference(studyInstanceUID: "2.25.30", seriesInstanceUID: "2.25.31",
            referencedSOPClassUID: waveform.referencedSOPClassUID, referencedSOPInstanceUID: waveform.referencedSOPInstanceUID)
        let root = DicomSRContentItem(valueType: "CONTAINER", conceptName: concept, continuityOfContent: "SEPARATE",
            children: children, observationDateTime: dateTime, observationUID: "2.25.40",
            contentTemplate: .init(mappingResource: "DCMR", templateIdentifier: "1500"))
        let document = DicomSRDocument(sopClassUID: DicomSRDocument.comprehensive3DSRStorageSOPClassUID,
            templateIdentifier: "1500", root: root, currentRequestedProcedureEvidence: [current], pertinentOtherEvidence: [other])
        XCTAssertTrue(document.semanticValidation.isValid, "\(document.semanticValidation.errors)")
        let parsed = try XCTUnwrap(try open(document: document).structuredReport)
        XCTAssertEqual(parsed.root, root)
        XCTAssertEqual(parsed.currentRequestedProcedureEvidence, [current])
        XCTAssertEqual(parsed.pertinentOtherEvidence, [other])
        XCTAssertEqual(parsed.evidenceReferences, [current, other])
        XCTAssertTrue(parsed.parseDiagnostics.isEmpty, "\(parsed.parseDiagnostics)")
        XCTAssertTrue(parsed.semanticValidation.isValid, "\(parsed.semanticValidation.errors)")
        let reparsed = try XCTUnwrap(try open(document: parsed).structuredReport)
        XCTAssertEqual(reparsed.root, root)
        XCTAssertEqual(reparsed.currentRequestedProcedureEvidence, [current])
        XCTAssertEqual(reparsed.pertinentOtherEvidence, [other])
        XCTAssertNotEqual(DicomSourceImageReferenceIdentity(reference), DicomSourceImageReferenceIdentity(
            .init(referencedSOPClassUID: reference.referencedSOPClassUID,
                referencedSOPInstanceUID: reference.referencedSOPInstanceUID, referencedFrameNumbers: [2])))
        XCTAssertNotEqual(DicomSourceImageReferenceIdentity(waveform), DicomSourceImageReferenceIdentity(
            .init(referencedSOPClassUID: waveform.referencedSOPClassUID, referencedSOPInstanceUID: waveform.referencedSOPInstanceUID)))
    }

    func test_unparseableAndUnsupportedAttributes_recordPHIFreeDiagnostics() throws {
        var dataSet = DicomStructuredReportBuilder.dataSet(from: supportedMeasurementDocument(),
            studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let malformed = DicomDataSet(elements: [
            .init(tag: 0x0040A040, vr: .CS, value: .strings(["TCOORD"])),
            .init(tag: 0x0040A13A, vr: .DT, value: .strings(["invalid-private-value"])),
            .init(tag: 0x77770010, vr: .LO, value: .strings(["private-value"]))
        ])
        dataSet.set(.init(tag: 0x0040A730, vr: .SQ, value: .sequence([
            .init(dataSet: .init()), .init(dataSet: malformed)
        ])))
        let parsed = try XCTUnwrap(try open(dataSet: dataSet,
            sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID).structuredReport)
        XCTAssertEqual(parsed.root.children.count, 1)
        XCTAssertTrue(parsed.parseDiagnostics.contains { $0.path == [0] && $0.code == "itemSkipped" })
        XCTAssertTrue(parsed.parseDiagnostics.contains { $0.path == [1] && $0.code == "attributeNotRepresentable" })
        XCTAssertFalse(parsed.parseDiagnostics.contains { $0.message.contains("private-value") })
        let report = DicomStructuredReportBuilder.transformationReport(for: parsed)
        XCTAssertTrue(report.entries.contains { $0.path == [0] && $0.kind == .itemSkipped })
        XCTAssertTrue(report.entries.contains { $0.path == [1] && $0.kind == .attributeNotRepresentable })
    }

    func testStructuredReportSemanticSupportMatrixDeclaresValidatedScope() {
        let matrix = DicomSRSupportMatrix.standard

        XCTAssertTrue(matrix.supportedSOPClassUIDs.contains(DicomSRDocument.enhancedSRStorageSOPClassUID))
        XCTAssertTrue(matrix.supportedSOPClassUIDs.contains(DicomSRDocument.comprehensiveSRStorageSOPClassUID))
        XCTAssertTrue(matrix.supportedSOPClassUIDs.contains(
            DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
        ))
        XCTAssertEqual(
            matrix.supportedTemplateIdentifiersBySOPClassUID[DicomSRDocument.comprehensiveSRStorageSOPClassUID],
            ["1500"]
        )
        XCTAssertEqual(
            matrix.supportedTemplateIdentifiersBySOPClassUID[
                DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
            ],
            ["2010"]
        )
        // A.35.4.3.1.3 mandates TID 2010; a KOS without an explicit identifier uses it.
        XCTAssertTrue(matrix.supportsTemplate(nil, sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID))
        XCTAssertTrue(matrix.supportsTemplate("2010", sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID))
        XCTAssertFalse(matrix.supportsTemplate("1500", sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID))
        XCTAssertFalse(matrix.supportsTemplate(nil, sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID))
        XCTAssertTrue(matrix.supportedValueTypes.isSuperset(of: ["CONTAINER", "NUM", "IMAGE", "SCOORD", "CODE"]))
        XCTAssertTrue(matrix.supportedRelationshipTypes.isSuperset(of: ["CONTAINS", "INFERRED FROM", "SELECTED FROM"]))
        XCTAssertTrue(matrix.supportedByReferenceRelationshipTypes.isEmpty)
        XCTAssertTrue(matrix.supportedCodingSchemeDesignators.isSuperset(of: ["DCM", "SCT", "UCUM"]))
        XCTAssertTrue(matrix.supportedMeasurementUnitSchemes.contains("UCUM"))
        XCTAssertTrue(matrix.supportedMeasurementGroups.contains("TID1500 Imaging Measurement Report"))
        XCTAssertTrue(matrix.supportedObservationContextValueTypes.isSuperset(of: ["TEXT", "CODE", "PNAME"]))
        XCTAssertTrue(matrix.supportsEvidenceReferences)
        XCTAssertTrue(matrix.supportsTemplate("1500", sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID))
        XCTAssertFalse(matrix.supportsTemplate("1501", sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID))
    }

    func testStructuredReportParsesMeasurementsROIsCADFindingsAndRoundTrips() throws {
        let source = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.7001",
            referencedFrameNumbers: [3]
        )
        let keyReference = DicomKeyObjectReference(
            studyInstanceUID: "2.25.7000",
            seriesInstanceUID: "2.25.7002",
            referencedSOPClassUID: source.referencedSOPClassUID,
            referencedSOPInstanceUID: source.referencedSOPInstanceUID,
            referencedFrameNumbers: source.referencedFrameNumbers
        )
        let area = DicomCodedConcept(codeValue: "42798000", codingSchemeDesignator: "SCT", codeMeaning: "Area")
        let squareMillimeter = DicomCodedConcept(codeValue: "mm2", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter")
        let reportTitle = DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report")
        let findingTitle = DicomCodedConcept(codeValue: "111001", codingSchemeDesignator: "DCM", codeMeaning: "CAD Finding")
        let keyImage = DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object")

        let roi = DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            conceptName: DicomCodedConcept(codeValue: "111030", codingSchemeDesignator: "DCM", codeMeaning: "Image Region"),
            graphicType: "POLYLINE",
            graphicData: [1, 2, 3, 4, 5, 6],
            children: [
                DicomSRContentItem(
                    relationshipType: "SELECTED FROM",
                    valueType: "IMAGE",
                    conceptName: keyImage,
                    referencedSOPs: [source]
                )
            ]
        )
        let measurement = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: area,
            numericValue: 42.5,
            measurementUnits: squareMillimeter,
            trackingID: "lesion-area",
            trackingUID: "2.25.7101",
            children: [roi]
        )
        let cadFinding = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "CONTAINER",
            conceptName: findingTitle,
            trackingID: "cad-finding-1",
            children: [
                DicomSRContentItem(
                    relationshipType: "CONTAINS",
                    valueType: "IMAGE",
                    conceptName: keyImage,
                    referencedSOPs: [source]
                ),
                DicomSRContentItem(
                    relationshipType: "CONTAINS",
                    valueType: "NUM",
                    conceptName: area,
                    numericValue: 12.0,
                    measurementUnits: squareMillimeter
                )
            ]
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            sopInstanceUID: "2.25.7201",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: "1500",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: reportTitle,
                continuityOfContent: "SEPARATE",
                children: [measurement, cadFinding]
            ),
            evidenceReferences: [keyReference]
        )

        let decoder = try openValidated(document: document)
        let parsed = try XCTUnwrap(decoder.structuredReport)

        XCTAssertTrue(parsed.semanticValidation.isValid)
        XCTAssertEqual(parsed.sopInstanceUID, "2.25.7201")
        XCTAssertEqual(parsed.templateIdentifier, "1500")
        XCTAssertEqual(parsed.root.conceptName, reportTitle)
        XCTAssertEqual(parsed.flattenedContentItems.count, 7)
        XCTAssertEqual(parsed.measurements.count, 2)
        XCTAssertEqual(parsed.measurements.first?.name, area)
        XCTAssertEqual(parsed.measurements.first?.value, 42.5)
        XCTAssertEqual(parsed.measurements.first?.units, squareMillimeter)
        XCTAssertEqual(parsed.measurements.first?.trackingID, "lesion-area")
        XCTAssertEqual(parsed.measurements.first?.roi?.graphicType, "POLYLINE")
        XCTAssertEqual(parsed.measurements.first?.roi?.graphicData, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(parsed.measurements.first?.sourceImageReferences, [source])
        XCTAssertEqual(parsed.cadFindings.count, 1)
        XCTAssertEqual(parsed.cadFindings.first?.title, findingTitle)
        XCTAssertEqual(parsed.cadFindings.first?.measurements.first?.value, 12.0)
        XCTAssertEqual(parsed.keyObjectReferences, [keyReference])

        let reopened = try open(document: parsed)
        let reparsed = try XCTUnwrap(reopened.structuredReport)
        XCTAssertTrue(reparsed.semanticValidation.isValid)
        XCTAssertEqual(reparsed.measurements.map(\.value), [42.5, 12.0])
        XCTAssertEqual(reparsed.cadFindings.first?.sourceImageReferences, [source])
    }

    func testKeyObjectSelectionBuilderProducesNavigableReferences() throws {
        let keyObject = DicomKeyObjectReference(
            studyInstanceUID: "2.25.8001",
            seriesInstanceUID: "2.25.8002",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.8003",
            referencedFrameNumbers: [5]
        )
        let title = DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object")
        let dataSet = DicomKeyObjectSelectionBuilder.dataSet(
            title: title,
            keyObjects: [keyObject],
            studyInstanceUID: "2.25.8001",
            seriesInstanceUID: "2.25.8100",
            sopInstanceUID: "2.25.8200"
        )

        let decoder = try open(dataSet: dataSet, sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID)
        let kos = try XCTUnwrap(decoder.keyObjectSelection)

        XCTAssertEqual(kos.sopClassUID, DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID)
        XCTAssertEqual(kos.modality, "KO")
        XCTAssertTrue(kos.semanticValidation.isValid)
        XCTAssertEqual(kos.root.conceptName, title)
        XCTAssertEqual(kos.keyObjectReferences, [keyObject])
        XCTAssertEqual(kos.contentItems(matching: { $0.valueType == "IMAGE" }).first?.referencedSOPs.first, keyObject.sourceImageReference)
        // Issue #2784: the KOS IOD has no Content Identification module.
        XCTAssertNil(dataSet[.contentLabel])
        XCTAssertNil(dataSet[.contentDescription])
    }

    func test_structuredReportTraversal_preservesPreorderAndReferenceOrder() {
        let first = sourceReference(index: 1)
        let second = sourceReference(index: 2)
        let third = sourceReference(index: 3)
        let fourth = sourceReference(index: 4)
        let root = DicomSRContentItem(
            valueType: "CONTAINER",
            textValue: "root",
            referencedSOPs: [first, first],
            children: [
                DicomSRContentItem(
                    valueType: "CONTAINER",
                    textValue: "first-child",
                    referencedSOPs: [second, first],
                    children: [
                        DicomSRContentItem(
                            valueType: "IMAGE",
                            textValue: "grandchild",
                            referencedSOPs: [third, second]
                        )
                    ]
                ),
                DicomSRContentItem(
                    valueType: "IMAGE",
                    textValue: "second-child",
                    referencedSOPs: [fourth, third]
                )
            ]
        )

        XCTAssertEqual(
            root.flattened.map(\.textValue),
            ["root", "first-child", "grandchild", "second-child"]
        )
        XCTAssertEqual(root.allSourceImageReferences, [first, second, third, fourth])
    }

    func test_sourceReferenceDeduplication_preservesExactEqualityEdgeCases() {
        let nilClass = DicomSourceImageReference(
            referencedSOPClassUID: nil,
            referencedSOPInstanceUID: "2.25.shared",
            referencedFrameNumbers: [1, 2]
        )
        let emptyClass = DicomSourceImageReference(
            referencedSOPClassUID: "",
            referencedSOPInstanceUID: "2.25.shared",
            referencedFrameNumbers: [1, 2]
        )
        let orderedFrames = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.class",
            referencedSOPInstanceUID: "2.25.shared",
            referencedFrameNumbers: [1, 2]
        )
        let reversedFrames = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.class",
            referencedSOPInstanceUID: "2.25.shared",
            referencedFrameNumbers: [2, 1]
        )
        let root = DicomSRContentItem(
            valueType: "IMAGE",
            referencedSOPs: [nilClass, emptyClass, orderedFrames, reversedFrames, orderedFrames]
        )

        XCTAssertEqual(
            root.allSourceImageReferences,
            [nilClass, emptyClass, orderedFrames, reversedFrames]
        )
    }

    func test_keyObjectReferenceDeduplication_preservesCurrentIdentitySemantics() {
        let sharedSource = sourceReference(index: 1)
        let evidenceInFirstSeries = DicomKeyObjectReference(
            studyInstanceUID: "2.25.study-a",
            seriesInstanceUID: "2.25.series-a",
            referencedSOPClassUID: sharedSource.referencedSOPClassUID,
            referencedSOPInstanceUID: sharedSource.referencedSOPInstanceUID,
            referencedFrameNumbers: sharedSource.referencedFrameNumbers
        )
        let evidenceInSecondSeries = DicomKeyObjectReference(
            studyInstanceUID: "2.25.study-b",
            seriesInstanceUID: "2.25.series-b",
            referencedSOPClassUID: sharedSource.referencedSOPClassUID,
            referencedSOPInstanceUID: sharedSource.referencedSOPInstanceUID,
            referencedFrameNumbers: sharedSource.referencedFrameNumbers
        )
        let uniqueSource = sourceReference(index: 2)
        let expectedUniqueReference = DicomKeyObjectReference(
            referencedSOPClassUID: uniqueSource.referencedSOPClassUID,
            referencedSOPInstanceUID: uniqueSource.referencedSOPInstanceUID,
            referencedFrameNumbers: uniqueSource.referencedFrameNumbers
        )
        let document = DicomSRDocument(
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                children: [
                    DicomSRContentItem(
                        valueType: "IMAGE",
                        referencedSOPs: [sharedSource, uniqueSource, sharedSource]
                    )
                ]
            ),
            evidenceReferences: [evidenceInFirstSeries, evidenceInSecondSeries, evidenceInFirstSeries]
        )

        XCTAssertEqual(
            document.evidenceReferences,
            [evidenceInFirstSeries, evidenceInSecondSeries]
        )
        XCTAssertEqual(
            document.keyObjectReferences,
            [evidenceInFirstSeries, evidenceInSecondSeries, expectedUniqueReference]
        )
    }

    func test_structuredReportTraversal_handlesFiveThousandItemDeepChain() {
        let source = sourceReference(index: 1)
        var root = DicomSRContentItem(valueType: "IMAGE", referencedSOPs: [source])
        for depth in 0..<4_999 {
            root = DicomSRContentItem(
                valueType: "CONTAINER",
                textValue: "node-\(depth)",
                children: [root]
            )
        }

        let flattened = root.flattened

        XCTAssertEqual(flattened.count, 5_000)
        XCTAssertEqual(flattened.first?.textValue, "node-4998")
        XCTAssertEqual(flattened.last?.valueType, "IMAGE")
        XCTAssertEqual(root.allSourceImageReferences, [source])
    }

    func test_structuredReportTraversal_handlesWideTreeWithStableDeduplication() {
        let uniqueReferenceCount = 1_000
        let childCount = 5_000
        let children = (0..<childCount).map { index in
            DicomSRContentItem(
                valueType: "IMAGE",
                textValue: "child-\(index)",
                referencedSOPs: [sourceReference(index: index % uniqueReferenceCount)]
            )
        }
        let root = DicomSRContentItem(valueType: "CONTAINER", children: children)

        XCTAssertEqual(root.flattened.count, childCount + 1)
        XCTAssertEqual(root.allSourceImageReferences.count, uniqueReferenceCount)
        XCTAssertEqual(root.allSourceImageReferences.first, sourceReference(index: 0))
        XCTAssertEqual(root.allSourceImageReferences.last, sourceReference(index: uniqueReferenceCount - 1))
    }

    func testStructuredReportSemanticValidatorRejectsUnsupportedTemplateWithStableError() throws {
        let document = supportedMeasurementDocument(templateIdentifier: "9999")

        XCTAssertEqual(
            document.semanticValidation.errors.first,
            .unsupportedTemplateIdentifier("9999", sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID)
        )
        XCTAssertThrowsError(try DicomStructuredReportBuilder.validatedDataSet(
            from: document,
            studyInstanceUID: "2.25.7000",
            seriesInstanceUID: "2.25.7300",
            sopInstanceUID: document.sopInstanceUID
        )) { error in
            let failure = error as? DicomSRSemanticValidationFailure
            XCTAssertEqual(
                failure?.errors.first,
                .unsupportedTemplateIdentifier("9999", sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID)
            )
        }

        let syntacticDecoder = try open(document: document)
        let syntacticReport = try XCTUnwrap(syntacticDecoder.structuredReport)
        XCTAssertFalse(syntacticReport.semanticValidation.isValid)
    }

    func testStructuredReportSemanticValidatorRejectsUnsupportedRelationshipPattern() {
        let document = supportedMeasurementDocument(measurement: DicomSRContentItem(
            relationshipType: "HAS SOMETHING",
            valueType: "NUM",
            conceptName: areaConcept,
            numericValue: 42.5,
            measurementUnits: squareMillimeterConcept
        ))

        XCTAssertTrue(document.semanticValidation.errors.contains(
            .unsupportedRelationshipType(path: "root/0", relationshipType: "HAS SOMETHING")
        ))
    }

    func testStructuredReportSemanticValidatorRejectsByReferenceRelationshipPattern() {
        let document = supportedMeasurementDocument(measurement: DicomSRContentItem(
            relationshipType: "R-CONTAINS",
            valueType: "NUM",
            conceptName: areaConcept,
            numericValue: 42.5,
            measurementUnits: squareMillimeterConcept
        ))

        XCTAssertTrue(document.semanticValidation.errors.contains(
            .unsupportedByReferenceRelationship(path: "root/0", relationshipType: "R-CONTAINS")
        ))
    }

    func testStructuredReportSemanticValidatorRejectsMalformedNumericMeasurement() {
        let document = supportedMeasurementDocument(measurement: DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: areaConcept
        ))

        XCTAssertTrue(document.semanticValidation.errors.contains(.missingNumericValue(path: "root/0")))
        XCTAssertTrue(document.semanticValidation.errors.contains(.missingMeasurementUnits(path: "root/0")))
    }

    func testStructuredReportSemanticValidatorRejectsUnsupportedMeasurementUnits() {
        let document = supportedMeasurementDocument(measurement: DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: areaConcept,
            numericValue: 42.5,
            measurementUnits: DicomCodedConcept(codeValue: "1", codingSchemeDesignator: "99UNITS")
        ))

        XCTAssertTrue(document.semanticValidation.errors.contains(
            .unsupportedMeasurementUnit(path: "root/0", codingSchemeDesignator: "99UNITS")
        ))
    }

    func testKeyObjectSelectionSemanticValidationRejectsMissingReferences() {
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID,
            modality: "KO",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: keyObjectConcept,
                continuityOfContent: "SEPARATE",
                children: [
                    DicomSRContentItem(
                        relationshipType: "CONTAINS",
                        valueType: "IMAGE",
                        conceptName: keyObjectConcept
                    )
                ]
            )
        )

        XCTAssertTrue(document.semanticValidation.errors.contains(.missingReferencedSOP(path: "root/0")))
        XCTAssertTrue(document.semanticValidation.errors.contains(.missingEvidenceReference))
    }

    func testStructuredReportSemanticValidatorRejectsUnsupportedSOPClassScope() {
        let document = supportedMeasurementDocument(sopClassUID: DicomSRDocument.basicTextSRStorageSOPClassUID)

        XCTAssertEqual(
            document.semanticValidation.errors.first,
            .unsupportedSOPClassUID(DicomSRDocument.basicTextSRStorageSOPClassUID)
        )
    }

    func testStructuredReportSemanticValidatorPreservesObservationContextValueTypes() throws {
        let observerName = try XCTUnwrap(DicomPersonName("Reader^One"))
        let document = supportedMeasurementDocument(children: [
            DicomSRContentItem(
                relationshipType: "HAS OBS CONTEXT",
                valueType: "PNAME",
                conceptName: DicomCodedConcept(
                    codeValue: "121008",
                    codingSchemeDesignator: "DCM",
                    codeMeaning: "Person Observer Name"
                ),
                personNameValue: observerName
            ),
            supportedMeasurementItem()
        ])

        XCTAssertTrue(document.semanticValidation.isValid)
    }

    private var areaConcept: DicomCodedConcept {
        DicomCodedConcept(codeValue: "42798000", codingSchemeDesignator: "SCT", codeMeaning: "Area")
    }

    private var squareMillimeterConcept: DicomCodedConcept {
        DicomCodedConcept(codeValue: "mm2", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter")
    }

    private var reportTitleConcept: DicomCodedConcept {
        DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report")
    }

    private var keyObjectConcept: DicomCodedConcept {
        DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object")
    }

    private func sourceReference(index: Int) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.source-\(index)",
            referencedFrameNumbers: [index + 1]
        )
    }

    private var sourceImageReference: DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.7001",
            referencedFrameNumbers: [3]
        )
    }

    private var evidenceReference: DicomKeyObjectReference {
        DicomKeyObjectReference(
            studyInstanceUID: "2.25.7000",
            seriesInstanceUID: "2.25.7002",
            referencedSOPClassUID: sourceImageReference.referencedSOPClassUID,
            referencedSOPInstanceUID: sourceImageReference.referencedSOPInstanceUID,
            referencedFrameNumbers: sourceImageReference.referencedFrameNumbers
        )
    }

    private func supportedMeasurementItem() -> DicomSRContentItem {
        DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: areaConcept,
            numericValue: 42.5,
            measurementUnits: squareMillimeterConcept,
            children: [
                DicomSRContentItem(
                    relationshipType: "INFERRED FROM",
                    valueType: "SCOORD",
                    conceptName: DicomCodedConcept(
                        codeValue: "111030",
                        codingSchemeDesignator: "DCM",
                        codeMeaning: "Image Region"
                    ),
                    graphicType: "POLYLINE",
                    graphicData: [1, 2, 3, 4],
                    children: [
                        DicomSRContentItem(
                            relationshipType: "SELECTED FROM",
                            valueType: "IMAGE",
                            conceptName: keyObjectConcept,
                            referencedSOPs: [sourceImageReference]
                        )
                    ]
                )
            ]
        )
    }

    private func supportedMeasurementDocument(
        templateIdentifier: String? = "1500",
        sopClassUID: String? = DicomSRDocument.comprehensiveSRStorageSOPClassUID,
        measurement: DicomSRContentItem? = nil,
        children: [DicomSRContentItem]? = nil
    ) -> DicomSRDocument {
        DicomSRDocument(
            sopClassUID: sopClassUID,
            sopInstanceUID: "2.25.7201",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: templateIdentifier,
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: reportTitleConcept,
                continuityOfContent: "SEPARATE",
                children: children ?? [measurement ?? supportedMeasurementItem()]
            ),
            evidenceReferences: [evidenceReference]
        )
    }

    private func openValidated(document: DicomSRDocument) throws -> DCMDecoder {
        let dataSet = try DicomStructuredReportBuilder.validatedDataSet(
            from: document,
            studyInstanceUID: "2.25.7000",
            seriesInstanceUID: "2.25.7300",
            sopInstanceUID: document.sopInstanceUID
        )
        return try open(
            dataSet: dataSet,
            sopClassUID: document.sopClassUID ?? DicomSRDocument.enhancedSRStorageSOPClassUID
        )
    }

    private func open(document: DicomSRDocument) throws -> DCMDecoder {
        let dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.7000",
            seriesInstanceUID: "2.25.7300",
            sopInstanceUID: document.sopInstanceUID
        )
        return try open(
            dataSet: dataSet,
            sopClassUID: document.sopClassUID ?? DicomSRDocument.enhancedSRStorageSOPClassUID
        )
    }

    private func open(dataSet: DicomDataSet, sopClassUID: String) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured_report_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }
}


extension DicomStructuredReportTests {
    /// A mean of CT numbers such as 43.333333333333336 needs 17 characters as `String(Double)` writes it; DS allows 16.
    /// The number is written with the most digits that fit and reads back within the last one.
    func test_numericValueWithMoreDigitsThanDSHolds_isWrittenWithTheDigitsThatFit() throws {
        let mean = 130.0 / 3
        let measurement = DicomSRContentItem(
            relationshipType: "CONTAINS", valueType: "NUM",
            conceptName: DicomCodedConcept(codeValue: "112031", codingSchemeDesignator: "DCM", codeMeaning: "Attenuation Coefficient"),
            numericValue: mean,
            measurementUnits: DicomCodedConcept(codeValue: "[hnsf'U]", codingSchemeDesignator: "UCUM", codeMeaning: "Hounsfield unit"))
        let document = DicomSRDocument(
            sopInstanceUID: "2.25.2511",
            root: DicomSRContentItem(valueType: "CONTAINER",
                                     conceptName: DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM",
                                                                    codeMeaning: "Imaging Measurement Report"),
                                     continuityOfContent: "SEPARATE", children: [measurement]))
        let parsed = try XCTUnwrap(try open(document: document).structuredReport)
        let value = try XCTUnwrap(parsed.root.flattened.compactMap(\.numericValue).first)
        XCTAssertEqual(value, mean, accuracy: 1e-12)
    }

    func test_KOSExtendedParameters_validateTID2010AndRoundTrip() throws {
        let code = DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Of Interest")
        let ref = DicomKeyObjectReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.2345090")
        let dataSet = DicomKeyObjectSelectionBuilder.dataSet(title: code, keyObjects: [ref],
            studyInstanceUID: "2.25.2345091", seriesInstanceUID: "2.25.2345092", sopInstanceUID: "2.25.2345093",
            titleModifiers: [code], procedureCodes: [code],
            language: .init(code: .init(codeValue: "en", codingSchemeDesignator: "RFC5646", codeMeaning: "English")),
            observers: [.init(kind: .device, name: "PARITY", deviceUID: "2.25.2345094")],
            keyObjectDescription: "PARITY", compositeObjects: [ref], waveforms: [ref])
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet)).structuredReport)
        let result = DicomSRTemplateValidator.validate(parsed, template: "2010")
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(parsed.root.children.filter { ["IMAGE", "COMPOSITE", "WAVEFORM"].contains($0.valueType) }.count, 3)
        XCTAssertEqual(parsed.root.children.first { $0.conceptName?.codeValue == "113012" }?.textValue, "PARITY")
    }
}
