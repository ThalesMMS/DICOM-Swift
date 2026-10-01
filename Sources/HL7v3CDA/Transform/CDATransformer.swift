import Foundation
import HL7v2

/// The v2/CDA bridge is deliberately profile-shaped rather than a general
/// terminology engine.  It preserves the source paths in a report and uses
/// null flavors for required CDA slots that have no source value.
public struct CDATransformResult: Sendable {
    public let document: ClinicalDocument
    public let report: CDATransformReport
    public init(document: ClinicalDocument, report: CDATransformReport) {
        self.document = document
        self.report = report
    }
}

public struct CDATransformV2Result: Sendable {
    public let message: HL7Message
    public let report: CDATransformReport
    public init(message: HL7Message, report: CDATransformReport) {
        self.message = message
        self.report = report
    }
}

public struct CDATransformer: Sendable {
    public var options: CDATransformOptions

    public init(options: CDATransformOptions = .init()) { self.options = options }

    public func v2ToCDA(_ message: HL7Message, profile: CDATransformProfile? = nil) throws -> CDATransformResult {
        try Self.v2ToCDA(message, profile: profile, options: options)
    }

    public func cdaToV2(_ document: ClinicalDocument, profile: CDATransformProfile,
                        version: HL7Version = .v2_5_1) throws -> CDATransformV2Result {
        try Self.cdaToV2(document, profile: profile, version: version, options: options)
    }

    public static func v2ToCDA(_ message: HL7Message, profile: CDATransformProfile? = nil,
                               options: CDATransformOptions = .init()) throws -> CDATransformResult {
        guard let selected = profile ?? CDATransformProfile(message: message.messageType.code ?? "") else {
            throw CDATransformError.unsupportedMessageType(message.messageType.code ?? "")
        }
        var report = CDATransformReport()
        let document: ClinicalDocument
        switch selected {
        case .adt: document = try makeADTDocument(message, report: &report)
        case .oru: document = try makeORUDocument(message, report: &report)
        case .orm: document = try makeORMDocument(message, report: &report)
        }
        return try finish(document: document, report: report, options: options)
    }

    public static func cdaToV2(_ document: ClinicalDocument, profile: CDATransformProfile,
                               version: HL7Version = .v2_5_1,
                               options: CDATransformOptions = .init()) throws -> CDATransformV2Result {
        var report = CDATransformReport()
        let message: HL7Message
        switch profile {
        case .oru: message = try makeORUMessage(document, version: version, report: &report)
        case .adt: message = try makeADTMessage(document, version: version, report: &report)
        case .orm:
            // CDA plan entries are procedure/observation requests.  The v2
            // profile has no reverse ORM requirement in this lot, so retain a
            // deterministic loss rather than silently choosing ORU semantics.
            report.add(.lost("ClinicalDocument/component/structuredBody", reason: "noTargetInProfile"))
            throw CDATransformError.unsupportedProfile("orm-reverse")
        }
        return try finish(message: message, report: report, options: options)
    }

    // Familiar verb aliases for callers that prefer a noun/verb API.
    public static func transformV2ToCDA(_ message: HL7Message, profile: CDATransformProfile? = nil,
                                       options: CDATransformOptions = .init()) throws -> CDATransformResult {
        try v2ToCDA(message, profile: profile, options: options)
    }

    public static func transformCDAToV2(_ document: ClinicalDocument, profile: CDATransformProfile,
                                       version: HL7Version = .v2_5_1,
                                       options: CDATransformOptions = .init()) throws -> CDATransformV2Result {
        try cdaToV2(document, profile: profile, version: version, options: options)
    }

    private static func finish(document: ClinicalDocument, report: CDATransformReport,
                               options: CDATransformOptions) throws -> CDATransformResult {
        if options.strict, report.hasLoss { throw CDATransformError.lossNotAllowed(report) }
        return .init(document: document, report: report)
    }

    private static func finish(message: HL7Message, report: CDATransformReport,
                               options: CDATransformOptions) throws -> CDATransformV2Result {
        if options.strict, report.hasLoss { throw CDATransformError.lossNotAllowed(report) }
        return .init(message: message, report: report)
    }
}

// MARK: - v2 to CDA

private extension CDATransformer {
    static let cdaOID = "2.25.2362"
    static let loincOID = "2.16.840.1.113883.6.1"
    static let administrativeGenderOID = CodeSystemTranslator.administrativeGenderCodeSystem
    static let hl7CodeOID = "2.16.840.1.113883.12"

    static func makeADTDocument(_ message: HL7Message, report: inout CDATransformReport) throws -> ClinicalDocument {
        let pid = first(message, named: "PID")
        let pv1 = first(message, named: "PV1")
        let evn = first(message, named: "EVN")
        var document = makeHeader(message, title: "Admission", report: &report)
        document.recordTargets = [makeRecordTarget(pid, report: &report)]
        document.authors = [makeAuthor(message, evn: evn, report: &report)]
        document.custodian = makeCustodian(message, report: &report)
        document.componentOf = makeEncompassingEncounter(pv1, evn: evn, report: &report)

        if let pid, hasValue(pid, 10) { report.add(.lost("PID-10", reason: "noTargetInProfile")) }
        for segment in message.segments where !["MSH", "EVN", "PID", "PV1"].contains(segment.name) {
            if segment.fields.contains(where: { field in field.isPresent && field.repetitions.contains { rep in
                rep.components.contains { component in component.subcomponents.contains { $0.text?.isEmpty == false } }
            } }) {
                report.add(.lost(segment.name, reason: "noTargetInProfile"))
            }
        }

        let section = makeSection(template: nil, code: "46240-8", title: "Encounters",
                                  narrative: ["Encounter"], entries: [])
        setBody(&document, sections: [section])
        report.add(.mapped("PV1", "ClinicalDocument/componentOf/encompassingEncounter"))
        return document
    }

