import Foundation

/// DICOM Key Object or SR reference with optional study and series context.
public struct DicomKeyObjectReference: Equatable, Hashable, Sendable {
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let referencedFrameNumbers: [Int]

    public init(
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        referencedSOPClassUID: String?,
        referencedSOPInstanceUID: String?,
        referencedFrameNumbers: [Int] = []
    ) {
        self.studyInstanceUID = studyInstanceUID?.dicomSRNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomSRNonEmptyValue
        self.referencedSOPClassUID = referencedSOPClassUID?.dicomSRNonEmptyValue
        self.referencedSOPInstanceUID = referencedSOPInstanceUID?.dicomSRNonEmptyValue
        self.referencedFrameNumbers = referencedFrameNumbers
    }

    public var sourceImageReference: DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: referencedSOPClassUID,
            referencedSOPInstanceUID: referencedSOPInstanceUID,
            referencedFrameNumbers: referencedFrameNumbers
        )
    }

    public func referencesSameObject(as other: DicomKeyObjectReference) -> Bool {
        referencedSOPClassUID == other.referencedSOPClassUID &&
            referencedSOPInstanceUID == other.referencedSOPInstanceUID &&
            referencedFrameNumbers == other.referencedFrameNumbers
    }
}

/// One SR content item in the logical document tree.
public struct DicomSRContentItem: Equatable, Sendable {
    public let relationshipType: String?
    public let valueType: String
    public let conceptName: DicomCodedConcept?
    public let continuityOfContent: String?
    public let textValue: String?
    public let codeValue: DicomCodedConcept?
    public let numericValue: Double?
    public let measurementUnits: DicomCodedConcept?
    public let dateTimeValue: DicomDateTime?
    public let dateValue: DicomDate?
    public let timeValue: DicomTime?
    public let personNameValue: DicomPersonName?
    public let uidValue: String?
    public let referencedSOPs: [DicomSourceImageReference]
    public let graphicType: String?
    public let graphicData: [Double]
    public let trackingID: String?
    public let trackingUID: String?
    public let children: [DicomSRContentItem]

    public init(
        relationshipType: String? = nil,
        valueType: String,
        conceptName: DicomCodedConcept? = nil,
        continuityOfContent: String? = nil,
        textValue: String? = nil,
        codeValue: DicomCodedConcept? = nil,
        numericValue: Double? = nil,
        measurementUnits: DicomCodedConcept? = nil,
        dateTimeValue: DicomDateTime? = nil,
        dateValue: DicomDate? = nil,
        timeValue: DicomTime? = nil,
        personNameValue: DicomPersonName? = nil,
        uidValue: String? = nil,
        referencedSOPs: [DicomSourceImageReference] = [],
        graphicType: String? = nil,
        graphicData: [Double] = [],
        trackingID: String? = nil,
        trackingUID: String? = nil,
        children: [DicomSRContentItem] = []
    ) {
        self.relationshipType = relationshipType?.dicomSRNonEmptyValue?.uppercased()
        self.valueType = valueType.dicomSRNonEmptyValue?.uppercased() ?? "CONTAINER"
        self.conceptName = conceptName
        self.continuityOfContent = continuityOfContent?.dicomSRNonEmptyValue?.uppercased()
        self.textValue = textValue?.dicomSRNonEmptyValue
        self.codeValue = codeValue
        self.numericValue = numericValue
        self.measurementUnits = measurementUnits
        self.dateTimeValue = dateTimeValue
        self.dateValue = dateValue
        self.timeValue = timeValue
        self.personNameValue = personNameValue
        self.uidValue = uidValue?.dicomSRNonEmptyValue
        self.referencedSOPs = referencedSOPs
        self.graphicType = graphicType?.dicomSRNonEmptyValue?.uppercased()
        self.graphicData = graphicData
        self.trackingID = trackingID?.dicomSRNonEmptyValue
        self.trackingUID = trackingUID?.dicomSRNonEmptyValue
        self.children = children
    }

    public var flattened: [DicomSRContentItem] {
        [self] + children.flatMap(\.flattened)
    }

    public var allSourceImageReferences: [DicomSourceImageReference] {
        (referencedSOPs + children.flatMap(\.allSourceImageReferences)).removingDuplicateSRElements()
    }
}

