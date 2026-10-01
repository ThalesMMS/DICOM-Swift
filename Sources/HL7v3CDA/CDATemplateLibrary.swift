import Foundation

/// Built-in structural profiles.  The identifiers are the public C-CDA R2.1
/// template identifiers published by HL7 (see
/// https://www.hl7.org/cda/usrealm/ and the C-CDA implementation guide at
/// https://build.fhir.org/ig/HL7/CDA-ccda/).  This library deliberately encodes
/// only the constraints that can be checked from a CDA XML tree; it is not a
/// claim of complete C-CDA conformance.
public enum CDATemplateLibrary {
    public static let baseDocument: CDATemplate = {
        CDATemplate(root: "2.16.840.1.113883.10.20", name: "CDA R2 Base Document", kind: .document,
                     constraints: [
                        .cardinality(id: "cda.base.typeId", path: "typeId", 1...1),
                        .cardinality(id: "cda.base.typeId.root", path: "typeId/@root", 1...1),
                        .cardinality(id: "cda.base.typeId.extension", path: "typeId/@extension", 1...1),
                        .cardinality(id: "cda.base.templateId", path: "templateId", min: 0, max: nil),
                        .cardinality(id: "cda.base.id", path: "id", 1...1),
                        .cardinality(id: "cda.base.id.root", path: "id/@root", 1...1),
                        .cardinality(id: "cda.base.code", path: "code", 1...1),
                        .cardinality(id: "cda.base.code.value", path: "code/@code", 1...1),
                        .cardinality(id: "cda.base.code.system", path: "code/@codeSystem", 1...1),
                        .cardinality(id: "cda.base.title", path: "title", 1...1),
                        .cardinality(id: "cda.base.effectiveTime", path: "effectiveTime", 1...1),
                        .cardinality(id: "cda.base.effectiveTime.value", path: "effectiveTime/@value", 1...1),
                        .dataType(id: "cda.base.effectiveTime.type", path: "effectiveTime", xsiType: "TS"),
                        .custom(id: "cda.base.effectiveTime.precision", path: "effectiveTime", closure: { node in
                            guard let raw = node[attribute: "value"] else { return false }
                            let core = raw.prefix(while: { $0.isNumber })
                            return core.count >= 8
                        }),
                        .cardinality(id: "cda.base.confidentialityCode", path: "confidentialityCode", 1...1),
                        .cardinality(id: "cda.base.confidentialityCode.value", path: "confidentialityCode/@code", 1...1),
                        .cardinality(id: "cda.base.confidentialityCode.system", path: "confidentialityCode/@codeSystem", 1...1),
                        .nullFlavorPolicy(id: "cda.base.confidentialityCode.nullFlavor", path: "confidentialityCode", policy: .forbidden),
                        .valueSet(id: "cda.base.confidentialityCode.values", path: "confidentialityCode/@code",
                                  binding: .required, codes: ["N", "R", "V", "D", "I"], codeSystem: "2.16.840.1.113883.5.25"),
                        .cardinality(id: "cda.base.recordTarget", path: "recordTarget", min: 1, max: nil),
                        .custom(id: "cda.base.recordTarget.patientID", path: "recordTarget", closure: { node in
                            node.first("patientRole")?.elements("id").filter { $0[attribute: "root"] != nil }.count == 1
                        }),
                        .valueSet(id: "cda.base.administrativeGender.values",
                                  path: "recordTarget/patientRole/patient/administrativeGenderCode/@code",
                                  binding: .extensible, codes: ["F", "M", "UN", "U"], codeSystem: "2.16.840.1.113883.5.1"),
                        .cardinality(id: "cda.base.custodian", path: "custodian", 1...1),
                        .cardinality(id: "cda.base.custodian.organizationID", path: "custodian/assignedCustodian/representedCustodianOrganization/id/@root", 1...1),
                        .cardinality(id: "cda.base.setId", path: "setId", 0...1),
                        .conditional(id: "cda.base.setId.present", when: "setId", then: [
                            .cardinality(id: "cda.base.setId.root", path: "setId/@root", 1...1)
                        ]),
                        .uniqueID(id: "cda.base.id.unique", path: "id"),
                        .cardinality(id: "cda.base.component", path: "component", 1...1),
                        .cardinality(id: "cda.base.versionNumber", path: "versionNumber", 0...1),
                        .conditional(id: "cda.base.versionNumber.present", when: "versionNumber", then: [
                            .cardinality(id: "cda.base.versionNumber.value", path: "versionNumber/@value", 1...1)
                        ]),
                        .custom(id: "cda.base.versionIdentifiers.paired", closure: { node in
                            (node.first("setId") != nil) == (node.first("versionNumber") != nil)
                        }),
                        .valueSet(id: "cda.base.versionNumber.type", path: "versionNumber/@value",
                                  binding: .preferred, codes: []),
                        .dataType(id: "cda.base.versionNumber.dataType", path: "versionNumber", xsiType: "INT")
                     ])
    }()