    static func makeORUDocument(_ message: HL7Message, report: inout CDATransformReport) throws -> ClinicalDocument {
        let pid = first(message, named: "PID")
        let pv1 = first(message, named: "PV1")
        var document = makeHeader(message, title: "Results", report: &report)
        document.recordTargets = [makeRecordTarget(pid, report: &report)]
        document.authors = [makeAuthor(message, evn: nil, report: &report)]
        document.custodian = makeCustodian(message, report: &report)
        if let pv1 { document.componentOf = makeEncompassingEncounter(pv1, evn: nil, report: &report) }

        let groups = resultGroups(message)
        var entries: [Entry] = []
        var narrative: [String] = []
        if groups.isEmpty {
            report.add(.absent("Results section/entry", reason: "sourceNotPresent"))
        }
        for (index, group) in groups.enumerated() {
            let obrPath = "OBR[\(index + 1)]"
            let organizer = makeResultOrganizer(group.obr, index: index, report: &report)
            var statements = [CDAStatement]()
            for (obxIndex, obx) in group.obx.enumerated() {
                let observation = makeResultObservation(obx, index: obxIndex, report: &report)
                statements.append(.observation(observation))
                let text = text(obx, 5) ?? text(obx, 3) ?? "Result observation"
                narrative.append(text)
            }
            var organizerValue = organizer
            organizerValue.components = statements
            let entry = Entry(.organizer(organizerValue), typeCode: "DRIV")
            entries.append(entry)
            report.add(.mapped(obrPath, "Results/organizer[\(index + 1)]"))
            for nte in group.nte {
                let comment = text(nte, 3)
                if let comment { narrative.append(comment); report.add(.mapped("NTE-3", "Results/text")) }
            }
        }
        let section = makeSection(template: CDATemplateLibrary.resultsSection.id, code: "30954-2",
                                  title: "Results", narrative: narrative.isEmpty ? ["Results"] : narrative,
                                  entries: entries)
        setBody(&document, sections: [section])
        return document
    }

    static func makeORMDocument(_ message: HL7Message, report: inout CDATransformReport) throws -> ClinicalDocument {
        let pid = first(message, named: "PID")
        let pv1 = first(message, named: "PV1")
        var document = makeHeader(message, title: "Plan of Treatment", report: &report)
        document.recordTargets = [makeRecordTarget(pid, report: &report)]
        document.authors = [makeAuthor(message, evn: nil, report: &report)]
        document.custodian = makeCustodian(message, report: &report)
        if let pv1 { document.componentOf = makeEncompassingEncounter(pv1, evn: nil, report: &report) }

        let obrs = message.segments.filter { $0.name == "OBR" }
        var entries: [Entry] = []
        var narrative: [String] = []
        if obrs.isEmpty { report.add(.absent("Plan of Treatment/entry", reason: "sourceNotPresent")) }
        for (index, obr) in obrs.enumerated() {
            let code = codedValue(obr, 4)
            var node = XMLNode("procedure", attributes: ["classCode": "PROC", "moodCode": "RQO"])
            node.content.append(.element(templateNode(CDATemplateLibrary.plannedProcedure.id)))
            node.content.append(.element(idNode(identifier: text(obr, 2) ?? text(obr, 3), source: "OBR-2")))
            node.content.append(.element(codeNode(code, nullFlavor: code == nil ? .NI : nil)))
            let status = CodeSystemTranslator.resultStatus(text(obr, 25))
            if let statusValue = status.value {
                node.content.append(.element(XMLNode("statusCode", attributes: ["code": statusValue])))
                if status.changed { report.add(.changed("OBR-25", "Plan/entry[\(index + 1)]/procedure/statusCode", transformation: status.reason ?? "codeSystemTranslation")) }
            } else {
                node.content.append(.element(XMLNode("statusCode", attributes: ["nullFlavor": "NI"])))
                report.add(.absent("Plan/entry[\(index + 1)]/procedure/statusCode", reason: status.reason ?? "sourceNotPresent"))
            }
            if let time = timestampNode(text(obr, 7)) { node.content.append(.element(time)) } else {
                report.add(.absent("Plan/entry[\(index + 1)]/procedure/effectiveTime", reason: "sourceNotPresent"))
            }
            let statement = Procedure(node: node)
            entries.append(Entry(.procedure(statement), typeCode: "DRIV"))
            narrative.append(codedValue(obr, 4)?.text ?? "Planned procedure")
            report.add(.mapped("OBR-4", "Plan/entry[\(index + 1)]/procedure/code"))
        }
        let section = makeSection(template: CDATemplateLibrary.planOfTreatmentSection.id, code: "18776-5",
                                  title: "Plan of Treatment", narrative: narrative.isEmpty ? ["Plan"] : narrative,
                                  entries: entries)
        setBody(&document, sections: [section])
        return document
    }

    static func makeHeader(_ message: HL7Message, title: String,
                           report: inout CDATransformReport) -> ClinicalDocument {
        var root = XMLNode("ClinicalDocument")
        root.namespaces[""] = CDANamespace.hl7
        root.namespaces["xsi"] = CDANamespace.xsi
        var document = ClinicalDocument(node: root)
        document.node.replace("typeId", with: [XMLNode("typeId", attributes: ["root": "2.16.840.1.113883.1.3", "extension": "POCD_HD000040"])], order: ClinicalDocument.childOrder)
        document.templateIds = [(try? II(root: CDATemplateLibrary.usRealmHeader.id.root)) ?? II(nullFlavor: .NI)]
        let controlID = text(first(message, named: "MSH"), 10)
        document.id = idValue(identifier: controlID, source: "MSH-10")
        document.setId = idValue(identifier: controlID, source: "MSH-10")
        document.title = ST(title)
        document.code = (try? CD(code: title == "Results" ? "30954-2" : title == "Plan of Treatment" ? "18776-5" : "46240-8",
                                  codeSystem: loincOID, displayName: title))
        let timestamp = text(first(message, named: "MSH"), 7) ?? text(first(message, named: "EVN"), 2)
        if let timestamp, let value = try? TS(node: XMLNode("effectiveTime", attributes: ["value": timestamp])) {
            document.effectiveTime = value
            report.add(.mapped(text(first(message, named: "MSH"), 7) != nil ? "MSH-7" : "EVN-2", "ClinicalDocument/effectiveTime"))
        } else {
            document.node.replace("effectiveTime", with: [XMLNode("effectiveTime", attributes: ["nullFlavor": "NI"])], order: ClinicalDocument.childOrder)
            report.add(.absent("ClinicalDocument/effectiveTime", reason: "sourceNotPresent"))
        }
        document.confidentialityCode = try? CE(code: "N", codeSystem: "2.16.840.1.113883.5.25")
        document.node.replace("languageCode", with: [XMLNode("languageCode", attributes: ["code": "en-US"])], order: ClinicalDocument.childOrder)
        document.versionNumber = try? INT("1")
        document.node.replace("setId", with: [document.setId?.xml(named: "setId") ?? XMLNode("setId", attributes: ["nullFlavor": "NI"])], order: ClinicalDocument.childOrder)
        report.add(controlID == nil ? .absent("ClinicalDocument/id", reason: "sourceNotPresent") : .mapped("MSH-10", "ClinicalDocument/id"))
        return document
    }