/// A 2D SR spatial coordinate region suitable for image overlays.
public struct DicomSRGraphicRegion: Equatable, Sendable {
    public let graphicType: String
    public let graphicData: [Double]
    public let sourceImageReferences: [DicomSourceImageReference]

    public init(
        graphicType: String,
        graphicData: [Double],
        sourceImageReferences: [DicomSourceImageReference] = []
    ) {
        self.graphicType = graphicType
        self.graphicData = graphicData
        self.sourceImageReferences = sourceImageReferences
    }
}

/// Numeric SR measurement extracted from a report tree.
public struct DicomSRMeasurement: Equatable, Sendable {
    public let name: DicomCodedConcept?
    public let value: Double
    public let units: DicomCodedConcept?
    public let trackingID: String?
    public let trackingUID: String?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let roi: DicomSRGraphicRegion?

    public init(
        name: DicomCodedConcept?,
        value: Double,
        units: DicomCodedConcept?,
        trackingID: String? = nil,
        trackingUID: String? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        roi: DicomSRGraphicRegion? = nil
    ) {
        self.name = name
        self.value = value
        self.units = units
        self.trackingID = trackingID?.dicomSRNonEmptyValue
        self.trackingUID = trackingUID?.dicomSRNonEmptyValue
        self.sourceImageReferences = sourceImageReferences
        self.roi = roi
    }
}

/// CAD finding container extracted from an SR tree.
public struct DicomSRCADFinding: Equatable, Sendable {
    public let title: DicomCodedConcept?
    public let trackingID: String?
    public let trackingUID: String?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let measurements: [DicomSRMeasurement]
    public let contentItem: DicomSRContentItem

    public init(
        title: DicomCodedConcept?,
        trackingID: String? = nil,
        trackingUID: String? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        measurements: [DicomSRMeasurement] = [],
        contentItem: DicomSRContentItem
    ) {
        self.title = title
        self.trackingID = trackingID?.dicomSRNonEmptyValue
        self.trackingUID = trackingUID?.dicomSRNonEmptyValue
        self.sourceImageReferences = sourceImageReferences
        self.measurements = measurements
        self.contentItem = contentItem
    }
}

/// Parsed DICOM Structured Report or Key Object Selection document.
public struct DicomSRDocument: Equatable, Sendable {
    public static let basicTextSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.11"
    public static let enhancedSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.22"
    public static let comprehensiveSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.33"
    public static let comprehensive3DSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.34"
    public static let extensibleSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.35"
    public static let keyObjectSelectionDocumentStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.59"
    public static let mammographyCADSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.50"
    public static let chestCADSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.65"
    public static let colonCADSRStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.88.69"

    public static let structuredReportSOPClassUIDs: Set<String> = [
        basicTextSRStorageSOPClassUID,
        enhancedSRStorageSOPClassUID,
        comprehensiveSRStorageSOPClassUID,
        comprehensive3DSRStorageSOPClassUID,
        extensibleSRStorageSOPClassUID,
        keyObjectSelectionDocumentStorageSOPClassUID,
        mammographyCADSRStorageSOPClassUID,
        chestCADSRStorageSOPClassUID,
        colonCADSRStorageSOPClassUID
    ]

    public let sopClassUID: String?
    public let sopInstanceUID: String?
    public let modality: String?
    public let contentLabel: String?
    public let contentDescription: String?
    public let completionFlag: String?
    public let verificationFlag: String?
    public let templateIdentifier: String?
    public let root: DicomSRContentItem
    public let evidenceReferences: [DicomKeyObjectReference]

    public init(
        sopClassUID: String? = enhancedSRStorageSOPClassUID,
        sopInstanceUID: String? = nil,
        modality: String? = "SR",
        contentLabel: String? = nil,
        contentDescription: String? = nil,
        completionFlag: String? = nil,
        verificationFlag: String? = nil,
        templateIdentifier: String? = nil,
        root: DicomSRContentItem,
        evidenceReferences: [DicomKeyObjectReference] = []
    ) {
        self.sopClassUID = sopClassUID?.dicomSRNonEmptyValue
        self.sopInstanceUID = sopInstanceUID?.dicomSRNonEmptyValue
        self.modality = modality?.dicomSRNonEmptyValue?.uppercased()
        self.contentLabel = contentLabel?.dicomSRNonEmptyValue
        self.contentDescription = contentDescription?.dicomSRNonEmptyValue
        self.completionFlag = completionFlag?.dicomSRNonEmptyValue?.uppercased()
        self.verificationFlag = verificationFlag?.dicomSRNonEmptyValue?.uppercased()
        self.templateIdentifier = templateIdentifier?.dicomSRNonEmptyValue
        self.root = root
        self.evidenceReferences = evidenceReferences.removingDuplicateSRElements()
    }

