import Foundation

extension DCMDecoder {
    public var grayscalePresentationState: DicomGrayscalePresentationState? {
        synchronized {
            DicomGrayscalePresentationStateParser.makePresentationState(from: self)
        }
    }
}

private enum DicomGrayscalePresentationStateParser {
    static func makePresentationState(from decoder: DCMDecoder) -> DicomGrayscalePresentationState? {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomGSPSTrimmedValue
        guard let kind = presentationStateKind(for: sopClassUID) else {
            return nil
        }
        let displayedAreas = parseItems(in: decoder, for: .displayedAreaSelectionSequence).compactMap(displayedArea)
        let shutters: [DicomPresentationShutter] = kind == .blending ? [] : shutters(from: decoder)
        let voiSelections: [DicomPresentationVOISelection] = kind == .blending ? [] : voiSelections(from: decoder)
        let graphicAnnotations = parseItems(in: decoder, for: .graphicAnnotationSequence).map(graphicAnnotation)
        let displayTransformProfile = kind == .blending
            ? .identity : (voiSelections.first?.displayTransformProfile ?? decoder.displayTransformProfile)
        let paletteColorLookupTable = paletteColorLookupTable(from: decoder)
        return DicomGrayscalePresentationState(
            kind: kind,
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            contentLabel: decoder.info(for: .contentLabel),
            contentDescription: decoder.info(for: .contentDescription),
            presentationCreationDate: decoder.info(for: .presentationCreationDate),
            presentationCreationTime: decoder.info(for: .presentationCreationTime),
            referencedSeries: parseItems(in: decoder, for: .referencedSeriesSequence).compactMap(referencedSeries),
            displayedAreas: displayedAreas,
            spatialTransform: spatialTransform(from: decoder),
            shutters: shutters,
            shutterPresentationValue: kind == .blending ? nil : decoder.dataSet.int(for: .shutterPresentationValue).flatMap {
                UInt16(exactly: $0)
            },
            displayTransformProfile: displayTransformProfile,
            voiSelections: voiSelections,
            graphicLayers: parseItems(in: decoder, for: .graphicLayerSequence).map(graphicLayer),
            graphicAnnotations: graphicAnnotations,
            paletteColorLookupTable: paletteColorLookupTable,
            iccProfile: decoder.dataSet.element(for: .iccProfile)?.bytesValue,
            diagnostics: diagnostics(
                from: decoder,
                kind: kind,
                paletteColorLookupTable: paletteColorLookupTable,
                displayedAreas: displayedAreas,
                parsedShutters: shutters,
                graphicAnnotations: graphicAnnotations
            ),
            blendingItems: kind == .blending ? parseItems(in: decoder, for: .blendingSequence).compactMap {
                blendingItem(from: $0.dataSet, decoder: decoder)
            } : [],
            relativeOpacity: kind == .blending ? decoder.dataSet.element(for: .relativeOpacity)?.floatValue : nil
        )
    }

