import Foundation

// Typed views for the resource subset covered by the toolkit. Every view exposes the elements
// used by imaging workflows and the reference; other elements stay reachable through the
// generic accessors and are preserved on round trips.

public struct FHIRPatient: FHIRResourceView {
    public static let resourceType = "Patient"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var active: Bool? { get { bool("active") } set { set("active", bool: newValue) } }
    public var names: [FHIRHumanName] { get { views("name") } set { set("name", views: newValue) } }
    public var telecoms: [FHIRContactPoint] { views("telecom") }
    public var gender: String? { get { string("gender") } set { set("gender", string: newValue) } }
    public var birthDate: FHIRDate? { date("birthDate") }
    public var birthDateText: String? { get { string("birthDate") } set { set("birthDate", string: newValue) } }
    public var deceased: FHIRChoice? { choice("deceased") }
    public var addresses: [FHIRAddress] { views("address") }
    public var maritalStatus: FHIRCodeableConcept? { view("maritalStatus") }
    public var multipleBirth: FHIRChoice? { choice("multipleBirth") }
    public var managingOrganization: FHIRReference? { view("managingOrganization") }
    public var generalPractitioners: [FHIRReference] { views("generalPractitioner") }
    public var links: [FHIRJSONObject] { objects("link") }
}

public struct FHIRPractitioner: FHIRResourceView {
    public static let resourceType = "Practitioner"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var active: Bool? { bool("active") }
    public var names: [FHIRHumanName] { get { views("name") } set { set("name", views: newValue) } }
    public var telecoms: [FHIRContactPoint] { views("telecom") }
    public var gender: String? { string("gender") }
    public var qualifications: [FHIRJSONObject] { objects("qualification") }
}

public struct FHIROrganization: FHIRResourceView {
    public static let resourceType = "Organization"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var active: Bool? { bool("active") }
    public var types: [FHIRCodeableConcept] { views("type") }
    public var name: String? { get { string("name") } set { set("name", string: newValue) } }
    public var aliases: [String] { strings("alias") }
    public var telecoms: [FHIRContactPoint] { views("telecom") }
    public var addresses: [FHIRAddress] { views("address") }
    public var partOf: FHIRReference? { view("partOf") }
}

public struct FHIREncounter: FHIRResourceView {
    public static let resourceType = "Encounter"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var classCoding: FHIRCoding? { get { view("class") } set { set("class", view: newValue) } }
    public var types: [FHIRCodeableConcept] { views("type") }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var participants: [FHIRJSONObject] { objects("participant") }
    public var period: FHIRPeriod? { get { view("period") } set { set("period", view: newValue) } }
    public var reasonCodes: [FHIRCodeableConcept] { views("reasonCode") }
    public var serviceProvider: FHIRReference? { view("serviceProvider") }
    public var locations: [FHIRJSONObject] { objects("location") }
}

public struct FHIRObservation: FHIRResourceView {
    public static let resourceType = "Observation"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var categories: [FHIRCodeableConcept] { get { views("category") } set { set("category", views: newValue) } }
    public var code: FHIRCodeableConcept? { get { view("code") } set { set("code", view: newValue) } }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var encounter: FHIRReference? { view("encounter") }
    public var effective: FHIRChoice? { choice("effective") }
    public var issued: FHIRDateTime? { dateTime("issued") }
    public var performers: [FHIRReference] { views("performer") }
    public var value: FHIRChoice? { choice("value") }
    public var valueQuantity: FHIRQuantity? { view("valueQuantity") }
    public var dataAbsentReason: FHIRCodeableConcept? { view("dataAbsentReason") }
    public var interpretations: [FHIRCodeableConcept] { views("interpretation") }
    public var notes: [FHIRAnnotation] { views("note") }
    public var bodySite: FHIRCodeableConcept? { view("bodySite") }
    public var method: FHIRCodeableConcept? { view("method") }
    public var referenceRanges: [FHIRObservationReferenceRange] { views("referenceRange") }
    public var hasMembers: [FHIRReference] { views("hasMember") }
    public var derivedFrom: [FHIRReference] { views("derivedFrom") }
    public var components: [FHIRObservationComponent] { get { views("component") } set { set("component", views: newValue) } }

    public mutating func setValue(quantity: FHIRQuantity) { setChoice("value", typeSuffix: "Quantity", value: .object(quantity.json)) }
    public mutating func setValue(string: String) { setChoice("value", typeSuffix: "String", value: .string(string)) }
    public mutating func setValue(codeableConcept: FHIRCodeableConcept) { setChoice("value", typeSuffix: "CodeableConcept", value: .object(codeableConcept.json)) }
    public mutating func setEffective(dateTime: String) { setChoice("effective", typeSuffix: "DateTime", value: .string(dateTime)) }
}

