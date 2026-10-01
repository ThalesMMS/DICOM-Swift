import FHIR
import Foundation
import XCTest
@testable import ClinicalMapping

final class FHIRMappingTests: XCTestCase {
    func test_issuedWithoutZone_usesEffectiveDateWithoutFalseLoss() throws {
        for issued in ["2026-09-15", "2026-09-15T12:00:00"] {
            var result = ClinicalResult(patient: MappingFixtures.ana)
            result.issued = issued
            let mapped = try FHIRClinicalMapper.diagnosticReport(from: result, subject: "Patient/p1", options: .init(strict: true))
            XCTAssertNil(mapped.value.report.issuedText)
            XCTAssertEqual(mapped.value.report.effective?.string, "2026-09-15")
            XCTAssertFalse(mapped.report.hasLoss)
            XCTAssertTrue(mapped.report.entries.contains { $0.kind == .changed && $0.target == "DiagnosticReport.effectiveDateTime" })
        }
    }

    func test_identity_patientRoundTripKeepsAuthorities() async throws {
        let ana = MappingFixtures.ana
        var identity = ana
        identity.otherIdentifiers = [AssignedIdentifier(value: "NAT-77", authority: "urn:oid:2.16.840.1.113883.4.1")]
        let patient = FHIRClinicalMapper.patient(from: identity, id: "p1").value
        XCTAssertEqual(patient.identifiers.count, 2)
        XCTAssertEqual(patient.identifiers[0].json["assigner"]?["display"]?.string, "HOSP-A", "local namespaces are kept as assigner")
        XCTAssertEqual(patient.identifiers[1].system, "urn:oid:2.16.840.1.113883.4.1", "URI authorities become systems")
        XCTAssertEqual(patient.gender, "female")
        XCTAssertEqual(patient.names.first?.given, ["Ana", "Maria"])
        let report = await FHIRValidator().validate(patient.resource)
        XCTAssertTrue(report.isValid, report.errors.map(\.detail).joined(separator: ";"))
        let back = FHIRClinicalMapper.identity(from: patient).value
        XCTAssertEqual(back, identity)
    }