    private static func blendingItem(from dataSet: DicomDataSet,
                                      decoder: DCMDecoder) -> DicomPresentationBlendingItem? {
        guard let position = dataSet.string(for: .blendingPosition).flatMap(
            DicomPresentationBlendingItem.Position.init(rawValue:)
        ), let studyUID = dataSet.string(for: .studyInstanceUID) else { return nil }
        let base = DicomDisplayTransformProfile(
            rescaleParameters: .init(intercept: dataSet.float(for: .rescaleIntercept) ?? 0,
                                     slope: dataSet.float(for: .rescaleSlope) ?? 1),
            rescaleType: dataSet.string(for: .rescaleType),
            modalityLUTs: dataSet.sequenceItems(for: .modalityLUTSequence).compactMap {
                decoder.lookupTable(from: $0.dataSet, typeTag: .modalityLUTType)
            }
        )
        let selections = dataSet.sequenceItems(for: .softcopyVOILUTSequence).map {
            DicomPresentationVOISelection(
                referencedImages: $0.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage),
                displayTransformProfile: displayTransformProfile(from: $0.dataSet, base: base,
                                                                  littleEndian: decoder.littleEndian)
            )
        }
        return DicomPresentationBlendingItem(
            position: position, studyInstanceUID: studyUID,
            referencedSeries: dataSet.sequenceItems(for: .referencedSeriesSequence).compactMap(referencedSeries),
            displayTransformProfile: selections.first?.displayTransformProfile ?? base,
            voiSelections: selections
        )
    }

    private static func presentationStateKind(
        for sopClassUID: String
    ) -> DicomSoftcopyPresentationStateKind? {
        switch sopClassUID {
        case DicomGrayscalePresentationState.storageSOPClassUID:
            .grayscale
        case DicomGrayscalePresentationState.colorStorageSOPClassUID:
            .color
        case DicomGrayscalePresentationState.pseudoColorStorageSOPClassUID:
            .pseudoColor
        case DicomGrayscalePresentationState.blendingStorageSOPClassUID:
            .blending
        default:
            nil
        }
    }

    private static func paletteColorLookupTable(
        from decoder: DCMDecoder
    ) -> DicomPaletteColorLookupTable? {
        guard let redDescriptor = decoder.redPaletteDescriptor,
              let greenDescriptor = decoder.greenPaletteDescriptor,
              let blueDescriptor = decoder.bluePaletteDescriptor,
              redDescriptor == greenDescriptor,
              greenDescriptor == blueDescriptor,
              let red = decoder.reds,
              let green = decoder.greens,
              let blue = decoder.blues,
              red.count >= redDescriptor.entryCount,
              green.count >= greenDescriptor.entryCount,
              blue.count >= blueDescriptor.entryCount else {
            return nil
        }
        return DicomPaletteColorLookupTable(
            redDescriptor: redDescriptor,
            greenDescriptor: greenDescriptor,
            blueDescriptor: blueDescriptor,
            red: Array(red.prefix(redDescriptor.entryCount)),
            green: Array(green.prefix(greenDescriptor.entryCount)),
            blue: Array(blue.prefix(blueDescriptor.entryCount))
        )
    }

    private static func referencedSeries(from item: DicomSequenceItem) -> DicomPresentationReferencedSeries? {
        guard let seriesUID = item.dataSet.string(for: .seriesInstanceUID) else { return nil }
        return try? DicomPresentationReferencedSeries(
            seriesInstanceUID: seriesUID,
            images: item.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage)
        )
    }

    private static func voiSelections(from decoder: DCMDecoder) -> [DicomPresentationVOISelection] {
        let base = decoder.displayTransformProfile
        let items = parseItems(in: decoder, for: .softcopyVOILUTSequence)
        guard !items.isEmpty else { return [] }
        return items.map { item in
            DicomPresentationVOISelection(
                referencedImages: item.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage),
                displayTransformProfile: displayTransformProfile(
                    from: item.dataSet,
                    base: base,
                    littleEndian: decoder.littleEndian
                )
            )
        }
    }

    private static func displayTransformProfile(
        from dataSet: DicomDataSet,
        base: DicomDisplayTransformProfile,
        littleEndian: Bool
    ) -> DicomDisplayTransformProfile {
        let centers = dataSet.decimalStrings(for: .windowCenter)
        let widths = dataSet.decimalStrings(for: .windowWidth)
        let explanations = dataSet.strings(for: .windowCenterWidthExplanation)
        let windows = (0..<min(centers.count, widths.count)).compactMap { index -> DicomDisplayWindow? in
            let settings = WindowSettings(center: centers[index], width: widths[index])
            guard settings.isValid else { return nil }
            return DicomDisplayWindow(
                settings: settings,
                explanation: explanations.indices.contains(index)
                    ? explanations[index].dicomGSPSNonEmptyValue
                    : nil,
                source: .dicom(index: index)
            )
        }
        let voiLUTs = DicomVOILUTValidator.validate(
            items: dataSet.sequenceItems(for: .voiLUTSequence),
            littleEndian: littleEndian
        ).accepted

        return DicomDisplayTransformProfile(
            rescaleParameters: base.rescaleParameters,
            rescaleType: base.rescaleType,
            modalityLUTs: base.modalityLUTs,
            windows: windows,
            voiLUTs: voiLUTs,
            presentationLUTShape: base.presentationLUTShape,
            photometricInterpretation: base.photometricInterpretation,
            suggestedPresets: base.suggestedPresets,
            presentationLUT: base.presentationLUT
        )
    }

    private static func referencedImage(from item: DicomSequenceItem) -> DicomPresentationReferencedImage {
        DicomPresentationReferencedImage(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber)
        )
    }

    private static func graphicLayer(from item: DicomSequenceItem) -> DicomPresentationGraphicLayer {
        DicomPresentationGraphicLayer(
            name: item.dataSet.string(for: .graphicLayer) ?? "AI",
            order: item.dataSet.int(for: .graphicLayerOrder) ?? 1,
            recommendedDisplayGrayscaleValue: item.dataSet.element(for: .graphicLayerRecommendedDisplayGrayscaleValue)?
                .intValue
                .flatMap { UInt(exactly: $0) },
            recommendedDisplayCIELabValue: item.dataSet.ints(for: .graphicLayerRecommendedDisplayCIELabValue)
                .map { UInt16(clamping: $0) },
            description: item.dataSet.string(for: .graphicLayerDescription)
        )
    }

    private static func graphicAnnotation(from item: DicomSequenceItem) -> DicomPresentationGraphicAnnotation {
        DicomPresentationGraphicAnnotation(
            graphicLayer: item.dataSet.string(for: .graphicLayer) ?? "AI",
            referencedImages: item.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage),
            graphicObjects: item.dataSet.sequenceItems(for: .graphicObjectSequence).map(graphicObject),
            textObjects: item.dataSet.sequenceItems(for: .textObjectSequence).map(textObject),
            compoundGraphics: item.dataSet.sequenceItems(for: .compoundGraphicSequence).compactMap(
                compoundGraphic
            )
        )
    }

    private static func graphicObject(from item: DicomSequenceItem) -> DicomPresentationGraphicObject {
        DicomPresentationGraphicObject(
            annotationUnits: item.dataSet.string(for: .graphicAnnotationUnits) ?? "PIXEL",
            graphicType: item.dataSet.string(for: .graphicType) ?? "POLYLINE",
            graphicData: item.dataSet.floats(for: .graphicData),
            graphicFilled: item.dataSet.string(for: .graphicFilled).map { $0.dicomGSPSTrimmedValue.uppercased() == "Y" },
            compoundGraphicInstanceID: uint32(in: item.dataSet, for: .compoundGraphicInstanceID),
            trackingID: item.dataSet.string(for: .trackingID),
            trackingUID: item.dataSet.string(for: .trackingUID)
        )
    }

    private static func textObject(from item: DicomSequenceItem) -> DicomPresentationTextObject {
        DicomPresentationTextObject(
            text: item.dataSet.string(for: .unformattedTextValue) ?? "Annotation",
            boundingBoxAnnotationUnits: item.dataSet.string(for: .boundingBoxAnnotationUnits),
            anchorPoint: simd2(from: item.dataSet.floats(for: .anchorPoint)),
            anchorPointAnnotationUnits: item.dataSet.string(for: .anchorPointAnnotationUnits),
            anchorPointVisible: item.dataSet.string(for: .anchorPointVisibility).map {
                $0.dicomGSPSTrimmedValue.uppercased() == "Y"
            },
            boundingBoxTopLeft: simd2(from: item.dataSet.floats(for: .boundingBoxTopLeftHandCorner)),
            boundingBoxBottomRight: simd2(from: item.dataSet.floats(for: .boundingBoxBottomRightHandCorner)),
            boundingBoxHorizontalJustification: item.dataSet.string(
                for: .boundingBoxTextHorizontalJustification
            ),
            compoundGraphicInstanceID: uint32(in: item.dataSet, for: .compoundGraphicInstanceID),
            trackingID: item.dataSet.string(for: .trackingID),
            trackingUID: item.dataSet.string(for: .trackingUID)
        )
    }

    private static func compoundGraphic(
        from item: DicomSequenceItem
    ) -> DicomPresentationCompoundGraphic? {
        guard let instanceID = uint32(in: item.dataSet, for: .compoundGraphicInstanceID) else {
            return nil
        }
        return DicomPresentationCompoundGraphic(
            instanceID: instanceID,
            units: item.dataSet.string(for: .compoundGraphicUnits) ?? "",
            graphicType: item.dataSet.string(for: .compoundGraphicType) ?? "",
            graphicData: item.dataSet.floats(for: .graphicData),
            graphicFilled: yesNo(in: item.dataSet, for: .graphicFilled),
            rotationAngle: item.dataSet.float(for: .rotationAngle),
            rotationPoint: simd2(from: item.dataSet.floats(for: .rotationPoint)),
            gapLength: item.dataSet.float(for: .gapLength),
            diameterOfVisibility: item.dataSet.float(for: .diameterOfVisibility),
            tickAlignment: item.dataSet.string(for: .tickAlignment),
            tickLabelAlignment: item.dataSet.string(for: .tickLabelAlignment),
            showsTickLabels: yesNo(in: item.dataSet, for: .showTickLabel),
            majorTicks: item.dataSet.sequenceItems(for: .majorTicksSequence).compactMap(majorTick),
            lineStyle: item.dataSet.sequenceItems(for: .lineStyleSequence).first.map(lineStyle),
            fillStyle: item.dataSet.sequenceItems(for: .fillStyleSequence).first.map(fillStyle),
            textStyle: item.dataSet.sequenceItems(for: .textStyleSequence).first.map(textStyle),
            graphicGroupID: uint32(in: item.dataSet, for: .graphicGroupID)
        )
    }

    private static func majorTick(
        from item: DicomSequenceItem
    ) -> DicomPresentationCompoundGraphicMajorTick? {
        guard let position = item.dataSet.float(for: .tickPosition), position.isFinite else {
            return nil
        }
        return DicomPresentationCompoundGraphicMajorTick(
            position: position,
            label: item.dataSet.string(for: .tickLabel) ?? ""
        )
    }

    private static func lineStyle(
        from item: DicomSequenceItem
    ) -> DicomPresentationCompoundGraphicLineStyle {
        DicomPresentationCompoundGraphicLineStyle(
            patternOnColorCIELabValue: item.dataSet.ints(for: .patternOnColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            patternOffColorCIELabValue: item.dataSet.ints(for: .patternOffColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            patternOnOpacity: item.dataSet.float(for: .patternOnOpacity),
            patternOffOpacity: item.dataSet.float(for: .patternOffOpacity),
            lineThickness: item.dataSet.float(for: .lineThickness),
            lineDashingStyle: item.dataSet.string(for: .lineDashingStyle),
            linePattern: uint32(in: item.dataSet, for: .linePattern),
            shadowStyle: item.dataSet.string(for: .shadowStyle),
            shadowOffsetX: item.dataSet.float(for: .shadowOffsetX),
            shadowOffsetY: item.dataSet.float(for: .shadowOffsetY),
            shadowColorCIELabValue: item.dataSet.ints(for: .shadowColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            shadowOpacity: item.dataSet.float(for: .shadowOpacity)
        )
    }

    private static func fillStyle(
        from item: DicomSequenceItem
    ) -> DicomPresentationCompoundGraphicFillStyle {
        DicomPresentationCompoundGraphicFillStyle(
            patternOnColorCIELabValue: item.dataSet.ints(for: .patternOnColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            patternOffColorCIELabValue: item.dataSet.ints(for: .patternOffColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            patternOnOpacity: item.dataSet.float(for: .patternOnOpacity),
            patternOffOpacity: item.dataSet.float(for: .patternOffOpacity),
            fillMode: item.dataSet.string(for: .fillMode),
            fillPattern: item.dataSet.element(for: .fillPattern)?.bytesValue
        )
    }

    private static func textStyle(
        from item: DicomSequenceItem
    ) -> DicomPresentationCompoundGraphicTextStyle {
        DicomPresentationCompoundGraphicTextStyle(
            fontName: item.dataSet.string(for: .fontName),
            fontNameType: item.dataSet.string(for: .fontNameType),
            cssFontName: item.dataSet.string(for: .cssFontName),
            textColorCIELabValue: item.dataSet.ints(for: .textColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            horizontalAlignment: item.dataSet.string(for: .horizontalAlignment),
            verticalAlignment: item.dataSet.string(for: .verticalAlignment),
            shadowStyle: item.dataSet.string(for: .shadowStyle),
            shadowOffsetX: item.dataSet.float(for: .shadowOffsetX),
            shadowOffsetY: item.dataSet.float(for: .shadowOffsetY),
            shadowColorCIELabValue: item.dataSet.ints(for: .shadowColorCIELabValue).map {
                UInt16(clamping: $0)
            },
            shadowOpacity: item.dataSet.float(for: .shadowOpacity),
            isUnderlined: yesNo(in: item.dataSet, for: .underlined),
            isBold: yesNo(in: item.dataSet, for: .bold),
            isItalic: yesNo(in: item.dataSet, for: .italic)
        )
    }

    private static func uint32(in dataSet: DicomDataSet, for tag: DicomTag) -> UInt32? {
        dataSet.int(for: tag).flatMap(UInt32.init(exactly:))
    }

    private static func yesNo(in dataSet: DicomDataSet, for tag: DicomTag) -> Bool? {
        dataSet.string(for: tag).map { $0.dicomGSPSTrimmedValue.uppercased() == "Y" }
    }

    private static func displayedArea(from item: DicomSequenceItem) -> DicomPresentationDisplayedArea? {
        let topLeftValues = item.dataSet.ints(for: .displayedAreaTopLeftHandCorner)
        let bottomRightValues = item.dataSet.ints(for: .displayedAreaBottomRightHandCorner)
        guard bottomRightValues.count >= 2 else { return nil }
        let topLeft: SIMD2<Int32>
        if topLeftValues.count >= 2 {
            topLeft = SIMD2<Int32>(Int32(clamping: topLeftValues[0]), Int32(clamping: topLeftValues[1]))
        } else {
            topLeft = SIMD2<Int32>(1, 1)
        }
        return DicomPresentationDisplayedArea(
            referencedImages: item.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage),
            topLeft: topLeft,
            bottomRight: SIMD2<Int32>(
                Int32(clamping: bottomRightValues[0]),
                Int32(clamping: bottomRightValues[1])
            ),
            presentationSizeMode: item.dataSet.string(for: .presentationSizeMode) ?? "SCALE TO FIT",
            pixelOriginInterpretation: item.dataSet.string(for: .pixelOriginInterpretation),
            presentationPixelSpacing: item.dataSet.decimalStrings(for: .presentationPixelSpacing),
            presentationPixelAspectRatio: item.dataSet.ints(for: .presentationPixelAspectRatio),
            presentationPixelMagnificationRatio: item.dataSet.float(for: .presentationPixelMagnificationRatio)
        )
    }

    private static func spatialTransform(from decoder: DCMDecoder) -> DicomPresentationSpatialTransform {
        DicomPresentationSpatialTransform(
            isHorizontallyFlipped: decoder.dataSet.string(for: .imageHorizontalFlip)?
                .dicomGSPSTrimmedValue
                .uppercased() == "Y",
            rotationDegrees: decoder.dataSet.int(for: .imageRotation) ?? 0
        )
    }

    fileprivate static func shutters(from decoder: DCMDecoder) -> [DicomPresentationShutter] {
        let shapes = decoder.dataSet.strings(for: .shutterShape)
            .map { $0.dicomGSPSTrimmedValue.uppercased() }
        guard !shapes.isEmpty else { return [] }

        var shutters: [DicomPresentationShutter] = []
        if shapes.contains("RECTANGULAR"),
           let left = decoder.dataSet.int(for: .shutterLeftVerticalEdge),
           let right = decoder.dataSet.int(for: .shutterRightVerticalEdge),
           let upper = decoder.dataSet.int(for: .shutterUpperHorizontalEdge),
           let lower = decoder.dataSet.int(for: .shutterLowerHorizontalEdge) {
            shutters.append(.rectangular(left: Int32(clamping: left),
                                         right: Int32(clamping: right),
                                         upper: Int32(clamping: upper),
                                         lower: Int32(clamping: lower)))
        }

        let center = decoder.dataSet.ints(for: .centerOfCircularShutter)
        if shapes.contains("CIRCULAR"),
           center.count >= 2,
           let radius = decoder.dataSet.int(for: .radiusOfCircularShutter) {
            shutters.append(.circular(center: SIMD2<Int32>(
                Int32(clamping: center[0]),
                Int32(clamping: center[1])
            ), radius: Int32(clamping: radius)))
        }

        let vertexValues = decoder.dataSet.ints(for: .verticesOfPolygonalShutter)
        if shapes.contains("POLYGONAL"), vertexValues.count >= 6 {
            let vertices = stride(from: 0, to: vertexValues.count - 1, by: 2).map {
                SIMD2<Int32>(Int32(clamping: vertexValues[$0]), Int32(clamping: vertexValues[$0 + 1]))
            }
            shutters.append(.polygonal(vertices: vertices))
        }

        if shapes.contains("BITMAP"),
           let overlayGroup = decoder.dataSet.int(for: .shutterOverlayGroup),
           let group = UInt16(exactly: overlayGroup),
           let plane = decoder.overlayPlanes().first(where: { $0.group == overlayGroup }) {
            shutters.append(.bitmap(DicomPresentationBitmapShutter(
                overlayGroup: group,
                rows: plane.rows,
                columns: plane.columns,
                originRow: plane.originRow,
                originColumn: plane.originColumn,
                presentationValue: decoder.dataSet.int(for: .shutterPresentationValue).flatMap {
                    UInt16(exactly: $0)
                },
                mask: plane.mask
            )))
        }

        return shutters
    }

    private static func diagnostics(
        from decoder: DCMDecoder,
        kind: DicomSoftcopyPresentationStateKind,
        paletteColorLookupTable: DicomPaletteColorLookupTable?,
        displayedAreas: [DicomPresentationDisplayedArea],
        parsedShutters: [DicomPresentationShutter],
        graphicAnnotations: [DicomPresentationGraphicAnnotation]
    ) -> [DicomPresentationStateDiagnostic] {
        var result: [DicomPresentationStateDiagnostic] = []
        if kind == .pseudoColor, paletteColorLookupTable == nil {
            result.append(DicomPresentationStateDiagnostic(
                code: "invalid-pseudo-color-palette",
                message: "The Pseudo-Color presentation state has no valid matching red, green, and blue palette LUTs."
            ))
        }
        let rawCompoundItems = parseItems(in: decoder, for: .graphicAnnotationSequence).flatMap {
            $0.dataSet.sequenceItems(for: .compoundGraphicSequence)
        }
        let compoundGraphics = graphicAnnotations.flatMap(\.compoundGraphics)
        let unsupportedCompoundTypes = Set(compoundGraphics.map(\.graphicType))
            .subtracting(DicomPresentationCompoundGraphic.supportedTypes)
            .sorted()
        if !unsupportedCompoundTypes.isEmpty {
            result.append(DicomPresentationStateDiagnostic(
                code: "unsupported-compound-graphic-type",
                message: "Unsupported compound graphic types use their required simple fallback: "
                    + "\(unsupportedCompoundTypes.joined(separator: ", "))."
            ))
        }
        let invalidCompounds = compoundGraphics.filter {
            DicomPresentationCompoundGraphic.supportedTypes.contains($0.graphicType)
                && !$0.isStructurallyRenderable
        }
        let hasMisplacedTopLevelSequence = !decoder.dataSet.sequenceItems(for: .compoundGraphicSequence).isEmpty
        if rawCompoundItems.count != compoundGraphics.count || !invalidCompounds.isEmpty || hasMisplacedTopLevelSequence {
            result.append(DicomPresentationStateDiagnostic(
                code: "invalid-compound-graphic",
                message: "Malformed compound graphics were preserved and skipped; linked simple fallback objects remain available."
            ))
        }
        let instanceIDs = compoundGraphics.map(\.instanceID)
        if Set(instanceIDs).count != instanceIDs.count {
            result.append(DicomPresentationStateDiagnostic(
                code: "duplicate-compound-graphic-id",
                message: "Duplicate Compound Graphic Instance IDs were preserved; only the first renderable item is displayed."
            ))
        }
        let fallbackIDs = Set(graphicAnnotations.flatMap { annotation in
            annotation.graphicObjects.compactMap(\.compoundGraphicInstanceID)
                + annotation.textObjects.compactMap(\.compoundGraphicInstanceID)
        })
        let missingFallbackIDs = Set(compoundGraphics.filter(\.isStructurallyRenderable).map(\.instanceID))
            .subtracting(fallbackIDs)
        if !missingFallbackIDs.isEmpty {
            result.append(DicomPresentationStateDiagnostic(
                code: "missing-compound-graphic-fallback",
                message: "Renderable compound graphics are missing the required linked simple fallback: "
                    + missingFallbackIDs.sorted().map(String.init).joined(separator: ", ") + "."
            ))
        }
        let shutterShapes = Set(decoder.dataSet.strings(for: .shutterShape).map {
            $0.dicomGSPSTrimmedValue.uppercased()
        })
        let supportedShutterShapes: Set<String> = ["RECTANGULAR", "CIRCULAR", "POLYGONAL", "BITMAP"]
        let unsupportedShutters = shutterShapes.subtracting(supportedShutterShapes).sorted()
        if !unsupportedShutters.isEmpty {
            result.append(DicomPresentationStateDiagnostic(
                code: "unsupported-shutter-shape",
                message: "Unsupported shutter shapes: \(unsupportedShutters.joined(separator: ", "))."
            ))
        }
        if shutterShapes.contains("BITMAP"), !parsedShutters.contains(where: {
            if case .bitmap = $0 { return true }
            return false
        }) {
            result.append(DicomPresentationStateDiagnostic(
                code: "invalid-bitmap-shutter",
                message: "The bitmap shutter could not be decoded and was not rendered."
            ))
        }
        if displayedAreas.contains(where: { $0.pixelOriginInterpretation == "VOLUME" }) {
            result.append(DicomPresentationStateDiagnostic(
                code: "volume-pixel-origin-not-rendered",
                message: "VOLUME pixel-origin displayed areas are preserved but the current 2D viewer renders FRAME-relative areas only."
            ))
        }
        let supportedGraphicTypes: Set<String> = ["POINT", "POLYLINE", "INTERPOLATED", "CIRCLE", "ELLIPSE"]
        let unsupportedGraphicTypes = Set(graphicAnnotations.flatMap(\.graphicObjects).map(\.graphicType))
            .subtracting(supportedGraphicTypes)
            .sorted()
        if !unsupportedGraphicTypes.isEmpty {
            result.append(DicomPresentationStateDiagnostic(
                code: "unsupported-graphic-type",
                message: "Unsupported graphic types are preserved but not rendered: \(unsupportedGraphicTypes.joined(separator: ", "))."
            ))
        }
        let graphicUnits = graphicAnnotations.flatMap { annotation in
            annotation.graphicObjects.map(\.annotationUnits) + annotation.textObjects.compactMap {
                $0.anchorPointAnnotationUnits ?? $0.boundingBoxAnnotationUnits
            }
        }
        let unsupportedUnits = Set(graphicUnits.map { $0.dicomGSPSTrimmedValue.uppercased() })
            .subtracting(["PIXEL", "DISPLAY"])
            .sorted()
        if !unsupportedUnits.isEmpty {
            result.append(DicomPresentationStateDiagnostic(
                code: "unsupported-annotation-units",
                message: "Unsupported annotation units are preserved but not rendered: \(unsupportedUnits.joined(separator: ", "))."
            ))
        }
        return result
    }

    private static func simd2(from values: [Double]) -> SIMD2<Double>? {
        guard values.count >= 2 else { return nil }
        return SIMD2<Double>(values[0], values[1])
    }

    private static func parseItems(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        let valueLengthLimit: DicomSequenceValueParser.ValueLengthLimit?
        if tag == .softcopyVOILUTSequence {
            valueLengthLimit = DCMDecoder.voiLUTValueLengthLimit
        } else {
            valueLengthLimit = nil
        }
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet,
            valueLengthLimit: valueLengthLimit
        )) ?? []
    }
}

extension DCMDecoder {
    /// The image's own Display Shutter Module (issue #2822; common in XA, XRF, DX, MG and IO), parsed like a
    /// presentation state's: rectangular, circular, polygonal and bitmap shutters. Its Shutter Presentation Value
    /// is `dataSet.int(for: .shutterPresentationValue)`.
    public func displayShutters() -> [DicomPresentationShutter] {
        synchronized { DicomGrayscalePresentationStateParser.shutters(from: self) }
    }
}
