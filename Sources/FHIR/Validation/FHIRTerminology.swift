import Foundation

public enum FHIRCodeVerdict: Equatable, Sendable {
    case valid
    case invalid
    /// The value set is not known to the provider; the validator reports a warning, never an error.
    case unknownValueSet
}

/// Injected terminology: value-set membership for bindings. No network access is built in.
public protocol FHIRTerminologyProvider: Sendable {
    func validate(system: String?, code: String, valueSet: String) async -> FHIRCodeVerdict
    func knowsValueSet(_ url: String) async -> Bool
}

/// In-memory value sets keyed by canonical URL; ships the required bindings of the toolkit's resource subset.
public struct FHIRInMemoryTerminology: FHIRTerminologyProvider {
    public struct ValueSet: Sendable {
        public var codes: Set<String>
        public var system: String?
        public init(system: String? = nil, codes: Set<String>) {
            self.system = system
            self.codes = codes
        }
    }

    public var valueSets: [String: ValueSet]

    public init(valueSets: [String: ValueSet] = [:]) { self.valueSets = valueSets }

    public func validate(system: String?, code: String, valueSet: String) async -> FHIRCodeVerdict {
        guard let set = valueSets[valueSet] else { return .unknownValueSet }
        guard set.codes.contains(code) else { return .invalid }
        if let expected = set.system, let system, system != expected { return .invalid }
        return .valid
    }

    public func knowsValueSet(_ url: String) async -> Bool { valueSets[url] != nil }

