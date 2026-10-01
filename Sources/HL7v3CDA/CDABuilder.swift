import Foundation

public enum CDABuildError: Error, Sendable {
    case invalid(CDAValidationReport)
    case missingSection
}

/// Fluent, XML-tree based CDA builder.  The builder keeps all generated IDs in
/// one namespace and writes the corresponding `text/reference` link whenever an
/// entry is added.
public final class CDADocumentBuilder {
    public let templateSet: CDATemplateRegistry
    public var allowInvalid: Bool
    public private(set) var document: ClinicalDocument
    private var narrativeCounter = 0
    private var entryCounter = 0
    private var usedXMLIDs: Set<String> = []
    private var hasSeededRecordTarget = true
    private var hasSeededAuthor = true

    public init(templateSet: CDATemplateRegistry = .builtIn, allowInvalid: Bool = false) {
        self.templateSet = templateSet
        self.allowInvalid = allowInvalid
        var root = XMLNode("ClinicalDocument")
        root.namespaces[""] = CDANamespace.hl7
        root.namespaces["xsi"] = CDANamespace.xsi
        self.document = ClinicalDocument(node: root)
        seedDefaults()
    }

    public convenience init(templateSet: [CDATemplate], allowInvalid: Bool = false) {
        self.init(templateSet: CDATemplateRegistry(templates: templateSet), allowInvalid: allowInvalid)
    }

    public convenience init(templateSet: CDATemplate, allowInvalid: Bool = false) {
        self.init(templateSet: [templateSet], allowInvalid: allowInvalid)
    }

    /// Adds the standard CDA header values.  Callers can provide typed HL7
    /// values; convenience string overloads are available below.
    @discardableResult
    public func header(id: II? = nil, code: CD? = nil, title: String? = nil, effectiveTime: TS? = nil,
                       confidentialityCode: CE? = nil, languageCode: String? = nil,
                       setId: II? = nil, versionNumber: INT? = nil) -> Self {
        document.id = id ?? document.id
        document.code = code ?? document.code
        if let title { document.title = ST(title) }
        document.effectiveTime = effectiveTime ?? document.effectiveTime
        document.confidentialityCode = confidentialityCode ?? document.confidentialityCode
        if let languageCode { document.node.replace("languageCode", with: [XMLNode("languageCode", attributes: ["code": languageCode])], order: ClinicalDocument.childOrder) }
        document.setId = setId ?? document.setId
        document.versionNumber = versionNumber ?? document.versionNumber
        installDocumentTemplateIDs()
        return self
    }

    @discardableResult
    public func header(idRoot: String, idExtension: String? = nil, code: String = "34133-9",
                       codeSystem: String = "2.16.840.1.113883.6.1", title: String = "Synthetic CDA",
                       effectiveTime: String = "20000101000000", confidentiality: String = "N",
                       languageCode: String = "en-US", setIdRoot: String? = nil, versionNumber: Int = 1) -> Self {
        document.node.replace("id", with: [XMLNode("id", attributes: ["root": idRoot].merging(idExtension.map { ["extension": $0] } ?? [:]) { _, new in new })], order: ClinicalDocument.childOrder)
        document.node.replace("code", with: [XMLNode("code", attributes: ["code": code, "codeSystem": codeSystem])], order: ClinicalDocument.childOrder)
        document.title = ST(title)
        document.node.replace("effectiveTime", with: [XMLNode("effectiveTime", attributes: ["value": effectiveTime])], order: ClinicalDocument.childOrder)
        document.node.replace("confidentialityCode", with: [XMLNode("confidentialityCode", attributes: ["code": confidentiality, "codeSystem": "2.16.840.1.113883.5.25"])], order: ClinicalDocument.childOrder)
        document.node.replace("languageCode", with: [XMLNode("languageCode", attributes: ["code": languageCode])], order: ClinicalDocument.childOrder)
        document.node.replace("setId", with: [XMLNode("setId", attributes: ["root": setIdRoot ?? idRoot])], order: ClinicalDocument.childOrder)
        document.node.replace("versionNumber", with: [XMLNode("versionNumber", attributes: ["value": String(versionNumber)])], order: ClinicalDocument.childOrder)
        installDocumentTemplateIDs()
        return self
    }

