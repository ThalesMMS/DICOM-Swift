import Foundation

public enum DicomEncapsulatedDocumentError: Error, Equatable, LocalizedError, Sendable {
    case emptyDocument
    case invalidDocumentLength

    public var errorDescription: String? {
        switch self {
        case .invalidDocumentLength:
            return "Encapsulated Document Length must fit an unsigned 32-bit value."
        case .emptyDocument:
            return "Encapsulated Document payload cannot be empty."
        }
    }
}

public enum DicomEncapsulatedDocumentKind: Equatable, Hashable, Sendable {
    case pdf
    case cda
    case stl
    case obj
    case mtl

    public var storageSOPClassUID: String {
        switch self {
        case .pdf:
            return DicomEncapsulatedDocument.encapsulatedPDFStorageSOPClassUID
        case .cda:
            return DicomEncapsulatedDocument.encapsulatedCDAStorageSOPClassUID
        case .obj: return DicomEncapsulatedDocument.encapsulatedOBJStorageSOPClassUID
        case .mtl: return DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID
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
        case .obj: return "model/obj"
        case .mtl: return "model/mtl"
        case .stl:
            return "model/stl"
        }
    }

    public var defaultModality: String {
        switch self {
        case .pdf, .cda:
            return "DOC"
        case .stl, .obj, .mtl:
            return "M3D"
        }
    }

    public var preferredFileExtension: String {
        switch self {
        case .pdf:
            return "pdf"
        case .cda:
            return "xml"
        case .obj: return "obj"
        case .mtl: return "mtl"
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
        case DicomEncapsulatedDocument.encapsulatedOBJStorageSOPClassUID: self = .obj
        case DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID: self = .mtl
        default:
            return nil
        }
    }
}

public struct DicomEncapsulatedDocumentSourceInstance: Equatable, Hashable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?

    public let purposeCodes: [DicomCodedConcept]
    public let relativeURIReference: String?

    public init(referencedSOPClassUID: String?, referencedSOPInstanceUID: String?,
                purposeCodes: [DicomCodedConcept] = [], relativeURIReference: String? = nil) {
        self.purposeCodes = purposeCodes
        self.relativeURIReference = relativeURIReference
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
    public var frameOfReferenceUID: String?
    public var measurementUnits: DicomCodedConcept?
    public var sourceInstances: [DicomEncapsulatedDocumentSourceInstance]
    public var patientBirthDate: String?
    public var patientSex: String?
    public var referringPhysicianName: String?
    public var accessionNumber: String?
    public var acquisitionDateTime: String?
    public var burnedInAnnotation: String
    public var manufacturer: String?
    public var manufacturerModelName: String?
    public var deviceSerialNumber: String?
    public var softwareVersions: String?
    public var hl7InstanceIdentifier: String?

    public var imageLaterality: String? = nil
    public var recognizableVisualFeatures: String? = nil
    public var verificationFlag: String? = nil
    public var listOfMIMETypes: [String] = []
    public var documentClassCodes: [DicomCodedConcept] = []
    public var referencedImages: [DicomEncapsulatedDocumentSourceInstance] = []
    public var referencedInstances: [DicomEncapsulatedDocumentSourceInstance] = []
    public var predecessorDocuments: [DicomEncapsulatedDocumentHierarchy] = []
    public var identicalDocuments: [DicomEncapsulatedDocumentHierarchy] = []
    public var manufacturing3DModel: DicomManufacturing3DModel? = nil
    public var positionReferenceIndicator: String? = nil
    /// nil writes the actual payload length. An explicit value is retained for caller-controlled envelopes;
    /// the envelope validator diagnoses disagreement without discarding payload bytes.
    public var declaredDocumentLength: Int? = nil

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
        frameOfReferenceUID: String? = nil,
        measurementUnits: DicomCodedConcept? = nil,
        sourceInstances: [DicomEncapsulatedDocumentSourceInstance] = [],
        patientBirthDate: String? = nil,
        patientSex: String? = nil,
        referringPhysicianName: String? = nil,
        accessionNumber: String? = nil,
        acquisitionDateTime: String? = nil,
        burnedInAnnotation: String = "YES",
        manufacturer: String? = "DICOM-Swift",
        manufacturerModelName: String? = "DicomEncapsulatedDocumentBuilder",
        deviceSerialNumber: String? = "0",
        softwareVersions: String? = nil,
        hl7InstanceIdentifier: String? = nil
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
        self.frameOfReferenceUID = frameOfReferenceUID?.dicomEncDocNonEmptyValue
        self.measurementUnits = measurementUnits
        self.sourceInstances = sourceInstances.removingDuplicateEncDocElements()
        self.patientBirthDate = patientBirthDate?.dicomEncDocNonEmptyValue
        self.patientSex = patientSex?.dicomEncDocNonEmptyValue?.uppercased()
        self.referringPhysicianName = referringPhysicianName?.dicomEncDocNonEmptyValue
        self.accessionNumber = accessionNumber?.dicomEncDocNonEmptyValue
        self.acquisitionDateTime = acquisitionDateTime?.dicomEncDocNonEmptyValue
        self.burnedInAnnotation = burnedInAnnotation.dicomEncDocNonEmptyValue?.uppercased() ?? "YES"
        self.manufacturer = manufacturer?.dicomEncDocNonEmptyValue
        self.manufacturerModelName = manufacturerModelName?.dicomEncDocNonEmptyValue
        self.deviceSerialNumber = deviceSerialNumber?.dicomEncDocNonEmptyValue
        self.softwareVersions = softwareVersions?.dicomEncDocNonEmptyValue
        self.hl7InstanceIdentifier = hl7InstanceIdentifier?.dicomEncDocNonEmptyValue
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
            frameOfReferenceUID: decoder.info(for: .frameOfReferenceUID).dicomEncDocNonEmptyValue,
            sourceInstances: sourceInstances,
            patientBirthDate: decoder.info(for: 0x00100030).dicomEncDocNonEmptyValue,
            patientSex: decoder.info(for: .patientSex).dicomEncDocNonEmptyValue,
            referringPhysicianName: decoder.info(for: .referringPhysicianName).dicomEncDocNonEmptyValue,
            accessionNumber: decoder.info(for: .accessionNumber).dicomEncDocNonEmptyValue
        )
    }
}

