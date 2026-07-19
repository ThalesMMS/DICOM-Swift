import Foundation

/// One SOP Instance referenced by a Grayscale Softcopy Presentation State.
public struct DicomPresentationReferencedImage: Equatable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let referencedFrameNumbers: [Int]

    public init(
        referencedSOPClassUID: String?,
        referencedSOPInstanceUID: String?,
        referencedFrameNumbers: [Int] = []
    ) {
        self.referencedSOPClassUID = referencedSOPClassUID?.dicomGSPSNonEmptyValue
        self.referencedSOPInstanceUID = referencedSOPInstanceUID?.dicomGSPSNonEmptyValue
        self.referencedFrameNumbers = referencedFrameNumbers
    }

    public var sourceImageReference: DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: referencedSOPClassUID,
            referencedSOPInstanceUID: referencedSOPInstanceUID,
            referencedFrameNumbers: referencedFrameNumbers
        )
    }
}

/// A referenced image series in a presentation state relationship module.
public struct DicomPresentationReferencedSeries: Equatable, Sendable {
    public let seriesInstanceUID: String
    public let images: [DicomPresentationReferencedImage]

    public init(seriesInstanceUID: String, images: [DicomPresentationReferencedImage]) {
        self.seriesInstanceUID = seriesInstanceUID.dicomGSPSNonEmptyValue ?? DicomDataSetWriter.makeUID()
        self.images = images
    }
}

/// One graphic layer used by presentation-state annotations.
public struct DicomPresentationGraphicLayer: Equatable, Sendable {
    public let name: String
    public let order: Int
    public let recommendedDisplayGrayscaleValue: UInt?
    public let recommendedDisplayCIELabValue: [UInt16]
    public let description: String?

    public init(
        name: String,
        order: Int = 1,
        recommendedDisplayGrayscaleValue: UInt? = nil,
        recommendedDisplayCIELabValue: [UInt16] = [],
        description: String? = nil
    ) {
        self.name = name.dicomGSPSLayerName
        self.order = max(0, order)
        self.recommendedDisplayGrayscaleValue = recommendedDisplayGrayscaleValue
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.description = description?.dicomGSPSNonEmptyValue
    }
}

/// One image-relative or display-relative graphic object in a GSPS annotation.
public struct DicomPresentationGraphicObject: Equatable, Sendable {
    public let annotationUnits: String
    public let graphicType: String
    public let graphicData: [Double]
    public let graphicFilled: Bool?
    public let trackingID: String?
    public let trackingUID: String?

    public init(
        annotationUnits: String = "PIXEL",
        graphicType: String,
        graphicData: [Double],
        graphicFilled: Bool? = nil,
        trackingID: String? = nil,
        trackingUID: String? = nil
    ) {
        self.annotationUnits = annotationUnits.dicomGSPSNonEmptyValue?.uppercased() ?? "PIXEL"
        self.graphicType = graphicType.dicomGSPSNonEmptyValue?.uppercased() ?? "POLYLINE"
        self.graphicData = graphicData
        self.graphicFilled = graphicFilled
        self.trackingID = trackingID?.dicomGSPSNonEmptyValue
        self.trackingUID = trackingUID?.dicomGSPSNonEmptyValue
    }

    public var numberOfGraphicPoints: Int {
        graphicData.count / 2
    }
}

/// One display text object from a GSPS annotation.
public struct DicomPresentationTextObject: Equatable, Sendable {
    public let text: String
    public let anchorPoint: SIMD2<Double>?
    public let boundingBoxTopLeft: SIMD2<Double>?
    public let boundingBoxBottomRight: SIMD2<Double>?

    public init(
        text: String,
        anchorPoint: SIMD2<Double>? = nil,
        boundingBoxTopLeft: SIMD2<Double>? = nil,
        boundingBoxBottomRight: SIMD2<Double>? = nil
    ) {
        self.text = text.dicomGSPSNonEmptyValue ?? "Annotation"
        self.anchorPoint = anchorPoint
        self.boundingBoxTopLeft = boundingBoxTopLeft
        self.boundingBoxBottomRight = boundingBoxBottomRight
    }
}

