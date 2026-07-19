import Foundation

public enum DicomEncapsulatedDocumentError: Error, Equatable, LocalizedError, Sendable {
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "Encapsulated Document payload cannot be empty."
        }
    }
}

public enum DicomEncapsulatedDocumentKind: Equatable, Hashable, Sendable {
    case pdf
    case cda
    case stl

    public var storageSOPClassUID: String {
        switch self {
        case .pdf:
            return DicomEncapsulatedDocument.encapsulatedPDFStorageSOPClassUID
        case .cda:
            return DicomEncapsulatedDocument.encapsulatedCDAStorageSOPClassUID
        case .stl:
            return DicomEncapsulatedDocument.encapsulatedSTLStorageSOPClassUID
        }
    }

    public var defaultMIMEType: String {
        switch self {
        case .pdf:
            return "application/pdf"
        case .cda:
            return "text/xml"
        case .stl:
            return "model/stl"
        }
    }

    public var preferredFileExtension: String {
        switch self {
        case .pdf:
            return "pdf"
        case .cda:
            return "xml"
        case .stl:
            return "stl"
        }
    }

    public init?(storageSOPClassUID: String) {
        let trimmed = storageSOPClassUID.dicomEncDocTrimmedValue
        switch trimmed {
        case DicomEncapsulatedDocument.encapsulatedPDFStorageSOPClassUID:
            self = .pdf
        case DicomEncapsulatedDocument.encapsulatedCDAStorageSOPClassUID:
            self = .cda
        case DicomEncapsulatedDocument.encapsulatedSTLStorageSOPClassUID:
            self = .stl
        default:
            return nil
        }
    }
}

public struct DicomEncapsulatedDocumentSourceInstance: Equatable, Hashable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?

    public init(referencedSOPClassUID: String?, referencedSOPInstanceUID: String?) {
        self.referencedSOPClassUID = referencedSOPClassUID?.dicomEncDocNonEmptyValue
        self.referencedSOPInstanceUID = referencedSOPInstanceUID?.dicomEncDocNonEmptyValue
    }
}

public struct DicomEncapsulatedDocumentBuildOptions: Equatable, Sendable {
    public var kind: DicomEncapsulatedDocumentKind
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var studyID: String?
    public var studyDate: String?
    public var studyTime: String?
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var seriesDate: String?
    public var seriesTime: String?
    public var contentDate: String?
    public var contentTime: String?
    public var documentTitle: String?
    public var conceptName: DicomCodedConcept?
    public var mimeType: String?
    public var sourceInstances: [DicomEncapsulatedDocumentSourceInstance]

    public init(
        kind: DicomEncapsulatedDocumentKind = .pdf,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        studyID: String? = nil,
        studyDate: String? = nil,
        studyTime: String? = nil,
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        seriesDate: String? = nil,
        seriesTime: String? = nil,
        contentDate: String? = nil,
        contentTime: String? = nil,
        documentTitle: String? = nil,
        conceptName: DicomCodedConcept? = nil,
        mimeType: String? = nil,
        sourceInstances: [DicomEncapsulatedDocumentSourceInstance] = []
    ) {
        self.kind = kind
        self.sopInstanceUID = sopInstanceUID?.dicomEncDocNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomEncDocNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomEncDocNonEmptyValue
        self.patientName = patientName?.dicomEncDocNonEmptyValue
        self.patientID = patientID?.dicomEncDocNonEmptyValue
        self.studyID = studyID?.dicomEncDocNonEmptyValue
        self.studyDate = studyDate?.dicomEncDocNonEmptyValue
        self.studyTime = studyTime?.dicomEncDocNonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.seriesDate = seriesDate?.dicomEncDocNonEmptyValue
        self.seriesTime = seriesTime?.dicomEncDocNonEmptyValue
        self.contentDate = contentDate?.dicomEncDocNonEmptyValue
        self.contentTime = contentTime?.dicomEncDocNonEmptyValue
        self.documentTitle = documentTitle?.dicomEncDocNonEmptyValue
        self.conceptName = conceptName
        self.mimeType = mimeType?.dicomEncDocNonEmptyValue
        self.sourceInstances = sourceInstances.removingDuplicateEncDocElements()
    }

    public static func preservingClinicalContext(
        from decoder: DCMDecoder,
        kind: DicomEncapsulatedDocumentKind = .pdf,
        documentTitle: String? = nil,
        conceptName: DicomCodedConcept? = nil,
        mimeType: String? = nil,
        sopInstanceUID: String? = nil
    ) -> DicomEncapsulatedDocumentBuildOptions {
        var sourceInstances: [DicomEncapsulatedDocumentSourceInstance] = []
        let sourceSOPClassUID = decoder.info(for: .sopClassUID).dicomEncDocNonEmptyValue
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID).dicomEncDocNonEmptyValue
        if sourceSOPClassUID != nil || sourceSOPInstanceUID != nil {
            sourceInstances.append(DicomEncapsulatedDocumentSourceInstance(
                referencedSOPClassUID: sourceSOPClassUID,
                referencedSOPInstanceUID: sourceSOPInstanceUID
            ))
        }

