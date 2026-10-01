import Foundation
import XCTest
@testable import FHIR

final class FHIRTypedViewTests: XCTestCase {
    func test_patientAndObservationViews_readOfficialExamples() throws {
        let patient = try XCTUnwrap(FHIRFixtures.resource("patient-example").as(FHIRPatient.self))
        XCTAssertEqual(patient.id, "example")
        XCTAssertEqual(patient.names.first?.family, "Chalmers")
        XCTAssertEqual(patient.names.first?.given, ["Peter", "James"])
        XCTAssertEqual(patient.gender, "male")
        XCTAssertEqual(patient.birthDate?.description, "1974-12-25")
        XCTAssertEqual(patient.primitiveExtension("birthDate")?["extension"]?[0]?["url"]?.string, "http://hl7.org/fhir/StructureDefinition/patient-birthTime")
        XCTAssertEqual(patient.deceased?.typeName, "boolean")
        XCTAssertEqual(patient.identifiers.first?.system, "urn:oid:1.2.36.146.595.217.0.1")
        XCTAssertEqual(patient.managingOrganization?.parsed?.resourceType, "Organization")
        XCTAssertNil(patient.resource.as(FHIRObservation.self))

        let observation = try XCTUnwrap(FHIRFixtures.resource("observation-example").as(FHIRObservation.self))
        XCTAssertEqual(observation.status, "final")
        XCTAssertEqual(observation.code?.coding(system: "http://loinc.org")?.code, "29463-7")
        XCTAssertEqual(observation.valueQuantity?.value?.lexical, "185")
        XCTAssertEqual(observation.valueQuantity?.unit, "lbs")
        XCTAssertEqual(observation.effective?.string, "2016-03-28")
        let pressure = try XCTUnwrap(FHIRFixtures.resource("observation-example-bloodpressure").as(FHIRObservation.self))
        XCTAssertEqual(pressure.components.count, 2)
        XCTAssertEqual(pressure.components[0].valueQuantity?.value?.intValue, 107)
        XCTAssertEqual(pressure.components[0].interpretations.first?.codings.first?.code, "N")
    }

    func test_imagingStudyDiagnosticReportAndDocumentReferenceViews() throws {
        let study = try XCTUnwrap(FHIRFixtures.resource("imagingstudy-example").as(FHIRImagingStudy.self))
        XCTAssertEqual(study.studyInstanceUID, "2.16.124.113543.6003.1154777499.30246.19789.3503430045")
        XCTAssertEqual(study.numberOfSeries, 1)
        XCTAssertEqual(study.series.first?.uid, "2.16.124.113543.6003.2588828330.45298.17418.2723805630")
        XCTAssertEqual(study.series.first?.modality?.code, "CT")
        XCTAssertEqual(study.series.first?.instances.first?.sopClass?.code, "urn:oid:1.2.840.10008.5.1.4.1.1.2")
        XCTAssertEqual(study.subject?.reference, "Patient/dicom")
        let reportBundle = try XCTUnwrap(FHIRFixtures.resource("diagnosticreport-example").as(FHIRBundle.self))
        let report = try XCTUnwrap(reportBundle.resources(of: FHIRDiagnosticReport.self).first)
        XCTAssertEqual(report.status, "final")
        XCTAssertEqual(report.results.count, reportBundle.resources(of: FHIRObservation.self).count)
        let firstResult = try XCTUnwrap(report.results.first?.reference)
        XCTAssertEqual(reportBundle.resolve(reference: firstResult)?.resourceType, "Observation")
        let contained = try XCTUnwrap(FHIRFixtures.own("contained-and-references").as(FHIRDiagnosticReport.self))
        XCTAssertEqual(contained.resource.containedResource(id: "obs1")?.resourceType, "Observation")
        XCTAssertEqual(contained.results.first?.parsed?.kind, .contained)
        XCTAssertEqual(contained.results.last?.parsed?.kind, .urn)
        let document = try XCTUnwrap(FHIRFixtures.resource("documentreference-example").as(FHIRDocumentReference.self))
        XCTAssertEqual(document.contents.first?.attachment?.contentType, "application/hl7-v3+xml")
        XCTAssertEqual(document.masterIdentifier?.system, "urn:ietf:rfc:3986")
    }

