import DicomCore
import FHIR
import Foundation
import XCTest
@testable import ClinicalMapping

final class ClinicalWorkflowTests: XCTestCase {
    func test_reusedOrderNumbers_doNotLinkOtherOrUnknownPatients() async throws {
        let order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"))
        var other = order.value.patient
        other.identifier = AssignedIdentifier(value: "OTHER", authority: "HOSP-A")
        other.otherIdentifiers = []
        var conflicting = order.value.patient; conflicting.birthDate = "1980-01-01"
        for patient in [other, conflicting, ClinicalPatientIdentity()] {
            for number in ["accession", "placer", "filler"] {
                let store = ClinicalInMemoryWorkflowStore()
                let engine = ClinicalWorkflowEngine(store: store, policy: .init(acceptResultsWithoutOrder: true, refuseIdentityConflicts: false))
                let savedOrder = await engine.ingest(order: order)
                var study = try DICOMClinicalMapper.study(from: try DICOMMappingTests.datasets())
                study.value.patient = patient
                study.value.accessionNumber = number == "accession" ? order.value.accessionNumber : nil
                study.value.placerOrderNumber = number == "placer" ? order.value.placerOrderNumber : nil
                study.value.fillerOrderNumber = number == "filler" ? order.value.fillerOrderNumber : nil
                let studyOutcome = await engine.ingest(study: study)
                XCTAssertNil(studyOutcome.linkedOrderKey, number)
                var result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result"))
                result.value.patient = patient
                result.value.accessionNumber = study.value.accessionNumber
                result.value.placerOrderNumber = study.value.placerOrderNumber
                result.value.fillerOrderNumber = study.value.fillerOrderNumber
                result.value.studyInstanceUID = nil
                let resultOutcome = await engine.ingest(result: result)
                XCTAssertNil(resultOutcome.linkedOrderKey, number)
                let links = await store.links(orderKey: savedOrder.key)
                XCTAssertTrue(links.isEmpty)
            }
        }
    }

    func test_correction_onlySupersedesResultsForTheSamePatient() async throws {
        for includeSamePatient in [false, true] {
            let store = ClinicalInMemoryWorkflowStore()
            let engine = ClinicalWorkflowEngine(store: store, policy: .init(acceptResultsWithoutOrder: true))
            var mapped = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result-corrected"))
            var other = mapped.value; other.version = 10
            other.patient.identifier = AssignedIdentifier(value: "OTHER", authority: "HOSP-A")
            other.patient.otherIdentifiers = []
            await store.saveResult(other, key: try XCTUnwrap(other.idempotencyKey))
            var previous = mapped.value; previous.version = 2
            if includeSamePatient { await store.saveResult(previous, key: try XCTUnwrap(previous.idempotencyKey)) }
            mapped.value.version = 11
            let outcome = await engine.ingest(result: mapped)
            XCTAssertEqual(outcome.supersededResultKey, includeSamePatient ? previous.idempotencyKey : nil)
        }
    }

    func test_identityConflict_takesPriorityOverAnyStoredMatch() async throws {
        let store = ClinicalInMemoryWorkflowStore()
        let engine = ClinicalWorkflowEngine(store: store)
        var order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"))
        let matching = order.value.patient
        var conflicting = matching; conflicting.birthDate = "1981-01-02"
        for swapped in [false, true] {
            await store.saveIdentity(swapped ? conflicting : matching, key: "patient:a")
            await store.saveIdentity(swapped ? matching : conflicting, key: "patient:b")
            let outcome = await engine.ingest(order: order)
            XCTAssertEqual(outcome.disposition, .refused)
            XCTAssertEqual(outcome.identity, .conflict(existingKey: swapped ? "patient:a" : "patient:b", fields: ["birthDate"]))
            order.provenance.sourceIdentifier += "-next"
            order.provenance.sourceDigest = nil
        }
    }

    func test_correction_supersedesHighestNumericVersion() async throws {
        let store = ClinicalInMemoryWorkflowStore()
        let engine = ClinicalWorkflowEngine(store: store, policy: .init(acceptResultsWithoutOrder: true))
        var mapped = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result-corrected"))
        for version in [9, 10] {
            var previous = mapped.value; previous.version = version
            await store.saveResult(previous, key: try XCTUnwrap(previous.idempotencyKey))
        }
        mapped.value.version = 11
        let outcome = await engine.ingest(result: mapped)
        XCTAssertEqual(outcome.supersededResultKey, "result:FIL-900@PACS-A:v10")
    }