        return DicomEncapsulatedDocumentBuildOptions(
            kind: kind,
            sopInstanceUID: sopInstanceUID,
            studyInstanceUID: decoder.info(for: .studyInstanceUID).dicomEncDocNonEmptyValue,
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID).dicomEncDocNonEmptyValue,
            patientName: decoder.info(for: .patientName).dicomEncDocNonEmptyValue,
            patientID: decoder.info(for: .patientID).dicomEncDocNonEmptyValue,
            studyID: decoder.info(for: .studyID).dicomEncDocNonEmptyValue,
            studyDate: decoder.info(for: .studyDate).dicomEncDocNonEmptyValue,
            studyTime: decoder.info(for: .studyTime).dicomEncDocNonEmptyValue,
            seriesNumber: decoder.intValue(for: .seriesNumber),
            instanceNumber: 1,
            seriesDate: decoder.info(for: .seriesDate).dicomEncDocNonEmptyValue,
            seriesTime: decoder.info(for: .seriesTime).dicomEncDocNonEmptyValue,
            documentTitle: documentTitle,
            conceptName: conceptName,
            mimeType: mimeType,
            sourceInstances: sourceInstances
        )
    }
}

public struct DicomEncapsulatedDocument: Equatable, Sendable {
    public static let encapsulatedPDFStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.1"
    public static let encapsulatedCDAStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.2"
    public static let encapsulatedSTLStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.3"

    public static let supportedStorageSOPClassUIDs: Set<String> = [
        encapsulatedPDFStorageSOPClassUID,
        encapsulatedCDAStorageSOPClassUID,
        encapsulatedSTLStorageSOPClassUID
    ]

    public let sopClassUID: String
    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let modality: String?
    public let patientName: DicomPersonName?
    public let patientID: String?
    public let documentTitle: String?
    public let conceptName: DicomCodedConcept?
    public let mimeType: String
    public let documentData: Data
    public let sourceInstances: [DicomEncapsulatedDocumentSourceInstance]

    public init(
        sopClassUID: String,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        modality: String? = "DOC",
        patientName: DicomPersonName? = nil,
        patientID: String? = nil,
        documentTitle: String? = nil,
        conceptName: DicomCodedConcept? = nil,
        mimeType: String,
        documentData: Data,
        sourceInstances: [DicomEncapsulatedDocumentSourceInstance] = []
    ) {
        self.sopClassUID = sopClassUID.dicomEncDocNonEmptyValue ?? sopClassUID
        self.sopInstanceUID = sopInstanceUID?.dicomEncDocNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomEncDocNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomEncDocNonEmptyValue
        self.modality = modality?.dicomEncDocNonEmptyValue?.uppercased()
        self.patientName = patientName
        self.patientID = patientID?.dicomEncDocNonEmptyValue
        self.documentTitle = documentTitle?.dicomEncDocNonEmptyValue
        self.conceptName = conceptName
        self.mimeType = mimeType.dicomEncDocNonEmptyValue ?? mimeType
        self.documentData = documentData
        self.sourceInstances = sourceInstances.removingDuplicateEncDocElements()
    }

    public var kind: DicomEncapsulatedDocumentKind? {
        DicomEncapsulatedDocumentKind(storageSOPClassUID: sopClassUID)
    }

    public var encapsulatedDocumentLength: Int {
        documentData.count
    }

    public var preferredFileExtension: String {
        if let kind {
            return kind.preferredFileExtension
        }
        switch mimeType.lowercased() {
        case "application/pdf":
            return "pdf"
        case "text/xml", "application/xml":
            return "xml"
        case "model/stl", "application/sla":
            return "stl"
        default:
            return "bin"
        }
    }

    public func writeDocument(to url: URL) throws {
        try documentData.write(to: url, options: [.atomic])
    }
}

