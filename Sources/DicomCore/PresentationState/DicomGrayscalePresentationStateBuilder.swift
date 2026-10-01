import Foundation

public enum DicomGrayscalePresentationStateBuilder {
    public enum BuildError: Error, Equatable {
        case invalidBlendingItemCount(Int)
        case invalidBlendingPositions
        case invalidRelativeOpacity
    }

    public static let storageSOPClassUID = DicomGrayscalePresentationState.storageSOPClassUID

    public static func dataSet(
        referencedSeries: [DicomPresentationReferencedSeries],
        graphicAnnotations: [DicomPresentationGraphicAnnotation],
        graphicLayers: [DicomPresentationGraphicLayer] = [],
        options: DicomPresentationStateBuildOptions = DicomPresentationStateBuildOptions()
    ) throws -> DicomDataSet {
        if options.kind == .blending {
            guard options.blendingItems.count == 2 else {
                throw BuildError.invalidBlendingItemCount(options.blendingItems.count)
            }
            guard options.blendingItems[0].position != options.blendingItems[1].position else {
                throw BuildError.invalidBlendingPositions
            }
            guard let opacity = options.relativeOpacity, opacity.isFinite, (0...1).contains(opacity) else {
                throw BuildError.invalidRelativeOpacity
            }
        }
        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let layers = resolvedLayers(explicitLayers: graphicLayers, annotations: graphicAnnotations)
        let displayedAreas = options.displayedAreas.isEmpty
            ? [options.displayedArea ?? DicomPresentationDisplayedArea(bottomRight: SIMD2<Int32>(1, 1))]
            : options.displayedAreas

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, storageSOPClassUID(for: options.kind)),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, "PR"),
            string(.contentLabel, vr: .CS, options.contentLabel),
            string(.presentationCreationDate, vr: .DA, options.presentationCreationDate ?? now.date),
            string(.presentationCreationTime, vr: .TM, options.presentationCreationTime ?? now.time),
            sequence(.referencedSeriesSequence, referencedSeries.map(referencedSeriesDataSet)),
            sequence(.displayedAreaSelectionSequence, displayedAreas.map(displayedAreaDataSet)),
            string(.imageHorizontalFlip, vr: .CS, options.spatialTransform.isHorizontallyFlipped ? "Y" : "N"),
            us(.imageRotation, options.spatialTransform.rotationDegrees)
        ]

        // A.33: Patient, General Study, General Series, General Equipment and Content Identification carry
        // Type 2 values when unknown; Instance Number is Type 1.
        elements.append(string(.patientName, vr: .PN, options.patientName ?? ""))
        elements.append(string(.patientID, vr: .LO, options.patientID ?? ""))
        elements.append(DicomDataElement(tag: 0x00100030, vr: .DA, value: .strings([options.patientBirthDate])))
        elements.append(DicomDataElement(tag: 0x00100040, vr: .CS, value: .strings([options.patientSex])))
        elements.append(DicomDataElement(tag: 0x00080020, vr: .DA, value: .strings([options.studyDate])))
        elements.append(DicomDataElement(tag: 0x00080030, vr: .TM, value: .strings([options.studyTime])))
        elements.append(DicomDataElement(tag: 0x00080090, vr: .PN, value: .strings([options.referringPhysicianName])))
        elements.append(DicomDataElement(tag: 0x00200010, vr: .SH, value: .strings([options.studyID])))
        elements.append(DicomDataElement(tag: 0x00080050, vr: .SH, value: .strings([options.accessionNumber])))
        elements.append(DicomDataElement(tag: 0x00080070, vr: .LO, value: .strings([options.manufacturer])))
        elements.append(string(.contentDescription, vr: .LO, options.contentDescription ?? ""))
        appendOptionalString(.contentCreatorName, vr: .PN, options.contentCreatorName, to: &elements)
        elements.append(DicomDataElement(tag: DicomTag.seriesNumber.rawValue, vr: .IS,
                                         value: .strings([options.seriesNumber.map(String.init) ?? ""])))
        appendOptionalIntegerString(.instanceNumber, options.instanceNumber ?? 1, to: &elements)
        // C.10.5/C.10.7 are conditional modules: their sequences carry one or more items or are absent.
        if !layers.isEmpty {
            elements.append(sequence(.graphicLayerSequence, layers.map(graphicLayerDataSet)))
        }
        if !graphicAnnotations.isEmpty {
            elements.append(sequence(.graphicAnnotationSequence, graphicAnnotations.map(graphicAnnotationDataSet)))
        }
        let profile = options.displayTransformProfile
        if options.kind == .grayscale || options.kind == .pseudoColor {
            appendSoftcopyVOI(
                options.voiSelections.isEmpty
                    ? [DicomPresentationVOISelection(displayTransformProfile: profile)] : options.voiSelections,
                to: &elements
            )
            if !profile.modalityLUTs.isEmpty {
                appendVOILUTs(profile.modalityLUTs, sequenceTag: .modalityLUTSequence, to: &elements)
            } else if !profile.rescaleParameters.isIdentity {
                elements.append(ds(.rescaleIntercept, [profile.rescaleParameters.intercept]))
                elements.append(ds(.rescaleSlope, [profile.rescaleParameters.slope]))
                elements.append(string(.rescaleType, vr: .LO, profile.rescaleType ?? "US"))
            }
        }
        if options.kind == .grayscale {
            if let table = profile.presentationLUT {
                appendVOILUTs([table], sequenceTag: .presentationLUTSequence, to: &elements)
            } else {
                elements.append(string(.presentationLUTShape, vr: .CS,
                                       profile.presentationLUTShape?.rawValue ?? "IDENTITY"))
            }
        }
        if options.kind == .pseudoColor || options.kind == .blending, let palette = options.paletteColorLookupTable {
            appendPalette(palette, to: &elements)
        }
        if options.kind != .blending {
            appendShutters(options.shutters, presentationValue: options.shutterPresentationValue, to: &elements)
        } else {
            elements.append(sequence(.blendingSequence, try options.blendingItems.map { item in
                guard let studyUID = item.studyInstanceUID.dicomGSPSNonEmptyValue else {
                    throw DICOMError.missingRequiredTag(tag: "0020,000D", description: "Study Instance UID")
                }
                var itemElements = [
                    string(.blendingPosition, vr: .CS, item.position.rawValue),
                    string(.studyInstanceUID, vr: .UI, studyUID),
                    sequence(.referencedSeriesSequence, item.referencedSeries.map(referencedSeriesDataSet))
                ]
                let itemProfile = item.displayTransformProfile
                if !itemProfile.modalityLUTs.isEmpty {
                    appendVOILUTs(itemProfile.modalityLUTs, sequenceTag: .modalityLUTSequence, to: &itemElements)
                } else {
                    itemElements.append(ds(.rescaleIntercept, [itemProfile.rescaleParameters.intercept]))
                    itemElements.append(ds(.rescaleSlope, [itemProfile.rescaleParameters.slope]))
                    itemElements.append(string(.rescaleType, vr: .LO, itemProfile.rescaleType ?? "US"))
                }
                appendSoftcopyVOI(item.voiSelections.isEmpty
                    ? [DicomPresentationVOISelection(displayTransformProfile: itemProfile)] : item.voiSelections,
                    to: &itemElements)
                return DicomDataSet(elements: itemElements)
            }))
            if let opacity = options.relativeOpacity {
                elements.append(fl(.relativeOpacity, [opacity]))
            }
        }
        if let iccProfile = options.iccProfile, !iccProfile.isEmpty {
            elements.append(DicomDataElement(tag: DicomTag.iccProfile.rawValue, vr: .OB, value: .bytes(iccProfile)))
        }

        return DicomDataSet(elements: elements)
    }

    public static func part10Data(
        referencedSeries: [DicomPresentationReferencedSeries],
        graphicAnnotations: [DicomPresentationGraphicAnnotation],
        graphicLayers: [DicomPresentationGraphicLayer] = [],
        options: DicomPresentationStateBuildOptions = DicomPresentationStateBuildOptions()
    ) throws -> Data {
        let dataSet = try dataSet(
            referencedSeries: referencedSeries,
            graphicAnnotations: graphicAnnotations,
            graphicLayers: graphicLayers,
            options: options
        )
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: storageSOPClassUID(for: options.kind),
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    private static func storageSOPClassUID(for kind: DicomSoftcopyPresentationStateKind) -> String {
        switch kind {
        case .grayscale: DicomGrayscalePresentationState.storageSOPClassUID
        case .color: DicomGrayscalePresentationState.colorStorageSOPClassUID
        case .pseudoColor: DicomGrayscalePresentationState.pseudoColorStorageSOPClassUID
        case .blending: DicomGrayscalePresentationState.blendingStorageSOPClassUID
        }
    }

    private static func resolvedLayers(
        explicitLayers: [DicomPresentationGraphicLayer],
        annotations: [DicomPresentationGraphicAnnotation]
    ) -> [DicomPresentationGraphicLayer] {
        var layers = explicitLayers
        for annotation in annotations where !layers.contains(where: { $0.name == annotation.graphicLayer }) {
            layers.append(DicomPresentationGraphicLayer(name: annotation.graphicLayer, order: layers.count + 1))
        }
        return layers
    }

    private static func referencedSeriesDataSet(_ series: DicomPresentationReferencedSeries) -> DicomDataSet {
        DicomDataSet(elements: [
            string(.seriesInstanceUID, vr: .UI, series.seriesInstanceUID),
            sequence(.referencedImageSequence, series.images.map(referencedImageDataSet))
        ])
    }

    private static func referencedImageDataSet(_ image: DicomPresentationReferencedImage) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        appendOptionalString(.referencedSOPClassUID, vr: .UI, image.referencedSOPClassUID, to: &elements)
        appendOptionalString(.referencedSOPInstanceUID, vr: .UI, image.referencedSOPInstanceUID, to: &elements)
        if !image.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(image.referencedFrameNumbers.map(String.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func graphicLayerDataSet(_ layer: DicomPresentationGraphicLayer) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.graphicLayer, vr: .CS, layer.name),
            DicomDataElement(
                tag: DicomTag.graphicLayerOrder.rawValue,
                vr: .IS,
                value: .strings([String(layer.order)])
            )
        ]
        if let grayscale = layer.recommendedDisplayGrayscaleValue {
            elements.append(DicomDataElement(
                tag: DicomTag.graphicLayerRecommendedDisplayGrayscaleValue.rawValue,
                vr: .US,
                value: .unsignedIntegers([grayscale])
            ))
        }
        if !layer.recommendedDisplayCIELabValue.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.graphicLayerRecommendedDisplayCIELabValue.rawValue,
                vr: .US,
                value: .unsignedIntegers(layer.recommendedDisplayCIELabValue.map(UInt.init))
            ))
        }
        appendOptionalString(.graphicLayerDescription, vr: .LO, layer.description, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func graphicAnnotationDataSet(_ annotation: DicomPresentationGraphicAnnotation) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.graphicLayer, vr: .CS, annotation.graphicLayer)
        ]
        if !annotation.graphicObjects.isEmpty {
            elements.append(sequence(.graphicObjectSequence, annotation.graphicObjects.map(graphicObjectDataSet)))
        }
        if !annotation.referencedImages.isEmpty {
            elements.append(sequence(.referencedImageSequence, annotation.referencedImages.map(referencedImageDataSet)))
        }
        if !annotation.textObjects.isEmpty {
            elements.append(sequence(.textObjectSequence, annotation.textObjects.map(textObjectDataSet)))
        }
        if !annotation.compoundGraphics.isEmpty {
            elements.append(sequence(.compoundGraphicSequence, annotation.compoundGraphics.map(
                compoundGraphicDataSet
            )))
        }
        return DicomDataSet(elements: elements)
    }

    private static func graphicObjectDataSet(_ object: DicomPresentationGraphicObject) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.graphicAnnotationUnits, vr: .CS, object.annotationUnits),
            us(.graphicDimensions, 2),
            us(.numberOfGraphicPoints, object.numberOfGraphicPoints),
            DicomDataElement(tag: DicomTag.graphicData.rawValue, vr: .FL, value: .floats(object.graphicData)),
            string(.graphicType, vr: .CS, object.graphicType)
        ]
        // C.10.5.1.2: closed graphics declare whether they are filled; an outline is the default.
        if let graphicFilled = object.graphicFilled ?? (isClosed(object) ? false : nil) {
            elements.append(string(.graphicFilled, vr: .CS, graphicFilled ? "Y" : "N"))
        }
        if let compoundGraphicInstanceID = object.compoundGraphicInstanceID {
            elements.append(ul(.compoundGraphicInstanceID, compoundGraphicInstanceID))
        }
        appendOptionalString(.trackingID, vr: .UT, object.trackingID, to: &elements)
        appendOptionalString(.trackingUID, vr: .UI, object.trackingUID, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func isClosed(_ object: DicomPresentationGraphicObject) -> Bool {
        switch object.graphicType {
        case "CIRCLE", "ELLIPSE": return true
        case "POLYLINE", "INTERPOLATED":
            let data = object.graphicData
            return data.count >= 4 && data[0] == data[data.count - 2] && data[1] == data[data.count - 1]
        default: return false
        }
    }

    private static func textObjectDataSet(_ object: DicomPresentationTextObject) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.unformattedTextValue, vr: .ST, object.text)
        ]
        appendOptionalString(
            .boundingBoxAnnotationUnits,
            vr: .CS,
            object.boundingBoxAnnotationUnits,
            to: &elements
        )
        appendOptionalString(
            .anchorPointAnnotationUnits,
            vr: .CS,
            object.anchorPointAnnotationUnits,
            to: &elements
        )
        if let anchorPoint = object.anchorPoint {
            elements.append(fl(.anchorPoint, [anchorPoint.x, anchorPoint.y]))
        }
        // C.10.5: the visibility flag accompanies an anchor point; the relationship is shown by default.
        if let anchorPointVisible = object.anchorPointVisible ?? (object.anchorPoint == nil ? nil : true) {
            elements.append(string(.anchorPointVisibility, vr: .CS, anchorPointVisible ? "Y" : "N"))
        }
        if let topLeft = object.boundingBoxTopLeft {
            elements.append(fl(.boundingBoxTopLeftHandCorner, [topLeft.x, topLeft.y]))
        }
        if let bottomRight = object.boundingBoxBottomRight {
            elements.append(fl(.boundingBoxBottomRightHandCorner, [bottomRight.x, bottomRight.y]))
        }
        appendOptionalString(
            .boundingBoxTextHorizontalJustification,
            vr: .CS,
            object.boundingBoxHorizontalJustification,
            to: &elements
        )
        if let compoundGraphicInstanceID = object.compoundGraphicInstanceID {
            elements.append(ul(.compoundGraphicInstanceID, compoundGraphicInstanceID))
        }
        appendOptionalString(.trackingID, vr: .UT, object.trackingID, to: &elements)
        appendOptionalString(.trackingUID, vr: .UI, object.trackingUID, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func compoundGraphicDataSet(
        _ graphic: DicomPresentationCompoundGraphic
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            ul(.compoundGraphicInstanceID, graphic.instanceID),
            string(.compoundGraphicUnits, vr: .CS, graphic.units),
            us(.graphicDimensions, 2),
            us(.numberOfGraphicPoints, graphic.graphicData.count / 2),
            DicomDataElement(tag: DicomTag.graphicData.rawValue, vr: .FL, value: .floats(graphic.graphicData)),
            string(.compoundGraphicType, vr: .CS, graphic.graphicType)
        ]
        if let graphicFilled = graphic.graphicFilled ?? (["RECTANGLE", "ELLIPSE"].contains(graphic.graphicType) ? false : nil) {
            elements.append(string(.graphicFilled, vr: .CS, graphicFilled ? "Y" : "N"))
        }
        if let rotationAngle = graphic.rotationAngle {
            elements.append(DicomDataElement(
                tag: DicomTag.rotationAngle.rawValue,
                vr: .FD,
                value: .floats([rotationAngle])
            ))
        }
        if let rotationPoint = graphic.rotationPoint {
            elements.append(fl(.rotationPoint, [rotationPoint.x, rotationPoint.y]))
        }
        if let gapLength = graphic.gapLength {
            elements.append(fl(.gapLength, [gapLength]))
        }
        if let diameterOfVisibility = graphic.diameterOfVisibility {
            elements.append(fl(.diameterOfVisibility, [diameterOfVisibility]))
        }
        appendOptionalString(.tickAlignment, vr: .CS, graphic.tickAlignment, to: &elements)
        appendOptionalString(.tickLabelAlignment, vr: .CS, graphic.tickLabelAlignment, to: &elements)
        if let showsTickLabels = graphic.showsTickLabels {
            elements.append(string(.showTickLabel, vr: .CS, showsTickLabels ? "Y" : "N"))
        }
        if !graphic.majorTicks.isEmpty {
            elements.append(sequence(.majorTicksSequence, graphic.majorTicks.map { tick in
                DicomDataSet(elements: [
                    fl(.tickPosition, [tick.position]),
                    string(.tickLabel, vr: .SH, tick.label)
                ])
            }))
        }
        if let lineStyle = graphic.lineStyle {
            elements.append(sequence(.lineStyleSequence, [lineStyleDataSet(lineStyle)]))
        }
        if let fillStyle = graphic.fillStyle {
            elements.append(sequence(.fillStyleSequence, [fillStyleDataSet(fillStyle)]))
        }
        if let textStyle = graphic.textStyle {
            elements.append(sequence(.textStyleSequence, [textStyleDataSet(textStyle)]))
        }
        if let graphicGroupID = graphic.graphicGroupID {
            elements.append(ul(.graphicGroupID, graphicGroupID))
        }
        return DicomDataSet(elements: elements)
    }

    private static func lineStyleDataSet(
        _ style: DicomPresentationCompoundGraphicLineStyle
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        appendCIELab(style.patternOnColorCIELabValue, tag: .patternOnColorCIELabValue, to: &elements)
        appendCIELab(style.patternOffColorCIELabValue, tag: .patternOffColorCIELabValue, to: &elements)
        appendOptionalFloat(style.patternOnOpacity, tag: .patternOnOpacity, to: &elements)
        appendOptionalFloat(style.patternOffOpacity, tag: .patternOffOpacity, to: &elements)
        appendOptionalFloat(style.lineThickness, tag: .lineThickness, to: &elements)
        appendOptionalString(.lineDashingStyle, vr: .CS, style.lineDashingStyle, to: &elements)
        if let linePattern = style.linePattern {
            elements.append(ul(.linePattern, linePattern))
        }
        appendOptionalString(.shadowStyle, vr: .CS, style.shadowStyle, to: &elements)
        appendOptionalFloat(style.shadowOffsetX, tag: .shadowOffsetX, to: &elements)
        appendOptionalFloat(style.shadowOffsetY, tag: .shadowOffsetY, to: &elements)
        appendCIELab(style.shadowColorCIELabValue, tag: .shadowColorCIELabValue, to: &elements)
        appendOptionalFloat(style.shadowOpacity, tag: .shadowOpacity, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func fillStyleDataSet(
        _ style: DicomPresentationCompoundGraphicFillStyle
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        appendCIELab(style.patternOnColorCIELabValue, tag: .patternOnColorCIELabValue, to: &elements)
        appendCIELab(style.patternOffColorCIELabValue, tag: .patternOffColorCIELabValue, to: &elements)
        appendOptionalFloat(style.patternOnOpacity, tag: .patternOnOpacity, to: &elements)
        appendOptionalFloat(style.patternOffOpacity, tag: .patternOffOpacity, to: &elements)
        appendOptionalString(.fillMode, vr: .CS, style.fillMode, to: &elements)
        if let fillPattern = style.fillPattern {
            elements.append(DicomDataElement(
                tag: DicomTag.fillPattern.rawValue,
                vr: .OB,
                value: .bytes(fillPattern)
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func textStyleDataSet(
        _ style: DicomPresentationCompoundGraphicTextStyle
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        appendOptionalString(.fontName, vr: .LO, style.fontName, to: &elements)
        appendOptionalString(.fontNameType, vr: .CS, style.fontNameType, to: &elements)
        appendOptionalString(.cssFontName, vr: .LO, style.cssFontName, to: &elements)
        appendCIELab(style.textColorCIELabValue, tag: .textColorCIELabValue, to: &elements)
        appendOptionalString(.horizontalAlignment, vr: .CS, style.horizontalAlignment, to: &elements)
        appendOptionalString(.verticalAlignment, vr: .CS, style.verticalAlignment, to: &elements)
        appendOptionalString(.shadowStyle, vr: .CS, style.shadowStyle, to: &elements)
        appendOptionalFloat(style.shadowOffsetX, tag: .shadowOffsetX, to: &elements)
        appendOptionalFloat(style.shadowOffsetY, tag: .shadowOffsetY, to: &elements)
        appendCIELab(style.shadowColorCIELabValue, tag: .shadowColorCIELabValue, to: &elements)
        appendOptionalFloat(style.shadowOpacity, tag: .shadowOpacity, to: &elements)
        appendOptionalYesNo(style.isUnderlined, tag: .underlined, to: &elements)
        appendOptionalYesNo(style.isBold, tag: .bold, to: &elements)
        appendOptionalYesNo(style.isItalic, tag: .italic, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func appendCIELab(
        _ values: [UInt16],
        tag: DicomTag,
        to elements: inout [DicomDataElement]
    ) {
        guard values.count >= 3 else { return }
        elements.append(DicomDataElement(
            tag: tag.rawValue,
            vr: .US,
            value: .unsignedIntegers(values.prefix(3).map(UInt.init))
        ))
    }

    private static func appendOptionalFloat(
        _ value: Double?,
        tag: DicomTag,
        to elements: inout [DicomDataElement]
    ) {
        guard let value else { return }
        elements.append(fl(tag, [value]))
    }

    private static func appendOptionalYesNo(
        _ value: Bool?,
        tag: DicomTag,
        to elements: inout [DicomDataElement]
    ) {
        guard let value else { return }
        elements.append(string(tag, vr: .CS, value ? "Y" : "N"))
    }

    private static func displayedAreaDataSet(_ area: DicomPresentationDisplayedArea) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            sl(.displayedAreaTopLeftHandCorner, [area.topLeft.x, area.topLeft.y]),
            sl(.displayedAreaBottomRightHandCorner, [area.bottomRight.x, area.bottomRight.y]),
            string(.presentationSizeMode, vr: .CS, area.presentationSizeMode)
        ]
        if !area.referencedImages.isEmpty {
            elements.append(sequence(.referencedImageSequence, area.referencedImages.map(referencedImageDataSet)))
        }
        appendOptionalString(
            .pixelOriginInterpretation,
            vr: .CS,
            area.pixelOriginInterpretation,
            to: &elements
        )
        if area.presentationPixelSpacing.count == 2 {
            elements.append(ds(.presentationPixelSpacing, area.presentationPixelSpacing))
        }
        // C.10.4: the aspect ratio is required without a presentation pixel spacing; square pixels are the default.
        if area.presentationPixelAspectRatio.count == 2 || area.presentationPixelSpacing.count != 2 {
            let ratio = area.presentationPixelAspectRatio.count == 2 ? area.presentationPixelAspectRatio : [1, 1]
            elements.append(DicomDataElement(
                tag: DicomTag.presentationPixelAspectRatio.rawValue,
                vr: .IS,
                value: .strings(ratio.map(String.init))
            ))
        }
        if let magnification = area.presentationPixelMagnificationRatio {
            elements.append(fl(.presentationPixelMagnificationRatio, [magnification]))
        }
        return DicomDataSet(elements: elements)
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }

    private static func ul(_ tag: DicomTag, _ value: UInt32) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers([UInt(value)]))
    }

    private static func sl(_ tag: DicomTag, _ values: [Int32]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .SL, value: .signedIntegers(values.map(Int.init)))
    }

    private static func isElement(_ tag: DicomTag, _ values: [Int32]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings(values.map(String.init)))
    }

    private static func ds(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values.map { String($0) }))
    }

    private static func fl(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .FL, value: .floats(values))
    }

    private static func appendDisplayWindows(_ windows: [DicomDisplayWindow],
                                             to elements: inout [DicomDataElement]) {
        guard !windows.isEmpty else { return }
        elements.append(ds(.windowCenter, windows.map(\.settings.center)))
        elements.append(ds(.windowWidth, windows.map(\.settings.width)))
        let explanations = windows.compactMap(\.explanation)
        if !explanations.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.windowCenterWidthExplanation.rawValue,
                vr: .LO,
                value: .strings(explanations)
            ))
        }
    }

    private static func appendSoftcopyVOI(
        _ selections: [DicomPresentationVOISelection],
        to elements: inout [DicomDataElement]
    ) {
        let items = selections.compactMap { selection -> DicomDataSet? in
            let profile = selection.displayTransformProfile
            var itemElements: [DicomDataElement] = []
            if !selection.referencedImages.isEmpty {
                itemElements.append(sequence(
                    .referencedImageSequence,
                    selection.referencedImages.map(referencedImageDataSet)
                ))
            }
            if !profile.voiLUTs.isEmpty {
                appendVOILUTs(profile.voiLUTs, to: &itemElements)
            } else if !profile.windows.isEmpty {
                appendDisplayWindows(profile.windows, to: &itemElements)
            }
            return itemElements.isEmpty ? nil : DicomDataSet(elements: itemElements)
        }
        if !items.isEmpty {
            elements.append(sequence(.softcopyVOILUTSequence, items))
        }
    }

    private static func appendPalette(
        _ palette: DicomPaletteColorLookupTable,
        to elements: inout [DicomDataElement]
    ) {
        let channels: [(DicomTag, DicomTag, DicomLUTDescriptor, [UInt8])] = [
            (.redPaletteDescriptor, .redPalette, palette.redDescriptor, palette.red),
            (.greenPaletteDescriptor, .greenPalette, palette.greenDescriptor, palette.green),
            (.bluePaletteDescriptor, .bluePalette, palette.blueDescriptor, palette.blue)
        ]
        for (descriptorTag, dataTag, descriptor, values) in channels {
            let descriptorValues = [descriptor.storedEntryCount, descriptor.firstMappedValue, 8]
            elements.append(DicomDataElement(
                tag: descriptorTag.rawValue, vr: descriptor.firstMappedValue < 0 ? .SS : .US,
                value: descriptor.firstMappedValue < 0 ? .signedIntegers(descriptorValues)
                    : .unsignedIntegers(descriptorValues.map(UInt.init))
            ))
            var bytes = Data(values.prefix(descriptor.entryCount))
            if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
            elements.append(DicomDataElement(tag: dataTag.rawValue, vr: .OW, value: .bytes(bytes)))
        }
    }

    private static func appendVOILUTs(
        _ lookupTables: [DicomLookupTable],
        sequenceTag: DicomTag = .voiLUTSequence,
        to elements: inout [DicomDataElement]
    ) {
        let dataSets = lookupTables.compactMap { lookupTable -> DicomDataSet? in
            let descriptor = lookupTable.descriptor
            guard !lookupTable.data.isEmpty,
                  lookupTable.data.count >= descriptor.entryCount,
                  (8...16).contains(descriptor.bitsPerEntry) else {
                return nil
            }
            let descriptorValues = [
                descriptor.storedEntryCount,
                descriptor.firstMappedValue,
                descriptor.bitsPerEntry
            ]
            let descriptorElement: DicomDataElement
            if descriptor.firstMappedValue < 0 {
                descriptorElement = DicomDataElement(
                    tag: DicomTag.lutDescriptor.rawValue,
                    vr: .SS,
                    value: .signedIntegers(descriptorValues)
                )
            } else {
                descriptorElement = DicomDataElement(
                    tag: DicomTag.lutDescriptor.rawValue,
                    vr: .US,
                    value: .unsignedIntegers(descriptorValues.map(UInt.init))
                )
            }
            let values = lookupTable.data.prefix(descriptor.entryCount)
            var bytes = Data()
            if descriptor.bitsPerEntry == 8 && (sequenceTag == .voiLUTSequence || sequenceTag == .presentationLUTSequence) {
                guard values.allSatisfy({ $0 <= UInt8.max }) else { return nil }
                bytes.append(contentsOf: values.map(UInt8.init))
                if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
            } else {
                bytes.reserveCapacity(descriptor.entryCount * MemoryLayout<UInt16>.size)
                for value in values {
                    var littleEndian = value.littleEndian
                    withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
                }
            }
            var itemElements = [
                descriptorElement,
                DicomDataElement(tag: DicomTag.lutData.rawValue, vr: .OW, value: .bytes(bytes))
            ]
            appendOptionalString(
                .lutExplanation,
                vr: .LO,
                lookupTable.explanation,
                to: &itemElements
            )
            if sequenceTag == .modalityLUTSequence {
                itemElements.append(string(.modalityLUTType, vr: .LO, lookupTable.lutType ?? "US"))
            }
            return DicomDataSet(elements: itemElements)
        }
        if !dataSets.isEmpty {
            elements.append(sequence(sequenceTag, dataSets))
        }
    }

    private static func appendShutters(
        _ shutters: [DicomPresentationShutter],
        presentationValue: UInt16?,
        to elements: inout [DicomDataElement]
    ) {
        guard !shutters.isEmpty else { return }
        var shapes: [String] = []
        for shutter in shutters {
            switch shutter {
            case let .rectangular(left, right, upper, lower):
                shapes.append("RECTANGULAR")
                elements.append(isElement(.shutterLeftVerticalEdge, [left]))
                elements.append(isElement(.shutterRightVerticalEdge, [right]))
                elements.append(isElement(.shutterUpperHorizontalEdge, [upper]))
                elements.append(isElement(.shutterLowerHorizontalEdge, [lower]))
            case let .circular(center, radius):
                shapes.append("CIRCULAR")
                elements.append(isElement(.centerOfCircularShutter, [center.x, center.y]))
                elements.append(isElement(.radiusOfCircularShutter, [radius]))
            case let .polygonal(vertices):
                shapes.append("POLYGONAL")
                elements.append(isElement(.verticesOfPolygonalShutter, vertices.flatMap { [$0.x, $0.y] }))
            case .bitmap(let bitmap):
                guard bitmap.rows > 0,
                      bitmap.columns > 0,
                      bitmap.mask.count >= bitmap.rows * bitmap.columns,
                      (0x6000...0x601E).contains(Int(bitmap.overlayGroup)),
                      bitmap.overlayGroup.isMultiple(of: 2) else {
                    continue
                }
                shapes.append("BITMAP")
                elements.append(DicomDataElement(
                    tag: DicomTag.shutterOverlayGroup.rawValue,
                    vr: .US,
                    value: .unsignedIntegers([UInt(bitmap.overlayGroup)])
                ))
                let group = Int(bitmap.overlayGroup)
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0010),
                    vr: .US,
                    value: .unsignedIntegers([UInt(bitmap.rows)])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0011),
                    vr: .US,
                    value: .unsignedIntegers([UInt(bitmap.columns)])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0040),
                    vr: .CS,
                    value: .strings(["G"])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0050),
                    vr: .SS,
                    value: .signedIntegers([bitmap.originRow + 1, bitmap.originColumn + 1])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0100),
                    vr: .US,
                    value: .unsignedIntegers([1])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x0102),
                    vr: .US,
                    value: .unsignedIntegers([0])
                ))
                elements.append(DicomDataElement(
                    tag: overlayTag(group: group, element: 0x3000),
                    vr: .OW,
                    value: .bytes(packedOverlayMask(bitmap.mask, count: bitmap.rows * bitmap.columns))
                ))
            }
        }
        if !shapes.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.shutterShape.rawValue,
                vr: .CS,
                value: .strings(shapes)
            ))
            let bitmapPresentationValue = shutters.compactMap { shutter -> UInt16? in
                guard case .bitmap(let bitmap) = shutter else { return nil }
                return bitmap.presentationValue
            }.first
            if let presentationValue = presentationValue ?? bitmapPresentationValue {
                elements.append(DicomDataElement(
                    tag: DicomTag.shutterPresentationValue.rawValue,
                    vr: .US,
                    value: .unsignedIntegers([UInt(presentationValue)])
                ))
            }
        }
    }

    private static func overlayTag(group: Int, element: Int) -> Int {
        (group << 16) | element
    }

    private static func packedOverlayMask(_ mask: Data, count: Int) -> Data {
        var packed = Data(count: max(2, ((count + 7) / 8 + 1) & ~1))
        for (offset, index) in mask.indices.prefix(count).enumerated() where mask[index] != 0 {
            packed[offset / 8] |= UInt8(1 << (offset % 8))
        }
        return packed
    }

    private static func appendOptionalString(
        _ tag: DicomTag,
        vr: DicomVR,
        _ value: String?,
        to elements: inout [DicomDataElement]
    ) {
        guard let value = value?.dicomGSPSNonEmptyValue else { return }
        elements.append(string(tag, vr: vr, value))
    }

    private static func appendOptionalIntegerString(
        _ tag: DicomTag,
        _ value: Int?,
        to elements: inout [DicomDataElement]
    ) {
        guard let value else { return }
        elements.append(DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings([String(value)])))
    }

    private static func currentDicomDateTime() -> (date: String, time: String) {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyyMMdd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HHmmss"

        return (dateFormatter.string(from: date), timeFormatter.string(from: date))
    }
}