public struct FHIRObservationReferenceRange: FHIRElementView {
    public static let typeName = "ObservationReferenceRange"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var low: FHIRQuantity? { view("low") }
    public var high: FHIRQuantity? { view("high") }
    public var type: FHIRCodeableConcept? { view("type") }
    public var text: String? { string("text") }
}

public struct FHIRObservationComponent: FHIRElementView {
    public static let typeName = "ObservationComponent"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var code: FHIRCodeableConcept? { get { view("code") } set { set("code", view: newValue) } }
    public var value: FHIRChoice? { choice("value") }
    public var valueQuantity: FHIRQuantity? { view("valueQuantity") }
    public var interpretations: [FHIRCodeableConcept] { views("interpretation") }
    public var referenceRanges: [FHIRObservationReferenceRange] { views("referenceRange") }
}

public struct FHIRDiagnosticReport: FHIRResourceView {
    public static let resourceType = "DiagnosticReport"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var basedOn: [FHIRReference] { views("basedOn") }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var categories: [FHIRCodeableConcept] { get { views("category") } set { set("category", views: newValue) } }
    public var code: FHIRCodeableConcept? { get { view("code") } set { set("code", view: newValue) } }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var encounter: FHIRReference? { get { view("encounter") } set { set("encounter", view: newValue) } }
    public var effective: FHIRChoice? { choice("effective") }
    public var issued: FHIRDateTime? { dateTime("issued") }
    public var issuedText: String? { get { string("issued") } set { set("issued", string: newValue) } }
    public var performers: [FHIRReference] { get { views("performer") } set { set("performer", views: newValue) } }
    public var resultsInterpreters: [FHIRReference] { views("resultsInterpreter") }
    public var results: [FHIRReference] { get { views("result") } set { set("result", views: newValue) } }
    public var imagingStudies: [FHIRReference] { get { views("imagingStudy") } set { set("imagingStudy", views: newValue) } }
    public var media: [FHIRJSONObject] { objects("media") }
    public var conclusion: String? { get { string("conclusion") } set { set("conclusion", string: newValue) } }
    public var conclusionCodes: [FHIRCodeableConcept] { views("conclusionCode") }
    public var presentedForms: [FHIRAttachment] { get { views("presentedForm") } set { set("presentedForm", views: newValue) } }
}

public struct FHIRImagingStudy: FHIRResourceView {
    public static let resourceType = "ImagingStudy"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var modalities: [FHIRCoding] { get { views("modality") } set { set("modality", views: newValue) } }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var encounter: FHIRReference? { get { view("encounter") } set { set("encounter", view: newValue) } }
    public var started: FHIRDateTime? { dateTime("started") }
    public var startedText: String? { get { string("started") } set { set("started", string: newValue) } }
    public var basedOn: [FHIRReference] { get { views("basedOn") } set { set("basedOn", views: newValue) } }
    public var referrer: FHIRReference? { get { view("referrer") } set { set("referrer", view: newValue) } }
    public var interpreters: [FHIRReference] { views("interpreter") }
    public var endpoints: [FHIRReference] { get { views("endpoint") } set { set("endpoint", views: newValue) } }
    public var numberOfSeries: Int? { get { int("numberOfSeries") } set { set("numberOfSeries", int: newValue) } }
    public var numberOfInstances: Int? { get { int("numberOfInstances") } set { set("numberOfInstances", int: newValue) } }
    public var procedureReference: FHIRReference? { view("procedureReference") }
    public var procedureCodes: [FHIRCodeableConcept] { get { views("procedureCode") } set { set("procedureCode", views: newValue) } }
    public var reasonCodes: [FHIRCodeableConcept] { views("reasonCode") }
    public var description: String? { get { string("description") } set { set("description", string: newValue) } }
    public var series: [FHIRImagingStudySeries] { get { views("series") } set { set("series", views: newValue) } }

    /// The DICOM Study Instance UID carried as `urn:oid:` identifier with system `urn:dicom:uid`.
    public var studyInstanceUID: String? {
        identifiers.first { $0.system == "urn:dicom:uid" }?.value.map { $0.hasPrefix("urn:oid:") ? String($0.dropFirst(8)) : $0 }
    }
}

public struct FHIRImagingStudySeries: FHIRElementView {
    public static let typeName = "ImagingStudySeries"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var uid: String? { get { string("uid") } set { set("uid", string: newValue) } }
    public var number: Int? { get { int("number") } set { set("number", int: newValue) } }
    public var modality: FHIRCoding? { get { view("modality") } set { set("modality", view: newValue) } }
    public var description: String? { get { string("description") } set { set("description", string: newValue) } }
    public var numberOfInstances: Int? { get { int("numberOfInstances") } set { set("numberOfInstances", int: newValue) } }
    public var endpoints: [FHIRReference] { get { views("endpoint") } set { set("endpoint", views: newValue) } }
    public var bodySite: FHIRCoding? { get { view("bodySite") } set { set("bodySite", view: newValue) } }
    public var laterality: FHIRCoding? { view("laterality") }
    public var started: FHIRDateTime? { dateTime("started") }
    public var startedText: String? { get { string("started") } set { set("started", string: newValue) } }
    public var performers: [FHIRJSONObject] { objects("performer") }
    public var instances: [FHIRImagingStudyInstance] { get { views("instance") } set { set("instance", views: newValue) } }
}