/// One GSPS graphic annotation group applied to all or a subset of referenced images.
public struct DicomPresentationGraphicAnnotation: Equatable, Sendable {
    public let graphicLayer: String
    public let referencedImages: [DicomPresentationReferencedImage]
    public let graphicObjects: [DicomPresentationGraphicObject]
    public let textObjects: [DicomPresentationTextObject]

    public init(
        graphicLayer: String,
        referencedImages: [DicomPresentationReferencedImage] = [],
        graphicObjects: [DicomPresentationGraphicObject],
        textObjects: [DicomPresentationTextObject] = []
    ) {
        self.graphicLayer = graphicLayer.dicomGSPSLayerName
        self.referencedImages = referencedImages
        self.graphicObjects = graphicObjects
        self.textObjects = textObjects
    }
}

public struct DicomPresentationSpatialTransform: Equatable, Sendable {
    public let isHorizontallyFlipped: Bool
    public let rotationDegrees: Int

    public init(isHorizontallyFlipped: Bool = false, rotationDegrees: Int = 0) {
        self.isHorizontallyFlipped = isHorizontallyFlipped
        self.rotationDegrees = ((rotationDegrees % 360) + 360) % 360
    }

    public static let identity = DicomPresentationSpatialTransform()
}

public enum DicomPresentationShutter: Equatable, Sendable {
    case rectangular(left: Int32, right: Int32, upper: Int32, lower: Int32)
    case circular(center: SIMD2<Int32>, radius: Int32)
    case polygonal(vertices: [SIMD2<Int32>])
}

/// Parsed Grayscale Softcopy Presentation State with graphic annotations.
public struct DicomGrayscalePresentationState: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.11.1"

    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let contentLabel: String?
    public let contentDescription: String?
    public let presentationCreationDate: String?
    public let presentationCreationTime: String?
    public let referencedSeries: [DicomPresentationReferencedSeries]
    public let displayedAreas: [DicomPresentationDisplayedArea]
    public let spatialTransform: DicomPresentationSpatialTransform
    public let shutters: [DicomPresentationShutter]
    public let displayTransformProfile: DicomDisplayTransformProfile
    public let graphicLayers: [DicomPresentationGraphicLayer]
    public let graphicAnnotations: [DicomPresentationGraphicAnnotation]
    public let iccProfile: Data?

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        contentLabel: String? = nil,
        contentDescription: String? = nil,
        presentationCreationDate: String? = nil,
        presentationCreationTime: String? = nil,
        referencedSeries: [DicomPresentationReferencedSeries],
        displayedAreas: [DicomPresentationDisplayedArea] = [],
        spatialTransform: DicomPresentationSpatialTransform = .identity,
        shutters: [DicomPresentationShutter] = [],
        displayTransformProfile: DicomDisplayTransformProfile = .identity,
        graphicLayers: [DicomPresentationGraphicLayer],
        graphicAnnotations: [DicomPresentationGraphicAnnotation],
        iccProfile: Data? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomGSPSNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomGSPSNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomGSPSNonEmptyValue
        self.contentLabel = contentLabel?.dicomGSPSNonEmptyValue
        self.contentDescription = contentDescription?.dicomGSPSNonEmptyValue
        self.presentationCreationDate = presentationCreationDate?.dicomGSPSNonEmptyValue
        self.presentationCreationTime = presentationCreationTime?.dicomGSPSNonEmptyValue
        self.referencedSeries = referencedSeries
        self.displayedAreas = displayedAreas
        self.spatialTransform = spatialTransform
        self.shutters = shutters
        self.displayTransformProfile = displayTransformProfile
        self.graphicLayers = graphicLayers
        self.graphicAnnotations = graphicAnnotations
        self.iccProfile = iccProfile
    }
}

public struct DicomPresentationDisplayedArea: Equatable, Sendable {
    public let topLeft: SIMD2<Int32>
    public let bottomRight: SIMD2<Int32>
    public let presentationSizeMode: String