    public static let usRealmHeader: CDATemplate = CDATemplate(
        root: "2.16.840.1.113883.10.20.22.1.1", versionDate: "2015-08-01",
        name: "C-CDA R2.1 US Realm Header", kind: .document,
        inherits: [baseDocument.id], constraints: [
            .fixedValue(id: "ccda.header.typeId.root", path: "typeId/@root", value: "2.16.840.1.113883.1.3"),
            .fixedValue(id: "ccda.header.typeId.extension", path: "typeId/@extension", value: "POCD_HD000040"),
            .cardinality(id: "ccda.header.author", path: "author", min: 1, max: nil),
            .cardinality(id: "ccda.header.author.time", path: "author/time", min: 1, max: nil),
            .cardinality(id: "ccda.header.author.time.value", path: "author/time/@value", min: 1, max: nil)
        ])

    public static let continuityOfCareDocument: CDATemplate = CDATemplate(
        root: "2.16.840.1.113883.10.20.22.1.2", versionDate: "2015-08-01",
        name: "Continuity of Care Document", kind: .document,
        inherits: [usRealmHeader.id], constraints: [
            .fixedValue(id: "ccda.ccd.code", path: "code/@code", value: "34133-9"),
            .fixedValue(id: "ccda.ccd.codeSystem", path: "code/@codeSystem", value: "2.16.840.1.113883.6.1")
        ])

    public static let dischargeSummary: CDATemplate = CDATemplate(
        root: "2.16.840.1.113883.10.20.22.1.8", versionDate: "2015-08-01",
        name: "Discharge Summary", kind: .document,
        inherits: [usRealmHeader.id], constraints: [])

    private static func section(_ root: String, _ name: String, code: String, extension versionExtension: String? = nil,
                                inherits: [CDATemplateReference] = []) -> CDATemplate {
        CDATemplate(root: root, extension: versionExtension, versionDate: "2015-08-01", name: name, kind: .section,
                     inherits: inherits, constraints: [
                        .cardinality(id: "ccda.section.code", path: "code", 1...1),
                        .cardinality(id: "ccda.section.code.value.required", path: "code/@code", 1...1),
                        .cardinality(id: "ccda.section.code.system.required", path: "code/@codeSystem", 1...1),
                        .nullFlavorPolicy(id: "ccda.section.code.nullFlavor", path: "code", policy: .forbidden),
                        .fixedValue(id: "ccda.section.code.value", path: "code/@code", value: code),
                        .fixedValue(id: "ccda.section.code.system", path: "code/@codeSystem", value: "2.16.840.1.113883.6.1"),
                        .cardinality(id: "ccda.section.title", path: "title", 1...1),
                        .cardinality(id: "ccda.section.text", path: "text", 1...1),
                        .cardinality(id: "ccda.section.entry", path: "entry", min: 0, max: nil)
                     ])
    }

    public static let problemsSection = section("2.16.840.1.113883.10.20.22.2.5.1", "Problems Section", code: "11450-4")
    public static let medicationsSection = section("2.16.840.1.113883.10.20.22.2.1.1", "Medications Section", code: "10160-0")
    public static let allergiesSection = section("2.16.840.1.113883.10.20.22.2.6.1", "Allergies Section", code: "48765-2")
    public static let resultsSection = section("2.16.840.1.113883.10.20.22.2.3.1", "Results Section", code: "30954-2")
    public static let vitalSignsSection = section("2.16.840.1.113883.10.20.22.2.4.1", "Vital Signs Section", code: "8716-3", extension: "2015-08-01")
    public static let proceduresSection = section("2.16.840.1.113883.10.20.22.2.7.1", "Procedures Section", code: "47519-4")
    public static let encountersSection = section("2.16.840.1.113883.10.20.22.2.22.1", "Encounters Section", code: "46240-8")
    public static let planOfTreatmentSection = section("2.16.840.1.113883.10.20.22.2.10", "Plan of Treatment Section", code: "18776-5")

