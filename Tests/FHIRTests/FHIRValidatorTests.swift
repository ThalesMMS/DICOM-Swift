import Foundation
import XCTest
@testable import FHIR

final class FHIRValidatorTests: XCTestCase {
    private let validator = FHIRValidator()

    func test_missingRequiredComplexElements_areRejectedWithExactPaths() async throws {
        let observation = try mutate("observation-example") { $0.removeValue(forKey: "code") }
        let missingCode = await validator.validate(observation)
        XCTAssertTrue(missingCode.errors.contains { $0.path == "Observation.code" && $0.code == "required" })
        var audit = FHIRResource(resourceType: "AuditEvent")
        let missingAuditFields = await validator.validate(audit)
        for path in ["AuditEvent.type", "AuditEvent.source"] {
            XCTAssertTrue(missingAuditFields.errors.contains { $0.path == path && $0.code == "required" }, path)
        }
        audit.json["source"] = ["site": "synthetic"]
        let missingObserver = await validator.validate(audit)
        XCTAssertTrue(missingObserver.errors.contains { $0.path == "AuditEvent.source.observer" && $0.code == "required" })
    }

    func test_nestedProfileCardinality_isCheckedPerParent() async throws {
        let profile = try FHIRProfile(structureDefinition: FHIRResource(jsonData: Data("""
        {"resourceType":"StructureDefinition","url":"http://isis.test/one-given","name":"OneGiven","type":"Patient",
         "differential":{"element":[{"path":"Patient.name.given","min":1,"max":"1"}]}}
        """.utf8)))
        let validator = FHIRValidator(profiles: .init([profile]))
        var patient = FHIRResource(resourceType: "Patient")
        patient.json["active"] = true
        patient.json["name"] = [["given": ["Ana"]], ["given": ["Maria"]]]
        let valid = await validator.validate(patient, profiles: [profile.url])
        XCTAssertTrue(valid.isValid, valid.errors.map(\.detail).joined(separator: "; "))
        patient.json["name"] = [["family": "Synthetic"], ["given": ["Maria"]]]
        let missing = await validator.validate(patient, profiles: [profile.url])
        XCTAssertTrue(missing.errors.contains { $0.path == "Patient.name.given" && $0.code == "required" })
        patient.json.removeValue(forKey: "name")
        let noParent = await validator.validate(patient, profiles: [profile.url])
        XCTAssertTrue(noParent.isValid, "an absent optional parent does not require its children")
    }

    func test_mimeBindingWithoutExpansion_reportsUnavailableInsteadOfInvalid() async throws {
        let profile = try FHIRProfile(structureDefinition: FHIRResource(jsonData: Data("""
        {"resourceType":"StructureDefinition","url":"http://isis.test/mime","name":"Mime","type":"Patient",
         "differential":{"element":[{"path":"Patient.photo.contentType",
           "binding":{"strength":"required","valueSet":"http://hl7.org/fhir/ValueSet/mimetypes"}}]}}
        """.utf8)))
        var patient = FHIRResource(resourceType: "Patient")
        patient.json["photo"] = [["contentType": "image/png", "url": "https://isis.test/synthetic.png"]]
        let result = await FHIRValidator(profiles: .init([profile])).validate(patient, profiles: [profile.url])
        XCTAssertTrue(result.isValid, result.errors.map(\.detail).joined(separator: "; "))
        XCTAssertTrue(result.warnings.contains { $0.path == "Patient.photo.contentType" && $0.code == "not-supported" })
    }

    private func mutate(_ name: String, _ change: (inout FHIRJSONObject) -> Void) throws -> FHIRResource {
        var json = name.hasPrefix("own:") ? try FHIRFixtures.own(String(name.dropFirst(4))).json : try FHIRFixtures.resource(name).json
        change(&json)
        return FHIRResource(json: json)
    }

    func test_officialCorpus_hasNoStructuralErrors() async throws {
        for name in FHIRFixtures.official + ["own:primitive-extensions", "own:choice-and-decimals", "own:contained-and-references"] {
            let resource = name.hasPrefix("own:") ? try FHIRFixtures.own(String(name.dropFirst(4))) : try FHIRFixtures.resource(name)
            let report = await validator.validate(resource)
            XCTAssertTrue(report.isValid, name + ": " + report.errors.map { $0.path + " " + $0.code + " " + $0.detail }.joined(separator: "; "))
            XCTAssertTrue(report.evaluatedInvariants.contains("dom-3"), name)
        }
    }