public struct FHIRImagingStudyInstance: FHIRElementView {
    public static let typeName = "ImagingStudySeriesInstance"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var uid: String? { get { string("uid") } set { set("uid", string: newValue) } }
    public var sopClass: FHIRCoding? { get { view("sopClass") } set { set("sopClass", view: newValue) } }
    public var number: Int? { get { int("number") } set { set("number", int: newValue) } }
    public var title: String? { get { string("title") } set { set("title", string: newValue) } }
}

public struct FHIRDocumentReference: FHIRResourceView {
    public static let resourceType = "DocumentReference"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var masterIdentifier: FHIRIdentifier? { get { view("masterIdentifier") } set { set("masterIdentifier", view: newValue) } }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var docStatus: String? { string("docStatus") }
    public var type: FHIRCodeableConcept? { get { view("type") } set { set("type", view: newValue) } }
    public var categories: [FHIRCodeableConcept] { get { views("category") } set { set("category", views: newValue) } }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var date: FHIRDateTime? { dateTime("date") }
    public var dateText: String? { get { string("date") } set { set("date", string: newValue) } }
    public var authors: [FHIRReference] { get { views("author") } set { set("author", views: newValue) } }
    public var custodian: FHIRReference? { view("custodian") }
    public var description: String? { get { string("description") } set { set("description", string: newValue) } }
    public var securityLabels: [FHIRCodeableConcept] { views("securityLabel") }
    public var contents: [FHIRDocumentReferenceContent] { get { views("content") } set { set("content", views: newValue) } }
    public var context: FHIRJSONObject? { object("context") }
}

public struct FHIRDocumentReferenceContent: FHIRElementView {
    public static let typeName = "DocumentReferenceContent"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(attachment: FHIRAttachment, format: FHIRCoding? = nil) {
        json = FHIRJSONObject()
        set("attachment", view: attachment); set("format", view: format)
    }
    public var attachment: FHIRAttachment? { get { view("attachment") } set { set("attachment", view: newValue) } }
    public var format: FHIRCoding? { view("format") }
}

public struct FHIRBinary: FHIRResourceView {
    public static let resourceType = "Binary"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(contentType: String, data: Data, securityContext: FHIRReference? = nil) {
        self.init()
        set("contentType", string: contentType); set("securityContext", view: securityContext); set("data", string: data.base64EncodedString())
    }
    public var contentType: String? { string("contentType") }
    public var securityContext: FHIRReference? { view("securityContext") }
    public var data: Data? { string("data").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }
}

public struct FHIREndpoint: FHIRResourceView {
    public static let resourceType = "Endpoint"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var connectionType: FHIRCoding? { get { view("connectionType") } set { set("connectionType", view: newValue) } }
    public var name: String? { get { string("name") } set { set("name", string: newValue) } }
    public var managingOrganization: FHIRReference? { view("managingOrganization") }
    public var payloadTypes: [FHIRCodeableConcept] { get { views("payloadType") } set { set("payloadType", views: newValue) } }
    public var payloadMimeTypes: [String] { get { strings("payloadMimeType") } set { set("payloadMimeType", strings: newValue) } }
    public var address: String? { get { string("address") } set { set("address", string: newValue) } }
}

public struct FHIRCondition: FHIRResourceView {
    public static let resourceType = "Condition"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var clinicalStatus: FHIRCodeableConcept? { view("clinicalStatus") }
    public var verificationStatus: FHIRCodeableConcept? { view("verificationStatus") }
    public var categories: [FHIRCodeableConcept] { views("category") }
    public var severity: FHIRCodeableConcept? { view("severity") }
    public var code: FHIRCodeableConcept? { view("code") }
    public var bodySites: [FHIRCodeableConcept] { views("bodySite") }
    public var subject: FHIRReference? { view("subject") }
    public var encounter: FHIRReference? { view("encounter") }
    public var onset: FHIRChoice? { choice("onset") }
    public var abatement: FHIRChoice? { choice("abatement") }
    public var recordedDate: FHIRDateTime? { dateTime("recordedDate") }
}