    static func makeRecordTarget(_ pid: HL7Segment?, report: inout CDATransformReport) -> RecordTarget {
        var patientRole = PatientRole()
        let identifier = firstRepetition(pid, 3)
        let identifierValue = identifier?.components[safe: 0]?.subcomponents[safe: 0]?.text
        let authority = identifier.flatMap { HL7ExtendedID($0) }?.authority
        let root = authority?.universalID?.isEmpty == false ? authority!.universalID! : cdaOID
        var id = XMLNode("id", attributes: ["root": root])
        id[attribute: "extension"] = identifierValue
        id[attribute: "assigningAuthorityName"] = authority?.namespace
        patientRole.node.replace("id", with: [id], order: PatientRole.childOrder)
        if identifierValue == nil { patientRole.node.replace("id", with: [XMLNode("id", attributes: ["nullFlavor": "NI"])], order: PatientRole.childOrder); report.add(.absent("recordTarget/patientRole/id", reason: "sourceNotPresent")) }

        if let pid {
            let names = pid[5].repetitions.compactMap { rep -> PN? in
                let value = HL7PersonName(rep)
                guard let family = value?.family ?? value?.given else { return nil }
                var parts: [ENPart] = []
                if let given = value?.given, !given.isEmpty { parts.append(.init(part: "given", text: given)) }
                if !family.isEmpty { parts.append(.init(part: "family", text: family)) }
                // CDA PN has no "additional" part: middle names are further "given" parts.
                if let middle = value?.middle, !middle.isEmpty { parts.append(.init(part: "given", text: middle)) }
                if let prefix = value?.prefix, !prefix.isEmpty { parts.append(.init(part: "prefix", text: prefix)) }
                if let suffix = value?.suffix, !suffix.isEmpty { parts.append(.init(part: "suffix", text: suffix)) }
                return try? PN(parts: parts)
            }
            var patient = Patient()
            patient.names = names
            if names.isEmpty { patient.node.replace("name", with: [XMLNode("name", attributes: ["nullFlavor": "NI"])], order: Patient.childOrder); report.add(.absent("recordTarget/patientRole/patient/name", reason: "sourceNotPresent")) }
            let gender = CodeSystemTranslator.gender(text(pid, 8))
            if let value = gender.value {
                patient.node.replace("administrativeGenderCode", with: [XMLNode("administrativeGenderCode", attributes: ["code": value, "codeSystem": administrativeGenderOID])], order: Patient.childOrder)
                if gender.changed { report.add(.changed("PID-8", "recordTarget/patientRole/patient/administrativeGenderCode", transformation: gender.reason ?? "codeSystemTranslation")) }
            } else {
                patient.node.replace("administrativeGenderCode", with: [XMLNode("administrativeGenderCode", attributes: ["nullFlavor": "UNK"])], order: Patient.childOrder)
                report.add(.absent("recordTarget/patientRole/patient/administrativeGenderCode", reason: gender.reason ?? "sourceNotPresent"))
            }
            if let birth = text(pid, 7), let ts = try? TS(node: XMLNode("birthTime", attributes: ["value": birth])) {
                patient.birthTime = ts; report.add(.mapped("PID-7", "recordTarget/patientRole/patient/birthTime"))
            } else { patient.node.replace("birthTime", with: [XMLNode("birthTime", attributes: ["nullFlavor": "UNK"])], order: Patient.childOrder); report.add(.absent("recordTarget/patientRole/patient/birthTime", reason: "sourceNotPresent")) }
            patientRole.patient = patient
            if names.isEmpty { report.add(.absent("PID-5", reason: "sourceNotPresent")) } else { report.add(.mapped("PID-5", "recordTarget/patientRole/patient/name")) }
            if let address = pid[11].repetitions.first.flatMap(HL7Address.init) {
                patientRole.addresses = [makeAddress(address)]
                report.add(.mapped("PID-11", "recordTarget/patientRole/addr"))
            } else { report.add(.absent("recordTarget/patientRole/addr", reason: "sourceNotPresent")) }
            var telecomUseChanged = false
            let telecoms = pid[13].repetitions.compactMap { repetition -> TEL? in
                guard let value = HL7Telecom(repetition), let number = value.number, !number.isEmpty else { return nil }
                let use = CodeSystemTranslator.telecomUse(value.use)
                if use.changed || (value.use != nil && use.value == nil) { telecomUseChanged = true }
                return try? TEL(value: number, use: [use.value].compactMap { $0 })
            }
            if telecomUseChanged { report.add(.changed("PID-13.2", "recordTarget/patientRole/telecom/@use", transformation: "telecomUseTranslation")) }
            patientRole.telecoms = telecoms
            if telecoms.isEmpty { report.add(.absent("recordTarget/patientRole/telecom", reason: "sourceNotPresent")) } else { report.add(.mapped("PID-13", "recordTarget/patientRole/telecom")) }
        } else {
            report.add(.absent("PID", reason: "sourceNotPresent"))
            patientRole.patient = Patient(node: XMLNode("patient", children: [XMLNode("name", attributes: ["nullFlavor": "NI"]), XMLNode("administrativeGenderCode", attributes: ["nullFlavor": "UNK"])]))
        }
        var target = RecordTarget(); target.patientRole = patientRole
        return target
    }