    func test_structuralErrors_areReportedWithPathsAndCodes() async throws {
        let cases: [(String, (inout FHIRJSONObject) -> Void, String, String)] = [
            ("unknown element", { $0["bogusElement"] = .string("x") }, "Patient.bogusElement", "unknown-element"),
            ("wrong shape", { $0["name"] = ["family": "x"] }, "Patient.name", "structure"),
            ("empty array", { $0["name"] = .array([]) }, "Patient.name", "structure"),
            ("bad date", { $0["birthDate"] = .string("1974-13-40") }, "Patient.birthDate", "value"),
            ("bool as string", { $0["active"] = .string("true") }, "Patient.active", "structure"),
            ("choice conflict", { $0["deceasedDateTime"] = .string("2020-01-01") }, "Patient.deceased[x]", "structure"),
            ("bad code binding", { $0["gender"] = .string("bogus") }, "Patient.gender", "code-invalid"),
            ("companion mismatch", { $0["_gender"] = .string("x") }, "Patient._gender", "structure"),
            ("bad reference", { $0["managingOrganization"] = ["reference": "organization/1"] }, "Patient.managingOrganization.reference", "value"),
            ("empty element", { $0["maritalStatus"] = .object(FHIRJSONObject()) }, "Patient.maritalStatus", "invariant"),
            ("id too long", { $0["id"] = .string(String(repeating: "a", count: 65)) }, "Patient.id", "value"),
            ("bad narrative", { $0["text"] = ["status": "generated", "div": "<p>x</p>"] }, "Patient.text.div", "invalid")
        ]
        for (label, change, path, code) in cases {
            let report = await validator.validate(try mutate("patient-example", change))
            XCTAssertTrue(report.errors.contains { $0.path == path && $0.code == code }, label + ": " + report.errors.map { $0.path + " " + $0.code }.joined(separator: "; "))
        }
        let missing = await validator.validate(try mutate("observation-example") { $0.removeValue(forKey: "status") })
        XCTAssertTrue(missing.errors.contains { $0.path == "Observation.status" && $0.code == "required" })
        let lenient = FHIRValidator(options: .init(allowUnknownElements: true))
        let tolerated = await lenient.validate(try mutate("patient-example") { $0["bogusElement"] = .string("x") })
        XCTAssertTrue(tolerated.isValid)
        XCTAssertEqual(tolerated.warnings.first?.code, "unknown-element")
        let outcome = missing.operationOutcome()
        XCTAssertTrue(outcome.hasErrors)
        XCTAssertEqual(outcome.issues.first?.expressions, ["Observation.status"])
    }

    func test_containedAndBundleInvariants() async throws {
        let danglingContained = await validator.validate(try mutate("own:contained-and-references") { _ in })
        XCTAssertTrue(danglingContained.isValid)
        var report = try FHIRFixtures.own("contained-and-references").json
        report["result"] = [["reference": "#missing"]]
        let dangling = await validator.validate(FHIRResource(json: report))
        XCTAssertTrue(dangling.errors.contains { $0.path == "DiagnosticReport.result[0].reference" && $0.code == "invariant" })
        var nested = try FHIRFixtures.own("contained-and-references").json
        var inner = nested["contained"]![0]!.object!
        inner["contained"] = [["resourceType": "Patient", "id": "deep"]]
        inner.removeValue(forKey: "id")
        nested["contained"] = .array([.object(inner)])
        let deep = await validator.validate(FHIRResource(json: nested))
        XCTAssertTrue(deep.errors.contains { $0.path == "DiagnosticReport.contained[0].contained" })
        XCTAssertTrue(deep.errors.contains { $0.path == "DiagnosticReport.contained[0].id" && $0.code == "required" })

        let unreferenced = await validator.validate(try mutate("own:contained-and-references") { $0["result"] = [["reference": "urn:uuid:3fdc72f4-a11d-4a9d-9260-a9f745779e1d"]] })
        XCTAssertTrue(unreferenced.errors.contains { $0.detail.hasPrefix("dom-3") }, "contained resource must be referenced")

        let transactionWithTotal = await validator.validate(try mutate("bundle-transaction") { $0["total"] = 3 })
        XCTAssertTrue(transactionWithTotal.errors.contains { $0.detail.hasPrefix("bdl-1") })
        let missingRequest = await validator.validate(try mutate("bundle-transaction") {
            var entries = $0["entry"]!.array!
            var first = entries[0].object!
            first.removeValue(forKey: "request")
            entries[0] = .object(first)
            $0["entry"] = .array(entries)
        })
        XCTAssertTrue(missingRequest.errors.contains { $0.detail.hasPrefix("bdl-3") })
        let period = await validator.validate(try mutate("encounter-example") { $0["period"] = ["start": "2020-02-01", "end": "2020-01-01"] })
        XCTAssertTrue(period.errors.contains { $0.path == "Encounter.period" && $0.detail.hasPrefix("per-1") })
        let absent = await validator.validate(try mutate("observation-example") { $0["dataAbsentReason"] = ["text": "x"] })
        XCTAssertTrue(absent.errors.contains { $0.detail.hasPrefix("obs-6") })
    }

