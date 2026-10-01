import CryptoKit
import DicomCore
import Foundation

/// DICOM <-> clinical model: orders to Modality Worklist items, datasets to studies, performed steps
/// (MPPS) and results as Structured Reports. Only identifiers, codes and header values move.
public enum DICOMClinicalMapper {
    public static let mapperName = "DICOMClinicalMapper/1"
    static let issuerOfPatientID = 0x0010_0021
    static let patientBirthDate = 0x0010_0030
    static let issuerOfAccessionNumberSequence = 0x0008_0051
    static let universalEntityID = 0x0040_0032
    static let localNamespaceEntityID = 0x0040_0031
    static let placerOrderNumber = 0x0040_2016
    static let fillerOrderNumber = 0x0040_2017
    static let requestedProcedureCodeSequence = 0x0032_1064
    static let scheduledProtocolCodeSequence = 0x0040_0008
    static let referencedStudySequence = 0x0008_1110
    static let studyID = 0x0020_0010
    static let priority = 0x0040_1003

    static func element(_ tag: Int, _ vr: DicomVR, _ value: String?) -> DicomDataElement? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items.map { DicomSequenceItem(dataSet: $0) }))
    }

    static func issuerSequence(_ authority: String?) -> DicomDataSet? {
        guard let issuer = element(localNamespaceEntityID, .UT, authority) else { return nil }
        return DicomDataSet(elements: [issuer])
    }

    static func codeSequence(_ code: ClinicalCode) -> DicomDataSet {
        DicomDataSet(elements: [element(0x0008_0100, .SH, code.code), element(0x0008_0102, .SH, code.system ?? "99ISIS"), element(0x0008_0104, .LO, code.display ?? code.code)].compactMap { $0 })
    }

    static func personName(_ practitioner: ClinicalPractitioner?) -> String? {
        guard let practitioner else { return nil }
        return [practitioner.familyName ?? "", practitioner.givenName ?? ""].joined(separator: "^")
    }

    /// ISO 8601 -> DICOM DA/TM pair (no time zone is invented; a date-only value yields no time).
    static func dicomDateTime(_ iso: String?) -> (date: String?, time: String?) {
        guard let iso else { return (nil, nil) }
        let date = String(iso.prefix(10)).replacingOccurrences(of: "-", with: "")
        guard date.count == 8 else { return (nil, nil) }
        guard let t = iso.firstIndex(of: "T") else { return (date, nil) }
        let time = iso[iso.index(after: t)...].prefix(8).replacingOccurrences(of: ":", with: "")
        return (date, time.count >= 4 ? String(time) : nil)
    }

    static func isoDate(_ da: String?) -> String? {
        guard let digits = da?.filter(\.isNumber), digits.count == 8 else { return nil }
        let year = String(digits.prefix(4))
        let month = String(digits.dropFirst(4).prefix(2))
        let day = String(digits.dropFirst(6))
        return year + "-" + month + "-" + day
    }

    static func isoDateTime(da: String?, tm: String?) -> String? {
        guard let date = isoDate(da) else { return nil }
        guard let tm = tm?.filter(\.isNumber), tm.count >= 6 else { return date }
        let hours = String(tm.prefix(2))
        let minutes = String(tm.dropFirst(2).prefix(2))
        let seconds = String(tm.dropFirst(4).prefix(2))
        return date + "T" + hours + ":" + minutes + ":" + seconds
    }

    // MARK: identity

    public static func identity(from dataset: DicomDataSet, report: inout MappingReport) -> ClinicalPatientIdentity {
        var identity = ClinicalPatientIdentity()
        if let patientID = dataset.string(for: .patientID)?.trimmingCharacters(in: .whitespaces), !patientID.isEmpty {
            identity.identifier = AssignedIdentifier(value: patientID, authority: dataset.strings(for: issuerOfPatientID).first)
            report.add(.mapped("(0010,0020)+(0010,0021)", "patient.identifier"))
        } else { report.add(.absent("patient.identifier", reason: "PatientID missing")) }
        if let name = dataset.string(for: .patientName) {
            let alphabetic = name.split(separator: "=", omittingEmptySubsequences: false).first.map(String.init) ?? name
            let parts = alphabetic.split(separator: "^", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            identity.familyName = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            identity.givenName = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            report.add(.mapped("(0010,0010)", "patient.name"))
        } else { report.add(.absent("patient.name")) }
        identity.birthDate = isoDate(dataset.strings(for: patientBirthDate).first)
        report.add(identity.birthDate == nil ? .absent("patient.birthDate") : .mapped("(0010,0030)", "patient.birthDate"))
        if let sex = dataset.string(for: .patientSex)?.trimmingCharacters(in: .whitespaces).uppercased(), ["M", "F", "O"].contains(sex) {
            identity.sex = sex; report.add(.mapped("(0010,0040)", "patient.sex"))
        }
        return identity
    }

    static func patientElements(_ identity: ClinicalPatientIdentity) -> [DicomDataElement] {
        var elements: [DicomDataElement] = []
        let name = identity.familyName != nil || identity.givenName != nil ? [identity.familyName ?? "", identity.givenName ?? ""].joined(separator: "^") : nil
        if let e = element(DicomTag.patientName.rawValue, .PN, name) { elements.append(e) }
        if let e = element(DicomTag.patientID.rawValue, .LO, identity.identifier?.value) { elements.append(e) }
        if let e = element(issuerOfPatientID, .LO, identity.identifier?.authority) { elements.append(e) }
        if let e = element(patientBirthDate, .DA, identity.birthDate?.replacingOccurrences(of: "-", with: "")) { elements.append(e) }
        if let e = element(DicomTag.patientSex.rawValue, .CS, identity.sex) { elements.append(e) }
        return elements
    }

    // MARK: order -> worklist

    /// Modality Worklist item (Scheduled Procedure Step + Requested Procedure + Imaging Service Request modules).
    public static func worklistItem(from order: ClinicalOrder, studyInstanceUID: String, scheduledStationAETitle: String? = nil,
                                    options: MappingOptions = .init()) throws -> Mapped<DicomModalityWorklistItem> {
        var report = MappingReport()
        guard order.accessionNumber != nil || order.placerOrderNumber != nil else { throw MappingError.missingIdentifier("order.accessionNumber or placerOrderNumber") }
        let (date, time) = dicomDateTime(order.scheduledStart)
        var step: [DicomDataElement] = [
            element(DicomWorkflowTag.scheduledStationAETitle, .AE, scheduledStationAETitle ?? order.scheduledStationAETitle),
            element(DicomWorkflowTag.scheduledProcedureStepStartDate, .DA, date),
            element(DicomWorkflowTag.scheduledProcedureStepStartTime, .TM, time),
            element(DicomWorkflowTag.modality, .CS, order.modality),
            element(DicomWorkflowTag.scheduledProcedureStepDescription, .LO, order.procedureDescription ?? order.procedure?.display),
            element(DicomWorkflowTag.scheduledProcedureStepID, .SH, order.requestedProcedureID.map { $0 + "-1" } ?? order.accessionNumber.map { $0.value + "-1" }),
            element(0x0040_0006, .PN, personName(order.referringPhysician))
        ].compactMap { $0 }
        if let procedure = order.procedure { step.append(sequence(scheduledProtocolCodeSequence, [codeSequence(procedure)])) }
        report.add(.mapped("order.scheduledStart", "(0040,0002)/(0040,0003)"))
        if order.scheduledStart != nil, time == nil { report.add(.changed("order.scheduledStart", "(0040,0003)", reason: "timeAbsentInSource")) }
        var elements: [DicomDataElement] = patientElements(order.patient) + [
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
            element(DicomWorkflowTag.accessionNumber, .SH, order.accessionNumber?.value),
            element(DicomWorkflowTag.requestedProcedureID, .SH, order.requestedProcedureID ?? order.accessionNumber?.value),
            element(DicomWorkflowTag.requestedProcedureDescription, .LO, order.procedureDescription ?? order.procedure?.display),
            element(placerOrderNumber, .LO, order.placerOrderNumber?.value),
            element(fillerOrderNumber, .LO, order.fillerOrderNumber?.value),
            element(priority, .SH, order.priority),
            element(DicomTag.referringPhysicianName.rawValue, .PN, personName(order.referringPhysician))
        ].compactMap { $0 }
        if let issuer = issuerSequence(order.accessionNumber?.authority) { elements.append(sequence(issuerOfAccessionNumberSequence, [issuer])); report.add(.mapped("order.accessionNumber.authority", "(0008,0051)")) }
        if let issuer = issuerSequence(order.placerOrderNumber?.authority) { elements.append(sequence(0x0040_2026, [issuer])); report.add(.mapped("order.placerOrderNumber.authority", "(0040,2026)")) }
        if let issuer = issuerSequence(order.fillerOrderNumber?.authority) { elements.append(sequence(0x0040_2027, [issuer])); report.add(.mapped("order.fillerOrderNumber.authority", "(0040,2027)")) }
        if let procedure = order.procedure { elements.append(sequence(requestedProcedureCodeSequence, [codeSequence(procedure)])); report.add(.mapped("order.procedure", "(0032,1064)")) }
        elements.append(sequence(DicomWorkflowTag.scheduledProcedureStepSequence, [DicomDataSet(elements: step)]))
        report.add(.mapped("order", "ModalityWorklistItem"))
        if order.reason != nil { report.add(.lost("order.reason", reason: "noTargetInProfile")) }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        let item = DicomModalityWorklistItem(dataSet: DicomDataSet(elements: elements))
        return Mapped(value: item, provenance: .init(sourceKind: .dicom, sourceIdentifier: studyInstanceUID, mapper: mapperName, report: report))
    }

    /// Order read back from a worklist item (identifiers with issuers when the sequences are present).
    public static func order(from item: DicomModalityWorklistItem) -> Mapped<ClinicalOrder> {
        var report = MappingReport()
        let dataset = item.dataSet
        var order = ClinicalOrder(patient: identity(from: dataset, report: &report))
        func issuer(_ tag: Int) -> String? { dataset.element(for: tag)?.sequenceItems.first?.dataSet.strings(for: localNamespaceEntityID).first }
        order.accessionNumber = item.accessionNumber.map { AssignedIdentifier(value: $0, authority: issuer(issuerOfAccessionNumberSequence)) }
        order.placerOrderNumber = dataset.strings(for: placerOrderNumber).first.map { AssignedIdentifier(value: $0, authority: issuer(0x0040_2026)) }
        order.fillerOrderNumber = dataset.strings(for: fillerOrderNumber).first.map { AssignedIdentifier(value: $0, authority: issuer(0x0040_2027)) }
        order.requestedProcedureID = item.requestedProcedureID
        order.procedureDescription = item.requestedProcedureDescription
        if let code = dataset.element(for: requestedProcedureCodeSequence)?.sequenceItems.first?.dataSet {
            order.procedure = code.strings(for: 0x0008_0100).first.map { ClinicalCode(system: code.strings(for: 0x0008_0102).first, code: $0, display: code.strings(for: 0x0008_0104).first) }
        }
        order.modality = item.modality
        order.scheduledStart = isoDateTime(da: item.scheduledProcedureStepStartDate, tm: item.scheduledProcedureStepStartTime)
        order.scheduledStationAETitle = item.scheduledStationAETitle
        order.status = .scheduled
        if let referrer = dataset.string(for: .referringPhysicianName) {
            let parts = referrer.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            order.referringPhysician = ClinicalPractitioner(familyName: parts.first, givenName: parts.count > 1 ? parts[1] : nil)
        }
        report.add(.mapped("ModalityWorklistItem", "order"))
        return Mapped(value: order, provenance: .init(sourceKind: .dicom, sourceIdentifier: dataset.string(for: .studyInstanceUID) ?? item.stableIdentifier, mapper: mapperName, report: report))
    }

    // MARK: datasets -> study

    public static func study(from datasets: [DicomDataSet]) throws -> Mapped<ClinicalStudy> {
        guard let first = datasets.first else { throw MappingError.missingIdentifier("datasets") }
        let uids = Set(datasets.compactMap { $0.string(for: .studyInstanceUID)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard uids.count == 1, let studyUID = uids.first else { throw MappingError.missingIdentifier("StudyInstanceUID (exactly one study expected)") }
        var report = MappingReport()
        var study = ClinicalStudy(studyInstanceUID: studyUID, patient: identity(from: first, report: &report))
        for dataset in datasets.dropFirst() {
            var patientReport = MappingReport()
            let other = identity(from: dataset, report: &patientReport)
            if other.isEmpty { continue }
            if study.patient.isEmpty { study.patient = other; continue }
            switch study.patient.compare(with: other) {
            case .same: break
            case .conflict(let fields): throw MappingError.identityConflict(fields)
            case .unrelated: throw MappingError.identityConflict(["patient identity"])
            }
        }
        func issuer(_ tag: Int) -> String? { first.element(for: tag)?.sequenceItems.first?.dataSet.strings(for: localNamespaceEntityID).first }
        study.accessionNumber = first.string(for: .accessionNumber).flatMap { $0.isEmpty ? nil : AssignedIdentifier(value: $0, authority: issuer(issuerOfAccessionNumberSequence)) }
        study.placerOrderNumber = first.strings(for: placerOrderNumber).first.map { AssignedIdentifier(value: $0, authority: issuer(0x0040_2026)) }
        study.fillerOrderNumber = first.strings(for: fillerOrderNumber).first.map { AssignedIdentifier(value: $0, authority: issuer(0x0040_2027)) }
        let attributes = first.element(for: 0x0040_0275)?.sequenceItems.first?.dataSet   // Request Attributes Sequence
        study.requestedProcedureID = attributes?.string(for: DicomWorkflowTag.requestedProcedureID) ?? first.strings(for: DicomWorkflowTag.requestedProcedureID).first
        study.studyID = first.strings(for: studyID).first
        study.description = first.string(for: .studyDescription)
        study.started = isoDateTime(da: first.string(for: .studyDate), tm: first.string(for: .studyTime))
        study.performedProcedureStepID = first.strings(for: DicomWorkflowTag.performedProcedureStepID).first
        if let referrer = first.string(for: .referringPhysicianName), !referrer.isEmpty {
            let parts = referrer.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            study.referringPhysician = ClinicalPractitioner(familyName: parts.first, givenName: parts.count > 1 ? parts[1] : nil)
        }
        var seriesOrder: [String] = []
        var grouped: [String: [DicomDataSet]] = [:]
        for dataset in datasets {
            let uid = dataset.string(for: .seriesInstanceUID) ?? ""
            if grouped[uid] == nil { seriesOrder.append(uid) }
            grouped[uid, default: []].append(dataset)
        }
        study.series = seriesOrder.map { uid in
            let members = grouped[uid]!.sorted { ($0.int(for: .instanceNumber) ?? 0) < ($1.int(for: .instanceNumber) ?? 0) }
            let classes = Dictionary(members.compactMap { dataset -> (String, String)? in
                guard let instanceUID = dataset.string(for: .sopInstanceUID), let sopClass = dataset.string(for: .sopClassUID),
                      !instanceUID.isEmpty, !sopClass.isEmpty else { return nil }
                return (instanceUID, sopClass)
            }, uniquingKeysWith: { first, _ in first })
            return ClinicalStudy.Series(uid: uid, number: members[0].int(for: .seriesNumber), modality: members[0].string(for: .modality),
                                        description: members[0].string(for: .seriesDescription), instanceUIDs: members.compactMap { $0.string(for: .sopInstanceUID) },
                                        sopClassUIDs: classes.isEmpty ? nil : classes)
        }
        study.modalities = Array(NSOrderedSet(array: study.series.compactMap(\.modality))) as? [String] ?? []
        report.add(.mapped("datasets", "study"))
        if study.accessionNumber == nil { report.add(.absent("study.accessionNumber")) }
        let digest = Data(SHA256.hash(data: Data(datasets.compactMap { $0.string(for: .sopInstanceUID) }.joined(separator: "|").utf8))).map { String(format: "%02x", $0) }.joined()
        return Mapped(value: study, provenance: .init(sourceKind: .dicom, sourceIdentifier: studyUID, sourceDigest: digest, mapper: mapperName, report: report))
    }

    // MARK: performed procedure step

    public static func performedStep(order: ClinicalOrder?, study: ClinicalStudy, stationAETitle: String, status: DicomMPPSStatus = .inProgress,
                                     worklistItem: DicomModalityWorklistItem? = nil) -> DicomMPPSCreateRequest {
        let (date, time) = dicomDateTime(study.started)
        return DicomMPPSCreateRequest(status: status, performedStationAETitle: stationAETitle,
                                      performedProcedureStepID: study.performedProcedureStepID ?? (order?.requestedProcedureID ?? study.accessionNumber?.value).map { $0 + "-P1" },
                                      performedProcedureStepDescription: study.description ?? order?.procedureDescription, startDate: date, startTime: time, worklistItem: worklistItem)
    }

    // MARK: result <-> SR

    public static let textReportTemplate = "2000"

    /// Basic Text SR (TID 2000 shape): title, observations as NUM/CODE/TEXT items, report text and evidence.
    public static func structuredReport(from result: ClinicalResult, options: MappingOptions = .init()) throws -> Mapped<DicomSRDocument> {
        var report = MappingReport()
        var children: [DicomSRContentItem] = []
        for (index, observation) in result.observations.enumerated() {
            let concept = DicomCodedConcept(codeValue: observation.code.code, codingSchemeDesignator: observation.code.system.map(codingScheme) ?? "99ISIS", codeMeaning: observation.code.display ?? observation.code.code)
            switch observation.value {
            case .numeric(let value, let unit):
                guard let number = Double(value) else { report.add(.lost("result.observations[\(index)]", reason: "numericNotParseable")); continue }
                children.append(DicomSRContentItem(relationshipType: "CONTAINS", valueType: "NUM", conceptName: concept, numericValue: number,
                                                   measurementUnits: DicomCodedConcept(codeValue: unit ?? "1", codingSchemeDesignator: "UCUM", codeMeaning: unit ?? "no units")))
                if Double(value).map({ String($0) }) != value { report.add(.changed("result.observations[\(index)].value", "NUM", reason: "decimalLexicalNormalized")) }
            case .coded(let code):
                children.append(DicomSRContentItem(relationshipType: "CONTAINS", valueType: "CODE", conceptName: concept,
                                                   codeValue: DicomCodedConcept(codeValue: code.code, codingSchemeDesignator: code.system.map(codingScheme) ?? "99ISIS", codeMeaning: code.display ?? code.code)))
            case .text(let text):
                children.append(DicomSRContentItem(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: text))
            case .absent(let reason):
                report.add(.changed("result.observations[\(index)]", "SR", reason: "absentValue:" + reason))
            }
            report.add(.mapped("result.observations[\(index)]", "SR content item"))
        }
        if !result.reportText.isEmpty {
            children.append(DicomSRContentItem(relationshipType: "CONTAINS", valueType: "TEXT",
                                               conceptName: DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding"),
                                               textValue: result.reportText.joined(separator: "\n")))
            report.add(.mapped("result.reportText", "SR TEXT"))
        }
        let title = DicomCodedConcept(codeValue: result.procedure?.code ?? "18748-4", codingSchemeDesignator: result.procedure?.system.map(codingScheme) ?? "LN", codeMeaning: result.procedure?.display ?? "Diagnostic imaging study")
        let root = DicomSRContentItem(valueType: "CONTAINER", conceptName: title, continuityOfContent: "SEPARATE", children: children)
        let evidence = result.studyInstanceUID.map { [DicomKeyObjectReference(studyInstanceUID: $0, referencedSOPClassUID: nil, referencedSOPInstanceUID: nil)] } ?? []
        let completion: String = result.status == .preliminary ? "PARTIAL" : "COMPLETE"
        let verification: String = result.status == .final || result.status == .corrected ? "VERIFIED" : "UNVERIFIED"
        if result.status == .corrected {
            report.add(.changed("result.status", "(0040,A491)/(0040,A493)", reason: "correctedNotDistinguishableFromFinal"))
        }
        if result.supersedes != nil { report.add(.lost("result.supersedes", reason: "noTargetInProfile")) }
        let document = DicomSRDocument(sopClassUID: DicomSRDocument.basicTextSRStorageSOPClassUID, modality: "SR", contentLabel: "REPORT",
                                       contentDescription: result.procedure?.display, completionFlag: completion, verificationFlag: verification,
                                       templateIdentifier: textReportTemplate, root: root, evidenceReferences: evidence)
        if result.author != nil { report.add(.lost("result.author", reason: "verifyingObserverNotEmitted")) }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        return Mapped(value: document, provenance: .init(sourceKind: .dicom, sourceIdentifier: result.identifier?.description ?? "result", mapper: mapperName, report: report))
    }

    static func codingScheme(_ system: String) -> String {
        switch system {
        case "http://loinc.org", "LN": return "LN"
        case "http://snomed.info/sct", "SCT", "SRT": return "SCT"
        case "http://unitsofmeasure.org", "UCUM": return "UCUM"
        case "http://dicom.nema.org/resources/ontology/DCM", "DCM": return "DCM"
        default: return system.count <= 16 ? system : "99ISIS"
        }
    }

    static func system(_ scheme: String?) -> String? {
        switch scheme {
        case "LN": return "http://loinc.org"
        case "SCT", "SRT": return "http://snomed.info/sct"
        case "UCUM": return "http://unitsofmeasure.org"
        case "DCM": return "http://dicom.nema.org/resources/ontology/DCM"
        default: return scheme
        }
    }

    /// Reads a text/measurement SR back into a result (patient/order identifiers come from the dataset when supplied).
    public static func result(from document: DicomSRDocument, dataset: DicomDataSet? = nil) -> Mapped<ClinicalResult> {
        var report = MappingReport()
        var patient = ClinicalPatientIdentity()
        if let dataset { patient = identity(from: dataset, report: &report) }
        var result = ClinicalResult(patient: patient)
        if let dataset {
            func issuer(_ tag: Int) -> String? { dataset.element(for: tag)?.sequenceItems.first?.dataSet.strings(for: localNamespaceEntityID).first }
            result.accessionNumber = dataset.string(for: .accessionNumber).flatMap { $0.isEmpty ? nil : AssignedIdentifier(value: $0, authority: issuer(issuerOfAccessionNumberSequence)) }
            result.studyInstanceUID = dataset.string(for: .studyInstanceUID)
            result.identifier = dataset.string(for: .sopInstanceUID).map { AssignedIdentifier(value: $0, authority: "urn:dicom:uid") }
        }
        if result.studyInstanceUID == nil { result.studyInstanceUID = document.evidenceReferences.first?.studyInstanceUID }
        if let concept = document.root.conceptName { result.procedure = ClinicalCode(system: system(concept.codingSchemeDesignator), code: concept.codeValue, display: concept.codeMeaning) }
        result.status = document.completionFlag == "PARTIAL" ? .preliminary : (document.verificationFlag == "VERIFIED" ? .final : .preliminary)
        var texts: [String] = []
        for item in document.root.children {
            guard let concept = item.conceptName else { continue }
            let code = ClinicalCode(system: system(concept.codingSchemeDesignator), code: concept.codeValue, display: concept.codeMeaning)
            switch item.valueType {
            case "NUM":
                guard let number = item.numericValue else { continue }
                result.observations.append(.init(code: code, value: .numeric(value: Self.lexical(number), unit: item.measurementUnits?.codeValue)))
            case "CODE":
                guard let value = item.codeValue else { continue }
                result.observations.append(.init(code: code, value: .coded(ClinicalCode(system: system(value.codingSchemeDesignator), code: value.codeValue, display: value.codeMeaning))))
            case "TEXT":
                if concept.codeValue == "121071", let text = item.textValue { texts.append(contentsOf: text.split(separator: "\n").map(String.init)) }
                else if let text = item.textValue { result.observations.append(.init(code: code, value: .text(text))) }
            default:
                report.add(.lost("SR " + item.valueType, reason: "valueTypeUnsupported"))
            }
        }
        result.reportText = texts
        report.add(.mapped("SR", "result"))
        return Mapped(value: result, provenance: .init(sourceKind: .dicom, sourceIdentifier: document.sopInstanceUID ?? "SR", mapper: mapperName, report: report))
    }

    static func lexical(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}
