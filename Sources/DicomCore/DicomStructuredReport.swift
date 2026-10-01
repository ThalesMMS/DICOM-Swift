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
    public let referencedContentItemIdentifier: [Int]?
    public let frameOfReferenceUID: String?
    public let fiducialUID: String?
    public let temporalRangeType: String?
    public let referencedSamplePositions: [Int]
    public let referencedTimeOffsets: [Double]
    public let referencedDateTimes: [DicomDateTime]
    public let numericValueQualifier: DicomCodedConcept?
    public let floatingPointValue: Double?
    public let rationalNumeratorValue: Int?
    public let rationalDenominatorValue: Int?
    public let observationDateTime: DicomDateTime?
    public let observationUID: String?
    public let contentTemplate: DicomSRTemplateIdentification?

    public var isByReference: Bool { referencedContentItemIdentifier != nil }

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
        children: [DicomSRContentItem] = [],
        referencedContentItemIdentifier: [Int]? = nil,
        frameOfReferenceUID: String? = nil,
        fiducialUID: String? = nil,
        temporalRangeType: String? = nil,
        referencedSamplePositions: [Int] = [],
        referencedTimeOffsets: [Double] = [],
        referencedDateTimes: [DicomDateTime] = [],
        numericValueQualifier: DicomCodedConcept? = nil,
        floatingPointValue: Double? = nil,
        rationalNumeratorValue: Int? = nil,
        rationalDenominatorValue: Int? = nil,
        observationDateTime: DicomDateTime? = nil,
        observationUID: String? = nil,
        contentTemplate: DicomSRTemplateIdentification? = nil
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
        self.referencedContentItemIdentifier = referencedContentItemIdentifier
        self.frameOfReferenceUID = frameOfReferenceUID
        self.fiducialUID = fiducialUID
        self.temporalRangeType = temporalRangeType
        self.referencedSamplePositions = referencedSamplePositions
        self.referencedTimeOffsets = referencedTimeOffsets
        self.referencedDateTimes = referencedDateTimes
        self.numericValueQualifier = numericValueQualifier
        self.floatingPointValue = floatingPointValue
        self.rationalNumeratorValue = rationalNumeratorValue
        self.rationalDenominatorValue = rationalDenominatorValue
        self.observationDateTime = observationDateTime
        self.observationUID = observationUID
        self.contentTemplate = contentTemplate
    }

    public var flattened: [DicomSRContentItem] {
        var result: [DicomSRContentItem] = []
        var pending = [self]
        while let item = pending.popLast() {
            result.append(item)
            pending.append(contentsOf: item.children.reversed())
        }
        return result
    }

    public var allSourceImageReferences: [DicomSourceImageReference] {
        var result: [DicomSourceImageReference] = []
        var seen = Set<DicomSourceImageReferenceIdentity>()
        for item in flattened {
            for reference in item.referencedSOPs
            where seen.insert(DicomSourceImageReferenceIdentity(reference)).inserted {
                result.append(reference)
            }
        }
        return result
    }

    public static func == (lhs: DicomSRContentItem, rhs: DicomSRContentItem) -> Bool {
        guard locallyEquals(lhs, rhs) else { return false }
        var pending = [EqualityChildrenFrame(lhs: lhs.children, rhs: rhs.children)]
        while !pending.isEmpty {
            let frameIndex = pending.index(before: pending.endIndex)
            let childIndex = pending[frameIndex].nextChildIndex
            guard childIndex < pending[frameIndex].lhs.count else {
                pending.removeLast()
                continue
            }
            let left = pending[frameIndex].lhs[childIndex]
            let right = pending[frameIndex].rhs[childIndex]
            pending[frameIndex].nextChildIndex += 1
            guard locallyEquals(left, right) else { return false }
            if !left.children.isEmpty {
                pending.append(EqualityChildrenFrame(lhs: left.children, rhs: right.children))
            }
        }
        return true
    }

    private static func locallyEquals(_ lhs: DicomSRContentItem, _ rhs: DicomSRContentItem) -> Bool {
        lhs.relationshipType == rhs.relationshipType &&
            lhs.valueType == rhs.valueType &&
            lhs.conceptName == rhs.conceptName &&
            lhs.continuityOfContent == rhs.continuityOfContent &&
            lhs.textValue == rhs.textValue &&
            lhs.codeValue == rhs.codeValue &&
            lhs.numericValue == rhs.numericValue &&
            lhs.measurementUnits == rhs.measurementUnits &&
            lhs.dateTimeValue == rhs.dateTimeValue &&
            lhs.dateValue == rhs.dateValue &&
            lhs.timeValue == rhs.timeValue &&
            lhs.personNameValue == rhs.personNameValue &&
            lhs.uidValue == rhs.uidValue &&
            lhs.referencedSOPs == rhs.referencedSOPs &&
            lhs.graphicType == rhs.graphicType &&
            lhs.graphicData == rhs.graphicData &&
            lhs.trackingID == rhs.trackingID &&
            lhs.trackingUID == rhs.trackingUID &&
            lhs.referencedContentItemIdentifier == rhs.referencedContentItemIdentifier &&
            lhs.frameOfReferenceUID == rhs.frameOfReferenceUID &&
            lhs.fiducialUID == rhs.fiducialUID &&
            lhs.temporalRangeType == rhs.temporalRangeType &&
            lhs.referencedSamplePositions == rhs.referencedSamplePositions &&
            lhs.referencedTimeOffsets == rhs.referencedTimeOffsets &&
            lhs.referencedDateTimes == rhs.referencedDateTimes &&
            lhs.numericValueQualifier == rhs.numericValueQualifier &&
            lhs.floatingPointValue == rhs.floatingPointValue &&
            lhs.rationalNumeratorValue == rhs.rationalNumeratorValue &&
            lhs.rationalDenominatorValue == rhs.rationalDenominatorValue &&
            lhs.observationDateTime == rhs.observationDateTime &&
            lhs.observationUID == rhs.observationUID &&
            lhs.contentTemplate == rhs.contentTemplate &&
            lhs.children.count == rhs.children.count
    }

    private struct EqualityChildrenFrame {
        let lhs: [DicomSRContentItem]
        let rhs: [DicomSRContentItem]
        var nextChildIndex = 0
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
    /// Content Label and Description as read from a file. The SR and Key Object Selection IODs have no Content
    /// Identification module (PS3.3 A.35), so `DicomStructuredReportBuilder` never writes them.
    public let contentLabel: String?
    public let contentDescription: String?
    public let completionFlag: String?
    public let verificationFlag: String?
    public let templateIdentifier: String?
    public let root: DicomSRContentItem
    public let evidenceReferences: [DicomKeyObjectReference]
    public let currentRequestedProcedureEvidence: [DicomKeyObjectReference]
    public let pertinentOtherEvidence: [DicomKeyObjectReference]
    /// Predecessor Documents Sequence (0040,A360): the SR instances this revision replaces (issue #2823).
    public let predecessorDocuments: [DicomKeyObjectReference]
    /// Verifying Observer Sequence (0040,A073), written only with a Verification Flag of VERIFIED.
    public let verifyingObservers: [DicomSRVerifyingObserver]
    public let parseDiagnostics: [DicomSRParseDiagnostic]


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
        evidenceReferences: [DicomKeyObjectReference] = [],
        currentRequestedProcedureEvidence: [DicomKeyObjectReference] = [],
        pertinentOtherEvidence: [DicomKeyObjectReference] = [],
        predecessorDocuments: [DicomKeyObjectReference] = [],
        verifyingObservers: [DicomSRVerifyingObserver] = [],
        parseDiagnostics: [DicomSRParseDiagnostic] = []
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
        self.evidenceReferences = (evidenceReferences + currentRequestedProcedureEvidence + pertinentOtherEvidence)
            .removingDuplicateSRElements()
        self.currentRequestedProcedureEvidence = currentRequestedProcedureEvidence
        self.pertinentOtherEvidence = pertinentOtherEvidence
        self.predecessorDocuments = predecessorDocuments
        self.verifyingObservers = verifyingObservers
        self.parseDiagnostics = parseDiagnostics
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
        let contentByObject = Dictionary(grouping: contentReferences) {
            DicomSourceImageReferenceIdentity($0.sourceImageReference, includesFrames: false)
        }
        var result: [DicomKeyObjectReference] = []
        var seenReferences: Set<DicomKeyObjectReference> = []
        for evidence in evidenceReferences {
            let identity = DicomSourceImageReferenceIdentity(evidence.sourceImageReference, includesFrames: false)
            let selected = evidence.referencedFrameNumbers.isEmpty ? contentByObject[identity] ?? [] : []
            let contextual = selected.isEmpty ? [evidence] : selected.map {
                DicomKeyObjectReference(studyInstanceUID: evidence.studyInstanceUID, seriesInstanceUID: evidence.seriesInstanceUID,
                    referencedSOPClassUID: $0.referencedSOPClassUID, referencedSOPInstanceUID: $0.referencedSOPInstanceUID,
                    referencedFrameNumbers: $0.referencedFrameNumbers)
            }
            for reference in contextual where seenReferences.insert(reference).inserted { result.append(reference) }
        }
        var seenObjects = Set(result.map { DicomSourceImageReferenceIdentity($0.sourceImageReference) })
        for reference in contentReferences {
            if seenObjects.insert(DicomSourceImageReferenceIdentity(reference.sourceImageReference)).inserted {
                result.append(reference)
            }
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
        let represented = Set(document.root.allSourceImageReferences.map {
            DicomSourceImageReferenceIdentity($0, includesContentSelectors: false)
        })
        for (index, reference) in document.evidenceReferences.enumerated()
            where !reference.referencedFrameNumbers.isEmpty &&
            !represented.contains(DicomSourceImageReferenceIdentity(reference.sourceImageReference)) {
            throw DicomStructuredReportBuildError.unrepresentedEvidenceFrames(index: index)
        }
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
            string(.specificCharacterSet, vr: .CS, "ISO_IR 192"),
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
        let isKeyObject = sopClassUID == DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
        // Type 2 attributes of the Patient, General Study, General Equipment and SR/KO Document Series
        // modules (PS3.3 A.35): present and empty until the caller supplies their values.
        elements += [
            string(.patientName, vr: .PN, ""), string(.patientID, vr: .LO, ""),
            DicomDataElement(tag: 0x00100030, vr: .DA, value: .strings([""])), string(.patientSex, vr: .CS, ""),
            string(.studyDate, vr: .DA, ""), string(.studyTime, vr: .TM, ""),
            DicomDataElement(tag: 0x00080090, vr: .PN, value: .strings([""])),
            DicomDataElement(tag: 0x00200010, vr: .SH, value: .strings([""])),
            DicomDataElement(tag: 0x00080050, vr: .SH, value: .strings([""])),
            DicomDataElement(tag: 0x00080070, vr: .LO, value: .strings([""])),
            DicomDataElement(tag: 0x00081111, vr: .SQ, value: .sequence([]))
        ]
        if !isKeyObject {
            elements.append(DicomDataElement(tag: 0x0040A372, vr: .SQ, value: .sequence([])))
        }
        if !isKeyObject, let completionFlag = document.completionFlag {
            elements.append(string(.completionFlag, vr: .CS, completionFlag))
        }
        if !isKeyObject, let verificationFlag = document.verificationFlag {
            elements.append(string(.verificationFlag, vr: .CS, verificationFlag))
        }
        // PS3.3 C.17.2 (issue #2823): Verifying Observer Sequence is Type 1C, present only when VERIFIED.
        if !isKeyObject, document.verificationFlag == "VERIFIED", !document.verifyingObservers.isEmpty {
            elements.append(DicomDataElement(tag: 0x0040A073, vr: .SQ, value: .sequence(document.verifyingObservers.map {
                DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    DicomDataElement(tag: 0x0040A030, vr: .DT, value: .strings([$0.dateTime])),
                    DicomDataElement(tag: 0x0040A075, vr: .PN, value: .strings([$0.name])),
                    DicomDataElement(tag: 0x0040A027, vr: .LO, value: .strings([$0.organization])),
                    DicomDataElement(tag: 0x0040A088, vr: .SQ, value: .sequence([]))
                ]))
            })))
        }
        // Predecessor Documents Sequence is Type 1C, present when this instance is a revision of others.
        if !isKeyObject, !document.predecessorDocuments.isEmpty {
            elements.append(DicomDataElement(tag: 0x0040A360, vr: .SQ, value: .sequence(
                evidenceStudyDataSets(from: document.predecessorDocuments, representedImages: [])
                    .map(DicomSequenceItem.init(dataSet:))
            )))
        }
        // A.35.4.3.1.3 mandates the KOS root template; a document without an explicit identifier uses it.
        let templateIdentifier = document.templateIdentifier ?? DicomSRProfileConstraints(sopClassUID: sopClassUID)?.rootTemplateIdentifier
        if let templateIdentifier, document.root.contentTemplate == nil {
            elements.append(sequence(.contentTemplateSequence, [
                DicomDataSet(elements: [
                    string(.mappingResource, vr: .CS, "DCMR"),
                    string(.templateIdentifier, vr: .CS, templateIdentifier)
                ])
            ]))
        }
        elements.append(contentsOf: additionalContentElements(document.root))
        if !document.root.children.isEmpty {
            elements.append(sequence(.contentSequence, contentItemDataSets(document.root.children)))
        }
        let groupedEvidence = Set(document.currentRequestedProcedureEvidence + document.pertinentOtherEvidence)
        let currentEvidence = document.currentRequestedProcedureEvidence + document.evidenceReferences.filter {
            !groupedEvidence.contains($0)
        }
        let representedImages = Set(document.root.allSourceImageReferences.map {
            DicomSourceImageReferenceIdentity($0, includesContentSelectors: false)
        })
        for (tag, references) in [
            (DicomTag.currentRequestedProcedureEvidenceSequence, currentEvidence),
            (DicomTag.pertinentOtherEvidenceSequence, document.pertinentOtherEvidence)
        ] where !references.isEmpty {
            elements.append(sequence(tag, evidenceStudyDataSets(from: references, representedImages: representedImages)))
        }
        return DicomDataSet(elements: elements)
    }

    static func contentItemDataSet(_ item: DicomSRContentItem) -> DicomDataSet {
        var pending = [ContentItemBuildFrame(item: item)]
        while !pending.isEmpty {
            let frameIndex = pending.index(before: pending.endIndex)
            let childIndex = pending[frameIndex].nextChildIndex
            if !pending[frameIndex].item.isByReference, childIndex < pending[frameIndex].item.children.count {
                let child = pending[frameIndex].item.children[childIndex]
                pending[frameIndex].nextChildIndex += 1
                pending.append(ContentItemBuildFrame(item: child))
                continue
            }

            let frame = pending.removeLast()
            let dataSet = contentItemDataSet(frame.item, childDataSets: frame.childDataSets)
            guard !pending.isEmpty else { return dataSet }
            pending[pending.index(before: pending.endIndex)].childDataSets.append(dataSet)
        }
        return DicomDataSet()
    }

    private static func contentItemDataSets(_ items: [DicomSRContentItem]) -> [DicomDataSet] {
        items.map(contentItemDataSet)
    }

    fileprivate static func contentItemDataSet(
        _ item: DicomSRContentItem,
        childDataSets: [DicomDataSet]
    ) -> DicomDataSet {
        if let identifier = item.referencedContentItemIdentifier {
            var elements = [DicomDataElement(tag: 0x0040DB73, vr: .UL, value: .signedIntegers(identifier))]
            if let relationship = item.relationshipType {
                elements.insert(string(.relationshipType, vr: .CS, relationship), at: 0)
            }
            return DicomDataSet(elements: elements)
        }
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
        if item.numericValue != nil || item.floatingPointValue != nil || item.rationalNumeratorValue != nil ||
            item.rationalDenominatorValue != nil || item.numericValueQualifier != nil {
            var measuredElements: [DicomDataElement] = []
            if let value = item.numericValue { measuredElements.append(ds(.numericValue, [value])) }
            if let value = item.floatingPointValue {
                measuredElements.append(.init(tag: 0x0040A161, vr: .FD, value: .floats([value])))
            }
            if let value = item.rationalNumeratorValue {
                measuredElements.append(.init(tag: 0x0040A162, vr: .SL, value: .signedIntegers([value])))
            }
            if let value = item.rationalDenominatorValue {
                measuredElements.append(.init(tag: 0x0040A163, vr: .UL, value: .signedIntegers([value])))
            }
            if let units = item.measurementUnits {
                measuredElements.append(sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(units)]))
            }
            elements.append(sequence(.measuredValueSequence,
                measuredElements.isEmpty ? [] : [DicomDataSet(elements: measuredElements)]))
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
            elements.append(string(.trackingID, vr: .UT, trackingID))
        }
        if let trackingUID = item.trackingUID {
            elements.append(string(.trackingUID, vr: .UI, trackingUID))
        }
        elements.append(contentsOf: additionalContentElements(item))
        if !childDataSets.isEmpty {
            elements.append(sequence(.contentSequence, childDataSets))
        }
        return DicomDataSet(elements: elements)
    }

    private static func additionalContentElements(_ item: DicomSRContentItem) -> [DicomDataElement] {
        var elements: [DicomDataElement] = []
        if let value = item.frameOfReferenceUID {
            elements.append(.init(tag: 0x30060024, vr: .UI, value: .strings([value])))
        }
        if let value = item.fiducialUID {
            elements.append(.init(tag: 0x0070031A, vr: .UI, value: .strings([value])))
        }
        if let value = item.temporalRangeType {
            elements.append(.init(tag: 0x0040A130, vr: .CS, value: .strings([value])))
        }
        if let value = item.observationUID {
            elements.append(.init(tag: 0x0040A171, vr: .UI, value: .strings([value])))
        }
        if let value = item.observationDateTime {
            elements.append(.init(tag: 0x0040A032, vr: .DT, value: .strings([value.rawValue])))
        }
        if !item.referencedSamplePositions.isEmpty {
            elements.append(.init(tag: 0x0040A132, vr: .UL, value: .signedIntegers(item.referencedSamplePositions)))
        }
        if !item.referencedTimeOffsets.isEmpty {
            elements.append(.init(tag: 0x0040A138, vr: .DS, value: .strings(item.referencedTimeOffsets.map { String($0) })))
        }
        if !item.referencedDateTimes.isEmpty {
            elements.append(.init(tag: 0x0040A13A, vr: .DT, value: .strings(item.referencedDateTimes.map(\.rawValue))))
        }
        if let qualifier = item.numericValueQualifier {
            elements.append(.init(tag: 0x0040A301, vr: .SQ,
                value: .sequence([.init(dataSet: codedConceptDataSet(qualifier))])))
        }
        if let template = item.contentTemplate {
            elements.append(sequence(.contentTemplateSequence, [.init(elements: [
                string(.mappingResource, vr: .CS, template.mappingResource),
                string(.templateIdentifier, vr: .CS, template.templateIdentifier)
            ])]))
        }
        return elements
    }

    private struct ContentItemBuildFrame {
        let item: DicomSRContentItem
        var nextChildIndex = 0
        var childDataSets: [DicomDataSet] = []
    }

    static func evidenceStudyDataSets(from references: [DicomKeyObjectReference],
                                     representedImages: Set<DicomSourceImageReferenceIdentity>) -> [DicomDataSet] {
        let groupedByStudy = Dictionary(grouping: references) { $0.studyInstanceUID ?? "" }
        return groupedByStudy.keys.sorted().map { studyUID in
            let studyReferences = groupedByStudy[studyUID] ?? []
            let groupedBySeries = Dictionary(grouping: studyReferences) { $0.seriesInstanceUID ?? "" }
            let seriesDataSets = groupedBySeries.keys.sorted().map { seriesUID in
                let sopItems = (groupedBySeries[seriesUID] ?? []).map {
                    // Frame selection belongs in IMAGE content. Compatibility writing retains
                    // unrepresented legacy scope; validated writing rejects it before serialization.
                    referencedSOPDataSet($0, includeFrameNumbers:
                        !representedImages.contains(DicomSourceImageReferenceIdentity($0.sourceImageReference)))
                }
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
        if let version = concept.codingSchemeVersion {
            elements.append(.init(tag: 0x00080103, vr: .SH, value: .strings([version])))
        }
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        return DicomDataSet(elements: elements)
    }

    private static func referencedSOPDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var dataSet = referencedSOPDataSet(DicomKeyObjectReference(
            referencedSOPClassUID: reference.referencedSOPClassUID,
            referencedSOPInstanceUID: reference.referencedSOPInstanceUID,
            referencedFrameNumbers: reference.referencedFrameNumbers
        ))
        if !reference.referencedSegmentNumbers.isEmpty {
            dataSet.set(.init(tag: 0x0062000B, vr: .US, value: .signedIntegers(reference.referencedSegmentNumbers)))
        }
        if !reference.referencedWaveformChannels.isEmpty {
            dataSet.set(.init(tag: 0x0040A0B0, vr: .US, value: .signedIntegers(reference.referencedWaveformChannels)))
        }
        return dataSet
    }

    private static func referencedSOPDataSet(_ reference: DicomKeyObjectReference,
                                           includeFrameNumbers: Bool = true) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if includeFrameNumbers, !reference.referencedFrameNumbers.isEmpty {
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

    /// The writer fits each number into the 16 bytes a DS allows: `String(Double)` gives up to 17 significant
    /// digits, so a mean such as 43.333333333333336 could not be written.
    private static func ds(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .floats(values))
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
        titleModifiers: [DicomCodedConcept] = [],
        procedureCodes: [DicomCodedConcept] = [],
        language: DicomSRLanguage? = nil,
        observers: [DicomSRObserver] = [],
        keyObjectDescription: String? = nil,
        compositeObjects: [DicomKeyObjectReference] = [],
        waveforms: [DicomKeyObjectReference] = []
    ) -> DicomDataSet {
        var additionalItems = titleModifiers.map {
            DicomSRMeasurementReportBuilder.item("CODE", "113011", "Document Title Modifier", rel: "HAS CONCEPT MOD", value: $0)
        }
        additionalItems += procedureCodes.map {
            DicomSRMeasurementReportBuilder.item("CODE", "121023", "Procedure Code", rel: "HAS CONCEPT MOD", value: $0)
        }
        if let language { additionalItems.append(DicomSRMeasurementReportBuilder.languageItem(language)) }
        additionalItems += DicomSRMeasurementReportBuilder.observerItems(observers)
        if let keyObjectDescription {
            additionalItems.append(DicomSRMeasurementReportBuilder.item("TEXT", "113012", "Key Object Description", text: keyObjectDescription))
        }
        additionalItems += compositeObjects.map {
            DicomSRContentItem(relationshipType: "CONTAINS", valueType: "COMPOSITE", referencedSOPs: [$0.sourceImageReference])
        }
        additionalItems += waveforms.map {
            DicomSRContentItem(relationshipType: "CONTAINS", valueType: "WAVEFORM", referencedSOPs: [$0.sourceImageReference])
        }
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
            } + additionalItems
        )
        let document = DicomSRDocument(
            sopClassUID: keyObjectSelectionDocumentStorageSOPClassUID,
            modality: "KO",
            root: root,
            evidenceReferences: keyObjects + compositeObjects + waveforms
        )
        return DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID
        )
    }
}