    static func makeAddress(_ address: HL7Address) -> AD {
        var parts: [ADXP] = []
        if let street = address.street, !street.isEmpty, let value = try? ADXP(part: "streetAddressLine", text: street) { parts.append(value) }
        if let city = address.city, !city.isEmpty, let value = try? ADXP(part: "city", text: city) { parts.append(value) }
        if let state = address.state, !state.isEmpty, let value = try? ADXP(part: "state", text: state) { parts.append(value) }
        if let postal = address.postalCode, !postal.isEmpty, let value = try? ADXP(part: "postalCode", text: postal) { parts.append(value) }
        if let country = address.country, !country.isEmpty, let value = try? ADXP(part: "country", text: country) { parts.append(value) }
        // A nullFlavor-only address is always representable, so the fallback cannot fail.
        return (try? AD(parts: parts, use: ["HP"])) ?? (try? AD(node: XMLNode("addr", attributes: ["nullFlavor": "NI"])))!
    }

    static func makeAuthor(_ message: HL7Message, evn: HL7Segment?, report: inout CDATransformReport) -> Author {
        var node = XMLNode("author")
        let time = text(evn, 2) ?? text(first(message, named: "MSH"), 7)
        node.content.append(.element(XMLNode("time", attributes: time.map { ["value": $0] } ?? ["nullFlavor": "NI"])))
        let app = text(first(message, named: "MSH"), 3)
        let facility = text(first(message, named: "MSH"), 4)
        let assigned = XMLNode("assignedAuthor", children: [
            XMLNode("id", attributes: app.map { ["root": cdaOID, "extension": $0] } ?? ["nullFlavor": "NI"]),
            XMLNode("assignedAuthoringDevice", children: [XMLNode("manufacturerModelName", text: app ?? "")]),
            XMLNode("representedOrganization", children: [
                XMLNode("id", attributes: facility.map { ["root": cdaOID, "extension": $0] } ?? ["nullFlavor": "NI"]),
                XMLNode("name", text: facility ?? "")
            ])
        ])
        node.content.append(.element(assigned))
        report.add(app == nil ? .absent("MSH-3", reason: "sourceNotPresent") : .mapped("MSH-3", "author/assignedAuthor/assignedAuthoringDevice"))
        report.add(facility == nil ? .absent("MSH-4", reason: "sourceNotPresent") : .mapped("MSH-4", "custodian/assignedCustodian/representedCustodianOrganization"))
        return Author(node: node)
    }

    static func makeCustodian(_ message: HL7Message, report: inout CDATransformReport) -> Custodian {
        let facility = text(first(message, named: "MSH"), 4)
        let organization = XMLNode("representedCustodianOrganization", children: [
            XMLNode("id", attributes: facility.map { ["root": cdaOID, "extension": $0] } ?? ["nullFlavor": "NI"]),
            XMLNode("name", text: facility ?? "")
        ])
        return Custodian(node: XMLNode("custodian", children: [XMLNode("assignedCustodian", children: [organization])]))
    }

    static func makeEncompassingEncounter(_ pv1: HL7Segment?, evn: HL7Segment?, report: inout CDATransformReport) -> ComponentOf {
        var encounter = XMLNode("encompassingEncounter", attributes: ["classCode": "ENC"])
        let classValue = text(pv1, 2)
        encounter.content.append(.element(classValue.map { XMLNode("code", attributes: ["code": $0, "codeSystem": "2.16.840.1.113883.5.4"]) } ?? XMLNode("code", attributes: ["nullFlavor": "NI"])))
        let time = text(pv1, 44) ?? text(evn, 2)
        if let time, let value = timestampNode(time) { encounter.content.append(.element(value)); report.add(.mapped(pv1 != nil && text(pv1, 44) != nil ? "PV1-44" : "EVN-2", "componentOf/encompassingEncounter/effectiveTime")) }
        else { encounter.content.append(.element(XMLNode("effectiveTime", attributes: ["nullFlavor": "NI"]))); report.add(.absent("componentOf/encompassingEncounter/effectiveTime", reason: "sourceNotPresent")) }
        if let pv1, let attending = firstRepetition(pv1, 7), let provider = HL7PersonName(attending) {
            var performer = XMLNode("encounterParticipant", attributes: ["typeCode": "ATND"])
            let nameParts = [provider.given, provider.family].compactMap { $0 }.enumerated().map { index, value in XMLNode(index == 0 ? "given" : "family", text: value) }
            performer.content.append(.element(XMLNode("assignedEntity", children: [XMLNode("id", attributes: ["nullFlavor": "NI"]), XMLNode("assignedPerson", children: [XMLNode("name", children: nameParts)])])))
            encounter.content.append(.element(performer))
            report.add(.mapped("PV1-7", "componentOf/encompassingEncounter/encounterParticipant"))
        } else { report.add(.absent("componentOf/encompassingEncounter/encounterParticipant", reason: "sourceNotPresent")) }
        if let pv1, let location = text(pv1, 3) {
            let pieces = location.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
            encounter.content.append(.element(XMLNode("location", children: [XMLNode("healthCareFacility", children: [XMLNode("location", children: [XMLNode("name", text: pieces.filter { !$0.isEmpty }.joined(separator: " "))])])])) )
            report.add(.mapped("PV1-3", "componentOf/encompassingEncounter/location"))
        } else { report.add(.absent("componentOf/encompassingEncounter/location", reason: "sourceNotPresent")) }
        var component = ComponentOf(); component.encompassingEncounter = EncompassingEncounter(node: encounter)
        return component
    }

    static func makeSection(template: CDATemplateReference?, code: String?, title: String,
                            narrative: [String], entries: [Entry]) -> Section {
        var section = Section()
        if let template { section.templateIds = [(try? II(root: template.root)) ?? II(nullFlavor: .NI)] }
        if let code { section.code = try? CD(code: code, codeSystem: loincOID, displayName: title) }
        section.title = ST(title)
        var textNode = XMLNode("text")
        for (index, value) in narrative.enumerated() {
            textNode.content.append(.element(XMLNode("paragraph", attributes: ["ID": "cda-n\(index + 1)"], text: value)))
        }
        section.narrative = textNode
        var resultEntries = entries
        for index in resultEntries.indices {
            var entry = resultEntries[index]
            let referenceID = "cda-n\(min(index + 1, max(1, narrative.count)))"
            entry = attachNarrativeReference(entry, id: referenceID)
            resultEntries[index] = entry
        }
        section.entries = resultEntries
        return section
    }

