import DicomCore
import Foundation

/// Maps DICOM dataset metadata to imaging FHIR resources and back. Only identifiers, codes and
/// header values are read; pixel data, catalog rows and datasets are never copied.
public enum FHIRImagingMapper {
    public static let dicomUIDSystem = "urn:dicom:uid"
    public static let dicomCodeSystem = "http://dicom.nema.org/resources/ontology/DCM"
    public static let sopClassSystem = "urn:ietf:rfc:3986"
    public static let endpointConnectionSystem = "http://terminology.hl7.org/CodeSystem/endpoint-connection-type"

    public struct Options: Sendable {
        /// `Patient/123`; when nil the subject is a logical reference carrying the DICOM patient identifier.
        public var patientReference: String?
        public var encounterReference: String?
        public var endpointReference: String?
        public var includeInstances: Bool
        public var status: String
        public init(patientReference: String? = nil, encounterReference: String? = nil, endpointReference: String? = nil,
                    includeInstances: Bool = true, status: String = "available") {
            self.patientReference = patientReference
            self.encounterReference = encounterReference
            self.endpointReference = endpointReference
            self.includeInstances = includeInstances
            self.status = status
        }
    }

    public enum MappingError: Error, Equatable, Sendable {
        case noDatasets
        case missingStudyInstanceUID
        case multipleStudies([String])
    }

    /// Study/series/instance hierarchy from one study's datasets; instances are ordered by instance number.
    public static func imagingStudy(from datasets: [DicomDataSet], options: Options = .init()) throws -> FHIRImagingStudy {
        guard !datasets.isEmpty else { throw MappingError.noDatasets }
        let studyUIDs = Set(datasets.compactMap { $0.string(for: .studyInstanceUID)?.trimmed }.filter { !$0.isEmpty })
        guard studyUIDs.count <= 1 else { throw MappingError.multipleStudies(studyUIDs.sorted()) }
        guard let studyUID = studyUIDs.first else { throw MappingError.missingStudyInstanceUID }
        let first = datasets[0]
        var study = FHIRImagingStudy()
        study.identifiers = [FHIRIdentifier(system: dicomUIDSystem, value: "urn:oid:" + studyUID)]
        if let accession = first.string(for: .accessionNumber)?.trimmed, !accession.isEmpty {
            var identifier = FHIRIdentifier(value: accession, use: "usual")
            identifier.json["type"] = ["coding": [["system": "http://terminology.hl7.org/CodeSystem/v2-0203", "code": "ACSN"]]]
            study.identifiers.append(identifier)
        }
        study.status = options.status
        let modalities = Array(NSOrderedSet(array: datasets.compactMap { $0.string(for: .modality)?.trimmed }.filter { !$0.isEmpty })) as? [String] ?? []
        study.modalities = modalities.map { FHIRCoding(system: dicomCodeSystem, code: $0) }
        study.subject = subjectReference(first, options: options)
        if let encounter = options.encounterReference { study.encounter = FHIRReference(reference: encounter) }
        if let started = dateTime(date: first.string(for: .studyDate), time: first.string(for: .studyTime), dataset: first) { study.startedText = started }
        if let referrer = first.string(for: .referringPhysicianName)?.trimmed, !referrer.isEmpty {
            study.referrer = FHIRReference(display: personName(referrer))
        }
        if let endpoint = options.endpointReference { study.endpoints = [FHIRReference(reference: endpoint)] }
        if let description = first.string(for: .studyDescription)?.trimmed, !description.isEmpty { study.description = description }
        var seriesGroups: [String: [DicomDataSet]] = [:]
        var seriesOrder: [String] = []
        for dataset in datasets {
            let uid = dataset.string(for: .seriesInstanceUID)?.trimmed ?? ""
            if seriesGroups[uid] == nil { seriesOrder.append(uid) }
            seriesGroups[uid, default: []].append(dataset)
        }
        var series: [FHIRImagingStudySeries] = []
        for uid in seriesOrder {
            let members = seriesGroups[uid]!.sorted { ($0.int(for: .instanceNumber) ?? 0) < ($1.int(for: .instanceNumber) ?? 0) }
            let head = members[0]
            var item = FHIRImagingStudySeries()
            item.uid = uid
            if let number = head.int(for: .seriesNumber) { item.number = number }
            if let modality = head.string(for: .modality)?.trimmed, !modality.isEmpty { item.modality = FHIRCoding(system: dicomCodeSystem, code: modality) }
            if let description = head.string(for: .seriesDescription)?.trimmed, !description.isEmpty { item.description = description }
            item.numberOfInstances = members.count
            if let endpoint = options.endpointReference { item.endpoints = [FHIRReference(reference: endpoint)] }
            if let bodyPart = head.string(for: .bodyPartExamined)?.trimmed, !bodyPart.isEmpty {
                // Body Part Examined is a DICOM defined term; it is carried as display text, not as a SNOMED code.
                item.bodySite = FHIRCoding(display: bodyPart)
            }
            if let laterality = (head.strings(for: 0x0020_0060).first ?? head.strings(for: 0x0020_0062).first)?.trimmed, ["L", "R", "B"].contains(laterality) {
                item.json["laterality"] = .object(FHIRCoding(system: "http://snomed.info/sct", code: laterality == "L" ? "7771000" : (laterality == "R" ? "24028007" : "51440002"),
                                                              display: laterality == "L" ? "Left" : (laterality == "R" ? "Right" : "Bilateral")).json)
            }
            if let started = dateTime(date: head.string(for: .seriesDate), time: head.string(for: .seriesTime), dataset: head) { item.startedText = started }
            if options.includeInstances {
                item.instances = members.map { dataset in
                    var instance = FHIRImagingStudyInstance()
                    instance.uid = dataset.string(for: .sopInstanceUID)?.trimmed
                    if let sopClass = dataset.string(for: .sopClassUID)?.trimmed, !sopClass.isEmpty {
                        instance.sopClass = FHIRCoding(system: sopClassSystem, code: "urn:oid:" + sopClass)
                    }
                    if let number = dataset.int(for: .instanceNumber) { instance.number = number }
                    return instance
                }
            }
            series.append(item)
        }
        study.series = series
        study.numberOfSeries = series.count
        study.numberOfInstances = datasets.count
        return study
    }