public enum DicomEncapsulatedDocumentBuilder {
    public static func dataSet(
        documentData: Data,
        options: DicomEncapsulatedDocumentBuildOptions = DicomEncapsulatedDocumentBuildOptions()
    ) throws -> DicomDataSet {
        guard !documentData.isEmpty else {
            throw DicomEncapsulatedDocumentError.emptyDocument
        }

        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let mimeType = options.mimeType ?? options.kind.defaultMIMEType

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, options.kind.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, "DOC"),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            string(.mimeTypeOfEncapsulatedDocument, vr: .LO, mimeType),
            ul(.encapsulatedDocumentLength, documentData.count),
            DicomDataElement(
                tag: DicomTag.encapsulatedDocument.rawValue,
                vr: .OB,
                value: .bytes(documentData)
            )
        ]

        appendOptionalStrings(options, to: &elements)
        if let conceptName = options.conceptName {
            elements.append(sequence(.conceptNameCodeSequence, [codedConceptDataSet(conceptName)]))
        }
        if !options.sourceInstances.isEmpty {
            elements.append(sequence(.sourceInstanceSequence, options.sourceInstances.map(sourceInstanceDataSet)))
        }

        return DicomDataSet(elements: elements)
    }

    public static func part10Data(
        documentData: Data,
        options: DicomEncapsulatedDocumentBuildOptions = DicomEncapsulatedDocumentBuildOptions()
    ) throws -> Data {
        let dataSet = try dataSet(documentData: documentData, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: options.kind.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func write(
        documentData: Data,
        to url: URL,
        options: DicomEncapsulatedDocumentBuildOptions = DicomEncapsulatedDocumentBuildOptions()
    ) throws {
        let data = try part10Data(documentData: documentData, options: options)
        try data.write(to: url, options: [.atomic])
    }

    private static func appendOptionalStrings(
        _ options: DicomEncapsulatedDocumentBuildOptions,
        to elements: inout [DicomDataElement]
    ) {
        appendOptionalString(.patientName, vr: .PN, options.patientName, to: &elements)
        appendOptionalString(.patientID, vr: .LO, options.patientID, to: &elements)
        appendOptionalString(.studyID, vr: .SH, options.studyID, to: &elements)
        appendOptionalString(.studyDate, vr: .DA, options.studyDate, to: &elements)
        appendOptionalString(.studyTime, vr: .TM, options.studyTime, to: &elements)
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
        appendOptionalString(.documentTitle, vr: .ST, options.documentTitle, to: &elements)

        if let seriesNumber = options.seriesNumber {
            elements.append(isValue(.seriesNumber, seriesNumber))
        }
        if let instanceNumber = options.instanceNumber {
            elements.append(isValue(.instanceNumber, instanceNumber))
        }
    }

    private static func appendOptionalString(
        _ tag: DicomTag,
        vr: DicomVR,
        _ value: String?,
        to elements: inout [DicomDataElement]
    ) {
        guard let value = value?.dicomEncDocNonEmptyValue else { return }
        elements.append(string(tag, vr: vr, value))
    }

    private static func sourceInstanceDataSet(_ reference: DicomEncapsulatedDocumentSourceInstance) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        return DicomDataSet(elements: elements)
    }

    private static func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
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

    private static func isValue(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings([String(value)]))
    }

    private static func ul(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers([UInt(value)]))
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
    public var encapsulatedDocument: DicomEncapsulatedDocument? {
        synchronized {
            DicomEncapsulatedDocumentParser.makeDocument(from: self)
        }
    }
}

private enum DicomEncapsulatedDocumentParser {
    static func makeDocument(from decoder: DCMDecoder) -> DicomEncapsulatedDocument? {
        guard matches(decoder),
              let payload = documentData(from: decoder),
              let mimeType = decoder.info(for: .mimeTypeOfEncapsulatedDocument).dicomEncDocNonEmptyValue else {
            return nil
        }

        let sourceInstances = parseItems(in: decoder, for: .sourceInstanceSequence)
            .map(sourceInstance)
        let conceptName = parseItems(in: decoder, for: .conceptNameCodeSequence)
            .first
            .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }

        return DicomEncapsulatedDocument(
            sopClassUID: decoder.info(for: .sopClassUID),
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            modality: decoder.info(for: .modality),
            patientName: decoder.dataSet.personName(for: .patientName),
            patientID: decoder.info(for: .patientID),
            documentTitle: decoder.info(for: .documentTitle),
            conceptName: conceptName,
            mimeType: mimeType,
            documentData: payload,
            sourceInstances: sourceInstances
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomEncDocTrimmedValue
        let modality = decoder.info(for: .modality).dicomEncDocTrimmedValue
        return DicomEncapsulatedDocument.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
            (modality == "DOC" && decoder.tagMetadataCache[DicomTag.encapsulatedDocument.rawValue] != nil)
    }

    private static func documentData(from decoder: DCMDecoder) -> Data? {
        guard let raw = decoder.dataSet.element(for: .encapsulatedDocument)?.bytesValue,
              !raw.isEmpty else {
            return nil
        }

        guard let declaredLength = decoder.dataSet.element(for: .encapsulatedDocumentLength)?.intValue,
              declaredLength >= 0,
              declaredLength <= raw.count else {
            return raw
        }
        return raw.prefix(declaredLength)
    }

    private static func sourceInstance(from item: DicomSequenceItem) -> DicomEncapsulatedDocumentSourceInstance {
        DicomEncapsulatedDocumentSourceInstance(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID)
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

private extension Array where Element: Equatable {
    func removingDuplicateEncDocElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension String {
    var dicomEncDocTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomEncDocNonEmptyValue: String? {
        let trimmed = dicomEncDocTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