    public var flattenedContentItems: [DicomSRContentItem] {
        root.flattened
    }

    public var measurements: [DicomSRMeasurement] {
        DicomSRExtraction.measurements(in: root)
    }

    public var cadFindings: [DicomSRCADFinding] {
        DicomSRExtraction.cadFindings(in: root)
    }

    /// Validates this document against the declared DicomCore SR semantic support matrix.
    public var semanticValidation: DicomSRSemanticValidationResult {
        DicomSRSemanticValidator.validate(self)
    }

    public var keyObjectReferences: [DicomKeyObjectReference] {
        let contentReferences = root.allSourceImageReferences.map {
            DicomKeyObjectReference(
                referencedSOPClassUID: $0.referencedSOPClassUID,
                referencedSOPInstanceUID: $0.referencedSOPInstanceUID,
                referencedFrameNumbers: $0.referencedFrameNumbers
            )
        }
        var result = evidenceReferences
        for reference in contentReferences where !result.contains(where: { $0.referencesSameObject(as: reference) }) {
            result.append(reference)
        }
        return result
    }

    public func contentItems(matching predicate: (DicomSRContentItem) -> Bool) -> [DicomSRContentItem] {
        flattenedContentItems.filter(predicate)
    }
}

extension DCMDecoder {
    public var structuredReport: DicomSRDocument? {
        synchronized {
            DicomSRParser.makeDocument(from: self)
        }
    }

    public var keyObjectSelection: DicomSRDocument? {
        guard let document = structuredReport,
              document.sopClassUID == DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID ||
              document.modality == "KO" else {
            return nil
        }
        return document
    }
}

/// Serializes SR document models into controlled Part 10-ready datasets.
public enum DicomStructuredReportBuilder {
    /// Serializes a semantically supported SR document, throwing stable validation errors otherwise.
    public static func validatedDataSet(
        from document: DicomSRDocument,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil
    ) throws -> DicomDataSet {
        try DicomSRSemanticValidator.validateForSemanticUse(document)
        return dataSet(
            from: document,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID
        )
    }

