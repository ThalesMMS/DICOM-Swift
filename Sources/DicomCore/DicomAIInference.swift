import Foundation

public struct DicomAIFindingMeasurement: Equatable, Sendable {
    public let concept: DicomCodedConcept
    public let value: Double
    public let units: DicomCodedConcept
    public let trackingID: String?
    public let trackingUID: String?

    public init(
        concept: DicomCodedConcept,
        value: Double,
        units: DicomCodedConcept,
        trackingID: String? = nil,
        trackingUID: String? = nil
    ) {
        self.concept = concept
        self.value = value
        self.units = units
        self.trackingID = trackingID?.dicomAINonEmptyValue
        self.trackingUID = trackingUID?.dicomAINonEmptyValue
    }
}

public struct DicomAIFinding: Equatable, Sendable {
    public let title: DicomCodedConcept
    public let findingCode: DicomCodedConcept?
    public let description: String?
    public let confidence: Double?
    public let trackingID: String
    public let trackingUID: String
    public let sourceImageReferences: [DicomKeyObjectReference]
    public let regions: [DicomSRGraphicRegion]
    public let measurements: [DicomAIFindingMeasurement]

    public init(
        title: DicomCodedConcept,
        findingCode: DicomCodedConcept? = nil,
        description: String? = nil,
        confidence: Double? = nil,
        trackingID: String,
        trackingUID: String,
        sourceImageReferences: [DicomKeyObjectReference],
        regions: [DicomSRGraphicRegion] = [],
        measurements: [DicomAIFindingMeasurement] = []
    ) {
        self.title = title
        self.findingCode = findingCode
        self.description = description?.dicomAINonEmptyValue
        self.confidence = confidence
        self.trackingID = trackingID.dicomAINonEmptyValue ?? "finding"
        self.trackingUID = trackingUID.dicomAINonEmptyValue ?? DicomDataSetWriter.makeUID()
        self.sourceImageReferences = sourceImageReferences
        self.regions = regions
        self.measurements = measurements
    }
}

public struct DicomAIMaskFrame: Equatable, Sendable {
    public let index: Int
    public let sourceImageReferences: [DicomSourceImageReference]
    public let geometry: DicomFrameGeometry?
    public let pixels: [UInt8]

    public init(
        index: Int,
        sourceImageReferences: [DicomSourceImageReference] = [],
        geometry: DicomFrameGeometry? = nil,
        pixels: [UInt8]
    ) {
        self.index = max(0, index)
        self.sourceImageReferences = sourceImageReferences
        self.geometry = geometry
        self.pixels = pixels
    }
}

public struct DicomAIMask: Equatable, Sendable {
    public let rows: Int
    public let columns: Int
    public let segment: DicomSegment
    public let frames: [DicomAIMaskFrame]

    public init(rows: Int, columns: Int, segment: DicomSegment, frames: [DicomAIMaskFrame]) {
        self.rows = rows
        self.columns = columns
        self.segment = segment
        self.frames = frames
    }
}

public struct DicomAIAnnotation: Equatable, Sendable {
    public let layer: DicomPresentationGraphicLayer
    public let sourceImageReferences: [DicomKeyObjectReference]
    public let graphicObject: DicomPresentationGraphicObject

    public init(
        layer: DicomPresentationGraphicLayer = DicomPresentationGraphicLayer(name: "AI", order: 1),
        sourceImageReferences: [DicomKeyObjectReference],
        graphicObject: DicomPresentationGraphicObject
    ) {
        self.layer = layer
        self.sourceImageReferences = sourceImageReferences
        self.graphicObject = graphicObject
    }
}

public struct DicomAIInferenceBuildOptions: Equatable, Sendable {
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var algorithmName: String?
    public var contentLabel: String
    public var contentDescription: String?

    public init(
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        algorithmName: String? = nil,
        contentLabel: String = "AI_FINDINGS",
        contentDescription: String? = "External inference output"
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomAINonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomAINonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomAINonEmptyValue
        self.patientName = patientName?.dicomAINonEmptyValue
        self.patientID = patientID?.dicomAINonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.algorithmName = algorithmName?.dicomAINonEmptyValue
        self.contentLabel = contentLabel.dicomAINonEmptyValue ?? "AI_FINDINGS"
        self.contentDescription = contentDescription?.dicomAINonEmptyValue
    }
}