    @discardableResult
    public func header(patient: Patient? = nil, recordTarget: RecordTarget? = nil,
                       author: Author? = nil, custodian: Custodian? = nil,
                       legalAuthenticator: LegalAuthenticator? = nil,
                       encounter: EncompassingEncounter? = nil) -> Self {
        if let recordTarget { self.recordTarget(recordTarget) }
        else if let patient { self.patient(patient) }
        if let author { self.author(author) }
        if let custodian { self.custodian(custodian) }
        if let legalAuthenticator { self.legalAuthenticator(legalAuthenticator) }
        if let encounter { self.encounter(encounter) }
        return self
    }

    @discardableResult
    public func recordTarget(_ target: RecordTarget) -> Self {
        document.recordTargets = hasSeededRecordTarget ? [target] : document.recordTargets + [target]
        hasSeededRecordTarget = false
        return self
    }

    @discardableResult
    public func patient(_ patient: Patient, roleID: II? = nil) -> Self {
        var role = PatientRole()
        role.patient = patient
        role.node.replace("id", with: roleID.map { [$0.xml(named: "id")] } ?? [XMLNode("id", attributes: ["root": "2.25.2362", "extension": "patient"])], order: PatientRole.childOrder)
        var target = RecordTarget(); target.patientRole = role
        document.recordTargets = [target]
        hasSeededRecordTarget = false
        return self
    }

    @discardableResult
    public func author(_ value: Author) -> Self {
        document.authors = hasSeededAuthor ? [value] : document.authors + [value]
        hasSeededAuthor = false
        return self
    }
    @discardableResult
    public func custodian(_ value: Custodian) -> Self { document.custodian = value; return self }
    @discardableResult
    public func legalAuthenticator(_ value: LegalAuthenticator) -> Self { document.legalAuthenticator = value; return self }
    @discardableResult
    public func encounter(_ value: EncompassingEncounter) -> Self {
        var component = document.componentOf ?? ComponentOf()
        component.encompassingEncounter = value
        document.componentOf = component
        return self
    }

    /// Adds a section and invokes a section-scoped fluent configurator.
    @discardableResult
    public func section(template: CDATemplateReference? = nil, code: CD? = nil, title: String,
                        _ configure: ((CDASectionBuilder) -> Void)? = nil) -> Self {
        var value = Section()
        let selected = template ?? templateForSectionCode(code?.code)
        if let selected { value.templateIds = [selected.toII()] }
        if let code { value.code = code }
        value.title = ST(title)
        let scoped = CDASectionBuilder(section: value, owner: self)
        configure?(scoped)
        appendSection(scoped.section)
        return self
    }

    @discardableResult
    public func section(template: CDATemplate, code: CD? = nil, title: String,
                        _ configure: ((CDASectionBuilder) -> Void)? = nil) -> Self {
        section(template: template.id, code: code, title: title, configure)
    }

    @discardableResult
    public func section(template: CDATemplate, code: String, title: String,
                        _ configure: ((CDASectionBuilder) -> Void)? = nil) -> Self {
        section(template: template.id, code: code, title: title, configure)
    }

    @discardableResult
    public func section(template: CDATemplateReference? = nil, code: String, title: String,
                        _ configure: ((CDASectionBuilder) -> Void)? = nil) -> Self {
        let coded = try? CD(code: code, codeSystem: "2.16.840.1.113883.6.1")
        return section(template: template, code: coded, title: title, configure)
    }

    @discardableResult
    public func section(template: CDATemplateReference? = nil, code: String, title: String,
                        configure: (inout Section) -> Void) -> Self {
        var value = Section()
        let selected = template ?? templateForSectionCode(code)
        if let selected { value.templateIds = [selected.toII()] }
        value.code = try? CD(code: code, codeSystem: "2.16.840.1.113883.6.1")
        value.title = ST(title)
        configure(&value)
        reserveExistingXMLIDs(in: value.node)
        appendSection(value)
        return self
    }

    public func build() throws -> ClinicalDocument { try build(allowInvalid: allowInvalid) }

    public func build(allowInvalid: Bool) throws -> ClinicalDocument {
        let result = CDAValidator(templates: templateSet).validate(document)
        if !allowInvalid && !result.isValid { throw CDABuildError.invalid(result) }
        return document
    }