    public static func dataSet(
        from document: DicomSRDocument,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil
    ) -> DicomDataSet {
        let instanceUID = sopInstanceUID?.dicomSRNonEmptyValue
            ?? document.sopInstanceUID
            ?? DicomDataSetWriter.makeUID()
        let sopClassUID = document.sopClassUID ?? DicomSRDocument.enhancedSRStorageSOPClassUID
        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, sopClassUID),
            string(.sopInstanceUID, vr: .UI, instanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, document.modality ?? "SR"),
            string(.valueType, vr: .CS, document.root.valueType)
        ]

        if let conceptName = document.root.conceptName {
            elements.append(sequence(.conceptNameCodeSequence, [codedConceptDataSet(conceptName)]))
        }
        if let continuity = document.root.continuityOfContent {
            elements.append(string(.continuityOfContent, vr: .CS, continuity))
        }
        if let contentLabel = document.contentLabel {
            elements.append(string(.contentLabel, vr: .LO, contentLabel))
        }
        if let contentDescription = document.contentDescription {
            elements.append(string(.contentDescription, vr: .ST, contentDescription))
        }
        if let completionFlag = document.completionFlag {
            elements.append(string(.completionFlag, vr: .CS, completionFlag))
        }
        if let verificationFlag = document.verificationFlag {
            elements.append(string(.verificationFlag, vr: .CS, verificationFlag))
        }
        if let templateIdentifier = document.templateIdentifier {
            elements.append(sequence(.contentTemplateSequence, [
                DicomDataSet(elements: [
                    string(.mappingResource, vr: .SH, "DCMR"),
                    string(.templateIdentifier, vr: .CS, templateIdentifier)
                ])
            ]))
        }
        if !document.root.children.isEmpty {
            elements.append(sequence(.contentSequence, document.root.children.map(contentItemDataSet)))
        }
        if !document.evidenceReferences.isEmpty {
            elements.append(sequence(
                .currentRequestedProcedureEvidenceSequence,
                evidenceStudyDataSets(from: document.evidenceReferences)
            ))
        }
        return DicomDataSet(elements: elements)
    }

    static func contentItemDataSet(_ item: DicomSRContentItem) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.valueType, vr: .CS, item.valueType)
        ]
        if let relationshipType = item.relationshipType {
            elements.append(string(.relationshipType, vr: .CS, relationshipType))
        }
        if let conceptName = item.conceptName {
            elements.append(sequence(.conceptNameCodeSequence, [codedConceptDataSet(conceptName)]))
        }
        if let continuity = item.continuityOfContent {
            elements.append(string(.continuityOfContent, vr: .CS, continuity))
        }
        if let textValue = item.textValue {
            elements.append(string(.textValue, vr: .UT, textValue))
        }
        if let codeValue = item.codeValue {
            elements.append(sequence(.conceptCodeSequence, [codedConceptDataSet(codeValue)]))
        }
        if let numericValue = item.numericValue {
            var measuredElements = [ds(.numericValue, [numericValue])]
            if let units = item.measurementUnits {
                measuredElements.append(sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(units)]))
            }
            elements.append(sequence(.measuredValueSequence, [DicomDataSet(elements: measuredElements)]))
        }
        if let dateTimeValue = item.dateTimeValue {
            elements.append(string(.dateTime, vr: .DT, dateTimeValue.rawValue))
        }
        if let dateValue = item.dateValue {
            elements.append(string(.date, vr: .DA, dateValue.rawValue))
        }
        if let timeValue = item.timeValue {
            elements.append(string(.time, vr: .TM, timeValue.rawValue))
        }
        if let personNameValue = item.personNameValue {
            elements.append(string(.personName, vr: .PN, personNameValue.rawValue))
        }
        if let uidValue = item.uidValue {
            elements.append(string(.uid, vr: .UI, uidValue))
        }
        if !item.referencedSOPs.isEmpty {
            elements.append(sequence(.referencedSOPSequence, item.referencedSOPs.map(referencedSOPDataSet)))
        }
        if let graphicType = item.graphicType {
            elements.append(string(.graphicType, vr: .CS, graphicType))
        }
        if !item.graphicData.isEmpty {
            elements.append(DicomDataElement(tag: DicomTag.graphicData.rawValue, vr: .FL, value: .floats(item.graphicData)))
        }
        if let trackingID = item.trackingID {
            elements.append(string(.trackingID, vr: .LO, trackingID))
        }
        if let trackingUID = item.trackingUID {
            elements.append(string(.trackingUID, vr: .UI, trackingUID))
        }
        if !item.children.isEmpty {
            elements.append(sequence(.contentSequence, item.children.map(contentItemDataSet)))
        }
        return DicomDataSet(elements: elements)
    }

    static func evidenceStudyDataSets(from references: [DicomKeyObjectReference]) -> [DicomDataSet] {
        let groupedByStudy = Dictionary(grouping: references) { $0.studyInstanceUID ?? "" }
        return groupedByStudy.keys.sorted().map { studyUID in
            let studyReferences = groupedByStudy[studyUID] ?? []
            let groupedBySeries = Dictionary(grouping: studyReferences) { $0.seriesInstanceUID ?? "" }
            let seriesDataSets = groupedBySeries.keys.sorted().map { seriesUID in
                let sopItems = (groupedBySeries[seriesUID] ?? []).map(referencedSOPDataSet)
                return DicomDataSet(elements: [
                    string(.seriesInstanceUID, vr: .UI, seriesUID),
                    sequence(.referencedSOPSequence, sopItems)
                ])
            }
            return DicomDataSet(elements: [
                string(.studyInstanceUID, vr: .UI, studyUID),
                sequence(.referencedSeriesSequence, seriesDataSets)
            ])
        }
    }

    static func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        return DicomDataSet(elements: elements)
    }

    private static func referencedSOPDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        referencedSOPDataSet(DicomKeyObjectReference(
            referencedSOPClassUID: reference.referencedSOPClassUID,
            referencedSOPInstanceUID: reference.referencedSOPInstanceUID,
            referencedFrameNumbers: reference.referencedFrameNumbers
        ))
    }

    private static func referencedSOPDataSet(_ reference: DicomKeyObjectReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(reference.referencedFrameNumbers.map(String.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func ds(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values.map { String($0) }))
    }
}

