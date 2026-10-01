import Foundation
import XCTest
@testable import FHIR

/// REST client qualified against the independent Python FHIR server (fhir.resources validation).
final class FHIRClientOracleTests: XCTestCase {
    private func patient(_ family: String, given: String, identifier: String, birth: String = "1980-01-02") -> FHIRResource {
        var patient = FHIRPatient()
        patient.names = [FHIRHumanName(family: family, given: [given])]
        patient.identifiers = [FHIRIdentifier(system: "urn:isis:mrn", value: identifier)]
        patient.gender = "female"
        patient.birthDateText = birth
        return patient.resource
    }

    func test_crud_vread_history_andConditionalHeaders() async throws {
        let server = try await FHIROracleServer.start()
        defer { server.stop() }
        let client = server.client()
        let capabilities = try await client.capabilities().get()
        XCTAssertEqual(capabilities.fhirVersion, "4.0.1")
        XCTAssertTrue(capabilities.interactions(for: "Patient").contains("search-type"))

        let created = try await client.create(patient("Synthetic", given: "Ana", identifier: "MRN-1"))
        let createdResource = try XCTUnwrap(created.value.flatMap { $0 })
        let id = try XCTUnwrap(createdResource.id)
        XCTAssertEqual(created.metadata?.status, 201)
        XCTAssertEqual(created.metadata?.versionId, "1")
        XCTAssertTrue(created.metadata?.location?.hasSuffix("/Patient/\(id)/_history/1") ?? false)

        let read = try await client.read("Patient", id: id)
        XCTAssertEqual(read.value??.as(FHIRPatient.self)?.names.first?.family, "Synthetic")
        let notModified = try await client.read("Patient", id: id, ifNoneMatch: "W/\"1\"")
        XCTAssertNil(notModified.value.flatMap { $0 })
        XCTAssertEqual(notModified.metadata?.status, 304)

        var updated = try XCTUnwrap(read.value??.as(FHIRPatient.self))
        updated.gender = "other"
        let conflict = try await client.update(updated.resource, ifMatch: "W/\"99\"")
        XCTAssertTrue(conflict.failure?.isVersionConflict ?? false)
        XCTAssertEqual(conflict.failure?.outcome?.issues.first?.code, "conflict")
        XCTAssertFalse(conflict.failure?.uncertain ?? true)
        let accepted = try await client.update(updated.resource, ifMatch: "W/\"1\"")
        XCTAssertEqual(accepted.metadata?.versionId, "2")
        XCTAssertEqual(accepted.value??.as(FHIRPatient.self)?.gender, "other")

        let first = try await client.vread("Patient", id: id, version: "1").get()
        XCTAssertEqual(first.as(FHIRPatient.self)?.gender, "female")
        let history = try await client.history("Patient", id: id).get()
        XCTAssertEqual(history.type, "history")
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.map { $0.request?.method }, ["POST", "PUT"])

        let missing = try await client.read("Patient", id: "does-not-exist")
        XCTAssertTrue(missing.failure?.isNotFound ?? false)
        XCTAssertEqual(missing.failure?.outcome?.issues.first?.code, "not-found")