    static func attachNarrativeReference(_ entry: Entry, id: String) -> Entry {
        var node = entry.node
        guard let statementIndex = node.content.firstIndex(where: {
            if case .element(let child) = $0 { return ["act", "encounter", "observation", "organizer", "procedure", "substanceAdministration", "supply"].contains(child.name.localName) }
            return false
        }), case .element(var statement) = node.content[statementIndex] else { return entry }
        if statement.name.localName == "organizer", let componentIndex = statement.content.firstIndex(where: {
            if case .element(let child) = $0 { return child.name.localName == "component" }
            return false
        }), case .element(var component) = statement.content[componentIndex], let observationIndex = component.content.firstIndex(where: {
            if case .element(let child) = $0 { return child.name.localName == "observation" }
            return false
        }), case .element(var observation) = component.content[observationIndex] {
            observation.replace("text", with: [XMLNode("text", children: [XMLNode("reference", attributes: ["value": "#\(id)"])])], order: Observation.childOrder)
            component.content[observationIndex] = .element(observation); statement.content[componentIndex] = .element(component)
        } else {
            statement.replace("text", with: [XMLNode("text", children: [XMLNode("reference", attributes: ["value": "#\(id)"])])], order: statementOrder(statement.name.localName))
        }
        node.content[statementIndex] = .element(statement)
        return Entry(node: node)
    }

    static func makeResultOrganizer(_ obr: HL7Segment, index: Int, report: inout CDATransformReport) -> Organizer {
        var node = XMLNode("organizer", attributes: ["classCode": "BATTERY", "moodCode": "EVN"])
        node.content.append(.element(templateNode(CDATemplateLibrary.resultOrganizer.id)))
        node.content.append(.element(idNode(identifier: text(obr, 3) ?? text(obr, 2), source: "OBR-3")))
        let code = codedValue(obr, 4)
        node.content.append(.element(codeNode(code, nullFlavor: code == nil ? .NI : nil)))
        if let code { report.add(.mapped("OBR-4", "Results/organizer[\(index + 1)]/code")) }
        else { report.add(.absent("Results/organizer[\(index + 1)]/code", reason: "sourceNotPresent")) }
        let status = CodeSystemTranslator.resultStatus(text(obr, 25))
        if let value = status.value {
            node.content.append(.element(XMLNode("statusCode", attributes: ["code": value])))
            if status.changed { report.add(.changed("OBR-25", "Results/organizer[\(index + 1)]/statusCode", transformation: status.reason ?? "codeSystemTranslation")) }
        } else { node.content.append(.element(XMLNode("statusCode", attributes: ["nullFlavor": "NI"]))); report.add(.absent("Results/organizer/statusCode", reason: status.reason ?? "sourceNotPresent")) }
        if let value = timestampInterval(text(obr, 7)) { node.content.append(.element(value)); report.add(.mapped("OBR-7", "Results/organizer/effectiveTime")) }
        else { report.add(.absent("Results/organizer/effectiveTime", reason: "sourceNotPresent")) }
        return Organizer(node: node)
    }

    static func makeResultObservation(_ obx: HL7Segment, index: Int, report: inout CDATransformReport) -> Observation {
        var node = XMLNode("observation", attributes: ["classCode": "OBS", "moodCode": "EVN"])
        node.content.append(.element(templateNode(CDATemplateLibrary.resultObservation.id)))
        let code = codedValue(obx, 3)
        node.content.append(.element(idNode(identifier: text(obx, 3), source: "OBX-3")))
        node.content.append(.element(codeNode(code, nullFlavor: code == nil ? .NI : nil)))
        if code != nil { report.add(.mapped("OBX-3", "Results/observation[\(index + 1)]/code")) } else { report.add(.absent("Results/observation/code", reason: "sourceNotPresent")) }
        let status = CodeSystemTranslator.resultStatus(text(obx, 11))
        if let value = status.value {
            node.content.append(.element(XMLNode("statusCode", attributes: ["code": value])))
            if status.changed { report.add(.changed("OBX-11", "Results/observation/statusCode", transformation: status.reason ?? "codeSystemTranslation")) }
        } else { node.content.append(.element(XMLNode("statusCode", attributes: ["nullFlavor": "NI"]))); report.add(.absent("Results/observation/statusCode", reason: status.reason ?? "sourceNotPresent")) }
        if let value = timestampNode(text(obx, 14)) { node.content.append(.element(value)); report.add(.mapped("OBX-14", "Results/observation/effectiveTime")) }
        let valueType = CodeSystemTranslator.valueType(text(obx, 2))
        if let typed = makeCDAValue(obx, type: text(obx, 2), report: &report) {
            node.content.append(.element(typed))
            if let sourceType = text(obx, 2), valueType.changed { report.add(.changed("OBX-2", "Results/observation/value", transformation: valueType.reason ?? "valueTypeTranslation")); _ = sourceType }
        } else {
            report.add(.lost("OBX-5", reason: valueType.reason ?? "valueTypeUnsupported"))
        }
        if let interpretation = text(obx, 8) {
            for flag in interpretation.split(whereSeparator: { $0 == "~" || $0 == " " }).map(String.init) {
                let translation = CodeSystemTranslator.abnormalFlag(flag)
                if let value = translation.value { node.content.append(.element(XMLNode("interpretationCode", attributes: ["code": value, "codeSystem": CodeSystemTranslator.observationInterpretationCodeSystem]))) }
                else { report.add(.lost("OBX-8", reason: translation.reason ?? "codeSystemUnknown")) }
            }
            report.add(.mapped("OBX-8", "Results/observation/interpretationCode"))
        } else { report.add(.absent("Results/observation/interpretationCode", reason: "sourceNotPresent")) }
        if let range = text(obx, 7) {
            let referenceRange = XMLNode("referenceRange", children: [XMLNode("observationRange", children: [XMLNode("text", text: range)])])
            node.content.append(.element(referenceRange)); report.add(.mapped("OBX-7", "Results/observation/referenceRange"))
        } else { report.add(.absent("Results/observation/referenceRange", reason: "sourceNotPresent")) }
        return Observation(node: node)
    }

