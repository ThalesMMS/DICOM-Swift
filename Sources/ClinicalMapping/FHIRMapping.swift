import Foundation
import FHIR

/// FHIR <-> clinical model. Identifiers keep their `system`/assigner, references are built from
/// identifiers or supplied references, and a `Provenance` resource records the mapping.
public enum FHIRClinicalMapper {
    public static let mapperName = "FHIRClinicalMapper/1"
    public static let placerType = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "PLAC")])
    public static let fillerType = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "FILL")])
    public static let accessionType = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "ACSN")])
    public static let mrnType = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "MR")])

    // MARK: identifiers

    static func identifier(_ assigned: AssignedIdentifier, type: FHIRCodeableConcept? = nil) -> FHIRIdentifier {
        var identifier = FHIRIdentifier(value: assigned.value)
        if let authority = assigned.authority {
            // A URI authority becomes the system; a local namespace is kept verbatim as the assigner display.
            if authority.contains("://") || authority.hasPrefix("urn:") { identifier.system = authority }
            else { identifier.json["assigner"] = ["display": .string(authority)] }
        }
        if let type { identifier.json["type"] = .object(type.json) }
        return identifier
    }

    static func assigned(_ identifier: FHIRIdentifier) -> AssignedIdentifier? {
        guard let value = identifier.value else { return nil }
        return AssignedIdentifier(value: value, authority: identifier.system ?? identifier.json["assigner"]?["display"]?.string)
    }

    static func identifiers(ofType code: String, in identifiers: [FHIRIdentifier]) -> [FHIRIdentifier] {
        identifiers.filter { $0.type?.codings.contains { $0.code == code } ?? false }
    }

    static func code(_ clinical: ClinicalCode?) -> FHIRCodeableConcept? {
        clinical.map { FHIRCodeableConcept(codings: [FHIRCoding(system: $0.system, code: $0.code, display: $0.display)], text: $0.display) }
    }

    static func clinicalCode(_ concept: FHIRCodeableConcept?) -> ClinicalCode? {
        guard let coding = concept?.codings.first, let code = coding.code else { return nil }
        return ClinicalCode(system: coding.system, code: code, display: coding.display ?? concept?.text)
    }

    /// FHIR dateTime needs a zone once a time is present; without one the time is dropped and reported.
    static func fhirDateTime(_ iso: String?, target: String, report: inout MappingReport) -> String? {
        guard let iso else { return nil }
        guard iso.contains("T") else { return iso }
        if iso.hasSuffix("Z") || iso.range(of: "[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil { return iso }
        report.add(.changed("dateTime", target, reason: "timeDroppedWithoutTimeZone"))
        return String(iso.prefix(10))
    }

    static func fhirInstant(_ iso: String?) -> String? {
        guard let iso else { return nil }
        if iso.hasSuffix("Z") || iso.range(of: "T.*[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil { return iso }
        return nil
    }

    static func display(_ practitioner: ClinicalPractitioner) -> String? {
        let name = practitioner.displayName
        return name.isEmpty ? nil : name
    }

    static func fhirSex(_ sex: String?) -> String? {
        switch sex {
        case "M": return "male"
        case "F": return "female"
        case "O": return "other"
        default: return nil
        }
    }

    static func dicomSex(_ gender: String?) -> String? {
        switch gender {
        case "male": return "M"
        case "female": return "F"
        case "other": return "O"
        default: return nil
        }
    }

    // MARK: patient

    public static func patient(from identity: ClinicalPatientIdentity, id: String? = nil) -> Mapped<FHIRPatient> {
        var report = MappingReport()
        var patient = FHIRPatient(id: id)
        var identifiers: [FHIRIdentifier] = []
        if let primary = identity.identifier { identifiers.append(identifier(primary, type: mrnType)); report.add(.mapped("patient.identifier", "Patient.identifier")) }
        identifiers += identity.otherIdentifiers.map { identifier($0) }
        patient.identifiers = identifiers
        if identity.familyName != nil || identity.givenName != nil {
            patient.names = [FHIRHumanName(family: identity.familyName, given: identity.givenName.map { $0.split(separator: " ").map(String.init) } ?? [])]
            report.add(.mapped("patient.name", "Patient.name"))
        }
        if let gender = fhirSex(identity.sex) { patient.gender = gender; report.add(.mapped("patient.sex", "Patient.gender")) }
        if let birth = identity.birthDate { patient.birthDateText = birth; report.add(.mapped("patient.birthDate", "Patient.birthDate")) }
        return Mapped(value: patient, provenance: .init(sourceKind: .fhir, sourceIdentifier: patient.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    public static func identity(from patient: FHIRPatient) -> Mapped<ClinicalPatientIdentity> {
        var report = MappingReport()
        var identity = ClinicalPatientIdentity()
        let all = patient.identifiers
        let primary = identifiers(ofType: "MR", in: all).first ?? all.first
        identity.identifier = primary.flatMap(assigned)
        identity.otherIdentifiers = all.filter { $0.json != primary?.json }.compactMap(assigned)
        report.add(identity.identifier == nil ? .absent("patient.identifier") : .mapped("Patient.identifier", "patient.identifier"))
        if let name = patient.names.first(where: { $0.use == "official" }) ?? patient.names.first {
            identity.familyName = name.family
            identity.givenName = name.given.isEmpty ? nil : name.given.joined(separator: " ")
            report.add(.mapped("Patient.name", "patient.name"))
        }
        identity.sex = dicomSex(patient.gender)
        if patient.gender == "unknown" { report.add(.changed("Patient.gender", "patient.sex", reason: "unknownHasNoDICOMValue")) }
        identity.birthDate = patient.birthDateText
        return Mapped(value: identity, provenance: .init(sourceKind: .fhir, sourceIdentifier: patient.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    // MARK: order <-> ServiceRequest

    public static func serviceRequest(from order: ClinicalOrder, subject: String, id: String? = nil, options: MappingOptions = .init()) throws -> Mapped<FHIRServiceRequest> {
        var report = MappingReport()
        var request = FHIRServiceRequest(id: id)
        var identifiers: [FHIRIdentifier] = []
        if let placer = order.placerOrderNumber { identifiers.append(identifier(placer, type: placerType)); report.add(.mapped("order.placerOrderNumber", "ServiceRequest.identifier[PLAC]")) }
        if let filler = order.fillerOrderNumber { identifiers.append(identifier(filler, type: fillerType)); report.add(.mapped("order.fillerOrderNumber", "ServiceRequest.identifier[FILL]")) }
        if let accession = order.accessionNumber { identifiers.append(identifier(accession, type: accessionType)); report.add(.mapped("order.accessionNumber", "ServiceRequest.identifier[ACSN]")) }
        request.identifiers = identifiers
        switch order.status {
        case .requested, .scheduled: request.status = "active"
        case .inProgress: request.status = "active"
        case .completed: request.status = "completed"
        case .cancelled: request.status = "revoked"
        case .unknown: request.status = "unknown"
        }
        request.intent = "order"
        request.code = code(order.procedure) ?? order.procedureDescription.map { FHIRCodeableConcept(text: $0) }
        if request.code == nil { report.add(.absent("ServiceRequest.code")) } else { report.add(.mapped("order.procedure", "ServiceRequest.code")) }
        request.subject = FHIRReference(reference: subject)
        if let start = fhirDateTime(order.scheduledStart, target: "ServiceRequest.occurrenceDateTime", report: &report) { request.setChoice("occurrence", typeSuffix: "DateTime", value: .string(start)); report.add(.mapped("order.scheduledStart", "ServiceRequest.occurrenceDateTime")) }
        if let referrer = order.referringPhysician { request.requester = FHIRReference(display: display(referrer), identifier: referrer.identifier.map { identifier($0) }) }
        if let priority = order.priority {
            let mapped: String? = ["S": "stat", "A": "asap", "R": "routine", "P": "urgent", "T": "urgent"][priority.uppercased()]
            if let mapped { request.set("priority", string: mapped); report.add(.changed("order.priority", "ServiceRequest.priority", reason: "codeSystemTranslation")) }
            else { report.add(.lost("order.priority", reason: "codeSystemUnknown")) }
        }
        if let modality = order.modality {
            request.json["orderDetail"] = [.object(FHIRCodeableConcept(codings: [FHIRCoding(system: "http://dicom.nema.org/resources/ontology/DCM", code: modality)]).json)]
            report.add(.mapped("order.modality", "ServiceRequest.orderDetail"))
        }
        if let reason = order.reason { request.json["reasonCode"] = [.object(FHIRCodeableConcept(text: reason).json)] }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        return Mapped(value: request, provenance: .init(sourceKind: .fhir, sourceIdentifier: request.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    public static func order(from request: FHIRServiceRequest, patient: ClinicalPatientIdentity) -> Mapped<ClinicalOrder> {
        var report = MappingReport()
        var order = ClinicalOrder(patient: patient)
        let all = request.identifiers
        order.placerOrderNumber = identifiers(ofType: "PLAC", in: all).first.flatMap(assigned)
        order.fillerOrderNumber = identifiers(ofType: "FILL", in: all).first.flatMap(assigned)
        order.accessionNumber = identifiers(ofType: "ACSN", in: all).first.flatMap(assigned)
        if order.placerOrderNumber == nil, order.accessionNumber == nil, let untyped = all.first.flatMap(assigned) { order.placerOrderNumber = untyped; report.add(.changed("ServiceRequest.identifier", "order.placerOrderNumber", reason: "untypedIdentifierAssumedPlacer")) }
        order.procedure = clinicalCode(request.code)
        order.procedureDescription = request.code?.text
        if let occurrence = request.occurrence?.string { order.scheduledStart = occurrence }
        order.modality = request.json["orderDetail"]?.array?.first?.object.map { FHIRCodeableConcept(json: $0) }?.codings.first?.code
        order.priority = request.string("priority").flatMap { ["stat": "S", "asap": "A", "routine": "R", "urgent": "P"][$0] }
        switch request.status {
        case "completed": order.status = .completed
        case "revoked", "entered-in-error": order.status = .cancelled
        case "active": order.status = .requested
        default: order.status = .unknown
        }
        if let requester = request.requester { order.referringPhysician = ClinicalPractitioner(identifier: requester.identifier.flatMap(assigned), familyName: requester.display) }
        report.add(.mapped("ServiceRequest", "order"))
        return Mapped(value: order, provenance: .init(sourceKind: .fhir, sourceIdentifier: request.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    // MARK: study <-> ImagingStudy

    public static func imagingStudy(from study: ClinicalStudy, subject: String, basedOn: String? = nil, endpoint: String? = nil, id: String? = nil) -> Mapped<FHIRImagingStudy> {
        var report = MappingReport()
        var resource = FHIRImagingStudy(id: id)
        resource.identifiers = [FHIRIdentifier(system: "urn:dicom:uid", value: "urn:oid:" + study.studyInstanceUID)]
        if let accession = study.accessionNumber { resource.identifiers.append(identifier(accession, type: accessionType)); report.add(.mapped("study.accessionNumber", "ImagingStudy.identifier[ACSN]")) }
        resource.status = "available"
        resource.modalities = study.modalities.map { FHIRCoding(system: "http://dicom.nema.org/resources/ontology/DCM", code: $0) }
        resource.subject = FHIRReference(reference: subject)
        if let started = fhirDateTime(study.started, target: "ImagingStudy.started", report: &report) { resource.startedText = started }
        if let basedOn { resource.basedOn = [FHIRReference(reference: basedOn)] }
        if let endpoint { resource.endpoints = [FHIRReference(reference: endpoint)] }
        resource.numberOfSeries = study.series.count
        resource.numberOfInstances = study.instanceCount
        resource.description = study.description
        if let referrer = study.referringPhysician, let name = display(referrer) { resource.referrer = FHIRReference(display: name) }
        resource.series = study.series.map { series in
            var item = FHIRImagingStudySeries()
            item.uid = series.uid
            item.number = series.number
            item.modality = series.modality.map { FHIRCoding(system: "http://dicom.nema.org/resources/ontology/DCM", code: $0) }
            item.description = series.description
            item.numberOfInstances = series.instanceUIDs.count
            item.instances = series.instanceUIDs.map { uid in
                var instance = FHIRImagingStudyInstance()
                instance.uid = uid
                if let sopClass = series.sopClassUIDs?[uid], !sopClass.isEmpty {
                    instance.sopClass = FHIRCoding(system: FHIRImagingMapper.sopClassSystem, code: "urn:oid:" + sopClass)
                } else {
                    report.add(.absent("ImagingStudy.series.instance.sopClass", reason: "sourceSOPClassUIDAbsent"))
                }
                return instance
            }
            return item
        }
        report.add(.mapped("study", "ImagingStudy"))
        if study.placerOrderNumber != nil || study.fillerOrderNumber != nil { report.add(.lost("study.placer/fillerOrderNumber", reason: "carriedByServiceRequestNotImagingStudy")) }
        return Mapped(value: resource, provenance: .init(sourceKind: .fhir, sourceIdentifier: resource.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    public static func study(from resource: FHIRImagingStudy, patient: ClinicalPatientIdentity) throws -> Mapped<ClinicalStudy> {
        guard let uid = resource.studyInstanceUID else { throw MappingError.missingIdentifier("ImagingStudy.identifier[urn:dicom:uid]") }
        var report = MappingReport()
        var study = ClinicalStudy(studyInstanceUID: uid, patient: patient)
        study.accessionNumber = identifiers(ofType: "ACSN", in: resource.identifiers).first.flatMap(assigned)
        study.description = resource.description
        study.started = resource.startedText
        study.modalities = resource.modalities.compactMap(\.code)
        study.series = resource.series.compactMap { series in
            guard let uid = series.uid else { return nil }
            let classes = Dictionary(series.instances.compactMap { instance -> (String, String)? in
                guard let instanceUID = instance.uid, let code = instance.sopClass?.code, code.hasPrefix("urn:oid:") else { return nil }
                return (instanceUID, String(code.dropFirst(8)))
            }, uniquingKeysWith: { first, _ in first })
            return ClinicalStudy.Series(uid: uid, number: series.number, modality: series.modality?.code, description: series.description,
                                        instanceUIDs: series.instances.compactMap(\.uid), sopClassUIDs: classes.isEmpty ? nil : classes)
        }
        if let referrer = resource.referrer?.display { study.referringPhysician = ClinicalPractitioner(familyName: referrer) }
        report.add(.mapped("ImagingStudy", "study"))
        return Mapped(value: study, provenance: .init(sourceKind: .fhir, sourceIdentifier: resource.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    // MARK: result <-> DiagnosticReport + Observation

    public struct ReportBundle: Equatable, Sendable {
        public var report: FHIRDiagnosticReport
        public var observations: [FHIRObservation]
        public var provenance: FHIRResource
    }

    public static func diagnosticReport(from result: ClinicalResult, subject: String, basedOn: String? = nil, imagingStudy: String? = nil,
                                        idPrefix: String = "r", options: MappingOptions = .init()) throws -> Mapped<ReportBundle> {
        var report = MappingReport()
        var diagnostic = FHIRDiagnosticReport(id: idPrefix)
        var identifiers: [FHIRIdentifier] = []
        if let placer = result.placerOrderNumber { identifiers.append(identifier(placer, type: placerType)) }
        if let filler = result.fillerOrderNumber { identifiers.append(identifier(filler, type: fillerType)) }
        if let accession = result.accessionNumber { identifiers.append(identifier(accession, type: accessionType)) }
        if let own = result.identifier, !identifiers.contains(where: { $0.value == own.value }) { identifiers.append(identifier(own)) }
        diagnostic.identifiers = identifiers
        if !identifiers.isEmpty { report.add(.mapped("result.identifiers", "DiagnosticReport.identifier")) }
        switch result.status {
        case .preliminary: diagnostic.status = "preliminary"
        case .final: diagnostic.status = "final"
        case .corrected: diagnostic.status = "corrected"
        case .cancelled: diagnostic.status = "cancelled"
        case .unknown: diagnostic.status = "unknown"
        }
        diagnostic.categories = [FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v2-0074", code: "RAD")])]
        diagnostic.code = code(result.procedure) ?? FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "18748-4", display: "Diagnostic imaging study")])
        diagnostic.subject = FHIRReference(reference: subject)
        if let basedOn { diagnostic.json["basedOn"] = [.object(FHIRReference(reference: basedOn).json)] }
        if let issued = fhirInstant(result.issued) { diagnostic.issuedText = issued; report.add(.mapped("result.issued", "DiagnosticReport.issued")) }
        else if let effective = fhirDateTime(result.issued, target: "DiagnosticReport.effectiveDateTime", report: &report) { diagnostic.setChoice("effective", typeSuffix: "DateTime", value: .string(effective)); report.add(.changed("result.issued", "DiagnosticReport.effectiveDateTime", reason: "instantMappedToDateTime")) }
        if let imagingStudy { diagnostic.imagingStudies = [FHIRReference(reference: imagingStudy)] }
        else if let uid = result.studyInstanceUID { diagnostic.imagingStudies = [FHIRReference(identifier: FHIRIdentifier(system: "urn:dicom:uid", value: "urn:oid:" + uid))] }
        if let author = result.author { diagnostic.performers = [FHIRReference(display: display(author), identifier: author.identifier.map { identifier($0) })] }
        if !result.reportText.isEmpty { diagnostic.conclusion = result.reportText.joined(separator: "\n") }
        if result.status == .corrected, let supersedes = result.supersedes {
            diagnostic.json["extension"] = [.object(FHIRExtension(url: "http://isis.test/fhir/StructureDefinition/supersedes", valueSuffix: "Identifier", value: .object(identifier(supersedes).json)).json)]
            report.add(.mapped("result.supersedes", "DiagnosticReport.extension[supersedes]"))
        }
        var observations: [FHIRObservation] = []
        for (index, observation) in result.observations.enumerated() {
            var resource = FHIRObservation(id: idPrefix + "-obs\(index + 1)")
            resource.status = observation.status.map { ["F": "final", "P": "preliminary", "C": "corrected", "X": "cancelled", "I": "registered"][$0] ?? "unknown" } ?? diagnostic.status ?? "final"
            resource.code = code(observation.code)!
            resource.subject = FHIRReference(reference: subject)
            if let effective = fhirDateTime(observation.effective, target: "Observation.effectiveDateTime", report: &report) { resource.setEffective(dateTime: effective) }
            switch observation.value {
            case .numeric(let value, let unit):
                guard FHIRNumber.isValidLexical(value) else { report.add(.lost("result.observations[\(index)].value", reason: "numericNotParseable")); continue }
                resource.setValue(quantity: FHIRQuantity(value: FHIRNumber(lexical: value), unit: unit, system: unit == nil ? nil : "http://unitsofmeasure.org", code: unit))
            case .coded(let coded): resource.setValue(codeableConcept: code(coded)!)
            case .text(let text): resource.setValue(string: text)
            case .absent(let reason): resource.json["dataAbsentReason"] = .object(FHIRCodeableConcept(text: reason).json)
            }
            if let interpretation = observation.interpretation {
                resource.json["interpretation"] = [.object(FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation", code: interpretation)]).json)]
            }
            if let range = observation.referenceRange { resource.json["referenceRange"] = [["text": .string(range)]] }
            observations.append(resource)
            report.add(.mapped("result.observations[\(index)]", "Observation"))
        }
        diagnostic.results = observations.compactMap { $0.resource.relativeReference }.map { FHIRReference(reference: $0) }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        let provenanceResource = provenance(targets: [diagnostic.resource] + observations.map(\.resource), source: .init(sourceKind: .fhir, sourceIdentifier: diagnostic.resource.relativeReference ?? "", mapper: mapperName, report: report))
        let bundle = ReportBundle(report: diagnostic, observations: observations, provenance: provenanceResource)
        return Mapped(value: bundle, provenance: .init(sourceKind: .fhir, sourceIdentifier: diagnostic.resource.relativeReference ?? "", mapper: mapperName, report: report))
    }

    public static func result(from report: FHIRDiagnosticReport, observations: [FHIRObservation], patient: ClinicalPatientIdentity) -> Mapped<ClinicalResult> {
        var mapping = MappingReport()
        var result = ClinicalResult(patient: patient)
        let all = report.identifiers
        result.placerOrderNumber = identifiers(ofType: "PLAC", in: all).first.flatMap(assigned)
        result.fillerOrderNumber = identifiers(ofType: "FILL", in: all).first.flatMap(assigned)
        result.accessionNumber = identifiers(ofType: "ACSN", in: all).first.flatMap(assigned)
        result.identifier = result.fillerOrderNumber ?? all.first.flatMap(assigned)
        result.studyInstanceUID = report.imagingStudies.first?.identifier?.value.map { $0.hasPrefix("urn:oid:") ? String($0.dropFirst(8)) : $0 }
        result.procedure = clinicalCode(report.code)
        switch report.status {
        case "final": result.status = .final
        case "preliminary", "partial", "registered": result.status = .preliminary
        case "corrected", "amended", "appended": result.status = .corrected
        case "cancelled", "entered-in-error": result.status = .cancelled
        default: result.status = .unknown
        }
        result.issued = report.issuedText ?? report.effective?.string
        result.reportText = report.conclusion.map { $0.split(separator: "\n").map(String.init) } ?? []
        if let performer = report.performers.first { result.author = ClinicalPractitioner(identifier: performer.identifier.flatMap(assigned), familyName: performer.display) }
        if let supersedes = report.extensions(url: "http://isis.test/fhir/StructureDefinition/supersedes").first?.value?.view() as FHIRIdentifier? { result.supersedes = assigned(supersedes) }
        let referenced = Set(report.results.compactMap(\.reference))
        for observation in observations where referenced.isEmpty || referenced.contains(observation.resource.relativeReference ?? "") {
            guard let code = clinicalCode(observation.code) else { mapping.add(.lost("Observation.code", reason: "codeMissing")); continue }
            let value: ClinicalObservation.Value
            if let quantity = observation.valueQuantity, let number = quantity.value { value = .numeric(value: number.lexical, unit: quantity.code ?? quantity.unit) }
            else if let choice = observation.value, choice.typeName == "CodeableConcept", let concept: FHIRCodeableConcept = choice.view(), let coded = clinicalCode(concept) { value = .coded(coded) }
            else if let text = observation.value?.string { value = .text(text) }
            else if let reason = observation.dataAbsentReason?.text { value = .absent(reason: reason) }
            else { mapping.add(.lost("Observation.value[x]", reason: "valueTypeUnsupported")); continue }
            result.observations.append(.init(code: code, value: value, status: observation.status.map { ["final": "F", "preliminary": "P", "corrected": "C", "cancelled": "X"][$0] ?? "F" },
                                             effective: observation.effective?.string, interpretation: observation.interpretations.first?.codings.first?.code,
                                             referenceRange: observation.referenceRanges.first?.text))
        }
        mapping.add(.mapped("DiagnosticReport", "result"))
        return Mapped(value: result, provenance: .init(sourceKind: .fhir, sourceIdentifier: report.resource.relativeReference ?? "", mapper: mapperName, report: mapping))
    }

    // MARK: Provenance

    /// R4 `Provenance` targeting the produced resources with the agent, the mapper and the source entity.
    public static func provenance(targets: [FHIRResource], source: ClinicalProvenance, id: String? = nil) -> FHIRResource {
        var provenance = FHIRResource(resourceType: "Provenance", id: id)
        provenance.json["target"] = .array(targets.compactMap { $0.relativeReference }.map { .object(FHIRReference(reference: $0).json) })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        provenance.json["recorded"] = .string(formatter.string(from: source.recordedAt))
        provenance.json["activity"] = .object(FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/v3-DataOperation", code: "CREATE")]).json)
        provenance.json["agent"] = [[
            "type": .object(FHIRCodeableConcept(codings: [FHIRCoding(system: "http://terminology.hl7.org/CodeSystem/provenance-participant-type", code: "assembler")]).json),
            "who": .object(FHIRReference(display: source.agent + " " + source.mapper).json)
        ]]
        var entity = FHIRJSONObject()
        entity["role"] = .string("source")
        let sourceValue = source.sourceDigest ?? source.sourceIdentifier
        let sourceIdentifier = sourceValue.isEmpty ? nil : FHIRIdentifier(system: "urn:isis:source-digest", value: sourceValue)
        entity["what"] = .object(FHIRReference(display: source.sourceKind.rawValue + ":" + source.sourceIdentifier, identifier: sourceIdentifier).json)
        provenance.json["entity"] = [.object(entity)]
        var extensions: [FHIRJSON] = []
        for entry in source.report.entries {
            extensions.append(.object(FHIRExtension(url: "http://isis.test/fhir/StructureDefinition/mapping-" + entry.kind.rawValue, valueSuffix: "String",
                                                    value: .string([entry.source, entry.target, entry.reason].compactMap { $0 }.joined(separator: " -> "))).json))
        }
        if !extensions.isEmpty { provenance.json["extension"] = .array(extensions) }
        return provenance
    }
}