    public init(
        topLeft: SIMD2<Int32> = SIMD2<Int32>(1, 1),
        bottomRight: SIMD2<Int32>,
        presentationSizeMode: String = "SCALE TO FIT"
    ) {
        self.topLeft = topLeft
        self.bottomRight = bottomRight
        self.presentationSizeMode = presentationSizeMode.dicomGSPSNonEmptyValue?.uppercased() ?? "SCALE TO FIT"
    }
}

public struct DicomPresentationStateBuildOptions: Equatable, Sendable {
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var contentLabel: String
    public var contentDescription: String?
    public var contentCreatorName: String?
    public var presentationCreationDate: String?
    public var presentationCreationTime: String?
    public var displayedArea: DicomPresentationDisplayedArea?
    public var spatialTransform: DicomPresentationSpatialTransform
    public var shutters: [DicomPresentationShutter]
    public var displayTransformProfile: DicomDisplayTransformProfile
    public var iccProfile: Data?

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        contentLabel: String = "AI_FINDINGS",
        contentDescription: String? = "External inference annotations",
        contentCreatorName: String? = nil,
        presentationCreationDate: String? = nil,
        presentationCreationTime: String? = nil,
        displayedArea: DicomPresentationDisplayedArea? = nil,
        spatialTransform: DicomPresentationSpatialTransform = .identity,
        shutters: [DicomPresentationShutter] = [],
        displayTransformProfile: DicomDisplayTransformProfile = .identity,
        iccProfile: Data? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomGSPSNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomGSPSNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomGSPSNonEmptyValue
        self.patientName = patientName?.dicomGSPSNonEmptyValue
        self.patientID = patientID?.dicomGSPSNonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.contentLabel = contentLabel.dicomGSPSNonEmptyValue ?? "AI_FINDINGS"
        self.contentDescription = contentDescription?.dicomGSPSNonEmptyValue
        self.contentCreatorName = contentCreatorName?.dicomGSPSNonEmptyValue
        self.presentationCreationDate = presentationCreationDate?.dicomGSPSNonEmptyValue
        self.presentationCreationTime = presentationCreationTime?.dicomGSPSNonEmptyValue
        self.displayedArea = displayedArea
        self.spatialTransform = spatialTransform
        self.shutters = shutters
        self.displayTransformProfile = displayTransformProfile
        self.iccProfile = iccProfile
    }
}

public enum DicomGrayscalePresentationStateBuilder {
    public static let storageSOPClassUID = DicomGrayscalePresentationState.storageSOPClassUID