    /// Patient demographics from the DICOM patient module (identifier, name parts, gender, birth date).
    public static func patient(from dataset: DicomDataSet, id: String? = nil) -> FHIRPatient {
        var patient = FHIRPatient(id: id)
        if let patientID = dataset.string(for: .patientID)?.trimmed, !patientID.isEmpty {
            var identifier = FHIRIdentifier(value: patientID, use: "usual")
            identifier.json["type"] = ["coding": [["system": "http://terminology.hl7.org/CodeSystem/v2-0203", "code": "MR"]]]
            if let issuer = dataset.strings(for: 0x0010_0021).first?.trimmed, !issuer.isEmpty {
                identifier.json["assigner"] = ["display": .string(issuer)]
            }
            patient.identifiers = [identifier]
        }
        if let name = dataset.string(for: .patientName)?.trimmed, !name.isEmpty {
            let alphabetic = name.split(separator: "=", omittingEmptySubsequences: false).first.map(String.init) ?? name
            let parts = alphabetic.split(separator: "^", omittingEmptySubsequences: false).map { String($0).trimmed }
            var humanName = FHIRHumanName(family: parts.first.flatMap { $0.isEmpty ? nil : $0 },
                                          given: parts.dropFirst().prefix(2).filter { !$0.isEmpty })
            if parts.count > 3, !parts[3].isEmpty { humanName.json["prefix"] = .array([.string(parts[3])]) }
            if parts.count > 4, !parts[4].isEmpty { humanName.json["suffix"] = .array([.string(parts[4])]) }
            humanName.json["text"] = .string(alphabetic.replacingOccurrences(of: "^", with: " ").trimmed)
            patient.names = [humanName]
        }
        switch dataset.string(for: .patientSex)?.trimmed.uppercased() {
        case "M": patient.gender = "male"
        case "F": patient.gender = "female"
        case "O": patient.gender = "other"
        default: break
        }
        if let birth = dataset.strings(for: 0x0010_0030).first?.trimmed, let date = fhirDate(dicomDate: birth) { patient.birthDateText = date }
        return patient
    }