    fileprivate func nextNarrativeID() -> String {
        repeat { narrativeCounter += 1 } while usedXMLIDs.contains("narrative-\(narrativeCounter)")
        let result = "narrative-\(narrativeCounter)"
        usedXMLIDs.insert(result)
        return result
    }

    fileprivate func narrativeID(preferred: String?) -> String {
        guard let preferred, !preferred.isEmpty else { return nextNarrativeID() }
        if usedXMLIDs.insert(preferred).inserted { return preferred }
        var suffix = 2
        var candidate = "\(preferred)-\(suffix)"
        while !usedXMLIDs.insert(candidate).inserted {
            suffix += 1
            candidate = "\(preferred)-\(suffix)"
        }
        return candidate
    }

    fileprivate func reserveExistingXMLIDs(in node: XMLNode) {
        usedXMLIDs.formUnion(node.descendants().compactMap { $0[attribute: "ID"] })
    }

    fileprivate func nextEntryID() -> II {
        entryCounter += 1
        return (try? II(root: "2.25.2362", extension: "entry-\(entryCounter)")) ?? II(nullFlavor: .NI)
    }

    private func seedDefaults() {
        // The defaults are synthetic and contain no patient information.  They
        // make the fluent API useful for small examples while remaining valid
        // CDA header scaffolding until callers replace the values.
        document.node.replace("typeId", with: [XMLNode("typeId", attributes: ["root": "2.16.840.1.113883.1.3", "extension": "POCD_HD000040"])], order: ClinicalDocument.childOrder)
        document.node.replace("id", with: [XMLNode("id", attributes: ["root": "2.25.2362", "extension": "document"])], order: ClinicalDocument.childOrder)
        document.node.replace("code", with: [XMLNode("code", attributes: ["code": "34133-9", "codeSystem": "2.16.840.1.113883.6.1"])], order: ClinicalDocument.childOrder)
        document.title = ST("Synthetic CDA")
        document.node.replace("effectiveTime", with: [XMLNode("effectiveTime", attributes: ["value": "20000101000000"])], order: ClinicalDocument.childOrder)
        document.node.replace("confidentialityCode", with: [XMLNode("confidentialityCode", attributes: ["code": "N", "codeSystem": "2.16.840.1.113883.5.25"])], order: ClinicalDocument.childOrder)
        document.node.replace("languageCode", with: [XMLNode("languageCode", attributes: ["code": "en-US"])], order: ClinicalDocument.childOrder)
        document.node.replace("setId", with: [XMLNode("setId", attributes: ["root": "2.25.2362", "extension": "document-set"])], order: ClinicalDocument.childOrder)
        document.node.replace("versionNumber", with: [XMLNode("versionNumber", attributes: ["value": "1"])], order: ClinicalDocument.childOrder)
        document.node.replace("recordTarget", with: [XMLNode("recordTarget", children: [XMLNode("patientRole", children: [XMLNode("id", attributes: ["root": "2.25.2362", "extension": "patient"])])])], order: ClinicalDocument.childOrder)
        document.authors = [Author(node: XMLNode("author", children: [XMLNode("time", attributes: ["value": "20000101"]), XMLNode("assignedAuthor", children: [XMLNode("id", attributes: ["root": "2.25.2362", "extension": "author"])])]))]
        document.custodian = Custodian(node: XMLNode("custodian", children: [XMLNode("assignedCustodian", children: [XMLNode("representedCustodianOrganization", children: [XMLNode("id", attributes: ["root": "2.25.2362"]), XMLNode("name", text: "Synthetic Organization")])])]))
        installDocumentTemplateIDs()
    }

    private func installDocumentTemplateIDs() {
        let existing = document.templateIds
        let documentTemplates = templateSet.templates.filter { $0.kind == .document && $0.id.root != CDATemplateLibrary.baseDocument.id.root }
        guard let selected = documentTemplates.first?.id else { return }
        let refs = existing + (existing.contains { $0.root == selected.root } ? [] : [selected.toII()])
        document.templateIds = refs
    }