    /// Required-binding value sets of FHIR R4 for the elements the toolkit validates by default.
    public static let r4Required: FHIRInMemoryTerminology = {
        let base = "http://hl7.org/fhir/ValueSet/"
        func set(_ name: String, _ codes: [String], system: String? = nil) -> (String, ValueSet) {
            (base + name, ValueSet(system: system ?? "http://hl7.org/fhir/" + name, codes: Set(codes)))
        }
        let sets: [(String, ValueSet)] = [
            set("administrative-gender", ["male", "female", "other", "unknown"]),
            set("observation-status", ["registered", "preliminary", "final", "amended", "corrected", "cancelled", "entered-in-error", "unknown"]),
            set("diagnostic-report-status", ["registered", "partial", "preliminary", "final", "amended", "corrected", "appended", "cancelled", "entered-in-error", "unknown"]),
            set("imagingstudy-status", ["registered", "available", "cancelled", "entered-in-error", "unknown"]),
            set("document-reference-status", ["current", "superseded", "entered-in-error"]),
            set("composition-status", ["preliminary", "final", "amended", "entered-in-error"]),
            set("bundle-type", ["document", "message", "transaction", "transaction-response", "batch", "batch-response", "history", "searchset", "collection"]),
            set("http-verb", ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH"]),
            set("search-entry-mode", ["match", "include", "outcome"]),
            set("issue-severity", ["fatal", "error", "warning", "information"]),
            set("issue-type", ["invalid", "structure", "required", "value", "invariant", "security", "login", "unknown", "expired", "forbidden", "suppressed", "processing", "not-supported", "duplicate", "multiple-matches", "not-found", "deleted", "too-long", "code-invalid", "extension", "too-costly", "business-rule", "conflict", "transient", "lock-error", "no-store", "exception", "timeout", "incomplete", "throttled", "informational"]),
            set("subscription-status", ["requested", "active", "error", "off"]),
            set("subscription-channel-type", ["rest-hook", "websocket", "email", "sms", "message"]),
            set("encounter-status", ["planned", "arrived", "triaged", "in-progress", "onleave", "finished", "cancelled", "entered-in-error", "unknown"]),
            set("narrative-status", ["generated", "extensions", "additional", "empty"]),
            set("identifier-use", ["usual", "official", "temp", "secondary", "old"]),
            set("name-use", ["usual", "official", "temp", "nickname", "anonymous", "old", "maiden"]),
            set("contact-point-system", ["phone", "fax", "email", "pager", "url", "sms", "other"]),
            set("contact-point-use", ["home", "work", "temp", "old", "mobile"]),
            set("address-use", ["home", "work", "temp", "old", "billing"]),
            set("address-type", ["postal", "physical", "both"]),
            set("quantity-comparator", ["<", "<=", ">=", ">"]),
            set("endpoint-status", ["active", "suspended", "error", "off", "entered-in-error", "test"]),
            set("request-status", ["draft", "active", "on-hold", "revoked", "completed", "entered-in-error", "unknown"]),
            set("request-intent", ["proposal", "plan", "directive", "order", "original-order", "reflex-order", "filler-order", "instance-order", "option"]),
            set("medicationrequest-status", ["active", "on-hold", "cancelled", "completed", "entered-in-error", "stopped", "draft", "unknown"]),
            set("appointmentstatus", ["proposed", "pending", "booked", "arrived", "fulfilled", "cancelled", "noshow", "entered-in-error", "checked-in", "waitlist"]),
            set("allergy-intolerance-type", ["allergy", "intolerance"]),
            set("allergy-intolerance-category", ["food", "medication", "environment", "biologic"]),
            set("allergy-intolerance-criticality", ["low", "high", "unable-to-assess"]),
            set("publication-status", ["draft", "active", "retired", "unknown"]),
            set("capability-statement-kind", ["instance", "capability", "requirements"]),
            set("restful-capability-mode", ["client", "server"]),
            set("type-restful-interaction", ["read", "vread", "update", "patch", "delete", "history-instance", "history-type", "create", "search-type"])
        ]
        var dictionary: [String: ValueSet] = [:]
        for (url, valueSet) in sets { dictionary[url] = valueSet }
        return FHIRInMemoryTerminology(valueSets: dictionary)
    }()
}

/// Required bindings of the base specification for the validated subset (`Type.element` -> value set).
public enum FHIRBaseBindings {
    public static let required: [String: String] = {
        let base = "http://hl7.org/fhir/ValueSet/"
        return [
            "Patient.gender": base + "administrative-gender", "Practitioner.gender": base + "administrative-gender",
            "Observation.status": base + "observation-status", "DiagnosticReport.status": base + "diagnostic-report-status",
            "ImagingStudy.status": base + "imagingstudy-status", "DocumentReference.status": base + "document-reference-status",
            "DocumentReference.docStatus": base + "composition-status", "Bundle.type": base + "bundle-type",
            "BundleEntryRequest.method": base + "http-verb", "BundleEntrySearch.mode": base + "search-entry-mode",
            "OperationOutcomeIssue.severity": base + "issue-severity", "OperationOutcomeIssue.code": base + "issue-type",
            "Subscription.status": base + "subscription-status", "SubscriptionChannel.type": base + "subscription-channel-type",
            "Encounter.status": base + "encounter-status", "Narrative.status": base + "narrative-status",
            "Identifier.use": base + "identifier-use", "HumanName.use": base + "name-use",
            "ContactPoint.system": base + "contact-point-system", "ContactPoint.use": base + "contact-point-use",
            "Address.use": base + "address-use", "Address.type": base + "address-type",
            "Quantity.comparator": base + "quantity-comparator", "Endpoint.status": base + "endpoint-status",
            "ServiceRequest.status": base + "request-status", "ServiceRequest.intent": base + "request-intent",
            "MedicationRequest.status": base + "medicationrequest-status", "MedicationRequest.intent": base + "request-intent",
            "Appointment.status": base + "appointmentstatus", "AllergyIntolerance.type": base + "allergy-intolerance-type",
            "AllergyIntolerance.category": base + "allergy-intolerance-category", "AllergyIntolerance.criticality": base + "allergy-intolerance-criticality",
            "CapabilityStatement.status": base + "publication-status", "CapabilityStatement.kind": base + "capability-statement-kind",
            "CapabilityStatementRest.mode": base + "restful-capability-mode", "CapabilityStatementRestResourceInteraction.code": base + "type-restful-interaction"
        ]
    }()
}