    static func makeCDAValue(_ obx: HL7Segment, type: String?, report: inout CDATransformReport) -> XMLNode? {
        if type?.uppercased() == "SN" {
            let parts = obx[5][1].components.map { $0.subcomponents.first?.text ?? "" }
            guard let number = parts[safe: 1], let quantity = try? PQ(value: number, unit: text(obx, 6) ?? "1") else {
                report.add(.lost("OBX-5", reason: "valueTypeUnsupported")); return nil
            }
            if parts.first == "" || parts.first == "=" { return quantity.xml(named: "value", anyTyped: true) }
            return (try? IVL_PQ(low: parts.first == ">" || parts.first == ">=" ? quantity : nil,
                                high: parts.first == "<" || parts.first == "<=" ? quantity : nil))?.xml(named: "value", anyTyped: true)
        }
        guard let raw = text(obx, 5), !raw.isEmpty else { report.add(.absent("Results/observation/value", reason: "sourceNotPresent")); return nil }
        switch type?.uppercased() {
        case "NM":
            guard let value = try? PQ(value: raw, unit: text(obx, 6) ?? "1") else { report.add(.lost("OBX-5", reason: "invalidNumeric")); return nil }
            return value.xml(named: "value", anyTyped: true)
        case "CE", "CWE", "CNE":
            let value = codedValue(obx, 5) ?? parseCode(raw)
            guard let value else { report.add(.lost("OBX-5", reason: "codeSystemUnknown")); return nil }
            return (try? CD(code: value.identifier ?? raw, codeSystem: value.system, displayName: value.text))?.xml(named: "value", anyTyped: true)
        case "ST", "TX", "FT":
            return ST(raw).xml(named: "value", anyTyped: true)
        case "DT", "TM", "TS", "DTM":
            guard let value = try? TS(node: XMLNode("value", attributes: ["value": raw])) else { report.add(.lost("OBX-5", reason: "precisionReduced")); return nil }
            return value.xml(named: "value", anyTyped: true)
        default:
            report.add(.lost("OBX-2", reason: "valueTypeUnsupported")); return nil
        }
    }

    static func resultGroups(_ message: HL7Message) -> [(obr: HL7Segment, obx: [HL7Segment], nte: [HL7Segment])] {
        var result: [(HL7Segment, [HL7Segment], [HL7Segment])] = []
        var current: (HL7Segment, [HL7Segment], [HL7Segment])?
        for segment in message.segments {
            if segment.name == "OBR" {
                if let current { result.append(current) }
                current = (segment, [], [])
            } else if segment.name == "OBX", current != nil {
                current!.1.append(segment)
            } else if segment.name == "NTE", current != nil {
                current!.2.append(segment)
            }
        }
        if let current { result.append(current) }
        return result
    }
}

// MARK: - CDA to v2

private extension CDATransformer {
    static func makeORUMessage(_ document: ClinicalDocument, version: HL7Version,
                               report: inout CDATransformReport) throws -> HL7Message {
        var builder = HL7MessageBuilder(version: version)
        let patient = makePID(document, report: &report)
        let pv1 = makePV1(document, report: &report)
        let title = document.title?.text ?? "Results"
        builder.msh(sendingApp: document.custodian?.assignedCustodian?.representedCustodianOrganization?.names.first?.node.textContent ?? "",
                    sendingFacility: "", messageType: "ORU^R01", controlID: document.id?.extension ?? "CDA")
        builder.segment("PID") { value in value.segment = patient }
        builder.segment("PV1") { value in value.segment = pv1 }
        guard let sections = structuredSections(document), let section = sections.first(where: { $0.code?.code == "30954-2" || $0.title?.text?.lowercased().contains("result") == true }) else {
            report.add(.absent("Results section", reason: "sourceNotPresent"))
            return try builder.build(allowInvalid: true)
        }
        let organizers = section.entries.compactMap { $0.statement }.compactMap { statement -> Organizer? in if case .organizer(let organizer) = statement { return organizer }; return nil }
        if organizers.isEmpty { report.add(.absent("Results section/organizer", reason: "sourceNotPresent")) }
        for (organizerIndex, organizer) in organizers.enumerated() {
            let obr = makeOBR(organizer, index: organizerIndex, report: &report)
            builder.segment("OBR") { value in value.segment = obr }
            for (observationIndex, statement) in organizer.components.enumerated() {
                guard case .observation(let observation) = statement else { report.add(.lost("Results/organizer/component", reason: "noTargetInProfile")); continue }
                let obx = makeOBX(observation, index: observationIndex, report: &report)
                builder.segment("OBX") { value in value.segment = obx }
            }
        }
        return try builder.build(allowInvalid: true)
    }

    static func makeADTMessage(_ document: ClinicalDocument, version: HL7Version,
                               report: inout CDATransformReport) throws -> HL7Message {
        var builder = HL7MessageBuilder(version: version)
        let pid = makePID(document, report: &report)
        let pv1 = makePV1(document, report: &report)
        builder.msh(messageType: "ADT^A08", controlID: document.id?.extension ?? "CDA")
        var evn = HL7Segment(name: "EVN")
        evn[1] = HL7Field(.text("A08"))
        evn[2] = HL7Field(.text(document.effectiveTime?.value ?? ""))
        builder.adt(event: .A08, pid: pid, pv1: pv1, evn: evn)
        if document.recordTargets.first?.patientRole?.patient == nil { report.add(.absent("PID", reason: "sourceNotPresent")) }
        return try builder.build(allowInvalid: true)
    }