    func test_profiles_fromStructureDefinitionApplyCardinalityFixedBindingAndInvariants() async throws {
        let definition = try FHIRResource(jsonData: Data("""
        {"resourceType":"StructureDefinition","url":"http://isis.test/StructureDefinition/isis-weight","name":"IsisWeight","status":"active",
         "kind":"resource","abstract":false,"type":"Observation","baseDefinition":"http://hl7.org/fhir/StructureDefinition/Observation",
         "differential":{"element":[
           {"path":"Observation"},
           {"path":"Observation.subject","min":1,"max":"1","mustSupport":true},
           {"path":"Observation.code","patternCodeableConcept":{"coding":[{"system":"http://loinc.org","code":"29463-7"}]}},
           {"path":"Observation.value[x]","min":1,"type":[{"code":"Quantity"}]},
           {"path":"Observation.value[x].code","fixedCode":"kg"},
           {"path":"Observation.status","binding":{"strength":"required","valueSet":"http://isis.test/ValueSet/final-only"}},
           {"path":"Observation.effective[x]","constraint":[{"key":"isis-1","severity":"error","human":"effective must be a dateTime","expression":"$this is dateTime"}]}
         ]}}
        """.utf8))
        let profile = try FHIRProfile(structureDefinition: definition)
        XCTAssertEqual(profile.elements.count, 7)
        XCTAssertEqual(profile.elements[1].min, 1)
        XCTAssertEqual(profile.elements[1].max, 1)
        XCTAssertEqual(profile.elements[3].types, ["Quantity"])
        XCTAssertEqual(profile.elements[4].fixed, .string("kg"))
        XCTAssertEqual(profile.elements[5].binding?.strength, .required)
        XCTAssertEqual(profile.elements[6].constraints.first?.key, "isis-1")
        var terminology = FHIRInMemoryTerminology.r4Required
        terminology.valueSets["http://isis.test/ValueSet/final-only"] = .init(codes: ["final"])
        let validator = FHIRValidator(terminology: terminology, profiles: .init([profile]))

        var good = FHIRObservation(id: "w1")
        good.status = "final"
        good.code = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "29463-7", display: "Body weight")])
        good.subject = FHIRReference(reference: "Patient/1")
        good.setValue(quantity: FHIRQuantity(value: FHIRNumber(lexical: "70"), unit: "kg", system: "http://unitsofmeasure.org", code: "kg"))
        good.setEffective(dateTime: "2026-09-12T10:00:00Z")
        var resource = good.resource
        resource.meta = { var meta = FHIRMeta(); meta.profiles = [profile.url]; return meta }()
        let passing = await validator.validate(resource)
        XCTAssertTrue(passing.isValid, passing.errors.map { $0.path + " " + $0.detail }.joined(separator: "; "))
        XCTAssertEqual(passing.appliedProfiles, [profile.url])
        XCTAssertTrue(passing.evaluatedInvariants.contains("isis-1"))

        var bad = good
        bad.status = "preliminary"
        bad.code = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "8480-6")])
        bad.setValue(string: "seventy")
        bad.json.removeValue(forKey: "subject")
        bad.setChoice("effective", typeSuffix: "Period", value: ["start": "2026-01-01"])
        let failing = await validator.validate(bad.resource, profiles: [profile.url])
        let failures = failing.errors.map { $0.path + "|" + $0.code }
        XCTAssertTrue(failures.contains("Observation.subject|required"), failures.joined(separator: " "))
        XCTAssertTrue(failures.contains("Observation.code|value"))
        XCTAssertTrue(failures.contains("Observation.value[x]|structure"))
        XCTAssertTrue(failures.contains("Observation.status|code-invalid"))
        XCTAssertTrue(failures.contains("Observation.effective[x]|invariant"))
        let unknownProfile = await validator.validate(good.resource, profiles: ["http://isis.test/StructureDefinition/nope"])
        XCTAssertEqual(unknownProfile.errors.first?.code, "not-supported")
        XCTAssertThrowsError(try FHIRProfile(structureDefinition: FHIRFixtures.resource("patient-example"))) { XCTAssertEqual($0 as? FHIRProfile.LoadError, .notAStructureDefinition) }
    }

    func test_structuralVerdicts_agreeWithFhirResources() async throws {
        let mutations: [(String, FHIRResource)] = [
            ("valid", try FHIRFixtures.resource("observation-example")),
            ("missing-status", try mutate("observation-example") { $0.removeValue(forKey: "status") }),
            ("wrong-type", try mutate("patient-example") { $0["name"] = .string("x") }),
            ("bad-date", try mutate("patient-example") { $0["birthDate"] = .string("1974-13") }),
            ("unknown-element", try mutate("patient-example") { $0["bogusElement"] = .string("x") })
        ]
        let verdicts = try FHIROracleServer.examine(mutations.map { ($0.0, $0.1.jsonData(), "json") })
        for (name, resource) in mutations {
            let ours = await validator.validate(resource).isValid
            let theirs = try XCTUnwrap(verdicts[name]?["valid"] as? Bool, name)
            XCTAssertEqual(ours, theirs, name + " " + String(describing: verdicts[name]?["issues"]))
        }
    }
}