    func test_bundleViews_resolveReferencesAndExposeRequests() throws {
        let transaction = try XCTUnwrap(FHIRFixtures.resource("bundle-transaction").as(FHIRBundle.self))
        XCTAssertEqual(transaction.type, "transaction")
        XCTAssertEqual(transaction.entries.count, 10)
        XCTAssertEqual(transaction.entries.first?.request?.method, "POST")
        XCTAssertEqual(transaction.entries.first?.fullUrl, "urn:uuid:61ebe359-bfdc-4613-8bf2-c5e300945f0a")
        XCTAssertEqual(transaction.resolve(reference: "urn:uuid:61ebe359-bfdc-4613-8bf2-c5e300945f0a")?.resourceType, "Patient")
        XCTAssertEqual(transaction.entries[1].request?.ifNoneExist, "identifier=http:/example.org/fhir/ids|234234")
        let response = try XCTUnwrap(FHIRFixtures.resource("bundle-response").as(FHIRBundle.self))
        XCTAssertEqual(response.entries.first?.response?.statusCode, 201)
        XCTAssertEqual(response.entries.first?.response?.etag, "W/\"1\"")
        let search = try XCTUnwrap(FHIRFixtures.resource("bundle-example").as(FHIRBundle.self))
        XCTAssertEqual(search.total, 3)
        XCTAssertEqual(search.nextLink, "https://example.com/base/MedicationRequest?patient=347&searchId=ff15fd40-ff71-4b48-b366-09c706bed9d0&page=2")
        XCTAssertEqual(search.resources(of: FHIRMedicationRequest.self).count, 1)
        XCTAssertEqual(search.resolve(reference: "Medication/example")?.resourceType, "Medication")
        let outcome = try XCTUnwrap(FHIRFixtures.resource("operationoutcome-example").as(FHIROperationOutcome.self))
        XCTAssertTrue(outcome.hasErrors)
        XCTAssertEqual(outcome.issues.first?.code, "code-invalid")
    }

    func test_references_parseRelativeAbsoluteContainedAndURN() {
        XCTAssertEqual(FHIRReferenceTarget("Patient/123")?.kind, .relative)
        XCTAssertEqual(FHIRReferenceTarget("Patient/123")?.id, "123")
        XCTAssertEqual(FHIRReferenceTarget("https://x.test/base/Encounter/enc1/_history/3")?.kind, .absolute(base: "https://x.test/base"))
        XCTAssertEqual(FHIRReferenceTarget("https://x.test/base/Encounter/enc1/_history/3")?.versionId, "3")
        XCTAssertEqual(FHIRReferenceTarget("#obs1")?.kind, .contained)
        XCTAssertEqual(FHIRReferenceTarget("urn:uuid:3fdc72f4-a11d-4a9d-9260-a9f745779e1d")?.kind, .urn)
        XCTAssertNil(FHIRReferenceTarget("patient/123"), "resource types are capitalized")
        XCTAssertNil(FHIRReferenceTarget("#"))
        XCTAssertNil(FHIRReferenceTarget("Patient/"))
    }

    func test_mutation_preservesUnknownKeysAndOrdersCanonically() throws {
        var observation = FHIRObservation(id: "new")
        observation.status = "final"
        observation.code = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "8480-6")], text: "Systolic")
        observation.setValue(quantity: FHIRQuantity(value: FHIRNumber(lexical: "120.0"), unit: "mmHg", system: "http://unitsofmeasure.org", code: "mm[Hg]"))
        observation.setEffective(dateTime: "2026-09-12T10:00:00Z")
        observation.json["unknownFutureElement"] = ["k": "v"]
        observation.setValue(string: "replaced")
        XCTAssertNil(observation.json["valueQuantity"])
        XCTAssertEqual(observation.value?.string, "replaced")
        var resource = observation.resource
        resource.normalizeKeyOrder()
        XCTAssertEqual(Array(resource.json.keys.prefix(4)), ["resourceType", "id", "status", "code"])
        XCTAssertEqual(resource.json.keys.last, "unknownFutureElement")
        XCTAssertEqual(resource.relativeReference, "Observation/new")
        let parameters: FHIRParameters = {
            var p = FHIRParameters()
            p.add(name: "count", valueSuffix: "Integer", value: 5)
            p.add(name: "resource", resource: resource)
            return p
        }()
        XCTAssertEqual(parameters.parameter(named: "count")?.value?.number?.intValue, 5)
        XCTAssertEqual(parameters.parameter(named: "resource")?.resource?.resourceType, "Observation")
        let schema = FHIRSchema.r4
        XCTAssertTrue(schema.isResourceType("ImagingStudy"))
        XCTAssertEqual(schema.element(ofType: "Observation", named: "_status")?.type, "code")
        XCTAssertEqual(schema.type("Observation")?.choiceGroups["value"]?.count, 11)
        XCTAssertGreaterThan(schema.resourceTypes.count, 140)
    }
}