    private static func entry(_ root: String, _ name: String, element: String,
                              classCode: String? = nil, moodCode: String? = nil,
                              extension versionExtension: String? = nil,
                              inherits: [CDATemplateReference] = [], extra: [CDAConstraint] = []) -> CDATemplate {
        var constraints: [CDAConstraint] = [
            .cardinality(id: "ccda.entry.id", path: "id", 1...1),
            .cardinality(id: "ccda.entry.id.root", path: "id/@root", 1...1),
            .nullFlavorPolicy(id: "ccda.entry.id.nullFlavor", path: "id", policy: .forbidden),
            .cardinality(id: "ccda.entry.code", path: "code", 1...1),
            .cardinality(id: "ccda.entry.code.value", path: "code/@code", 1...1),
            .cardinality(id: "ccda.entry.code.system", path: "code/@codeSystem", 1...1),
            .nullFlavorPolicy(id: "ccda.entry.code.nullFlavor", path: "code", policy: .forbidden),
            .cardinality(id: "ccda.entry.statusCode", path: "statusCode", 1...1),
            .cardinality(id: "ccda.entry.statusCode.value", path: "statusCode/@code", 1...1),
            .nullFlavorPolicy(id: "ccda.entry.statusCode.nullFlavor", path: "statusCode", policy: .forbidden),
            .valueSet(id: "ccda.entry.statusCode.values", path: "statusCode/@code", binding: .required,
                      codes: ["active", "completed", "aborted", "cancelled", "held", "new", "normal", "suspended"]),
            .narrativeLinked(id: "ccda.entry.narrativeLinked", path: element == "organizer" ? "component/observation/text" : "text")
        ]
        if let classCode { constraints.append(.fixedValue(id: "ccda.entry.classCode", path: "@classCode", value: classCode)) }
        if let moodCode { constraints.append(.fixedValue(id: "ccda.entry.moodCode", path: "@moodCode", value: moodCode)) }
        constraints.append(.valueSet(id: "ccda.entry.moodCode.values", path: "@moodCode", binding: .required,
                                     codes: ["EVN", "INT", "PRMS", "ARQ", "RQO"]))
        constraints.append(contentsOf: extra)
        return CDATemplate(root: root, extension: versionExtension, versionDate: versionExtension ?? "2015-08-01", name: name, kind: .entry,
                            inherits: inherits, constraints: constraints)
    }

    public static let problemConcernAct = entry("2.16.840.1.113883.10.20.22.4.3", "Problem Concern Act", element: "act", classCode: "ACT", moodCode: "EVN")
    public static let problemObservation = entry("2.16.840.1.113883.10.20.22.4.4", "Problem Observation", element: "observation", classCode: "OBS", moodCode: "EVN")
    public static let medicationActivity = entry("2.16.840.1.113883.10.20.22.4.16", "Medication Activity", element: "substanceAdministration", classCode: "SBADM", moodCode: "EVN")
    public static let allergyConcernAct = entry("2.16.840.1.113883.10.20.22.4.30", "Allergy Concern Act", element: "act", classCode: "ACT", moodCode: "EVN")
    public static let allergyObservation = entry("2.16.840.1.113883.10.20.22.4.7", "Allergy Observation", element: "observation", classCode: "OBS", moodCode: "EVN")
    public static let resultOrganizer = entry("2.16.840.1.113883.10.20.22.4.1", "Result Organizer", element: "organizer", classCode: "BATTERY", moodCode: "EVN")
    public static let resultObservation = entry("2.16.840.1.113883.10.20.22.4.2", "Result Observation", element: "observation", classCode: "OBS", moodCode: "EVN")
    public static let vitalSignsOrganizer = entry("2.16.840.1.113883.10.20.22.4.26", "Vital Signs Organizer", element: "organizer", classCode: "CLUSTER", moodCode: "EVN", extension: "2015-08-01")
    public static let vitalSignsObservation = entry("2.16.840.1.113883.10.20.22.4.27", "Vital Signs Observation", element: "observation", classCode: "OBS", moodCode: "EVN", extension: "2014-06-09")
    public static let procedureActivity = entry("2.16.840.1.113883.10.20.22.4.14", "Procedure Activity", element: "procedure", classCode: "PROC", moodCode: "EVN")
    /// C-CDA R2.1 Planned Procedure (request/intent moods); used by the ORM transformation.
    public static let plannedProcedure = entry("2.16.840.1.113883.10.20.22.4.41", "Planned Procedure", element: "procedure", classCode: "PROC")

    public static let all: [CDATemplate] = [
        baseDocument, usRealmHeader, continuityOfCareDocument, dischargeSummary,
        problemsSection, medicationsSection, allergiesSection, resultsSection,
        vitalSignsSection, proceduresSection, encountersSection, planOfTreatmentSection,
        problemConcernAct, problemObservation, medicationActivity, allergyConcernAct,
        allergyObservation, resultOrganizer, resultObservation, vitalSignsOrganizer,
        vitalSignsObservation, procedureActivity, plannedProcedure
    ]

    public static let registry = CDATemplateRegistry(templates: all)
    public static let templateIDs: [CDATemplateReference] = all.map(\.id)
    public static let builtInTemplates = all
    public static let `default` = registry

    // Familiar short names keep profile selection readable while the longer
    // names above remain the canonical declarations.
    public static let ccd = continuityOfCareDocument
    public static let ccdTemplate = continuityOfCareDocument
    public static let usRealmHeaderTemplate = usRealmHeader
    public static let dischargeSummaryTemplate = dischargeSummary

    public static func template(for root: String) -> CDATemplate? { registry.template(root: root) }
    public static func template(for reference: CDATemplateReference) -> CDATemplate? { registry.template(for: reference) }
}

public typealias CDATemplates = CDATemplateLibrary