    /// DICOMweb/WADO endpoint resource; `connectionType` is one of `dicom-wado-rs`, `dicom-wado-uri`, `dicom-qido-rs`, `dicom-stow-rs`.
    public static func endpoint(address: String, connectionType: String = "dicom-wado-rs", name: String? = nil, status: String = "active", id: String? = nil) -> FHIREndpoint {
        var endpoint = FHIREndpoint(id: id)
        endpoint.status = status
        endpoint.connectionType = FHIRCoding(system: endpointConnectionSystem, code: connectionType)
        endpoint.name = name
        endpoint.payloadTypes = [FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/endpoint-payload-type", code: "none")])]
        endpoint.payloadMimeTypes = ["application/dicom", "application/dicom+json"]
        endpoint.address = address
        return endpoint
    }

    /// Report shell referencing the study; code/conclusion are supplied by the host's clinical layer.
    public static func diagnosticReport(for study: FHIRImagingStudy, studyReference: String, code: FHIRCodeableConcept,
                                        status: String = "final", issued: String? = nil, conclusion: String? = nil,
                                        presentedForm: FHIRAttachment? = nil, id: String? = nil) -> FHIRDiagnosticReport {
        var report = FHIRDiagnosticReport(id: id)
        report.status = status
        report.categories = [FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0074", code: "RAD")])]
        report.code = code
        report.subject = study.subject
        report.encounter = study.encounter
        if let issued { report.issuedText = issued }
        report.imagingStudies = [FHIRReference(reference: studyReference)]
        report.conclusion = conclusion
        if let presentedForm { report.presentedForms = [presentedForm] }
        return report
    }

    /// DocumentReference for an encapsulated or rendered document attached to a study.
    public static func documentReference(subject: FHIRReference?, type: FHIRCodeableConcept, attachment: FHIRAttachment,
                                         studyReference: String? = nil, masterIdentifier: String? = nil, status: String = "current",
                                         date: String? = nil, id: String? = nil) -> FHIRDocumentReference {
        var document = FHIRDocumentReference(id: id)
        if let masterIdentifier { document.masterIdentifier = FHIRIdentifier(system: dicomUIDSystem, value: "urn:oid:" + masterIdentifier) }
        document.status = status
        document.type = type
        document.subject = subject
        if let date { document.dateText = date }
        document.contents = [FHIRDocumentReferenceContent(attachment: attachment)]
        if let studyReference {
            document.json["context"] = ["related": [["reference": .string(studyReference)]]]
        }
        return document
    }

    public struct DICOMIdentifiers: Equatable, Sendable {
        public var studyInstanceUID: String
        public var series: [(uid: String, instances: [String])]
        public static func == (lhs: DICOMIdentifiers, rhs: DICOMIdentifiers) -> Bool {
            lhs.studyInstanceUID == rhs.studyInstanceUID && lhs.series.map(\.uid) == rhs.series.map(\.uid) && lhs.series.map(\.instances) == rhs.series.map(\.instances)
        }
    }

    /// Reads the DICOM UID hierarchy back from an `ImagingStudy` (strips `urn:oid:` prefixes).
    public static func dicomIdentifiers(from study: FHIRImagingStudy) -> DICOMIdentifiers? {
        guard let studyUID = study.studyInstanceUID else { return nil }
        let series = study.series.compactMap { item -> (uid: String, instances: [String])? in
            guard let uid = item.uid else { return nil }
            return (stripOID(uid), item.instances.compactMap { $0.uid }.map(stripOID))
        }
        return DICOMIdentifiers(studyInstanceUID: stripOID(studyUID), series: series)
    }

    // MARK: helpers

    static func subjectReference(_ dataset: DicomDataSet, options: Options) -> FHIRReference {
        if let reference = options.patientReference { return FHIRReference(reference: reference) }
        var reference = FHIRReference(type: "Patient")
        if let patientID = dataset.string(for: .patientID)?.trimmed, !patientID.isEmpty {
            reference.json["identifier"] = .object(FHIRIdentifier(value: patientID).json)
        }
        if let name = dataset.string(for: .patientName)?.trimmed, !name.isEmpty { reference.json["display"] = .string(personName(name)) }
        return reference
    }

    static func personName(_ pn: String) -> String {
        let alphabetic = pn.split(separator: "=", omittingEmptySubsequences: false).first.map(String.init) ?? pn
        return alphabetic.split(separator: "^").map { String($0).trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func stripOID(_ value: String) -> String { value.hasPrefix("urn:oid:") ? String(value.dropFirst(8)) : value }

    static func fhirDate(dicomDate: String) -> String? {
        let digits = dicomDate.filter(\.isNumber)
        guard digits.count == 8 else { return nil }
        let text = digits.prefix(4) + "-" + digits.dropFirst(4).prefix(2) + "-" + digits.dropFirst(6)
        return FHIRDate(String(text)) != nil ? String(text) : nil
    }

    /// DA + TM to FHIR dateTime; without a time zone in the dataset the value stays date-only (never fabricated).
    static func dateTime(date: String?, time: String?, dataset: DicomDataSet?) -> String? {
        guard let date, let day = fhirDate(dicomDate: date) else { return nil }
        guard let time = time?.trimmed, time.count >= 6, let offset = timeZoneOffset(from: dataset) else { return day }
        let digits = time.filter(\.isNumber)
        let clock = digits.prefix(2) + ":" + digits.dropFirst(2).prefix(2) + ":" + digits.dropFirst(4).prefix(2)
        let value = day + "T" + clock + offset
        return FHIRDateTime(value) != nil ? value : day
    }

    static func timeZoneOffset(from dataset: DicomDataSet?) -> String? {
        guard let offset = dataset?.strings(for: 0x0008_0201).first?.trimmed, offset.count == 5,
              let sign = offset.first, sign == "+" || sign == "-",
              offset.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)), minutes < 60 else { return nil }
        let total = (hours * 60 + minutes) * (sign == "-" ? -1 : 1)
        guard (-720...840).contains(total) else { return nil }
        return String(offset.prefix(3)) + ":" + offset.suffix(2)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