    func test_resultBeforeStudy_tracksPendingStudyWithoutOrderLinks() async throws {
        for includeOrder in [false, true] {
            let engine = ClinicalWorkflowEngine(policy: .init(acceptResultsWithoutOrder: true))
            if includeOrder {
                _ = await engine.ingest(order: try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")))
            }
            let result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result"))
            let outcome = await engine.ingest(result: result)
            XCTAssertEqual(outcome.disposition, .created)
            XCTAssertEqual(outcome.linkedOrderKey, includeOrder ? "order:PLC-500@RIS-A" : nil)
            let pending = await engine.pendingStudies
            XCTAssertEqual(pending, ["study:2.25.23269902"])
            _ = await engine.ingest(study: try DICOMClinicalMapper.study(from: try DICOMMappingTests.datasets()))
            let afterArrival = await engine.pendingStudies
            XCTAssertTrue(afterArrival.isEmpty)
        }
    }

    func test_idlessSources_doNotDiscardDistinctOrdersAndStillDeduplicateRetries() async throws {
        var firstOrder = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value
        var secondOrder = firstOrder
        secondOrder.placerOrderNumber = AssignedIdentifier(value: "PLC-501", authority: "RIS-A")
        firstOrder.patient = MappingFixtures.ana
        secondOrder.patient = MappingFixtures.ana
        let fhirOrders = try [firstOrder, secondOrder].map {
            FHIRClinicalMapper.order(from: try FHIRClinicalMapper.serviceRequest(from: $0, subject: "Patient/p1").value, patient: $0.patient)
        }
        let hl7Orders = try [firstOrder, secondOrder].map {
            try HL7v2ClinicalMapper.order(from: HL7v2ClinicalMapper.ormMessage(from: $0, controlID: "").value)
        }
        for orders in [fhirOrders, hl7Orders] {
            let store = ClinicalInMemoryWorkflowStore()
            let engine = ClinicalWorkflowEngine(store: store)
            let first = await engine.ingest(order: orders[0])
            let second = await engine.ingest(order: orders[1])
            let retry = await engine.ingest(order: orders[1])
            XCTAssertEqual(first.disposition, .created)
            XCTAssertEqual(second.disposition, .created)
            XCTAssertEqual(second.key, "order:PLC-501@RIS-A")
            XCTAssertEqual(retry.disposition, .duplicate)
            let counts = await store.counts
            XCTAssertEqual(counts.orders, 2)
        }
    }

    func test_idlessFHIRReports_doNotDiscardDistinctResults() async throws {
        let engine = ClinicalWorkflowEngine(policy: .init(acceptResultsWithoutOrder: true))
        for value in ["R-1", "R-2"] {
            var report = FHIRDiagnosticReport()
            report.identifiers = [FHIRIdentifier(system: "urn:test:reports", value: value)]
            let mapped = FHIRClinicalMapper.result(from: report, observations: [], patient: MappingFixtures.ana)
            let provenance = FHIRClinicalMapper.provenance(targets: [FHIRPatient(id: "p1").resource], source: mapped.provenance)
            XCTAssertNil(provenance.json["entity"]?[0]?["what"]?["identifier"], "absent source IDs must not become empty FHIR identifiers")
            let outcome = await engine.ingest(result: mapped)
            XCTAssertEqual(outcome.disposition, .created)
        }
    }

    func test_realSourceIdentifierNamedUnknown_stillDeduplicates() async throws {
        let engine = ClinicalWorkflowEngine()
        var mapped = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"))
        mapped.provenance.sourceIdentifier = "unknown"
        let first = await engine.ingest(order: mapped)
        mapped.value.placerOrderNumber = AssignedIdentifier(value: "PLC-501", authority: "RIS-A")
        mapped.provenance.sourceDigest = "different-digest"
        let duplicate = await engine.ingest(order: mapped)
        XCTAssertEqual(first.disposition, .created)
        XCTAssertEqual(duplicate.disposition, .duplicate)
        XCTAssertEqual(duplicate.key, first.key)
    }

    func test_orderStudyResult_flowPreservesIdentityAndIsIdempotent() async throws {
        let store = ClinicalInMemoryWorkflowStore()
        let engine = ClinicalWorkflowEngine(store: store)
        let order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order"))
        let first = await engine.ingest(order: order)
        XCTAssertEqual(first.disposition, .created)
        XCTAssertEqual(first.key, "order:PLC-500@RIS-A")
        XCTAssertEqual(first.identity, .new)
        let retry = await engine.ingest(order: order)
        XCTAssertEqual(retry.disposition, .duplicate, "the same message again (retry) creates nothing")
        let resent = await engine.ingest(order: try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")))
        XCTAssertEqual(resent.disposition, .duplicate)
        var counts = await store.counts
        XCTAssertEqual(counts.orders, 1)
        XCTAssertEqual(counts.patients, 1)

        let study = try DICOMClinicalMapper.study(from: try DICOMMappingTests.datasets())
        let studyOutcome = await engine.ingest(study: study)
        XCTAssertEqual(studyOutcome.disposition, .linked)
        XCTAssertEqual(studyOutcome.linkedOrderKey, "order:PLC-500@RIS-A")
        XCTAssertEqual(studyOutcome.identity, .matched(existingKey: "patient:MRN-1001@HOSP-A"))
        let studyRetry = await engine.ingest(study: study)
        XCTAssertEqual(studyRetry.disposition, .duplicate)
        let links = await store.links(orderKey: "order:PLC-500@RIS-A")
        XCTAssertEqual(links, ["study:2.25.23269902"])

        let result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result"))
        let resultOutcome = await engine.ingest(result: result)
        XCTAssertEqual(resultOutcome.disposition, .created)
        XCTAssertEqual(resultOutcome.linkedOrderKey, "order:PLC-500@RIS-A")
        XCTAssertEqual(resultOutcome.linkedStudyKey, "study:2.25.23269902")
        XCTAssertEqual(resultOutcome.identity, .matched(existingKey: "patient:MRN-1001@HOSP-A"))
        let resultRetry = await engine.ingest(result: result)
        XCTAssertEqual(resultRetry.disposition, .duplicate)
        var corrected = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result-corrected"))
        corrected.value.version = 2
        let correction = await engine.ingest(result: corrected)
        XCTAssertEqual(correction.disposition, .superseded)
        XCTAssertEqual(correction.supersededResultKey, "result:FIL-900@PACS-A:v1")
        counts = await store.counts
        XCTAssertEqual(counts.results, 2)
        XCTAssertEqual(counts.patients, 1, "one patient across order, study and result")
        let provenance = await store.provenance(key: "order:PLC-500@RIS-A")
        XCTAssertEqual(provenance.count, 3, "original plus two retries recorded, one order stored")
        XCTAssertEqual(provenance.first?.sourceIdentifier, "MSG-ORM-1")
    }

    func test_identityConflicts_andUnmatchedResults_areRefusedNotMerged() async throws {
        let engine = ClinicalWorkflowEngine(store: ClinicalInMemoryWorkflowStore())
        _ = await engine.ingest(order: try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")))
        var otherAuthority = try DICOMClinicalMapper.study(from: try DICOMMappingTests.datasets())
        otherAuthority.value.patient.identifier = AssignedIdentifier(value: "MRN-1001", authority: "HOSP-B")
        otherAuthority.value.accessionNumber = AssignedIdentifier(value: "ACC-42", authority: "HOSP-B")
        let refused = await engine.ingest(study: otherAuthority)
        XCTAssertEqual(refused.disposition, .refused)
        XCTAssertEqual(refused.identity, .conflict(existingKey: "patient:MRN-1001@HOSP-A", fields: ["identifier authority"]))
        let tolerant = ClinicalWorkflowEngine(store: ClinicalInMemoryWorkflowStore(), policy: .init(refuseIdentityConflicts: false))
        _ = await tolerant.ingest(order: try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")))
        let recorded = await tolerant.ingest(study: otherAuthority)
        XCTAssertEqual(recorded.disposition, .created)
        XCTAssertNil(recorded.linkedOrderKey, "same accession text under another issuer never links")
        if case .conflict = recorded.identity {} else { XCTFail("conflict must still be reported") }

        var orphan = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result"))
        orphan.value.fillerOrderNumber = AssignedIdentifier(value: "FIL-900", authority: "OTHER")
        orphan.value.placerOrderNumber = nil
        orphan.value.accessionNumber = nil
        let noOrder = await engine.ingest(result: orphan)
        XCTAssertEqual(noOrder.disposition, .refused)
        XCTAssertTrue(noOrder.reasons.first?.contains("no matching order") ?? false)
        let accepting = ClinicalWorkflowEngine(store: ClinicalInMemoryWorkflowStore(), policy: .init(acceptResultsWithoutOrder: true))
        let kept = await accepting.ingest(result: orphan)
        XCTAssertEqual(kept.disposition, .created)
        XCTAssertNil(kept.linkedOrderKey)
        let pending = await accepting.pendingStudies
        XCTAssertEqual(pending, ["study:2.25.23269902"], "an accepted orphan still references a study that has not arrived")
        var noKey = orphan
        noKey.value.identifier = nil; noKey.value.fillerOrderNumber = nil
        let withoutKey = await accepting.ingest(result: noKey)
        XCTAssertEqual(withoutKey.disposition, .refused)
    }
}