    static func makePID(_ document: ClinicalDocument, report: inout CDATransformReport) -> HL7Segment {
        var pid = HL7Segment(name: "PID")
        guard let role = document.recordTargets.first?.patientRole else { report.add(.absent("recordTarget/patientRole", reason: "sourceNotPresent")); return pid }
        let ids = role.ids
        if !ids.isEmpty {
            let repetitions = ids.compactMap { id -> HL7Repetition? in
                guard let value = id.extension else { return nil }
                return HL7Repetition(components: [HL7Component(subcomponents: [.text(value)]), HL7Component(), HL7Component(), HL7Component(subcomponents: [id.assigningAuthorityName.map { .text($0) } ?? .empty]), HL7Component(subcomponents: [.text("MR")])])
            }
            if !repetitions.isEmpty { pid[3] = HL7Field(repetitions: repetitions); report.add(.mapped("recordTarget/patientRole/id", "PID-3")) }
        }
        if let patient = role.patient {
            let names = patient.names.flatMap { name -> HL7Repetition? in
                let value = try? EN(node: name.node)
                let family = value?.parts.first(where: { $0.part == "family" })?.text ?? ""
                let givens = value?.parts.filter { $0.part == "given" }.map(\.text) ?? []
                let given = givens.first ?? ""
                let middle = givens.dropFirst().joined(separator: " ")
                let prefix = value?.parts.first(where: { $0.part == "prefix" })?.text ?? ""
                let suffix = value?.parts.first(where: { $0.part == "suffix" })?.text ?? ""
                return HL7Repetition(components: [HL7Component(subcomponents: [.text(family)]), HL7Component(subcomponents: [.text(given)]), HL7Component(subcomponents: [.text(middle)]), HL7Component(subcomponents: [.text(suffix)]), HL7Component(subcomponents: [.text(prefix)])])
            }
            if !names.isEmpty { pid[5] = HL7Field(repetitions: names); report.add(.mapped("recordTarget/patientRole/patient/name", "PID-5")) }
            if let birth = patient.birthTime?.value { pid[7] = HL7Field(.text(birth)); report.add(.mapped("recordTarget/patientRole/patient/birthTime", "PID-7")) }
            if let gender = patient.administrativeGenderCode?.code {
                let reverse = CodeSystemTranslator.reverseGender(gender)
                pid[8] = HL7Field(.text(reverse.value ?? "U")); report.add(reverse.value == nil ? .lost("administrativeGenderCode", reason: reverse.reason ?? "codeSystemUnknown") : .mapped("administrativeGenderCode", "PID-8"))
            }
        }
        if !role.addresses.isEmpty {
            let values = role.addresses.map { address in HL7Repetition(components: [HL7Component(subcomponents: [.text(address.parts.first(where: { $0.part == "streetAddressLine" })?.text ?? "")]), HL7Component(subcomponents: [.text("")]), HL7Component(subcomponents: [.text(address.parts.first(where: { $0.part == "city" })?.text ?? "")]), HL7Component(subcomponents: [.text(address.parts.first(where: { $0.part == "state" })?.text ?? "")]), HL7Component(subcomponents: [.text(address.parts.first(where: { $0.part == "postalCode" })?.text ?? "")]), HL7Component(subcomponents: [.text(address.parts.first(where: { $0.part == "country" })?.text ?? "")])]) }
            pid[11] = HL7Field(repetitions: values); report.add(.mapped("recordTarget/patientRole/addr", "PID-11"))
        }
        if !role.telecoms.isEmpty { pid[13] = HL7Field(repetitions: role.telecoms.map { HL7Repetition(components: [HL7Component(subcomponents: [.text($0.value ?? "")]), HL7Component(subcomponents: [.text(CodeSystemTranslator.reverseTelecomUse($0.use.first).value ?? "")])]) }); report.add(.mapped("recordTarget/patientRole/telecom", "PID-13")) }
        return pid
    }

    static func makePV1(_ document: ClinicalDocument, report: inout CDATransformReport) -> HL7Segment {
        var pv1 = HL7Segment(name: "PV1")
        if let encounter = document.componentOf?.encompassingEncounter {
            pv1[2] = HL7Field(.text(encounter.code?.code ?? "N"))
            if let time = encounter.effectiveTime?.low?.value ?? encounter.effectiveTime?.center?.value { pv1[44] = HL7Field(.text(time)); report.add(.mapped("encompassingEncounter/effectiveTime", "PV1-44")) }
            if encounter.node.first("location") != nil { report.add(.mapped("encompassingEncounter/location", "PV1-3")) }
        } else { pv1[2] = HL7Field(.text("N")); report.add(.absent("PV1-2", reason: "sourceNotPresent")) }
        return pv1
    }

    static func makeOBR(_ organizer: Organizer, index: Int, report: inout CDATransformReport) -> HL7Segment {
        var obr = HL7Segment(name: "OBR")
        obr[1] = HL7Field(.text(String(index + 1)))
        if let id = organizer.ids.first?.extension { obr[3] = HL7Field(.text(id)) }
        if let code = organizer.code { obr[4] = HL7Field(repetitions: [codedRepetition(code)]) ; report.add(.mapped("Results/organizer/code", "OBR-4")) } else { report.add(.absent("OBR-4", reason: "sourceNotPresent")) }
        if let value = organizer.effectiveTime?.low?.value ?? organizer.effectiveTime?.center?.value { obr[7] = HL7Field(.text(value)) }
        if let status = organizer.statusCode?.code {
            let translated = CodeSystemTranslator.reverseResultStatus(status)
            if let value = translated.value { obr[25] = HL7Field(.text(value)); report.add(.changed("Results/organizer/statusCode", "OBR-25", transformation: translated.reason ?? "codeSystemTranslation")) }
            else { report.add(.lost("Results/organizer/statusCode", reason: translated.reason ?? "codeSystemUnknown")) }
        }
        return obr
    }