    func test_order_serviceRequestRoundTrip_andImagingStudy() async throws {
        let order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value
        let request = try FHIRClinicalMapper.serviceRequest(from: order, subject: "Patient/p1", id: "sr1").value
        XCTAssertEqual(request.status, "active")
        XCTAssertEqual(request.intent, "order")
        XCTAssertEqual(request.identifiers.map { $0.type?.codings.first?.code }, ["PLAC", "FILL", "ACSN"])
        XCTAssertEqual(request.identifiers[2].json["assigner"]?["display"]?.string, "HOSP-A")
        XCTAssertEqual(request.occurrence?.string, "2026-09-13", "a time without zone is not invented into a FHIR dateTime")
        XCTAssertTrue(try FHIRClinicalMapper.serviceRequest(from: order, subject: "Patient/p1").report.entries.contains { $0.reason == "timeDroppedWithoutTimeZone" })
        XCTAssertEqual(request.string("priority"), "routine")
        let validation = await FHIRValidator().validate(request.resource)
        XCTAssertTrue(validation.isValid, validation.errors.map { $0.path + " " + $0.detail }.joined(separator: ";"))
        let back = FHIRClinicalMapper.order(from: request, patient: order.patient).value
        XCTAssertEqual(back.placerOrderNumber, order.placerOrderNumber)
        XCTAssertEqual(back.fillerOrderNumber, order.fillerOrderNumber)
        XCTAssertEqual(back.accessionNumber, order.accessionNumber)
        XCTAssertEqual(back.procedure, order.procedure)
        XCTAssertEqual(back.modality, "CT")
        XCTAssertEqual(back.priority, "R")

        let study = try DICOMClinicalMapper.study(from: try DICOMMappingTests.datasets()).value
        let imaging = FHIRClinicalMapper.imagingStudy(from: study, subject: "Patient/p1", basedOn: "ServiceRequest/sr1", id: "is1").value
        XCTAssertEqual(imaging.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(imaging.identifiers[1].value, "ACC-42")
        XCTAssertEqual(imaging.basedOn.first?.reference, "ServiceRequest/sr1")
        XCTAssertEqual(imaging.numberOfInstances, 2)
        XCTAssertEqual(imaging.series.first?.instances.map { $0.sopClass?.code }, ["urn:oid:1.2.840.10008.5.1.4.1.1.2", "urn:oid:1.2.840.10008.5.1.4.1.1.2"])
        let imagingValidation = await FHIRValidator().validate(imaging.resource)
        XCTAssertTrue(imagingValidation.isValid, imagingValidation.errors.map { $0.path + " " + $0.detail }.joined(separator: ";"))
        let studyBack = try FHIRClinicalMapper.study(from: imaging, patient: study.patient).value
        XCTAssertEqual(studyBack.studyInstanceUID, study.studyInstanceUID)
        XCTAssertEqual(studyBack.accessionNumber, study.accessionNumber)
        XCTAssertEqual(studyBack.series.map(\.instanceUIDs), study.series.map(\.instanceUIDs))
        XCTAssertEqual(studyBack.series.map(\.sopClassUIDs), study.series.map(\.sopClassUIDs))
    }

    func test_legacySeries_reportsMissingSOPClassesWithoutInventingCodes() async throws {
        let series = try JSONDecoder().decode(ClinicalStudy.Series.self, from: Data("""
        {"uid":"2.25.23269903","modality":"CT","instanceUIDs":["2.25.23269901"]}
        """.utf8))
        XCTAssertNil(series.sopClassUIDs)
        var study = ClinicalStudy(studyInstanceUID: "2.25.23269902", patient: MappingFixtures.ana)
        study.series = [series]
        let mapped = FHIRClinicalMapper.imagingStudy(from: study, subject: "Patient/p1")
        XCTAssertEqual(mapped.value.series.first?.instances.first?.uid, "2.25.23269901")
        XCTAssertNil(mapped.value.series.first?.instances.first?.sopClass)
        XCTAssertTrue(mapped.report.entries.contains { $0.reason == "sourceSOPClassUIDAbsent" })
        let validation = await FHIRValidator().validate(mapped.value.resource)
        XCTAssertTrue(validation.errors.contains { $0.path == "ImagingStudy.series[0].instance[0].sopClass" && $0.code == "required" })
    }

    func test_result_diagnosticReportBundleWithProvenance_andBack() async throws {
        let result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result")).value
        let mapped = try FHIRClinicalMapper.diagnosticReport(from: result, subject: "Patient/p1", basedOn: "ServiceRequest/sr1", imagingStudy: "ImagingStudy/is1", idPrefix: "dr1")
        let bundle = mapped.value
        XCTAssertEqual(bundle.report.status, "final")
        XCTAssertEqual(bundle.report.identifiers.map { $0.type?.codings.first?.code }, ["PLAC", "FILL", "ACSN"])
        XCTAssertEqual(bundle.report.imagingStudies.first?.reference, "ImagingStudy/is1")
        XCTAssertEqual(bundle.report.results.count, 3)
        XCTAssertEqual(bundle.report.conclusion, "Follow-up CT in 3 months.")
        XCTAssertNil(bundle.report.issuedText, "issued is an instant and the source had no zone")
        XCTAssertEqual(bundle.report.effective?.string, "2026-09-13")
        XCTAssertEqual(bundle.report.performers.first?.display, "Rita Reader")
        XCTAssertEqual(bundle.observations[0].valueQuantity?.value?.lexical, "12.5")
        XCTAssertEqual(bundle.observations[0].valueQuantity?.code, "mm")
        XCTAssertEqual(bundle.observations[0].interpretations.first?.codings.first?.code, "H")
        XCTAssertEqual(bundle.observations[1].value?.typeName, "CodeableConcept")
        XCTAssertEqual(bundle.observations[2].value?.string, "Single 12.5 mm nodule in the right upper lobe.")
        XCTAssertEqual(bundle.provenance.resourceType, "Provenance")
        XCTAssertEqual(bundle.provenance.json["target"]?.array?.count, 4)
        XCTAssertEqual(bundle.provenance.json["entity"]?[0]?["role"]?.string, "source")
        let validator = FHIRValidator()
        for resource in [bundle.report.resource] + bundle.observations.map(\.resource) + [bundle.provenance] {
            let report = await validator.validate(resource)
            XCTAssertTrue(report.isValid, resource.resourceType + ": " + report.errors.map { $0.path + " " + $0.detail }.joined(separator: ";"))
        }
        let back = FHIRClinicalMapper.result(from: bundle.report, observations: bundle.observations, patient: result.patient).value
        XCTAssertEqual(back.fillerOrderNumber, result.fillerOrderNumber)
        XCTAssertEqual(back.accessionNumber, result.accessionNumber)
        XCTAssertEqual(back.status, .final)
        XCTAssertEqual(back.observations.map(\.value), result.observations.map(\.value))
        XCTAssertEqual(back.reportText, result.reportText)

        var corrected = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result-corrected")).value
        corrected.supersedes = result.identifier
        corrected.version = 2
        let correctedBundle = try FHIRClinicalMapper.diagnosticReport(from: corrected, subject: "Patient/p1", idPrefix: "dr2").value
        XCTAssertEqual(correctedBundle.report.status, "corrected")
        XCTAssertEqual(correctedBundle.report.extensions.first?.url, "http://isis.test/fhir/StructureDefinition/supersedes")
        XCTAssertEqual(FHIRClinicalMapper.result(from: correctedBundle.report, observations: correctedBundle.observations, patient: result.patient).value.supersedes, result.identifier)
        XCTAssertFalse(mapped.report.entries.contains { ($0.reason ?? "").contains("nodule") }, "no clinical text in reports")
    }
}