public struct FHIRAllergyIntolerance: FHIRResourceView {
    public static let resourceType = "AllergyIntolerance"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var clinicalStatus: FHIRCodeableConcept? { view("clinicalStatus") }
    public var verificationStatus: FHIRCodeableConcept? { view("verificationStatus") }
    public var type: String? { string("type") }
    public var categories: [String] { strings("category") }
    public var criticality: String? { string("criticality") }
    public var code: FHIRCodeableConcept? { view("code") }
    public var patient: FHIRReference? { view("patient") }
    public var onset: FHIRChoice? { choice("onset") }
    public var reactions: [FHIRJSONObject] { objects("reaction") }
}

public struct FHIRMedicationRequest: FHIRResourceView {
    public static let resourceType = "MedicationRequest"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { string("status") }
    public var intent: String? { string("intent") }
    public var medication: FHIRChoice? { choice("medication") }
    public var subject: FHIRReference? { view("subject") }
    public var authoredOn: FHIRDateTime? { dateTime("authoredOn") }
    public var requester: FHIRReference? { view("requester") }
    public var dosageInstructions: [FHIRJSONObject] { objects("dosageInstruction") }
}

public struct FHIRMedicationStatement: FHIRResourceView {
    public static let resourceType = "MedicationStatement"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { string("status") }
    public var medication: FHIRChoice? { choice("medication") }
    public var subject: FHIRReference? { view("subject") }
    public var effective: FHIRChoice? { choice("effective") }
    public var dateAsserted: FHIRDateTime? { dateTime("dateAsserted") }
}

public struct FHIRAppointment: FHIRResourceView {
    public static let resourceType = "Appointment"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { string("status") }
    public var serviceTypes: [FHIRCodeableConcept] { views("serviceType") }
    public var start: FHIRDateTime? { dateTime("start") }
    public var end: FHIRDateTime? { dateTime("end") }
    public var participants: [FHIRJSONObject] { objects("participant") }
}

public struct FHIRSchedule: FHIRResourceView {
    public static let resourceType = "Schedule"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var active: Bool? { bool("active") }
    public var actors: [FHIRReference] { views("actor") }
    public var planningHorizon: FHIRPeriod? { view("planningHorizon") }
}

public struct FHIRServiceRequest: FHIRResourceView {
    public static let resourceType = "ServiceRequest"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var intent: String? { get { string("intent") } set { set("intent", string: newValue) } }
    public var code: FHIRCodeableConcept? { get { view("code") } set { set("code", view: newValue) } }
    public var subject: FHIRReference? { get { view("subject") } set { set("subject", view: newValue) } }
    public var occurrence: FHIRChoice? { choice("occurrence") }
    public var requester: FHIRReference? { get { view("requester") } set { set("requester", view: newValue) } }
    public var reasonCodes: [FHIRCodeableConcept] { views("reasonCode") }
}

public struct FHIRSubscription: FHIRResourceView {
    public static let resourceType = "Subscription"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(criteria: String, endpoint: String, payload: String = "application/fhir+json", headers: [String] = [], reason: String = "Isis subscription", end: String? = nil) {
        self.init()
        set("status", string: "requested")
        set("end", string: end)
        set("reason", string: reason)
        set("criteria", string: criteria)
        var channel = FHIRJSONObject()
        channel["type"] = .string("rest-hook")
        channel["endpoint"] = .string(endpoint)
        channel["payload"] = .string(payload)
        if !headers.isEmpty { channel["header"] = .array(headers.map(FHIRJSON.string)) }
        json["channel"] = .object(channel)
    }
    public var status: String? { get { string("status") } set { set("status", string: newValue) } }
    public var end: FHIRDateTime? { dateTime("end") }
    public var reason: String? { string("reason") }
    public var criteria: String? { string("criteria") }
    public var error: String? { string("error") }
    public var channel: FHIRJSONObject? { object("channel") }
    public var channelType: String? { channel?["type"]?.string }
    public var channelEndpoint: String? { channel?["endpoint"]?.string }
    public var channelPayload: String? { channel?["payload"]?.string }
    public var channelHeaders: [String] { channel?["header"]?.array?.compactMap(\.string) ?? [] }
}

public struct FHIRCapabilityStatement: FHIRResourceView {
    public static let resourceType = "CapabilityStatement"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var fhirVersion: String? { string("fhirVersion") }
    public var formats: [String] { strings("format") }
    public var rests: [FHIRJSONObject] { objects("rest") }
    /// Resource types listed in the first `rest` component.
    public var serverResourceTypes: [String] {
        rests.first?["resource"]?.array?.compactMap { $0.object?["type"]?.string } ?? []
    }
    public func interactions(for resourceType: String) -> [String] {
        rests.first?["resource"]?.array?.compactMap(\.object).first { $0["type"]?.string == resourceType }?["interaction"]?.array?
            .compactMap { $0.object?["code"]?.string } ?? []
    }
}