        let deleted = try await client.delete("Patient", id: id)
        XCTAssertEqual(deleted.metadata?.status, 204)
        let gone = try await client.read("Patient", id: id)
        XCTAssertEqual(gone.failure?.status, 410)
        let invalid = try await client.create(FHIRResource(jsonData: Data(#"{"resourceType":"Patient","name":"not a list"}"#.utf8)))
        XCTAssertEqual(invalid.failure?.status, 400)
        XCTAssertEqual(invalid.failure?.outcome?.hasErrors, true)
    }

    func test_conditionalCreate_search_paging_includesAndChaining() async throws {
        let server = try await FHIROracleServer.start()
        defer { server.stop() }
        let client = server.client()
        var ids: [String] = []
        for index in 0..<7 {
            let created = try await client.create(patient("Family\(index)", given: "Given", identifier: "MRN-\(index)", birth: "199\(index)-05-01"))
            ids.append(try XCTUnwrap(created.value??.id))
        }
        let duplicate = try await client.create(patient("Family0", given: "Given", identifier: "MRN-0"), ifNoneExist: "identifier=urn:isis:mrn|MRN-0")
        XCTAssertEqual(duplicate.metadata?.status, 200, "conditional create returns the existing resource")
        XCTAssertEqual(duplicate.value??.id, ids[0])

        var observation = FHIRObservation()
        observation.status = "final"
        observation.code = FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "29463-7")])
        observation.subject = FHIRReference(reference: "Patient/" + ids[1])
        observation.setValue(quantity: FHIRQuantity(value: FHIRNumber(lexical: "70.5"), unit: "kg"))
        observation.setEffective(dateTime: "2026-09-12T10:00:00Z")
        let createdObservation = try await client.create(observation.resource)
        XCTAssertEqual(createdObservation.metadata?.status, 201)