    public static func dataSet(
        referencedSeries: [DicomPresentationReferencedSeries],
        graphicAnnotations: [DicomPresentationGraphicAnnotation],
        graphicLayers: [DicomPresentationGraphicLayer] = [],
        options: DicomPresentationStateBuildOptions = DicomPresentationStateBuildOptions()
    ) -> DicomDataSet {
        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let layers = resolvedLayers(explicitLayers: graphicLayers, annotations: graphicAnnotations)

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, "PR"),
            string(.contentLabel, vr: .LO, options.contentLabel),
            string(.presentationCreationDate, vr: .DA, options.presentationCreationDate ?? now.date),
            string(.presentationCreationTime, vr: .TM, options.presentationCreationTime ?? now.time),
            sequence(.referencedSeriesSequence, referencedSeries.map(referencedSeriesDataSet)),
            sequence(.graphicLayerSequence, layers.map(graphicLayerDataSet)),
            sequence(.graphicAnnotationSequence, graphicAnnotations.map(graphicAnnotationDataSet)),
            sequence(.displayedAreaSelectionSequence, [displayedAreaDataSet(options.displayedArea)]),
            string(.imageHorizontalFlip, vr: .CS, options.spatialTransform.isHorizontallyFlipped ? "Y" : "N"),
            us(.imageRotation, options.spatialTransform.rotationDegrees),
            string(
                .presentationLUTShape,
                vr: .CS,
                options.displayTransformProfile.presentationLUTShape?.rawValue ?? "IDENTITY"
            )
        ]

        appendOptionalString(.patientName, vr: .PN, options.patientName, to: &elements)
        appendOptionalString(.patientID, vr: .LO, options.patientID, to: &elements)
        appendOptionalString(.contentDescription, vr: .ST, options.contentDescription, to: &elements)
        appendOptionalString(.contentCreatorName, vr: .PN, options.contentCreatorName, to: &elements)
        appendOptionalIntegerString(.seriesNumber, options.seriesNumber, to: &elements)
        appendOptionalIntegerString(.instanceNumber, options.instanceNumber, to: &elements)
        appendDisplayWindows(options.displayTransformProfile.windows, to: &elements)
        appendShutters(options.shutters, to: &elements)
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
        let dataSet = dataSet(
            referencedSeries: referencedSeries,
            graphicAnnotations: graphicAnnotations,
            graphicLayers: graphicLayers,
            options: options
        )
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
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
            string(.graphicLayer, vr: .LO, layer.name),
            us(.graphicLayerOrder, layer.order)
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
        appendOptionalString(.graphicLayerDescription, vr: .ST, layer.description, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func graphicAnnotationDataSet(_ annotation: DicomPresentationGraphicAnnotation) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.graphicLayer, vr: .LO, annotation.graphicLayer),
            sequence(.graphicObjectSequence, annotation.graphicObjects.map(graphicObjectDataSet))
        ]
        if !annotation.referencedImages.isEmpty {
            elements.append(sequence(.referencedImageSequence, annotation.referencedImages.map(referencedImageDataSet)))
        }
        if !annotation.textObjects.isEmpty {
            elements.append(sequence(.textObjectSequence, annotation.textObjects.map(textObjectDataSet)))
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
        if let graphicFilled = object.graphicFilled {
            elements.append(string(.graphicFilled, vr: .CS, graphicFilled ? "Y" : "N"))
        }
        appendOptionalString(.trackingID, vr: .LO, object.trackingID, to: &elements)
        appendOptionalString(.trackingUID, vr: .UI, object.trackingUID, to: &elements)
        return DicomDataSet(elements: elements)
    }

    private static func textObjectDataSet(_ object: DicomPresentationTextObject) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.unformattedTextValue, vr: .ST, object.text)
        ]
        if let anchorPoint = object.anchorPoint {
            elements.append(fl(.anchorPoint, [anchorPoint.x, anchorPoint.y]))
        }
        if let topLeft = object.boundingBoxTopLeft {
            elements.append(fl(.boundingBoxTopLeftHandCorner, [topLeft.x, topLeft.y]))
        }
        if let bottomRight = object.boundingBoxBottomRight {
            elements.append(fl(.boundingBoxBottomRightHandCorner, [bottomRight.x, bottomRight.y]))
        }
        return DicomDataSet(elements: elements)
    }

    private static func displayedAreaDataSet(_ displayedArea: DicomPresentationDisplayedArea?) -> DicomDataSet {
        let area = displayedArea ?? DicomPresentationDisplayedArea(bottomRight: SIMD2<Int32>(1, 1))
        return DicomDataSet(elements: [
            sl(.displayedAreaTopLeftHandCorner, [area.topLeft.x, area.topLeft.y]),
            sl(.displayedAreaBottomRightHandCorner, [area.bottomRight.x, area.bottomRight.y]),
            string(.presentationSizeMode, vr: .CS, area.presentationSizeMode)
        ])
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

    private static func appendShutters(_ shutters: [DicomPresentationShutter],
                                       to elements: inout [DicomDataElement]) {
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
            }
        }
        elements.append(DicomDataElement(tag: DicomTag.shutterShape.rawValue, vr: .CS, value: .strings(shapes)))
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

extension DCMDecoder {
    public var grayscalePresentationState: DicomGrayscalePresentationState? {
        synchronized {
            DicomGrayscalePresentationStateParser.makePresentationState(from: self)
        }
    }
}