    private func templateForSectionCode(_ code: String?) -> CDATemplateReference? {
        guard let code else { return nil }
        return templateSet.templates.first { template in
            guard template.kind == .section else { return false }
            return template.constraints.first(where: { $0.id == "ccda.section.code.value" })?.fixedValue == code
        }?.id
    }

    private func appendSection(_ section: Section) {
        var body: StructuredBody
        if case .structured(let existing) = document.body { body = existing }
        else { body = StructuredBody(); document.body = .structured(body) }
        body.sections = body.sections + [section]
        document.body = .structured(body)
    }
}

public final class CDASectionBuilder {
    fileprivate var section: Section
    private weak var owner: CDADocumentBuilder?
    private var currentNarrativeID: String?

    fileprivate init(section: Section, owner: CDADocumentBuilder) {
        self.section = section
        self.owner = owner
        owner.reserveExistingXMLIDs(in: section.node)
    }

    public var value: Section {
        get { section }
        set { section = newValue }
    }

    public var sectionValue: Section {
        get { section }
        set { section = newValue }
    }

    @discardableResult
    public func narrative(_ text: String, id: String? = nil) -> Self {
        let identifier = owner?.narrativeID(preferred: id) ?? id ?? "narrative"
        var textNode = section.narrative ?? XMLNode("text")
        textNode.content.append(.element(XMLNode("paragraph", attributes: ["ID": identifier], text: text)))
        section.narrative = textNode
        currentNarrativeID = identifier
        return self
    }

    @discardableResult
    public func narrative(id: String, text: String) -> Self { narrative(text, id: id) }

    @discardableResult
    public func entry(_ entry: Entry) -> Self {
        if entry.node.children.contains(where: { $0.first("text")?.first("reference")?[attribute: "value"] != nil }) {
            section.entries = section.entries + [entry]
            return self
        }
        ensureNarrative()
        var value = entry
        if let currentNarrativeID {
            var node = value.node
            if let statementIndex = node.content.firstIndex(where: {
                if case .element(let child) = $0 {
                    return ["act", "encounter", "observation", "organizer", "procedure", "substanceAdministration", "supply"].contains(child.name.localName)
                }
                return false
            }), case .element(var statement) = node.content[statementIndex] {
                installNarrativeReference(&statement, id: currentNarrativeID)
                node.content[statementIndex] = .element(statement)
                value = Entry(node: node)
            }
        }
        section.entries = section.entries + [value]
        return self
    }

    @discardableResult
    public func entry(_ statement: CDAStatement, narrative: String? = nil) -> Self {
        let builtEntry = makeEntry(statement: statement.node, template: nil, code: nil, status: nil, effectiveTime: nil,
                              value: nil, narrative: narrative)
        return self.entry(builtEntry)
    }