        let page = try await client.search(FHIRSearchQuery(resourceType: "Patient").count(3).sorted(by: "birthDate")).get()
        XCTAssertEqual(page.matches.count, 3)
        XCTAssertEqual(page.total, 7)
        XCTAssertNotNil(page.nextURL)
        let pages = try await client.collect(FHIRSearchQuery(resourceType: "Patient").count(3)).get()
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.flatMap(\.matches).count, 7)

        var bounded = server.client().configuration
        bounded.maxPages = 2
        let limited = try await FHIRClient(configuration: bounded).collect(FHIRSearchQuery(resourceType: "Patient").count(3))
        XCTAssertEqual(limited.failure?.reason, .pageLimit)

        let byBirth = try await client.search(FHIRSearchQuery(resourceType: "Patient").where(.date("birthdate", .ge, "1995"))).get()
        XCTAssertEqual(byBirth.matches.count, 2)
        let exact = try await client.search(FHIRSearchQuery(resourceType: "Patient").where(.string("family", "Family3", modifier: .exact))).get()
        XCTAssertEqual(exact.matches.map(\.id), [ids[3]])
        let byPost = try await client.searchByPost(FHIRSearchQuery(resourceType: "Patient").where(.string("family", "family3", modifier: .contains))).get()
        XCTAssertEqual(byPost.matches.count, 1)

        let included = try await client.search(FHIRSearchQuery(resourceType: "Observation")
            .where(.token("code", system: "http://loinc.org", code: "29463-7")).include("Observation", "subject")).get()
        XCTAssertEqual(included.matches.count, 1)
        XCTAssertEqual(included.included.map(\.resourceType), ["Patient"])
        let revIncluded = try await client.search(FHIRSearchQuery(resourceType: "Patient").where(.string("_id", ids[1])).revInclude("Observation", "subject")).get()
        XCTAssertEqual(revIncluded.included.map(\.resourceType), ["Observation"])
        let chained = try await client.search(FHIRSearchQuery(resourceType: "Observation").where(.chained("subject", targetType: "Patient", "family", "Family1"))).get()
        XCTAssertEqual(chained.matches.count, 1)
        let has = try await client.search(FHIRSearchQuery(resourceType: "Patient").where(.has("Observation", "subject", "code", "29463-7"))).get()
        XCTAssertEqual(has.matches.map(\.id), [ids[1]])
        let outside = try await client.search(url: URL(string: "http://127.0.0.1:1/Patient")!)
        XCTAssertEqual(outside.failure?.reason, .originNotAllowed)
    }

    func test_transactionAndBatch_resolveURNsAndReportPerEntry() async throws {
        let server = try await FHIROracleServer.start()
        defer { server.stop() }
        let client = server.client()
        let patientURN = "urn:uuid:8c1b0f6a-1111-4c6b-9d2e-000000000001"
        var observation = FHIRObservation()
        observation.status = "final"
        observation.code = FHIRCodeableConcept(text: "synthetic")
        observation.subject = FHIRReference(reference: patientURN)
        let transaction = FHIRBundle(type: "transaction", entries: [
            FHIRBundleEntry(fullUrl: patientURN, resource: patient("Tx", given: "One", identifier: "TX-1"), request: FHIRBundleRequest(method: "POST", url: "Patient")),
            FHIRBundleEntry(resource: observation.resource, request: FHIRBundleRequest(method: "POST", url: "Observation"))
        ])
        let response = try await client.transaction(transaction).get()
        XCTAssertEqual(response.type, "transaction-response")
        XCTAssertEqual(response.entries.map { $0.response?.statusCode }, [201, 201])
        let storedObservation = try XCTUnwrap(response.entries[1].resource?.as(FHIRObservation.self))
        let patientReference = try XCTUnwrap(storedObservation.subject?.reference)
        XCTAssertTrue(patientReference.hasPrefix("Patient/"), "urn:uuid replaced by the server-assigned id")
        let readBack = try await client.read("Patient", id: String(patientReference.dropFirst(8)))
        XCTAssertEqual(readBack.value??.resourceType, "Patient")

        let badTransaction = FHIRBundle(type: "transaction", entries: [
            FHIRBundleEntry(resource: patient("Tx", given: "Two", identifier: "TX-2"), request: FHIRBundleRequest(method: "POST", url: "Patient")),
            FHIRBundleEntry(resource: try FHIRResource(jsonData: Data(#"{"resourceType":"Patient","name":"not a list"}"#.utf8)), request: FHIRBundleRequest(method: "POST", url: "Patient"))
        ])
        let rejected = try await client.transaction(badTransaction)
        XCTAssertEqual(rejected.failure?.status, 400, "transactions are all-or-nothing")
        let afterRollback = try await client.search(FHIRSearchQuery(resourceType: "Patient").where(.token("identifier", system: "urn:isis:mrn", code: "TX-2"))).get()
        XCTAssertEqual(afterRollback.matches.count, 0)

        let batch = FHIRBundle(type: "batch", entries: [
            FHIRBundleEntry(resource: patient("Batch", given: "Ok", identifier: "B-1"), request: FHIRBundleRequest(method: "POST", url: "Patient")),
            FHIRBundleEntry(resource: try FHIRResource(jsonData: Data(#"{"resourceType":"Patient","birthDate":"1974-13"}"#.utf8)), request: FHIRBundleRequest(method: "POST", url: "Patient")),
            FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Patient/nope"))
        ])
        let batchResponse = try await client.transaction(batch).get()
        XCTAssertEqual(batchResponse.type, "batch-response")
        XCTAssertEqual(batchResponse.entries.map { $0.response?.statusCode }, [201, 400, 404])
        XCTAssertEqual(batchResponse.entries[1].response?.outcome?.as(FHIROperationOutcome.self)?.hasErrors, true)
        let wrongType = try await client.transaction(FHIRBundle(type: "searchset"))
        XCTAssertEqual(wrongType.failure?.reason, .invalidRequest)
    }

    func test_xmlFormat_andOperationsAgainstOracle() async throws {
        let server = try await FHIROracleServer.start()
        defer { server.stop() }
        let xml = server.client(format: .xml)
        let created = try await server.client().create(patient("Xml", given: "Path", identifier: "X-1"))
        let id = try XCTUnwrap(created.value??.id)
        let read = try await xml.read("Patient", id: id).get()
        XCTAssertEqual(read?.as(FHIRPatient.self)?.identifiers.first?.value, "X-1")
        let missingOperation = try await xml.operation("everything", type: "Patient", id: id)
        XCTAssertEqual(missingOperation.failure?.status, 404, "unsupported operations surface the server verdict")
        let headerClient = server.client { ["Authorization": "Bearer synthetic-token"] }
        let withHeader = try await headerClient.read("Patient", id: id)
        XCTAssertNotNil(withHeader.value.flatMap { $0 })
    }
}