enum DicomSRParser {
    static func makeDocument(from decoder: DCMDecoder) -> DicomSRDocument? {
        guard matches(decoder) else { return nil }
        var diagnostics: [DicomSRParseDiagnostic] = []
        let rootDataSet = decoder.dataSet
        let root = contentItem(from: rootDataSet, diagnostics: &diagnostics, isDocumentRoot: true)
            ?? DicomSRContentItem(valueType: "CONTAINER")
        let templateIdentifier = root.contentTemplate?.templateIdentifier
        let currentEvidence = references(in: decoder, for: .currentRequestedProcedureEvidenceSequence)
        let otherEvidence = references(in: decoder, for: .pertinentOtherEvidenceSequence)
        let evidenceReferences = currentEvidence + otherEvidence

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
            evidenceReferences: evidenceReferences,
            currentRequestedProcedureEvidence: currentEvidence,
            pertinentOtherEvidence: otherEvidence,
            predecessorDocuments: hierarchicalReferences(rootDataSet.sequenceItems(for: 0x0040A360)),
            verifyingObservers: rootDataSet.sequenceItems(for: 0x0040A073).compactMap { item in
                guard let name = item.dataSet.string(for: 0x0040A075) else { return nil }
                return DicomSRVerifyingObserver(name: name,
                                                organization: item.dataSet.string(for: 0x0040A027) ?? "",
                                                dateTime: item.dataSet.string(for: 0x0040A030) ?? "")
            },
            parseDiagnostics: diagnostics
        )
    }

    /// References of a Hierarchical SOP Instance Reference Macro sequence (study, series, instance).
    private static func hierarchicalReferences(_ studyItems: [DicomSequenceItem]) -> [DicomKeyObjectReference] {
        studyItems.flatMap { studyItem in
            let studyUID = studyItem.dataSet.string(for: .studyInstanceUID)
            return studyItem.dataSet.sequenceItems(for: .referencedSeriesSequence).flatMap { seriesItem in
                let seriesUID = seriesItem.dataSet.string(for: .seriesInstanceUID)
                return seriesItem.dataSet.sequenceItems(for: .referencedSOPSequence).map {
                    keyObjectReference(from: $0.dataSet, studyUID: studyUID, seriesUID: seriesUID)
                }
            }
        }
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomSRTrimmedValue
        let modality = decoder.info(for: .modality).dicomSRTrimmedValue
        return DicomSRDocument.structuredReportSOPClassUIDs.contains(sopClassUID) ||
            modality == "SR" ||
            modality == "KO" ||
            decoder.tagMetadataCache[DicomTag.contentSequence.rawValue] != nil
    }

    static func contentItem(from dataSet: DicomDataSet) -> DicomSRContentItem? {
        var diagnostics: [DicomSRParseDiagnostic] = []
        return contentItem(from: dataSet, diagnostics: &diagnostics)
    }

    static func contentItem(
        from dataSet: DicomDataSet,
        diagnostics: inout [DicomSRParseDiagnostic],
        isDocumentRoot: Bool = false
    ) -> DicomSRContentItem? {
        var path: [Int] = []
        var pending = [ContentItemParseFrame(dataSet: dataSet)]
        while !pending.isEmpty {
            let frameIndex = pending.index(before: pending.endIndex)
            let childIndex = pending[frameIndex].nextChildIndex
            if childIndex < pending[frameIndex].childDataSets.count {
                let child = pending[frameIndex].childDataSets[childIndex]
                pending[frameIndex].nextChildIndex += 1
                path.append(childIndex)
                pending.append(ContentItemParseFrame(dataSet: child,
                    isSkipped: pending[frameIndex].isSkipped || pending[frameIndex].dataSet.contains(0x0040DB73)))
                continue
            }

            let frame = pending.removeLast()
            let item = frame.isSkipped ? nil : contentItem(from: frame.dataSet, children: frame.children)
            if let item {
                recordUnrepresentedAttributes(frame.dataSet, item: item, path: path,
                    isDocumentRoot: isDocumentRoot && pending.isEmpty, diagnostics: &diagnostics)
            } else {
                diagnostics.append(.init(path: path, code: "itemSkipped", message: "Content item could not be parsed."))
            }
            if !path.isEmpty { path.removeLast() }
            guard !pending.isEmpty else { return item }
            if let item {
                pending[pending.index(before: pending.endIndex)].children.append(item)
            }
        }
        return nil
    }

    private static func recordUnrepresentedAttributes(
        _ dataSet: DicomDataSet,
        item: DicomSRContentItem,
        path: [Int],
        isDocumentRoot: Bool,
        diagnostics: inout [DicomSRParseDiagnostic]
    ) {
        let represented = DicomStructuredReportBuilder.contentItemDataSet(item, childDataSets: [])
        let rootTags: Set<Int> = [0x0040A040, 0x0040A043, 0x0040A050, 0x0040A160, 0x0040A504,
            0x0040A032, 0x0040A171, 0x0040DB73]
        var pending = [(dataSet, represented, isDocumentRoot)]
        while let (original, encoded, isRoot) = pending.popLast() {
            for element in original.elements {
                if element.tag == 0x0040A730 && !item.isByReference { continue }
                if isRoot && !rootTags.contains(element.tag) { continue }
                let replacement = encoded.element(for: element.tag)
                if replacement == nil || replacement!.vm.count < element.vm.count {
                    diagnostics.append(.init(path: path, code: "attributeNotRepresentable",
                        message: "Attribute " + String(format: "%08X", element.tag) + " could not be fully represented."))
                }
                if element.vr == .SQ {
                    let before = original.sequenceItems(for: element.tag)
                    let after = encoded.sequenceItems(for: element.tag)
                    if before.count > after.count && replacement != nil {
                        diagnostics.append(.init(path: path, code: "attributeNotRepresentable",
                            message: "Sequence items could not be fully represented."))
                    }
                    for index in 0..<min(before.count, after.count) {
                        pending.append((before[index].dataSet, after[index].dataSet, false))
                    }
                }
            }
        }
    }

    private static func contentItem(
        from dataSet: DicomDataSet,
        children: [DicomSRContentItem]
    ) -> DicomSRContentItem? {
        if dataSet.element(for: 0x0040DB73) != nil {
            return .init(relationshipType: dataSet.string(for: .relationshipType), valueType: "CONTAINER",
                referencedContentItemIdentifier: dataSet.ints(for: 0x0040DB73))
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
            children: children,
            frameOfReferenceUID: dataSet.string(for: 0x30060024),
            fiducialUID: dataSet.string(for: 0x0070031A),
            temporalRangeType: dataSet.string(for: 0x0040A130),
            referencedSamplePositions: dataSet.ints(for: 0x0040A132),
            referencedTimeOffsets: dataSet.floats(for: 0x0040A138),
            referencedDateTimes: dataSet.strings(for: 0x0040A13A).compactMap { DicomDateTime($0) },
            numericValueQualifier: dataSet.sequenceItems(for: 0x0040A301).first.flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            floatingPointValue: measuredValue?.float(for: 0x0040A161),
            rationalNumeratorValue: measuredValue?.int(for: 0x0040A162),
            rationalDenominatorValue: measuredValue?.int(for: 0x0040A163),
            observationDateTime: dataSet.dateTime(for: 0x0040A032),
            observationUID: dataSet.string(for: 0x0040A171),
            contentTemplate: template(in: dataSet)
        )
    }

    private static func template(in dataSet: DicomDataSet) -> DicomSRTemplateIdentification? {
        guard let item = dataSet.sequenceItems(for: .contentTemplateSequence).first?.dataSet,
              let resource = item.string(for: .mappingResource),
              let identifier = item.string(for: .templateIdentifier) else { return nil }
        return .init(mappingResource: resource, templateIdentifier: identifier)
    }

    private struct ContentItemParseFrame {
        let dataSet: DicomDataSet
        let childDataSets: [DicomDataSet]
        let isSkipped: Bool
        var nextChildIndex = 0
        var children: [DicomSRContentItem] = []

        init(dataSet: DicomDataSet, isSkipped: Bool = false) {
            self.dataSet = dataSet
            self.isSkipped = isSkipped
            self.childDataSets = dataSet.sequenceItems(for: .contentSequence).map(\.dataSet)
        }
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
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber),
            referencedSegmentNumbers: item.dataSet.ints(for: 0x0062000B),
            referencedWaveformChannels: item.dataSet.ints(for: 0x0040A0B0)
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

private extension Array where Element == DicomSourceImageReference {
    func removingDuplicateSRElements() -> [Element] {
        var seen = Set<DicomSourceImageReferenceIdentity>()
        var result: [Element] = []
        result.reserveCapacity(count)
        for element in self where seen.insert(DicomSourceImageReferenceIdentity(element)).inserted {
            result.append(element)
        }
        return result
    }
}

private extension Array where Element == DicomKeyObjectReference {
    func removingDuplicateSRElements() -> [Element] {
        var seen = Set<Element>()
        var result: [Element] = []
        result.reserveCapacity(count)
        for element in self where seen.insert(element).inserted {
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