private enum DicomGrayscalePresentationStateParser {
    static func makePresentationState(from decoder: DCMDecoder) -> DicomGrayscalePresentationState? {
        guard decoder.info(for: .sopClassUID).dicomGSPSTrimmedValue == DicomGrayscalePresentationState.storageSOPClassUID else {
            return nil
        }
        return DicomGrayscalePresentationState(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            contentLabel: decoder.info(for: .contentLabel),
            contentDescription: decoder.info(for: .contentDescription),
            presentationCreationDate: decoder.info(for: .presentationCreationDate),
            presentationCreationTime: decoder.info(for: .presentationCreationTime),
            referencedSeries: parseItems(in: decoder, for: .referencedSeriesSequence).map(referencedSeries),
            displayedAreas: parseItems(in: decoder, for: .displayedAreaSelectionSequence).compactMap(displayedArea),
            spatialTransform: spatialTransform(from: decoder),
            shutters: shutters(from: decoder),
            displayTransformProfile: decoder.displayTransformProfile,
            graphicLayers: parseItems(in: decoder, for: .graphicLayerSequence).map(graphicLayer),
            graphicAnnotations: parseItems(in: decoder, for: .graphicAnnotationSequence).map(graphicAnnotation),
            iccProfile: decoder.dataSet.element(for: .iccProfile)?.bytesValue
        )
    }

    private static func referencedSeries(from item: DicomSequenceItem) -> DicomPresentationReferencedSeries {
        DicomPresentationReferencedSeries(
            seriesInstanceUID: item.dataSet.string(for: .seriesInstanceUID) ?? DicomDataSetWriter.makeUID(),
            images: item.dataSet.sequenceItems(for: .referencedImageSequence).map(referencedImage)
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
            textObjects: item.dataSet.sequenceItems(for: .textObjectSequence).map(textObject)
        )
    }

    private static func graphicObject(from item: DicomSequenceItem) -> DicomPresentationGraphicObject {
        DicomPresentationGraphicObject(
            annotationUnits: item.dataSet.string(for: .graphicAnnotationUnits) ?? "PIXEL",
            graphicType: item.dataSet.string(for: .graphicType) ?? "POLYLINE",
            graphicData: item.dataSet.floats(for: .graphicData),
            graphicFilled: item.dataSet.string(for: .graphicFilled).map { $0.dicomGSPSTrimmedValue.uppercased() == "Y" },
            trackingID: item.dataSet.string(for: .trackingID),
            trackingUID: item.dataSet.string(for: .trackingUID)
        )
    }

    private static func textObject(from item: DicomSequenceItem) -> DicomPresentationTextObject {
        DicomPresentationTextObject(
            text: item.dataSet.string(for: .unformattedTextValue) ?? "Annotation",
            anchorPoint: simd2(from: item.dataSet.floats(for: .anchorPoint)),
            boundingBoxTopLeft: simd2(from: item.dataSet.floats(for: .boundingBoxTopLeftHandCorner)),
            boundingBoxBottomRight: simd2(from: item.dataSet.floats(for: .boundingBoxBottomRightHandCorner))
        )
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
            topLeft: topLeft,
            bottomRight: SIMD2<Int32>(
                Int32(clamping: bottomRightValues[0]),
                Int32(clamping: bottomRightValues[1])
            ),
            presentationSizeMode: item.dataSet.string(for: .presentationSizeMode) ?? "SCALE TO FIT"
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

    private static func shutters(from decoder: DCMDecoder) -> [DicomPresentationShutter] {
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

        return shutters
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
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet
        )) ?? []
    }
}

private extension String {
    var dicomGSPSTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomGSPSNonEmptyValue: String? {
        let trimmed = dicomGSPSTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }

    var dicomGSPSLayerName: String {
        let allowed = dicomGSPSTrimmedValue
            .uppercased()
            .map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            }
        let value = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.isEmpty ? "AI" : String(value.prefix(16))
    }
}