/// Builder for Key Object Selection documents.
public enum DicomKeyObjectSelectionBuilder {
    public static let keyObjectSelectionDocumentStorageSOPClassUID = DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID

    public static func dataSet(
        title: DicomCodedConcept,
        keyObjects: [DicomKeyObjectReference],
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        contentLabel: String = "KEY_IMAGES"
    ) -> DicomDataSet {
        let root = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: title,
            continuityOfContent: "SEPARATE",
            children: keyObjects.map {
                DicomSRContentItem(
                    relationshipType: "CONTAINS",
                    valueType: "IMAGE",
                    conceptName: title,
                    referencedSOPs: [$0.sourceImageReference]
                )
            }
        )
        let document = DicomSRDocument(
            sopClassUID: keyObjectSelectionDocumentStorageSOPClassUID,
            modality: "KO",
            contentLabel: contentLabel,
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            root: root,
            evidenceReferences: keyObjects
        )
        return DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID
        )
    }
}

private enum DicomSRParser {
    static func makeDocument(from decoder: DCMDecoder) -> DicomSRDocument? {
        guard matches(decoder) else { return nil }
        let rootChildren = parseItems(in: decoder, for: .contentSequence).compactMap {
            contentItem(from: $0.dataSet)
        }
        let templateIdentifier = parseItems(in: decoder, for: .contentTemplateSequence)
            .first?
            .dataSet
            .string(for: .templateIdentifier)
        let root = DicomSRContentItem(
            valueType: decoder.info(for: .valueType).dicomSRNonEmptyValue ?? "CONTAINER",
            conceptName: parseItems(in: decoder, for: .conceptNameCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            continuityOfContent: decoder.info(for: .continuityOfContent),
            textValue: decoder.info(for: .textValue),
            children: rootChildren
        )
        let evidenceReferences = references(in: decoder, for: .currentRequestedProcedureEvidenceSequence) +
            references(in: decoder, for: .pertinentOtherEvidenceSequence)

        return DicomSRDocument(
            sopClassUID: decoder.info(for: .sopClassUID),
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            modality: decoder.info(for: .modality),
            contentLabel: decoder.info(for: .contentLabel),
            contentDescription: decoder.info(for: .contentDescription),
            completionFlag: decoder.info(for: .completionFlag),
            verificationFlag: decoder.info(for: .verificationFlag),
            templateIdentifier: templateIdentifier,
            root: root,
            evidenceReferences: evidenceReferences
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomSRTrimmedValue
        let modality = decoder.info(for: .modality).dicomSRTrimmedValue
        return DicomSRDocument.structuredReportSOPClassUIDs.contains(sopClassUID) ||
            modality == "SR" ||
            modality == "KO" ||
            decoder.tagMetadataCache[DicomTag.contentSequence.rawValue] != nil
    }

    private static func contentItem(from dataSet: DicomDataSet) -> DicomSRContentItem? {
        let children = dataSet.sequenceItems(for: .contentSequence).compactMap {
            contentItem(from: $0.dataSet)
        }
        let measuredValue = dataSet.sequenceItems(for: .measuredValueSequence).first?.dataSet
        let referencedSOPs = dataSet.sequenceItems(for: .referencedSOPSequence).map(sourceImageReference)
        let valueType = dataSet.string(for: .valueType)?.dicomSRNonEmptyValue ?? (children.isEmpty ? nil : "CONTAINER")

        guard valueType != nil ||
              dataSet.string(for: .relationshipType)?.dicomSRNonEmptyValue != nil ||
              dataSet.string(for: .textValue)?.dicomSRNonEmptyValue != nil ||
              dataSet.sequenceItems(for: .conceptNameCodeSequence).first != nil ||
              measuredValue != nil ||
              !referencedSOPs.isEmpty ||
              !children.isEmpty else {
            return nil
        }

        return DicomSRContentItem(
            relationshipType: dataSet.string(for: .relationshipType),
            valueType: valueType ?? "CONTAINER",
            conceptName: dataSet.sequenceItems(for: .conceptNameCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            continuityOfContent: dataSet.string(for: .continuityOfContent),
            textValue: dataSet.string(for: .textValue),
            codeValue: dataSet.sequenceItems(for: .conceptCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            numericValue: measuredValue?.decimalString(for: .numericValue) ?? dataSet.decimalString(for: .numericValue),
            measurementUnits: measuredValue?.sequenceItems(for: .measurementUnitsCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            dateTimeValue: dataSet.dateTime(for: .dateTime),
            dateValue: dataSet.date(for: .date),
            timeValue: dataSet.time(for: .time),
            personNameValue: dataSet.personName(for: .personName),
            uidValue: dataSet.string(for: .uid),
            referencedSOPs: referencedSOPs,
            graphicType: dataSet.string(for: .graphicType),
            graphicData: dataSet.floats(for: .graphicData),
            trackingID: dataSet.string(for: .trackingID),
            trackingUID: dataSet.string(for: .trackingUID),
            children: children
        )
    }

    private static func references(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomKeyObjectReference] {
        parseItems(in: decoder, for: tag).flatMap { studyItem in
            let studyUID = studyItem.dataSet.string(for: .studyInstanceUID)
            return studyItem.dataSet.sequenceItems(for: .referencedSeriesSequence).flatMap { seriesItem in
                let seriesUID = seriesItem.dataSet.string(for: .seriesInstanceUID)
                return seriesItem.dataSet.sequenceItems(for: .referencedSOPSequence).map {
                    keyObjectReference(from: $0.dataSet, studyUID: studyUID, seriesUID: seriesUID)
                }
            }
        }.removingDuplicateSRElements()
    }

    private static func keyObjectReference(
        from dataSet: DicomDataSet,
        studyUID: String?,
        seriesUID: String?
    ) -> DicomKeyObjectReference {
        DicomKeyObjectReference(
            studyInstanceUID: studyUID,
            seriesInstanceUID: seriesUID,
            referencedSOPClassUID: dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: dataSet.ints(for: .referencedFrameNumber)
        )
    }

    private static func sourceImageReference(from item: DicomSequenceItem) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber)
        )
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

private enum DicomSRExtraction {
    static func measurements(in item: DicomSRContentItem) -> [DicomSRMeasurement] {
        var result: [DicomSRMeasurement] = []
        if item.valueType == "NUM", let value = item.numericValue {
            let roi = firstGraphicRegion(in: item)
            let sources = item.allSourceImageReferences
            result.append(DicomSRMeasurement(
                name: item.conceptName,
                value: value,
                units: item.measurementUnits,
                trackingID: item.trackingID,
                trackingUID: item.trackingUID,
                sourceImageReferences: sources,
                roi: roi
            ))
        }
        result.append(contentsOf: item.children.flatMap(measurements))
        return result
    }

    static func cadFindings(in item: DicomSRContentItem) -> [DicomSRCADFinding] {
        var result: [DicomSRCADFinding] = []
        if item.valueType == "CONTAINER", isCADFinding(item) {
            result.append(DicomSRCADFinding(
                title: item.conceptName,
                trackingID: item.trackingID,
                trackingUID: item.trackingUID,
                sourceImageReferences: item.allSourceImageReferences,
                measurements: measurements(in: item),
                contentItem: item
            ))
        }
        result.append(contentsOf: item.children.flatMap(cadFindings))
        return result
    }

    private static func firstGraphicRegion(in item: DicomSRContentItem) -> DicomSRGraphicRegion? {
        if item.valueType == "SCOORD", let graphicType = item.graphicType, !item.graphicData.isEmpty {
            return DicomSRGraphicRegion(
                graphicType: graphicType,
                graphicData: item.graphicData,
                sourceImageReferences: item.allSourceImageReferences
            )
        }
        return item.children.lazy.compactMap(firstGraphicRegion).first
    }

    private static func isCADFinding(_ item: DicomSRContentItem) -> Bool {
        let haystack = [
            item.conceptName?.codeMeaning,
            item.conceptName?.codeValue,
            item.trackingID
        ].compactMap { $0?.uppercased() }.joined(separator: " ")
        return haystack.contains("CAD") || haystack.contains("FINDING")
    }
}

private extension Array where Element: Equatable {
    func removingDuplicateSRElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension String {
    var dicomSRTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomSRNonEmptyValue: String? {
        let trimmed = dicomSRTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
