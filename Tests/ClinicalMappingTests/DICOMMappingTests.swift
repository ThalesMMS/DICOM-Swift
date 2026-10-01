import DicomCore
import DicomTestSupport
import Foundation
import XCTest
@testable import ClinicalMapping

final class DICOMMappingTests: XCTestCase {
    func test_anonymousStudyMembers_doNotHideConflictsBetweenKnownPatients() throws {
        func dataset(_ patientID: String?) -> DicomDataSet {
            var elements = [DicomStructuralFixtures.string(.studyInstanceUID, .UI, ["2.25.2364"])]
            if let patientID { elements.append(DicomStructuralFixtures.string(.patientID, .LO, [patientID])) }
            return DicomDataSet(elements: elements)
        }
        XCTAssertTrue(try DICOMClinicalMapper.study(from: [dataset(nil), dataset(nil)]).value.patient.isEmpty)
        for ids in [[nil, "A", nil, "A"], ["A", nil, "A"]] {
            XCTAssertEqual(try DICOMClinicalMapper.study(from: ids.map(dataset)).value.patient.identifier?.value, "A")
        }
        XCTAssertThrowsError(try DICOMClinicalMapper.study(from: [dataset(nil), dataset("A"), dataset(nil), dataset("B")])) {
            guard case MappingError.identityConflict = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func test_blankMutableAuthorities_omitIssuerSequencesWithoutTrapping() throws {
        for authority in ["", " \n\t"] {
            var order = ClinicalOrder(patient: MappingFixtures.ana)
            var identifier = AssignedIdentifier(value: "order-1")
            identifier.authority = authority
            order.accessionNumber = identifier
            order.placerOrderNumber = identifier
            order.fillerOrderNumber = identifier
            let item = try DICOMClinicalMapper.worklistItem(from: order, studyInstanceUID: "2.25.2364").value
            for tag in [0x0008_0051, 0x0040_2026, 0x0040_2027] {
                XCTAssertNil(item.dataSet.element(for: tag))
            }
        }
    }

    func test_correctedStructuredReport_reportsStatusDowngradeAndLostLineage() throws {
        var result = ClinicalResult(patient: MappingFixtures.ana)
        result.status = .corrected
        result.supersedes = AssignedIdentifier(value: "previous")
        let mapped = try DICOMClinicalMapper.structuredReport(from: result)
        XCTAssertEqual(mapped.value.completionFlag, "COMPLETE")
        XCTAssertEqual(mapped.value.verificationFlag, "VERIFIED")
        XCTAssertTrue(mapped.report.entries.contains { $0.kind == .changed && $0.source == "result.status" })
        XCTAssertTrue(mapped.report.lost.contains { $0.source == "result.supersedes" })
        XCTAssertThrowsError(try DICOMClinicalMapper.structuredReport(from: result, options: .init(strict: true)))
        result.status = .final
        result.supersedes = nil
        XCTAssertFalse(try DICOMClinicalMapper.structuredReport(from: result, options: .init(strict: true)).report.hasLoss)
    }

    static func datasets() throws -> [DicomDataSet] {
        try [1, 2].map { index in
            try DCMDecoder(data: try DicomStructuralFixtures.ctSlice(index: index, extra: [
                DicomStructuralFixtures.string(.patientName, .PN, ["Synthetic^Ana Maria"]), DicomStructuralFixtures.string(.patientID, .LO, ["MRN-1001"]),
                DicomDataElement(tag: 0x0010_0021, vr: .LO, value: .strings(["HOSP-A"])), DicomDataElement(tag: 0x0010_0030, vr: .DA, value: .strings(["19800102"])),
                DicomStructuralFixtures.string(.patientSex, .CS, ["F"]), DicomStructuralFixtures.string(.accessionNumber, .SH, ["ACC-42"]),
                DicomDataElement(tag: 0x0008_0051, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [DicomDataElement(tag: 0x0040_0031, vr: .UT, value: .strings(["HOSP-A"]))]))])),
                DicomDataElement(tag: 0x0040_2016, vr: .LO, value: .strings(["PLC-500"])),
                DicomDataElement(tag: 0x0040_2026, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [DicomDataElement(tag: 0x0040_0031, vr: .UT, value: .strings(["RIS-A"]))]))])),
                DicomStructuralFixtures.string(.studyDate, .DA, ["20260913"]), DicomStructuralFixtures.string(.studyTime, .TM, ["081500"]),
                DicomStructuralFixtures.string(.studyDescription, .LO, ["CT Chest"]), DicomStructuralFixtures.string(.referringPhysicianName, .PN, ["Referrer^Rui"])
            ])).dataSet
        }
    }

    func test_order_toWorklistItem_andBack() throws {
        let order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value
        let mapped = try DICOMClinicalMapper.worklistItem(from: order, studyInstanceUID: "2.25.23269902", scheduledStationAETitle: "CT01")
        let item = mapped.value
        XCTAssertEqual(item.patientID, "MRN-1001")
        XCTAssertEqual(item.dataSet.strings(for: 0x0010_0021).first, "HOSP-A")
        XCTAssertEqual(item.accessionNumber, "ACC-42")
        XCTAssertEqual(item.modality, "CT")
        XCTAssertEqual(item.scheduledStationAETitle, "CT01")
        XCTAssertEqual(item.scheduledProcedureStepStartDate, "20260913")
        XCTAssertEqual(item.scheduledProcedureStepStartTime, "080000")
        XCTAssertEqual(item.requestedProcedureDescription, "CT Chest")
        XCTAssertEqual(item.dataSet.strings(for: 0x0040_2016).first, "PLC-500")
        XCTAssertEqual(item.dataSet.element(for: 0x0008_0051)?.sequenceItems.first?.dataSet.strings(for: 0x0040_0031).first, "HOSP-A")
        XCTAssertEqual(item.dataSet.element(for: 0x0032_1064)?.sequenceItems.first?.dataSet.strings(for: .codeValue).first, "71020")
        XCTAssertTrue(mapped.report.entries.contains { $0.target == "(0008,0051)" })
        let back = DICOMClinicalMapper.order(from: item).value
        XCTAssertEqual(back.accessionNumber, order.accessionNumber)
        XCTAssertEqual(back.placerOrderNumber, order.placerOrderNumber)
        XCTAssertEqual(back.fillerOrderNumber, order.fillerOrderNumber)
        XCTAssertEqual(back.procedure, order.procedure)
        XCTAssertEqual(back.scheduledStart, "2026-09-13T08:00:00")
        XCTAssertEqual(back.patient.identifier, order.patient.identifier)
        XCTAssertEqual(back.status, .scheduled)
        var noIdentifiers = order
        noIdentifiers.accessionNumber = nil; noIdentifiers.placerOrderNumber = nil
        XCTAssertThrowsError(try DICOMClinicalMapper.worklistItem(from: noIdentifiers, studyInstanceUID: "2.25.1"))
    }

    func test_datasets_toStudy_andPerformedStep() throws {
        let mapped = try DICOMClinicalMapper.study(from: try Self.datasets())
        let study = mapped.value
        XCTAssertEqual(study.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(study.accessionNumber, AssignedIdentifier(value: "ACC-42", authority: "HOSP-A"))
        XCTAssertEqual(study.placerOrderNumber, AssignedIdentifier(value: "PLC-500", authority: "RIS-A"))
        XCTAssertEqual(study.patient.identifier, AssignedIdentifier(value: "MRN-1001", authority: "HOSP-A"))
        XCTAssertEqual(study.patient.familyName, "Synthetic")
        XCTAssertEqual(study.patient.birthDate, "1980-01-02")
        XCTAssertEqual(study.started, "2026-09-13T08:15:00")
        XCTAssertEqual(study.modalities, ["CT"])
        XCTAssertEqual(study.series.count, 1)
        XCTAssertEqual(study.series.first?.instanceUIDs, ["2.25.23269901", "2.25.23269902"])
        XCTAssertEqual(study.referringPhysician?.givenName, "Rui")
        XCTAssertEqual(mapped.provenance.sourceKind, .dicom)
        let order = try HL7v2ClinicalMapper.order(from: try MappingFixtures.hl7("order")).value
        let item = try DICOMClinicalMapper.worklistItem(from: order, studyInstanceUID: study.studyInstanceUID).value
        let mpps = DICOMClinicalMapper.performedStep(order: order, study: study, stationAETitle: "CT01", worklistItem: item)
        XCTAssertEqual(mpps.startDate, "20260913")
        XCTAssertEqual(mpps.startTime, "081500")
        XCTAssertEqual(mpps.performedProcedureStepDescription, "CT Chest")
        XCTAssertEqual(mpps.dataSet.element(for: 0x0040_0270)?.sequenceItems.first?.dataSet.string(for: .accessionNumber), "ACC-42")
        var mixed = try Self.datasets()
        mixed[1].set(DicomStructuralFixtures.string(.studyInstanceUID, .UI, ["2.25.999"]))
        XCTAssertThrowsError(try DICOMClinicalMapper.study(from: mixed))
    }

    func test_result_toStructuredReport_andBack() throws {
        let result = try HL7v2ClinicalMapper.result(from: try MappingFixtures.hl7("result")).value
        let mapped = try DICOMClinicalMapper.structuredReport(from: result)
        let document = mapped.value
        XCTAssertEqual(document.sopClassUID, DicomSRDocument.basicTextSRStorageSOPClassUID)
        XCTAssertEqual(document.completionFlag, "COMPLETE")
        XCTAssertEqual(document.verificationFlag, "VERIFIED")
        XCTAssertEqual(document.root.children.count, 4)
        XCTAssertEqual(document.root.children[0].valueType, "NUM")
        XCTAssertEqual(document.root.children[0].numericValue, 12.5)
        XCTAssertEqual(document.root.children[0].measurementUnits?.codeValue, "mm")
        XCTAssertEqual(document.root.children[1].valueType, "CODE")
        XCTAssertEqual(document.root.children[2].valueType, "TEXT")
        XCTAssertEqual(document.root.children[3].conceptName?.codeValue, "121071")
        XCTAssertEqual(document.evidenceReferences.first?.studyInstanceUID, "2.25.23269902")
        XCTAssertTrue(mapped.report.lost.contains { $0.source == "result.author" })
        let dataset = DicomStructuredReportBuilder.dataSet(from: document, studyInstanceUID: "2.25.23269902", seriesInstanceUID: "2.25.23269977")
        XCTAssertEqual(dataset.string(for: .modality), "SR")
        let back = DICOMClinicalMapper.result(from: document).value
        XCTAssertEqual(back.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(back.status, .final)
        XCTAssertEqual(back.observations.map(\.value), result.observations.map(\.value))
        XCTAssertEqual(back.reportText, result.reportText)
        XCTAssertEqual(back.procedure?.code, "71020")
        XCTAssertEqual(back.procedure?.system, "http://loinc.org")
        var preliminary = result
        preliminary.status = .preliminary
        XCTAssertEqual(try DICOMClinicalMapper.structuredReport(from: preliminary).value.completionFlag, "PARTIAL")
    }

    func test_study_rejectsPatientIdentifierIssuerAndDemographicConflicts() throws {
        let conflictingFields: [DicomDataElement] = [
            DicomStructuralFixtures.string(.patientID, .LO, ["MRN-OTHER"]),
            DicomDataElement(tag: 0x0010_0021, vr: .LO, value: .strings(["HOSP-B"])),
            DicomStructuralFixtures.string(.patientName, .PN, ["Synthetic^Beatriz"])
        ]
        for field in conflictingFields {
            var datasets = try Self.datasets()
            datasets[1].set(field)
            for ordered in [datasets, Array(datasets.reversed())] {
                XCTAssertThrowsError(try DICOMClinicalMapper.study(from: ordered)) {
                    guard case MappingError.identityConflict = $0 else { return XCTFail("\($0)") }
                }
            }
        }
    }
}