public struct DicomEncapsulatedDocument: Equatable, Sendable {
    public static let encapsulatedPDFStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.1"
    public static let encapsulatedCDAStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.2"
    public static let encapsulatedSTLStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.3"

    public static let encapsulatedOBJStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.4"
    public static let encapsulatedMTLStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.104.5"

    public static let supportedStorageSOPClassUIDs: Set<String> = [
        encapsulatedPDFStorageSOPClassUID,
        encapsulatedCDAStorageSOPClassUID,
        encapsulatedSTLStorageSOPClassUID, encapsulatedOBJStorageSOPClassUID, encapsulatedMTLStorageSOPClassUID
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
    public let frameOfReferenceUID: String?
    public let measurementUnits: DicomCodedConcept?
    public let sourceInstances: [DicomEncapsulatedDocumentSourceInstance]

    public var imageLaterality: String? = nil
    public var recognizableVisualFeatures: String? = nil
    public var verificationFlag: String? = nil
    public var listOfMIMETypes: [String] = []
    public var documentClassCodes: [DicomCodedConcept] = []
    public var referencedImages: [DicomEncapsulatedDocumentSourceInstance] = []
    public var referencedInstances: [DicomEncapsulatedDocumentSourceInstance] = []
    public var predecessorDocuments: [DicomEncapsulatedDocumentHierarchy] = []
    public var identicalDocuments: [DicomEncapsulatedDocumentHierarchy] = []
    public var manufacturing3DModel: DicomManufacturing3DModel? = nil
    public var positionReferenceIndicator: String? = nil
    public var instanceNumber: Int? = nil
    public var contentDate: String? = nil
    public var contentTime: String? = nil
    public var acquisitionDateTime: String? = nil
    public var burnedInAnnotation: String? = nil
    public var hl7InstanceIdentifier: String? = nil
    public var manufacturer: String? = nil
    public var manufacturerModelName: String? = nil
    public var deviceSerialNumber: String? = nil
    public var softwareVersions: String? = nil
    public var declaredDocumentLength: Int? = nil
    public var encodedValueLength: Int? = nil
    public var diagnostics: [DicomEncapsulatedDocumentDiagnostic] = []

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
        frameOfReferenceUID: String? = nil,
        measurementUnits: DicomCodedConcept? = nil,
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
        self.frameOfReferenceUID = frameOfReferenceUID?.dicomEncDocNonEmptyValue
        self.measurementUnits = measurementUnits
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

        guard let length = UInt32(exactly: options.declaredDocumentLength ?? documentData.count) else {
            throw DicomEncapsulatedDocumentError.invalidDocumentLength
        }
        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let mimeType = options.mimeType ?? options.kind.defaultMIMEType

        // PS3.3 A.45: Patient/General Study Type 2 attributes, Series and Instance Number (Type 1), Burned In
        // Annotation, Document Title and Concept Name (Type 2) and the equipment modules of the IOD.
        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, options.kind.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, options.kind.defaultModality),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            optionalString(.patientName, vr: .PN, options.patientName),
            optionalString(.patientID, vr: .LO, options.patientID),
            optionalString(0x00100030, vr: .DA, options.patientBirthDate),
            optionalString(.patientSex, vr: .CS, options.patientSex),
            optionalString(.studyDate, vr: .DA, options.studyDate),
            optionalString(.studyTime, vr: .TM, options.studyTime),
            optionalString(.referringPhysicianName, vr: .PN, options.referringPhysicianName),
            optionalString(.studyID, vr: .SH, options.studyID),
            optionalString(.accessionNumber, vr: .SH, options.accessionNumber),
            isValue(.seriesNumber, options.seriesNumber ?? 1),
            isValue(.instanceNumber, options.instanceNumber ?? 1),
            optionalString(0x00080070, vr: .LO, options.manufacturer),
            optionalString(0x0008002A, vr: .DT, options.acquisitionDateTime),
            string(0x00280301, vr: .CS, options.burnedInAnnotation),
            optionalString(.documentTitle, vr: .ST, options.documentTitle),
            options.conceptName.map { sequence(.conceptNameCodeSequence, [codedConceptDataSet($0)]) }
                ?? DicomDataElement(tag: DicomTag.conceptNameCodeSequence.rawValue, vr: .SQ, value: .sequence([])),
            string(.mimeTypeOfEncapsulatedDocument, vr: .LO, mimeType),
            ul(.encapsulatedDocumentLength, Int(length)),
            DicomDataElement(
                tag: DicomTag.encapsulatedDocument.rawValue,
                vr: .OB,
                value: .bytes(documentData)
            )
        ]

        switch options.kind {
        case .pdf, .cda:
            // C.8.6.1: a document converted from a workstation.
            elements.append(string(.conversionType, vr: .CS, "WSD"))
        case .stl, .obj, .mtl:
            // C.7.5.2: Enhanced General Equipment is mandatory for manufacturing models.
            elements.append(string(0x00081090, vr: .LO, options.manufacturerModelName ?? "DicomEncapsulatedDocumentBuilder"))
            elements.append(string(0x00181000, vr: .LO, options.deviceSerialNumber ?? "0"))
            elements.append(string(0x00181020, vr: .LO, options.softwareVersions ?? softwareVersion))
        }
        if options.kind == .cda, let identifier = options.hl7InstanceIdentifier {
            elements.append(string(0x0040E001, vr: .ST, identifier))
        }

        appendOptionalStrings(options, to: &elements)
        if options.kind == .stl || options.kind == .obj {
            // A.85.1/A.85.2: the Frame of Reference is mandatory; the measurement units (Type 1) are never invented,
            // so an STL without units stays non-conformant.
            elements.append(string(.frameOfReferenceUID, vr: .UI, options.frameOfReferenceUID ?? DicomDataSetWriter.makeUID()))
            elements.append(DicomDataElement(tag: 0x00201040, vr: .LO, value: .strings(options.positionReferenceIndicator.map { [$0] } ?? [])))
        } else if let frameOfReferenceUID = options.frameOfReferenceUID {
            elements.append(string(.frameOfReferenceUID, vr: .UI, frameOfReferenceUID))
        }
        if let measurementUnits = options.manufacturing3DModel?.measurementUnits ?? options.measurementUnits {
            elements.append(sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(measurementUnits)]))
        }
        if !options.sourceInstances.isEmpty {
            elements.append(sequence(.sourceInstanceSequence, options.sourceInstances.map(sourceInstanceDataSet)))
        }

        if let value = options.imageLaterality { elements.append(string(0x00200062, vr: .CS, value)) }
        if let value = options.recognizableVisualFeatures { elements.append(string(0x00280302, vr: .CS, value)) }
        if let value = options.verificationFlag { elements.append(string(0x0040A493, vr: .CS, value)) }
        if !options.listOfMIMETypes.isEmpty { elements.append(.init(tag: 0x00420014, vr: .LO, value: .strings(options.listOfMIMETypes))) }
        if !options.documentClassCodes.isEmpty { elements.append(EncDocFields.sequence(0x0040E008, options.documentClassCodes.map(EncDocFields.code))) }
        if !options.referencedImages.isEmpty { elements.append(EncDocFields.sequence(0x00081140, options.referencedImages.map(EncDocFields.reference))) }
        if !options.referencedInstances.isEmpty { elements.append(EncDocFields.sequence(0x0008114A, options.referencedInstances.map(EncDocFields.reference))) }
        if !options.predecessorDocuments.isEmpty { elements.append(EncDocFields.sequence(0x0040A360, options.predecessorDocuments.map(EncDocFields.hierarchy))) }
        if !options.identicalDocuments.isEmpty { elements.append(EncDocFields.sequence(0x0040A525, options.identicalDocuments.map(EncDocFields.hierarchy))) }
        if let model = options.manufacturing3DModel { elements += model.optionalElements }
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

    static let softwareVersion = "1.0"

    private static func appendOptionalStrings(
        _ options: DicomEncapsulatedDocumentBuildOptions,
        to elements: inout [DicomDataElement]
    ) {
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
    }

    /// A Type 2 attribute: the value when supplied, otherwise a zero-length element.
    private static func optionalString(_ tag: DicomTag, vr: DicomVR, _ value: String?) -> DicomDataElement {
        optionalString(tag.rawValue, vr: vr, value)
    }

    private static func optionalString(_ tag: Int, vr: DicomVR, _ value: String?) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings(value.map { [$0] } ?? []))
    }

    private static func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
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
        EncDocFields.reference(reference)
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
        let measurementUnits = parseItems(in: decoder, for: .measurementUnitsCodeSequence)
            .first
            .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }

        var document = DicomEncapsulatedDocument(
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
            frameOfReferenceUID: decoder.info(for: .frameOfReferenceUID),
            measurementUnits: measurementUnits,
            sourceInstances: sourceInstances
        )
        let ds = decoder.dataSet
        document.imageLaterality = ds[0x00200062]?.stringValue
        document.recognizableVisualFeatures = ds[0x00280302]?.stringValue
        document.verificationFlag = ds[0x0040A493]?.stringValue
        document.listOfMIMETypes = ds[0x00420014]?.stringValues ?? []
        document.documentClassCodes = (ds[0x0040E008]?.sequenceItems ?? []).compactMap { EncDocFields.parseCode($0.dataSet) }
        document.referencedImages = (ds[0x00081140]?.sequenceItems ?? []).map { EncDocFields.parseReference($0.dataSet) }
        document.referencedInstances = (ds[0x0008114A]?.sequenceItems ?? []).map { EncDocFields.parseReference($0.dataSet) }
        document.predecessorDocuments = (ds[0x0040A360]?.sequenceItems ?? []).flatMap { EncDocFields.parseHierarchies($0.dataSet) }
        document.identicalDocuments = (ds[0x0040A525]?.sequenceItems ?? []).flatMap { EncDocFields.parseHierarchies($0.dataSet) }
        document.manufacturing3DModel = DicomManufacturing3DModel(dataSet: ds)
        document.positionReferenceIndicator = ds[0x00201040]?.stringValue
        document.instanceNumber = ds[0x00200013]?.intValue
        document.contentDate = ds[0x00080023]?.stringValue
        document.contentTime = ds[0x00080033]?.stringValue
        document.acquisitionDateTime = ds[0x0008002A]?.stringValue
        document.burnedInAnnotation = ds[0x00280301]?.stringValue
        document.hl7InstanceIdentifier = ds[0x0040E001]?.stringValue
        document.manufacturer = ds[0x00080070]?.stringValue
        document.manufacturerModelName = ds[0x00081090]?.stringValue
        document.deviceSerialNumber = ds[0x00181000]?.stringValue
        document.softwareVersions = ds[0x00181020]?.stringValue
        document.declaredDocumentLength = ds[0x00420015]?.intValue
        document.encodedValueLength = ds[0x00420011]?.bytesValue?.count
        document.diagnostics = DicomEncapsulatedDocumentEnvelopeValidator.lengthDiagnostics(declared: document.declaredDocumentLength, raw: ds[0x00420011]?.bytesValue ?? Data())
        return document
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

        guard let length = decoder.dataSet.element(for: .encapsulatedDocumentLength)?.intValue,
              length >= 0, length % 2 == 1, raw.count == length + 1, raw.last == 0 else {
            return raw
        }
        return Data(raw.dropLast())
    }

    private static func sourceInstance(from item: DicomSequenceItem) -> DicomEncapsulatedDocumentSourceInstance {
        EncDocFields.parseReference(item.dataSet)
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

/// One study/series branch of the Hierarchical SOP Instance Reference Macro.
public struct DicomEncapsulatedDocumentHierarchy: Equatable, Sendable {
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    public var instances: [DicomEncapsulatedDocumentSourceInstance]

    public init(studyInstanceUID: String, seriesInstanceUID: String,
                instances: [DicomEncapsulatedDocumentSourceInstance]) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.instances = instances
    }
}

