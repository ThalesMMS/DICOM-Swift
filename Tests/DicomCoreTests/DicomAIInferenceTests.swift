import XCTest
@testable import DicomCore

final class DicomAIInferenceTests: XCTestCase {
    func test_contentIdentificationVRs_matchTheStandardInDictionaryAndPresentationBytes() throws {
        let dictionary = DCMDictionary()
        XCTAssertEqual(dictionary.vrCode(forTag: DicomTag.contentLabel.rawValue), "CS")
        XCTAssertEqual(dictionary.vrCode(forTag: DicomTag.contentDescription.rawValue), "LO")
        let data = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [],
            graphicAnnotations: [],
            options: .init(contentLabel: "REVIEW", contentDescription: "Synthetic presentation")
        )
        let decoder = try DCMDecoder(data: data)
        XCTAssertEqual(decoder.dataSet[.contentLabel]?.vr, .CS)
        XCTAssertEqual(decoder.dataSet[.contentDescription]?.vr, .LO)
        XCTAssertEqual(decoder.grayscalePresentationState?.contentLabel, "REVIEW")
        XCTAssertEqual(decoder.grayscalePresentationState?.contentDescription, "Synthetic presentation")
    }

    func test_graphicTrackingAndLayerDescription_useStandardVRs() throws {
        XCTAssertEqual(DCMDictionary().vrCode(forTag: DicomTag.trackingID.rawValue), "UT")
        let data = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [],
            graphicAnnotations: [.init(
                graphicLayer: "TEST",
                graphicObjects: [.init(graphicType: "POINT", graphicData: [1, 2], trackingID: "graphic-tracking")],
                textObjects: [.init(text: "Note", trackingID: "text-tracking")]
            )],
            graphicLayers: [.init(name: "TEST", description: "Synthetic layer")]
        )
        let decoder = try DCMDecoder(data: data)
        let layer = try XCTUnwrap(decoder.dataSet.sequenceItems(for: .graphicLayerSequence).first)
        XCTAssertEqual(layer.dataSet[.graphicLayerDescription]?.vr, .LO)
        let annotation = try XCTUnwrap(decoder.dataSet.sequenceItems(for: .graphicAnnotationSequence).first)
        let graphic = try XCTUnwrap(annotation.dataSet.sequenceItems(for: .graphicObjectSequence).first)
        let text = try XCTUnwrap(annotation.dataSet.sequenceItems(for: .textObjectSequence).first)
        XCTAssertEqual(graphic.dataSet[.trackingID]?.vr, .UT)
        XCTAssertEqual(text.dataSet[.trackingID]?.vr, .UT)
        XCTAssertEqual(decoder.grayscalePresentationState?.graphicLayers.first?.description, "Synthetic layer")
        XCTAssertEqual(decoder.grayscalePresentationState?.graphicAnnotations.first?.graphicObjects.first?.trackingID,
                       "graphic-tracking")
        XCTAssertEqual(decoder.grayscalePresentationState?.graphicAnnotations.first?.textObjects.first?.trackingID,
                       "text-tracking")
    }

    func test_compoundGraphicRotation_writesFDAndPreservesDoublePrecision() throws {
        let angle = 90.123456789
        let graphic = DicomPresentationCompoundGraphic(
            instanceID: 1, units: "PIXEL", graphicType: "RANGELINE", graphicData: [1, 1, 8, 8],
            rotationAngle: angle, rotationPoint: SIMD2<Double>(4, 4)
        )
        let data = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [],
            graphicAnnotations: [.init(graphicLayer: "TEST", graphicObjects: [], compoundGraphics: [graphic])]
        )
        let decoder = try DCMDecoder(data: data)
        let annotation = try XCTUnwrap(decoder.dataSet.sequenceItems(for: .graphicAnnotationSequence).first)
        let compound = try XCTUnwrap(annotation.dataSet.sequenceItems(for: .compoundGraphicSequence).first)
        XCTAssertEqual(compound.dataSet[.rotationAngle]?.vr, .FD)
        let decodedAngle = try XCTUnwrap(
            decoder.grayscalePresentationState?.graphicAnnotations.first?.compoundGraphics.first?.rotationAngle
        )
        XCTAssertEqual(decodedAngle, angle, accuracy: 1e-10)
    }

    func testFindingBecomesStructuredReportWithTrackingAndSourceReferences() throws {
        let source = DicomKeyObjectReference(
            studyInstanceUID: "2.25.9001",
            seriesInstanceUID: "2.25.9002",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9003",
            referencedFrameNumbers: [4]
        )
        let region = DicomSRGraphicRegion(
            graphicType: "POLYLINE",
            graphicData: [1, 1, 5, 1, 5, 5, 1, 1],
            sourceImageReferences: [source.sourceImageReference]
        )
        let area = DicomAIFindingMeasurement(
            concept: DicomCodedConcept(codeValue: "42798000", codingSchemeDesignator: "SCT", codeMeaning: "Area"),
            value: 14.5,
            units: DicomCodedConcept(codeValue: "mm2", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter")
        )
        let finding = DicomAIFinding(
            title: DicomCodedConcept(codeValue: "111001", codingSchemeDesignator: "DCM", codeMeaning: "CAD Finding"),
            findingCode: DicomCodedConcept(codeValue: "85756007", codingSchemeDesignator: "SCT", codeMeaning: "Lesion"),
            description: "Synthetic test finding",
            confidence: 0.92,
            trackingID: "finding-1",
            trackingUID: "2.25.9010",
            sourceImageReferences: [source],
            regions: [region],
            measurements: [area]
        )

        let data = try DicomAIInferenceBuilder.structuredReportPart10Data(
            findings: [finding],
            options: DicomAIInferenceBuildOptions(
                sopInstanceUID: "2.25.9020",
                studyInstanceUID: "2.25.9001",
                seriesInstanceUID: "2.25.9021",
                contentLabel: "AI_SR"
            )
        )

        let decoder = try open(data: data, name: "ai_sr")
        let report = try XCTUnwrap(decoder.structuredReport)
        // Issue #2784: the SR IODs have no Content Identification module.
        XCTAssertNil(decoder.dataSet[.contentLabel])
        XCTAssertNil(decoder.dataSet[.contentDescription])

        XCTAssertEqual(report.sopClassUID, DicomSRDocument.comprehensiveSRStorageSOPClassUID)
        XCTAssertEqual(report.sopInstanceUID, "2.25.9020")
        XCTAssertEqual(report.templateIdentifier, "1500")
        XCTAssertEqual(report.keyObjectReferences, [source])
        XCTAssertEqual(report.cadFindings.count, 1)
        XCTAssertEqual(report.cadFindings.first?.trackingID, "finding-1")
        XCTAssertEqual(report.cadFindings.first?.trackingUID, "2.25.9010")
        XCTAssertEqual(report.cadFindings.first?.sourceImageReferences, [source.sourceImageReference])
        XCTAssertEqual(report.measurements.map(\.value).sorted(), [0.92, 14.5])
        XCTAssertEqual(report.measurements.first { $0.value == 14.5 }?.roi?.graphicData, region.graphicData)
    }

    func testSyntheticMaskBecomesSegmentationWithTrackingAndLabelmap() throws {
        let source = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9101",
            referencedFrameNumbers: [1]
        )
        let segment = DicomSegment(
            number: 1,
            label: "Lesion",
            algorithmType: "AUTOMATIC",
            algorithmName: "SyntheticInference",
            trackingID: "mask-1",
            trackingUID: "2.25.9102",
            recommendedDisplayCIELabValue: [42000, 52000, 32000]
        )
        let mask = DicomAIMask(
            rows: 2,
            columns: 2,
            segment: segment,
            frames: [
                DicomAIMaskFrame(
                    index: 0,
                    sourceImageReferences: [source],
                    pixels: [1, 0, 0, 1]
                )
            ]
        )

        let data = try DicomAIInferenceBuilder.segmentationPart10Data(
            mask: mask,
            options: DicomAIInferenceBuildOptions(
                sopInstanceUID: "2.25.9103",
                studyInstanceUID: "2.25.9104",
                seriesInstanceUID: "2.25.9105",
                algorithmName: "SyntheticInference",
                contentLabel: "AI_SEG"
            )
        )

        let decoder = try open(data: data, name: "ai_seg")
        let parsed = try XCTUnwrap(decoder.segmentation)
        XCTAssertEqual(decoder.dataSet[.contentLabel]?.vr, .CS)

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.9103")
        XCTAssertEqual(parsed.segments.first?.trackingID, "mask-1")
        XCTAssertEqual(parsed.segments.first?.trackingUID, "2.25.9102")
        // Check both source identity and the derivation/purpose codes supplied by the builder.
        XCTAssertEqual(parsed.frames.first?.sourceImageReferences.map { DicomSourceImageReferenceIdentity($0) },
                       [DicomSourceImageReferenceIdentity(source)])
        let parsedSource = try XCTUnwrap(parsed.frames.first?.sourceImageReferences.first)
        XCTAssertEqual(parsedSource.derivationCode, DicomSegmentationBuilder.derivationCode)
        XCTAssertEqual(parsedSource.purposeOfReferenceCode, DicomSegmentationBuilder.sourcePurposeCode)
        XCTAssertEqual(parsed.labelmaps.first?.voxels, [1, 0, 0, 1])
    }

    func testGraphicAnnotationBecomesGrayscalePresentationState() throws {
        let source = DicomKeyObjectReference(
            studyInstanceUID: "2.25.9201",
            seriesInstanceUID: "2.25.9202",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9203",
            referencedFrameNumbers: [2]
        )
        let dataSet = try DicomAIInferenceBuilder.presentationStateDataSet(
            annotations: [
                DicomAIAnnotation(
                    layer: DicomPresentationGraphicLayer(name: "AI", order: 1, recommendedDisplayGrayscaleValue: 65535),
                    sourceImageReferences: [source],
                    graphicObject: DicomPresentationGraphicObject(
                        graphicType: "POLYLINE",
                        graphicData: [2, 2, 6, 2, 6, 6, 2, 2],
                        graphicFilled: false,
                        trackingID: "annotation-1",
                        trackingUID: "2.25.9204"
                    )
                )
            ],
            options: DicomAIInferenceBuildOptions(
                sopInstanceUID: "2.25.9205",
                studyInstanceUID: "2.25.9201",
                seriesInstanceUID: "2.25.9206",
                contentLabel: "AI_PR"
            ),
            displayedArea: DicomPresentationDisplayedArea(bottomRight: SIMD2<Int32>(512, 512))
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomGrayscalePresentationState.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )

        let decoder = try open(data: data, name: "ai_pr")
        let presentation = try XCTUnwrap(decoder.grayscalePresentationState)
        XCTAssertEqual(decoder.dataSet[.contentLabel]?.vr, .CS)

        XCTAssertEqual(presentation.sopInstanceUID, "2.25.9205")
        XCTAssertEqual(presentation.referencedSeries.first?.seriesInstanceUID, "2.25.9202")
        XCTAssertEqual(presentation.graphicLayers.first?.name, "AI")
        XCTAssertEqual(presentation.graphicAnnotations.first?.graphicObjects.first?.trackingID, "annotation-1")
        XCTAssertEqual(presentation.graphicAnnotations.first?.graphicObjects.first?.graphicData, [2, 2, 6, 2, 6, 6, 2, 2])
    }

    func test_presentationStateDataSet_missingSeriesUID_throwsMissingRequiredTag() {
        let valid = DicomKeyObjectReference(
            seriesInstanceUID: "2.25.2421.1",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.2421.11"
        )
        for seriesUID: String? in [nil, "", " ", " \n\t\0"] {
            let invalid = DicomKeyObjectReference(
                seriesInstanceUID: seriesUID,
                referencedSOPClassUID: valid.referencedSOPClassUID,
                referencedSOPInstanceUID: "2.25.2421.12"
            )
            for references in [[invalid], [valid, invalid]] {
                XCTAssertThrowsError(try DicomAIInferenceBuilder.presentationStateDataSet(
                    annotations: [.init(
                        sourceImageReferences: references,
                        graphicObject: .init(graphicType: "POINT", graphicData: [1, 2])
                    )],
                    options: .init()
                ), "Series UID: \(String(reflecting: seriesUID)), references: \(references.count)") { error in
                    XCTAssertEqual(error as? DICOMError, .missingRequiredTag(
                        tag: "0020,000E", description: "Referenced Series Instance UID"
                    ))
                }
            }
        }
    }

    func test_presentationStateDataSet_validReferences_preservesGroupingDeduplicationAndFrames() throws {
        let first = DicomKeyObjectReference(
            seriesInstanceUID: "2.25.2421.1",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.2421.11",
            referencedFrameNumbers: [1, 3]
        )
        let second = DicomKeyObjectReference(
            seriesInstanceUID: "2.25.2421.1",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.2421.12",
            referencedFrameNumbers: [2]
        )
        let otherSeries = DicomKeyObjectReference(
            seriesInstanceUID: "2.25.2421.2",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.4",
            referencedSOPInstanceUID: "2.25.2421.13",
            referencedFrameNumbers: [4]
        )
        let references = [[otherSeries, first, first], [first, second]]
        let dataSet = try DicomAIInferenceBuilder.presentationStateDataSet(
            annotations: references.map {
                .init(
                    sourceImageReferences: $0,
                    graphicObject: .init(graphicType: "POINT", graphicData: [1, 2])
                )
            },
            options: .init()
        )
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        let presentation = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)

        XCTAssertEqual(presentation.referencedSeries.map(\.seriesInstanceUID), ["2.25.2421.1", "2.25.2421.2"])
        XCTAssertEqual(presentation.referencedSeries.map { $0.images.map(\.sourceImageReference) }, [
            [first.sourceImageReference, second.sourceImageReference],
            [otherSeries.sourceImageReference]
        ])
        XCTAssertEqual(
            presentation.graphicAnnotations.map { $0.referencedImages.map(\.sourceImageReference) },
            references.map { $0.map(\.sourceImageReference) }
        )
    }

    func testGrayscalePresentationStateParsesDisplayStateAndTextObjects() throws {
        let source = DicomPresentationReferencedImage(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9303",
            referencedFrameNumbers: [1]
        )
        let window = DicomDisplayWindow(
            settings: WindowSettings(center: 50, width: 100),
            explanation: "Soft tissue",
            source: .dicom(index: 0)
        )
        let voiLUT = DicomLookupTable(
            descriptor: try XCTUnwrap(DicomLUTDescriptor(
                storedEntryCount: 4,
                firstMappedValue: 0,
                bitsPerEntry: 8
            )),
            explanation: "GSPS LUT",
            lutType: nil,
            data: [0, 64, 128, 255]
        )
        let alternateVOILUT = DicomLookupTable(
            descriptor: try XCTUnwrap(DicomLUTDescriptor(
                storedEntryCount: 4,
                firstMappedValue: 0,
                bitsPerEntry: 8
            )),
            explanation: "GSPS alternate LUT",
            lutType: nil,
            data: [0, 32, 160, 255]
        )
        let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: [
                DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.9302", images: [source])
            ],
            graphicAnnotations: [
                DicomPresentationGraphicAnnotation(
                    graphicLayer: "AI",
                    referencedImages: [source],
                    graphicObjects: [
                        DicomPresentationGraphicObject(
                            graphicType: "POLYLINE",
                            graphicData: [2, 2, 4, 2, 4, 4],
                            trackingID: "display-annotation"
                        ),
                        DicomPresentationGraphicObject(
                            annotationUnits: "MATRIX",
                            graphicType: "POINT",
                            graphicData: [2, 2],
                            trackingID: "preserved-matrix-annotation"
                        )
                    ],
                    textObjects: [
                        DicomPresentationTextObject(
                            text: "Finding",
                            boundingBoxAnnotationUnits: "DISPLAY",
                            anchorPoint: SIMD2<Double>(0.5, 0.5),
                            anchorPointAnnotationUnits: "DISPLAY",
                            anchorPointVisible: true,
                            boundingBoxTopLeft: SIMD2<Double>(0.2, 0.1),
                            boundingBoxBottomRight: SIMD2<Double>(0.8, 0.3),
                            boundingBoxHorizontalJustification: "CENTER"
                        )
                    ]
                )
            ],
            graphicLayers: [DicomPresentationGraphicLayer(
                name: "AI",
                recommendedDisplayGrayscaleValue: 65_535,
                recommendedDisplayCIELabValue: [50_000, 32_000, 48_000]
            )],
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: "2.25.9305",
                studyInstanceUID: "2.25.9301",
                seriesInstanceUID: "2.25.9306",
                contentLabel: "DISPLAY",
                displayedAreas: [DicomPresentationDisplayedArea(
                    referencedImages: [source],
                    topLeft: SIMD2<Int32>(2, 2),
                    bottomRight: SIMD2<Int32>(4, 4),
                    presentationSizeMode: "MAGNIFY",
                    pixelOriginInterpretation: "FRAME",
                    presentationPixelSpacing: [0.7, 0.8],
                    presentationPixelMagnificationRatio: 1.5
                )],
                spatialTransform: DicomPresentationSpatialTransform(
                    isHorizontallyFlipped: true,
                    rotationDegrees: 90
                ),
                shutters: [
                    .rectangular(left: 2, right: 4, upper: 2, lower: 4),
                    .bitmap(DicomPresentationBitmapShutter(
                        overlayGroup: 0x6000,
                        rows: 2,
                        columns: 2,
                        originRow: 0,
                        originColumn: 0,
                        mask: Data([1, 0, 0, 1])
                    ))
                ],
                shutterPresentationValue: 4_096,
                displayTransformProfile: DicomDisplayTransformProfile(
                    windows: [window],
                    voiLUTs: [voiLUT],
                    presentationLUTShape: .inverse
                ),
                voiSelections: [DicomPresentationVOISelection(
                    referencedImages: [source],
                    displayTransformProfile: DicomDisplayTransformProfile(
                        voiLUTs: [voiLUT, alternateVOILUT],
                        presentationLUTShape: .inverse
                    )
                )],
                iccProfile: Data([1, 2, 3])
            )
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomGrayscalePresentationState.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )

        let decoder = try open(data: data, name: "display_pr")
        let presentation = try XCTUnwrap(decoder.grayscalePresentationState)
        XCTAssertEqual(
            decoder.dataSet.sequenceItems(for: .graphicLayerSequence).first?.dataSet
                .element(for: .graphicLayerOrder)?.vr,
            .IS
        )
        XCTAssertEqual(
            decoder.dataSet.sequenceItems(for: .graphicLayerSequence).first?.dataSet
                .element(for: .graphicLayer)?.vr,
            .CS
        )

        XCTAssertNil(decoder.dataSet.element(for: .windowCenter))
        XCTAssertNil(decoder.dataSet.element(for: .voiLUTSequence))
        let softcopyItem = try XCTUnwrap(
            decoder.dataSet.sequenceItems(for: .softcopyVOILUTSequence).first
        )
        XCTAssertNil(softcopyItem.dataSet.element(for: .windowCenter))
        XCTAssertNotNil(softcopyItem.dataSet.element(for: .voiLUTSequence))

        XCTAssertEqual(presentation.displayedAreas.first?.topLeft, SIMD2<Int32>(2, 2))
        XCTAssertEqual(presentation.displayedAreas.first?.bottomRight, SIMD2<Int32>(4, 4))
        XCTAssertEqual(presentation.displayedAreas.first?.referencedImages, [source])
        XCTAssertEqual(presentation.displayedAreas.first?.presentationSizeMode, "MAGNIFY")
        XCTAssertEqual(presentation.displayedAreas.first?.pixelOriginInterpretation, "FRAME")
        XCTAssertEqual(presentation.displayedAreas.first?.presentationPixelSpacing, [0.7, 0.8])
        XCTAssertEqual(presentation.displayedAreas.first?.presentationPixelMagnificationRatio, 1.5)
        XCTAssertEqual(presentation.spatialTransform.rotationDegrees, 90)
        XCTAssertTrue(presentation.spatialTransform.isHorizontallyFlipped)
        XCTAssertEqual(presentation.shutters.first, .rectangular(left: 2, right: 4, upper: 2, lower: 4))
        guard case .bitmap(let bitmap) = presentation.shutters.last else {
            return XCTFail("Expected a bitmap shutter")
        }
        XCTAssertEqual(bitmap.mask, Data([1, 0, 0, 1]))
        XCTAssertEqual(presentation.shutterPresentationValue, 4_096)
        XCTAssertTrue(presentation.displayTransformProfile.windows.isEmpty)
        XCTAssertEqual(presentation.displayTransformProfile.voiLUTs, [voiLUT, alternateVOILUT])
        XCTAssertEqual(presentation.displayTransformProfile.presentationLUTShape, .inverse)
        XCTAssertEqual(presentation.graphicAnnotations.first?.textObjects.first?.text, "Finding")
        XCTAssertEqual(
            presentation.graphicAnnotations.first?.textObjects.first?.boundingBoxHorizontalJustification,
            "CENTER"
        )
        XCTAssertEqual(presentation.graphicAnnotations.first?.textObjects.first?.anchorPointVisible, true)
        XCTAssertEqual(presentation.graphicLayers.first?.recommendedDisplayCIELabValue, [50_000, 32_000, 48_000])
        XCTAssertEqual(presentation.iccProfile, Data([1, 2, 3, 0]))
        XCTAssertTrue(presentation.diagnostics.contains { $0.code == "unsupported-annotation-units" })

        let implicitData = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomGrayscalePresentationState.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let implicitDecoder = try open(data: implicitData, name: "display_pr_implicit")
        let implicitSoftcopyItem = try XCTUnwrap(
            implicitDecoder.dataSet.sequenceItems(for: .softcopyVOILUTSequence).first
        )
        XCTAssertEqual(implicitSoftcopyItem.dataSet.sequenceItems(for: .voiLUTSequence).count, 2)
        let implicitPresentation = try XCTUnwrap(implicitDecoder.grayscalePresentationState)
        XCTAssertEqual(implicitPresentation.displayedAreas, presentation.displayedAreas)
        XCTAssertEqual(implicitPresentation.graphicLayers, presentation.graphicLayers)
        XCTAssertEqual(implicitPresentation.graphicAnnotations, presentation.graphicAnnotations)
        XCTAssertEqual(implicitPresentation.voiSelections, presentation.voiSelections)
    }

    func testGrayscalePresentationStateBuilder_preservesBitmapShutterWithOffsetDataIndices() throws {
        let sourceMask = Data([0, 0, 1, 0, 1, 0])
        let bitmap = DicomPresentationBitmapShutter(
            overlayGroup: 0x6000,
            rows: 1,
            columns: 3,
            originRow: 0,
            originColumn: 0,
            mask: sourceMask[2...]
        )
        let data = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [],
            graphicAnnotations: [],
            options: DicomPresentationStateBuildOptions(shutters: [.bitmap(bitmap)])
        )

        let presentation = try XCTUnwrap(open(data: data, name: "offset_bitmap_shutter").grayscalePresentationState)
        guard case let .bitmap(decoded)? = presentation.shutters.first else {
            return XCTFail("Expected a bitmap shutter")
        }

        XCTAssertEqual(decoded.mask, Data([1, 0, 1]))
    }

    private func open(data: Data, name: String) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }
}