    @discardableResult
    public func problemObservation(code: CD? = nil, value: CDAAnyValue? = nil,
                                   statusCode: String = "completed", effectiveTime: IVL_TS? = nil,
                                   narrative: String? = nil) -> Self {
        let statement = makeStatement("observation", template: CDATemplateLibrary.problemObservation.id,
                                      classCode: "OBS", moodCode: "EVN", code: code ?? syntheticCode("problem"), status: statusCode,
                                      effectiveTime: effectiveTime, value: value)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.problemObservation.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func medicationActivity(code: CD? = nil, statusCode: String = "active",
                                   effectiveTime: IVL_TS? = nil, narrative: String? = nil) -> Self {
        let statement = makeStatement("substanceAdministration", template: CDATemplateLibrary.medicationActivity.id,
                                      classCode: "SBADM", moodCode: "EVN", code: code ?? syntheticCode("medication"), status: statusCode,
                                      effectiveTime: effectiveTime, value: nil)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.medicationActivity.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func allergyObservation(code: CD? = nil, value: CDAAnyValue? = nil,
                                   statusCode: String = "completed", narrative: String? = nil) -> Self {
        let statement = makeStatement("observation", template: CDATemplateLibrary.allergyObservation.id,
                                      classCode: "OBS", moodCode: "EVN", code: code ?? syntheticCode("allergy"), status: statusCode,
                                      effectiveTime: nil, value: value)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.allergyObservation.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func resultOrganizer(code: CD? = nil, statusCode: String = "completed",
                                observations: [(CD?, CDAAnyValue?)] = [], narrative: String? = nil) -> Self {
        var node = makeStatement("organizer", template: CDATemplateLibrary.resultOrganizer.id,
                                 classCode: "BATTERY", moodCode: "EVN", code: code ?? syntheticCode("result"),
                                 status: statusCode, effectiveTime: nil, value: nil)
        let sourceObservations = observations.isEmpty ? [(syntheticCode("result-0"), CDAAnyValue?.none)] : observations
        for (index, pair) in sourceObservations.enumerated() {
            let observation = makeStatement("observation", template: CDATemplateLibrary.resultObservation.id,
                                            classCode: "OBS", moodCode: "EVN", code: pair.0 ?? syntheticCode("result-\(index)"),
                                            status: "completed", effectiveTime: nil, value: pair.1)
            node.content.append(.element(XMLNode("component", children: [observation])))
        }
        return entry(makeEntry(statement: node, template: CDATemplateLibrary.resultOrganizer.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func resultObservation(code: CD? = nil, value: CDAAnyValue? = nil,
                                  statusCode: String = "completed", narrative: String? = nil) -> Self {
        let statement = makeStatement("observation", template: CDATemplateLibrary.resultObservation.id,
                                      classCode: "OBS", moodCode: "EVN", code: code ?? syntheticCode("result"),
                                      status: statusCode, effectiveTime: nil, value: value)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.resultObservation.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func vitalSignsOrganizer(code: CD? = nil, statusCode: String = "completed",
                                    narrative: String? = nil) -> Self {
        let statement = makeStatement("organizer", template: CDATemplateLibrary.vitalSignsOrganizer.id,
                                      classCode: "CLUSTER", moodCode: "EVN", code: code ?? syntheticCode("vital"),
                                      status: statusCode, effectiveTime: nil, value: nil)
        var organizer = statement
        let observation = makeStatement("observation", template: CDATemplateLibrary.vitalSignsObservation.id,
                                        classCode: "OBS", moodCode: "EVN", code: syntheticCode("vital-0"),
                                        status: "completed", effectiveTime: nil, value: nil)
        organizer.content.append(.element(XMLNode("component", children: [observation])))
        return entry(makeEntry(statement: organizer, template: CDATemplateLibrary.vitalSignsOrganizer.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func vitalSignsObservation(code: CD? = nil, value: CDAAnyValue? = nil,
                                      statusCode: String = "completed", effectiveTime: IVL_TS? = nil,
                                      narrative: String? = nil) -> Self {
        let statement = makeStatement("observation", template: CDATemplateLibrary.vitalSignsObservation.id,
                                      classCode: "OBS", moodCode: "EVN", code: code ?? syntheticCode("vital"),
                                      status: statusCode, effectiveTime: effectiveTime, value: value)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.vitalSignsObservation.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    @discardableResult
    public func procedureActivity(code: CD? = nil, statusCode: String = "completed",
                                  effectiveTime: IVL_TS? = nil, narrative: String? = nil) -> Self {
        let statement = makeStatement("procedure", template: CDATemplateLibrary.procedureActivity.id,
                                      classCode: "PROC", moodCode: "EVN", code: code ?? syntheticCode("procedure"),
                                      status: statusCode, effectiveTime: effectiveTime, value: nil)
        return entry(makeEntry(statement: statement, template: CDATemplateLibrary.procedureActivity.id,
                               code: nil, status: nil, effectiveTime: nil, value: nil, narrative: narrative))
    }

    private func makeEntry(statement: XMLNode, template: CDATemplateReference?, code: CD?, status: String?,
                           effectiveTime: IVL_TS?, value: CDAAnyValue?, narrative: String?) -> Entry {
        var node = statement
        if let template, !node.elements("templateId").contains(where: { $0[attribute: "root"] == template.root }) {
            node.replace("templateId", with: [template.toXMLNode()], order: statementOrder(for: node.name.localName))
        }
        if node.first("id") == nil, let identifier = owner?.nextEntryID() { node.replace("id", with: [identifier.xml(named: "id")], order: statementOrder(for: node.name.localName)) }
        if let code { node.replace("code", with: [code.xml(named: "code")], order: statementOrder(for: node.name.localName)) }
        if let status { node.replace("statusCode", with: [XMLNode("statusCode", attributes: ["code": status])], order: statementOrder(for: node.name.localName)) }
        if let effectiveTime { node.replace("effectiveTime", with: [effectiveTimeXML(effectiveTime)], order: statementOrder(for: node.name.localName)) }
        if let value { node.replace("value", with: [value.node], order: statementOrder(for: node.name.localName)) }
        if let narrative { _ = self.narrative(narrative) }
        ensureNarrative()
        if let currentNarrativeID {
            installNarrativeReference(&node, id: currentNarrativeID)
        }
        return Entry(node: XMLNode("entry", attributes: ["typeCode": "DRIV"], children: [node]))
    }

    private func makeStatement(_ element: String, template: CDATemplateReference, classCode: String, moodCode: String,
                               code: CD?, status: String, effectiveTime: IVL_TS?, value: CDAAnyValue?) -> XMLNode {
        var node = XMLNode(element, attributes: ["classCode": classCode, "moodCode": moodCode])
        node.content.append(.element(template.toXMLNode()))
        if let id = owner?.nextEntryID() { node.content.append(.element(id.xml(named: "id"))) }
        if let code { node.content.append(.element(code.xml(named: "code"))) }
        node.content.append(.element(XMLNode("statusCode", attributes: ["code": status])))
        if let effectiveTime { node.content.append(.element(effectiveTimeXML(effectiveTime))) }
        if let value { node.content.append(.element(value.node)) }
        if element == "substanceAdministration" {
            node.content.append(.element(XMLNode("consumable", children: [
                XMLNode("manufacturedProduct", children: [
                    XMLNode("manufacturedMaterial", children: [
                        XMLNode("code", attributes: ["code": "synthetic-medication", "codeSystem": "2.25.2362"])
                    ])
                ])
            ])))
        }
        return node
    }

    private func effectiveTimeXML(_ value: IVL_TS) -> XMLNode {
        var node = value.node
        node.name = XMLName("effectiveTime", namespaceURI: CDANamespace.hl7)
        return node
    }

    private func installNarrativeReference(_ node: inout XMLNode, id: String) {
        let link = XMLNode("text", children: [XMLNode("reference", attributes: ["value": "#\(id)"])])
        if node.name.localName != "organizer" {
            node.replace("text", with: [link], order: statementOrder(for: node.name.localName))
            return
        }
        // Organizer has no text slot in POCD_MT000040.  Attach the link to
        // its first component observation, which is the narrative-bearing
        // entry permitted by the schema.
        guard let componentIndex = node.content.firstIndex(where: {
            if case .element(let child) = $0 { return child.name.localName == "component" }
            return false
        }), case .element(var component) = node.content[componentIndex],
              let observationIndex = component.content.firstIndex(where: {
                  if case .element(let child) = $0 { return child.name.localName == "observation" }
                  return false
              }), case .element(var observation) = component.content[observationIndex] else { return }
        observation.replace("text", with: [link], order: Observation.childOrder)
        component.content[observationIndex] = .element(observation)
        node.content[componentIndex] = .element(component)
    }

    private func ensureNarrative() {
        if currentNarrativeID == nil { _ = narrative("Synthetic entry") }
    }

    private func syntheticCode(_ seed: String) -> CD {
        (try? CD(code: "synthetic-\(seed)", codeSystem: "2.25.2362")) ?? (try! CD(node: XMLNode("code", attributes: ["nullFlavor": "NI"])))
    }

    private func statementOrder(for name: String) -> [String] {
        switch name {
        case "observation": return Observation.childOrder
        case "organizer": return Organizer.childOrder
        case "substanceAdministration": return SubstanceAdministration.childOrder
        case "procedure": return Procedure.childOrder
        default: return Entry.childOrder
        }
    }
}

private extension CDATemplateReference {
    func toII() -> II {
        (try? II(root: root, extension: `extension`)) ?? II(nullFlavor: .NI)
    }
    func toXMLNode() -> XMLNode {
        var node = XMLNode("templateId", attributes: ["root": root])
        node[attribute: "extension"] = `extension`
        // Version dates belong to the profile metadata.  CDA II/templateId
        // has no validTime attribute, so it must not be emitted into XML.
        return node
    }
}