public enum DicomAIInferenceBuilder {
    public static func structuredReportDataSet(
        findings: [DicomAIFinding],
        options: DicomAIInferenceBuildOptions
    ) -> DicomDataSet {
        let root = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: DicomCodedConcept(
                codeValue: "126000",
                codingSchemeDesignator: "DCM",
                codeMeaning: "Imaging Measurement Report"
            ),
            continuityOfContent: "SEPARATE",
            children: findings.map(findingContainer)
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            sopInstanceUID: options.sopInstanceUID,
            modality: "SR",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: "1500",
            root: root,
            evidenceReferences: findings.flatMap(\.sourceImageReferences).removingDuplicateAIElements()
        )
        return DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: options.studyInstanceUID ?? DicomDataSetWriter.makeUID(),
            seriesInstanceUID: options.seriesInstanceUID ?? DicomDataSetWriter.makeUID(),
            sopInstanceUID: options.sopInstanceUID
        )
    }

    public static func structuredReportPart10Data(
        findings: [DicomAIFinding],
        options: DicomAIInferenceBuildOptions
    ) throws -> Data {
        let dataSet = structuredReportDataSet(findings: findings, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func segmentationDataSet(
        mask: DicomAIMask,
        options: DicomAIInferenceBuildOptions
    ) -> DicomDataSet {
        let segment = DicomSegment(
            number: mask.segment.number,
            label: mask.segment.label,
            description: mask.segment.description,
            algorithmType: mask.segment.algorithmType ?? "AUTOMATIC",
            algorithmName: mask.segment.algorithmName ?? options.algorithmName,
            propertyCategory: mask.segment.propertyCategory,
            propertyType: mask.segment.propertyType,
            trackingID: mask.segment.trackingID,
            trackingUID: mask.segment.trackingUID,
            recommendedDisplayCIELabValue: mask.segment.recommendedDisplayCIELabValue
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: options.sopInstanceUID,
            segmentationType: .binary,
            rows: mask.rows,
            columns: mask.columns,
            segments: [segment],
            frames: mask.frames.map {
                DicomSegmentationFrame(
                    index: $0.index,
                    segmentNumber: segment.number,
                    geometry: $0.geometry,
                    sourceImageReferences: $0.sourceImageReferences,
                    pixelData: .binary($0.pixels)
                )
            }
        )
        return DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: options.studyInstanceUID ?? DicomDataSetWriter.makeUID(),
            seriesInstanceUID: options.seriesInstanceUID ?? DicomDataSetWriter.makeUID(),
            sopInstanceUID: options.sopInstanceUID,
            contentLabel: options.contentLabel
        )
    }

    public static func segmentationPart10Data(
        mask: DicomAIMask,
        options: DicomAIInferenceBuildOptions
    ) throws -> Data {
        let dataSet = segmentationDataSet(mask: mask, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    /// Throws `DICOMError.missingRequiredTag` when a source image reference has no nonblank Series Instance UID.
    public static func presentationStateDataSet(
        annotations: [DicomAIAnnotation],
        options: DicomAIInferenceBuildOptions,
        displayedArea: DicomPresentationDisplayedArea? = nil
    ) throws -> DicomDataSet {
        let referencedSeries = try referencedSeries(from: annotations.flatMap(\.sourceImageReferences))
        let graphicAnnotations = annotations.map {
            DicomPresentationGraphicAnnotation(
                graphicLayer: $0.layer.name,
                referencedImages: $0.sourceImageReferences.map {
                    DicomPresentationReferencedImage(
                        referencedSOPClassUID: $0.referencedSOPClassUID,
                        referencedSOPInstanceUID: $0.referencedSOPInstanceUID,
                        referencedFrameNumbers: $0.referencedFrameNumbers
                    )
                },
                graphicObjects: [$0.graphicObject]
            )
        }
        return try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: referencedSeries,
            graphicAnnotations: graphicAnnotations,
            graphicLayers: annotations.map(\.layer).removingDuplicateAIElements(),
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: options.sopInstanceUID,
                studyInstanceUID: options.studyInstanceUID,
                seriesInstanceUID: options.seriesInstanceUID,
                patientName: options.patientName,
                patientID: options.patientID,
                seriesNumber: options.seriesNumber,
                instanceNumber: options.instanceNumber,
                contentLabel: options.contentLabel,
                contentDescription: options.contentDescription,
                displayedArea: displayedArea
            )
        )
    }

    public static func derivedImageDataSet(
        pixelData: DicomSecondaryCapturePixelData,
        sourceImageReferences: [DicomSourceImageReference],
        options: DicomAIInferenceBuildOptions
    ) -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: pixelData,
            options: DicomSecondaryCaptureBuildOptions(
                sopInstanceUID: options.sopInstanceUID,
                studyInstanceUID: options.studyInstanceUID,
                seriesInstanceUID: options.seriesInstanceUID,
                patientName: options.patientName,
                patientID: options.patientID,
                seriesNumber: options.seriesNumber,
                instanceNumber: options.instanceNumber,
                seriesDescription: options.contentDescription ?? "AI derived image",
                derivationDescription: "External inference derived image",
                sourceImageReferences: sourceImageReferences
            )
        )
    }

    private static func findingContainer(_ finding: DicomAIFinding) -> DicomSRContentItem {
        var children: [DicomSRContentItem] = finding.sourceImageReferences.map {
            DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "IMAGE",
                conceptName: DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object"),
                referencedSOPs: [$0.sourceImageReference]
            )
        }
        if let findingCode = finding.findingCode {
            children.append(DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "CODE",
                conceptName: DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding"),
                codeValue: findingCode
            ))
        }
        if let description = finding.description {
            children.append(DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "TEXT",
                conceptName: DicomCodedConcept(codeValue: "121106", codingSchemeDesignator: "DCM", codeMeaning: "Comment"),
                textValue: description
            ))
        }
        if let confidence = finding.confidence {
            children.append(DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "NUM",
                conceptName: DicomCodedConcept(codeValue: "111036", codingSchemeDesignator: "DCM", codeMeaning: "Confidence"),
                numericValue: confidence,
                measurementUnits: DicomCodedConcept(codeValue: "{ratio}", codingSchemeDesignator: "UCUM", codeMeaning: "ratio"),
                trackingID: finding.trackingID,
                trackingUID: finding.trackingUID
            ))
        }
        children.append(contentsOf: finding.regions.map(regionItem))
        children.append(contentsOf: finding.measurements.map {
            DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "NUM",
                conceptName: $0.concept,
                numericValue: $0.value,
                measurementUnits: $0.units,
                trackingID: $0.trackingID ?? finding.trackingID,
                trackingUID: $0.trackingUID ?? finding.trackingUID,
                children: finding.regions.map(regionItem)
            )
        })

        return DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "CONTAINER",
            conceptName: finding.title,
            trackingID: finding.trackingID,
            trackingUID: finding.trackingUID,
            children: children
        )
    }

    private static func regionItem(_ region: DicomSRGraphicRegion) -> DicomSRContentItem {
        DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            conceptName: DicomCodedConcept(codeValue: "111030", codingSchemeDesignator: "DCM", codeMeaning: "Image Region"),
            graphicType: region.graphicType,
            graphicData: region.graphicData,
            children: region.sourceImageReferences.map {
                DicomSRContentItem(
                    relationshipType: "SELECTED FROM",
                    valueType: "IMAGE",
                    conceptName: DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object"),
                    referencedSOPs: [$0]
                )
            }
        )
    }

    private static func referencedSeries(
        from references: [DicomKeyObjectReference]
    ) throws -> [DicomPresentationReferencedSeries] {
        let uniqueReferences = references.removingDuplicateAIElements()
        let grouped = Dictionary(grouping: uniqueReferences) { $0.seriesInstanceUID ?? "" }
        return try grouped.keys.sorted().map { seriesUID in
            try DicomPresentationReferencedSeries(
                seriesInstanceUID: seriesUID,
                images: (grouped[seriesUID] ?? []).map {
                    DicomPresentationReferencedImage(
                        referencedSOPClassUID: $0.referencedSOPClassUID,
                        referencedSOPInstanceUID: $0.referencedSOPInstanceUID,
                        referencedFrameNumbers: $0.referencedFrameNumbers
                    )
                }
            )
        }
    }
}

private extension Array where Element: Equatable {
    func removingDuplicateAIElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension String {
    var dicomAITrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomAINonEmptyValue: String? {
        let trimmed = dicomAITrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