internal enum EncDocFields {
    static func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }

    static func code(_ value: DicomCodedConcept) -> DicomDataSet {
        var fields = [text(0x00080100, .SH, value.codeValue), text(0x00080102, .SH, value.codingSchemeDesignator)]
        if let meaning = value.codeMeaning { fields.append(text(0x00080104, .LO, meaning)) }
        return .init(elements: fields)
    }

    static func parseCode(_ ds: DicomDataSet) -> DicomCodedConcept? { DicomCodedConcept(dataSet: ds) }

    static func reference(_ value: DicomEncapsulatedDocumentSourceInstance) -> DicomDataSet {
        var fields: [DicomDataElement] = []
        if let uid = value.referencedSOPClassUID { fields.append(text(0x00081150, .UI, uid)) }
        if let uid = value.referencedSOPInstanceUID { fields.append(text(0x00081155, .UI, uid)) }
        if !value.purposeCodes.isEmpty { fields.append(sequence(0x0040A170, value.purposeCodes.map(code))) }
        if let uri = value.relativeURIReference { fields.append(text(0x00687005, .UR, uri)) }
        return .init(elements: fields)
    }

    static func parseReference(_ ds: DicomDataSet) -> DicomEncapsulatedDocumentSourceInstance {
        .init(referencedSOPClassUID: ds[0x00081150]?.stringValue, referencedSOPInstanceUID: ds[0x00081155]?.stringValue,
              purposeCodes: (ds[0x0040A170]?.sequenceItems ?? []).compactMap { parseCode($0.dataSet) },
              relativeURIReference: ds[0x00687005]?.stringValue)
    }

    static func hierarchy(_ value: DicomEncapsulatedDocumentHierarchy) -> DicomDataSet {
        .init(elements: [text(0x0020000D, .UI, value.studyInstanceUID), sequence(0x00081115, [
            .init(elements: [text(0x0020000E, .UI, value.seriesInstanceUID),
                             sequence(0x00081199, value.instances.map(reference))])])])
    }

    static func parseHierarchies(_ ds: DicomDataSet) -> [DicomEncapsulatedDocumentHierarchy] {
        (ds[0x00081115]?.sequenceItems ?? []).map { series in
            .init(studyInstanceUID: ds[0x0020000D]?.stringValue ?? "",
                  seriesInstanceUID: series.dataSet[0x0020000E]?.stringValue ?? "",
                  instances: (series.dataSet[0x00081199]?.sequenceItems ?? []).map { parseReference($0.dataSet) })
        }
    }
}