    static func makeOBX(_ observation: Observation, index: Int, report: inout CDATransformReport) -> HL7Segment {
        var obx = HL7Segment(name: "OBX")
        obx[1] = HL7Field(.text(String(index + 1)))
        let value = observation.values.first
        let type: String
        switch value {
        case .pq: type = "NM"
        case .cd, .ce, .cs, .cv: type = "CE"
        case .st, .ed: type = "ST"
        case .ts: type = "TS"
        case .ivl_pq: type = "SN"
        default: type = "ST"
        }
        obx[2] = HL7Field(.text(type))
        if let code = observation.code { obx[3] = HL7Field(repetitions: [codedRepetition(code)]) ; report.add(.mapped("Results/observation/code", "OBX-3")) }
        switch value {
        case .pq(let pq):
            obx[5] = HL7Field(.text(pq.value ?? "")); if let unit = pq.unit { obx[6] = HL7Field(.text(unit)) }
        case .cd(let code): obx[5] = HL7Field(repetitions: [codedRepetition(code)])
        case .ce(let code): obx[5] = HL7Field(repetitions: [codedRepetition(code)])
        case .cs(let code): obx[5] = HL7Field(repetitions: [codedRepetition(code)])
        case .cv(let code): obx[5] = HL7Field(repetitions: [codedRepetition(code)])
        case .st(let string): obx[5] = HL7Field(.text(string.text ?? ""))
        case .ts(let time): obx[5] = HL7Field(.text(time.value ?? ""))
        case .ivl_pq(let interval):
            let comparator = interval.low != nil ? ">" : interval.high != nil ? "<" : ""
            let number = interval.low?.value ?? interval.high?.value ?? ""
            obx[5] = HL7Field(repetitions: [HL7Repetition(components: [HL7Component(subcomponents: [.text(comparator)]), HL7Component(subcomponents: [.text(number)])])])
        case .unknown:
            report.add(.lost("Results/observation/value", reason: "valueTypeUnsupported"))
        default: report.add(.lost("Results/observation/value", reason: "valueTypeUnsupported"))
        }
        if let status = observation.statusCode?.code, let translated = CodeSystemTranslator.reverseResultStatus(status).value { obx[11] = HL7Field(.text(translated)) }
        if let time = observation.effectiveTime?.low?.value ?? observation.effectiveTime?.center?.value { obx[14] = HL7Field(.text(time)) }
        if let interpretation = observation.node.elements("interpretationCode").compactMap({ $0[attribute: "code"] }).first { obx[8] = HL7Field(.text(interpretation)) }
        if let reference = observation.referenceRanges.first?.node.first("observationRange")?.first("text")?.textContent { obx[7] = HL7Field(.text(reference)) }
        return obx
    }
}

// MARK: - Shared helpers

private extension CDATransformer {
    static func first(_ message: HL7Message, named name: String) -> HL7Segment? { message.segments.first { $0.name == name } }
    static func text(_ segment: HL7Segment?, _ field: Int, _ component: Int = 1, repetition: Int = 1) -> String? {
        guard let value = segment?[field][repetition][component][1].text, !value.isEmpty else { return nil }
        return value
    }
    static func hasValue(_ segment: HL7Segment, _ field: Int) -> Bool { text(segment, field) != nil }
    static func firstRepetition(_ segment: HL7Segment?, _ field: Int) -> HL7Repetition? {
        guard let segment, segment[field].isPresent, !segment[field].repetitions.isEmpty else { return nil }
        return segment[field][1]
    }
    static func idValue(identifier: String?, source: String) -> II {
        guard let identifier, !identifier.isEmpty else { return II(nullFlavor: .NI) }
        return (try? II(root: cdaOID, extension: identifier)) ?? II(nullFlavor: .NI)
    }
    static func idNode(identifier: String?, source: String) -> XMLNode {
        guard let identifier, !identifier.isEmpty else { return XMLNode("id", attributes: ["nullFlavor": "NI"]) }
        return XMLNode("id", attributes: ["root": cdaOID, "extension": identifier])
    }
    static func codedValue(_ segment: HL7Segment, _ field: Int) -> HL7CodedElement? {
        guard let repetition = firstRepetition(segment, field) else { return nil }
        return HL7CodedElement(repetition)
    }
    static func parseCode(_ raw: String) -> HL7CodedElement? {
        let values = raw.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, !values[0].isEmpty else { return nil }
        return HL7CodedElement(identifier: values[0], text: values[safe: 1] ?? "", system: values[safe: 2] ?? "")
    }
    static func codeNode(_ value: HL7CodedElement?, nullFlavor: NullFlavor?) -> XMLNode {
        guard let value, let code = value.identifier, !code.isEmpty else { return XMLNode("code", attributes: ["nullFlavor": (nullFlavor ?? .NI).rawValue]) }
        var attributes = ["code": code]
        if let system = value.system, !system.isEmpty { attributes["codeSystem"] = system }
        if let display = value.text, !display.isEmpty { attributes["displayName"] = display }
        return XMLNode("code", attributes: attributes)
    }
    static func timestampNode(_ raw: String?) -> XMLNode? {
        guard let raw, let value = try? TS(node: XMLNode("effectiveTime", attributes: ["value": raw])) else { return nil }
        return value.xml(named: "effectiveTime")
    }
    static func timestampInterval(_ raw: String?) -> XMLNode? {
        guard let raw, let value = try? TS(node: XMLNode("low", attributes: ["value": raw])) else { return nil }
        return XMLNode("effectiveTime", children: [value.xml(named: "low")])
    }
    static func templateNode(_ reference: CDATemplateReference) -> XMLNode { XMLNode("templateId", attributes: ["root": reference.root]) }
    static func setBody(_ document: inout ClinicalDocument, sections: [Section]) {
        var body = StructuredBody(); body.sections = sections; document.body = .structured(body)
    }
    static func structuredSections(_ document: ClinicalDocument) -> [Section]? { guard case .structured(let body) = document.body else { return nil }; return body.sections }
    static func statementOrder(_ name: String) -> [String] {
        switch name {
        case "observation": return Observation.childOrder
        case "organizer": return Organizer.childOrder
        case "procedure": return Procedure.childOrder
        case "encounter": return Encounter.childOrder
        default: return Entry.childOrder
        }
    }
    static func codedRepetition<T: CodedDataType>(_ value: T) -> HL7Repetition {
        HL7Repetition(components: [HL7Component(subcomponents: [value.code.map { .text($0) } ?? .empty]), HL7Component(subcomponents: [value.displayName.map { .text($0) } ?? .empty]), HL7Component(subcomponents: [value.codeSystem.map { .text($0) } ?? .empty])])
    }
}

private extension HL7ExtendedID {
    init?(_ value: HL7Repetition) {
        self.init(value, definition: nil)
    }
}

private extension HL7PersonName {
    init?(_ value: HL7Repetition) {
        self.init(value, definition: nil)
    }
}

private extension HL7Address {
    init?(_ value: HL7Repetition) {
        self.init(value, definition: nil)
    }
}

private extension HL7Telecom {
    init?(_ value: HL7Repetition) {
        self.init(value, definition: nil)
    }
}

private extension HL7Repetition {
    subscript(safe index: Int) -> HL7Component? { components.indices.contains(index) ? components[index] : nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
