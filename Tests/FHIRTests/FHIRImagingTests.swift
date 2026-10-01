import DicomCore
import DicomTestSupport
import Foundation
import XCTest
@testable import FHIR

final class FHIRImagingTests: XCTestCase {
    static func datasets() throws -> [DicomDataSet] {
        var result: [DicomDataSet] = []
        for index in [3, 1, 2] {
            let data = try DicomStructuralFixtures.ctSlice(index: index, extra: [
                DicomStructuralFixtures.string(.studyDate, .DA, ["20260912"]), DicomStructuralFixtures.string(.studyTime, .TM, ["101500"]),
                DicomStructuralFixtures.string(.accessionNumber, .SH, ["ACC-2363"]), DicomStructuralFixtures.string(.studyDescription, .LO, ["CT Chest"]),
                DicomStructuralFixtures.string(.seriesDescription, .LO, ["Axial"]), DicomStructuralFixtures.string(.bodyPartExamined, .CS, ["CHEST"]),
                DicomStructuralFixtures.string(.patientSex, .CS, ["F"]), DicomDataElement(tag: 0x0010_0030, vr: .DA, value: .strings(["19800102"])),
                DicomDataElement(tag: 0x0010_0021, vr: .LO, value: .strings(["ISIS"])), DicomDataElement(tag: 0x0020_0060, vr: .CS, value: .strings(["L"])),
                DicomStructuralFixtures.string(.referringPhysicianName, .PN, ["Ref^Doc"])
            ])
            result.append(try DCMDecoder(data: data).dataSet)
        }
        let secondSeries = try DicomStructuralFixtures.ctSlice(index: 9, sopClass: "1.2.840.10008.5.1.4.1.1.4", series: "2.25.23269990",
                                                               extra: [DicomStructuralFixtures.string(.seriesNumber, .IS, ["4"])])
        result.append(try DCMDecoder(data: secondSeries).dataSet)
        return result
    }

    func test_imagingStudy_mapsHierarchyIdentifiersAndValidates() async throws {
        let datasets = try Self.datasets()
        let study = try FHIRImagingMapper.imagingStudy(from: datasets, options: .init(patientReference: "Patient/m1", endpointReference: "Endpoint/wado"))
        XCTAssertEqual(study.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(study.identifiers.count, 2)
        XCTAssertEqual(study.identifiers[1].value, "ACC-2363")
        XCTAssertEqual(study.status, "available")
        XCTAssertEqual(study.modalities.map(\.code), ["CT", "MR"])
        XCTAssertEqual(study.subject?.reference, "Patient/m1")
        XCTAssertEqual(study.startedText, "2026-09-12", "no time zone in the dataset: the time is never fabricated")
        XCTAssertEqual(study.referrer?.display, "Ref Doc")
        XCTAssertEqual(study.description, "CT Chest")
        XCTAssertEqual(study.numberOfSeries, 2)
        XCTAssertEqual(study.numberOfInstances, 4)
        let series = try XCTUnwrap(study.series.first)
        XCTAssertEqual(series.uid, "2.25.23269903")
        XCTAssertEqual(series.number, 3)
        XCTAssertEqual(series.modality?.code, "CT")
        XCTAssertEqual(series.bodySite?.display, "CHEST")
        XCTAssertEqual(series.laterality?.code, "7771000")
        XCTAssertEqual(series.instances.map(\.number), [1, 2, 3], "instances are ordered by instance number")
        XCTAssertEqual(series.instances.first?.sopClass?.code, "urn:oid:1.2.840.10008.5.1.4.1.1.2")
        XCTAssertEqual(series.endpoints.first?.reference, "Endpoint/wado")
        XCTAssertEqual(study.series[1].modality?.code, "MR")
        let identifiers = try XCTUnwrap(FHIRImagingMapper.dicomIdentifiers(from: study))
        XCTAssertEqual(identifiers.studyInstanceUID, "2.25.23269902")
        XCTAssertEqual(identifiers.series.map(\.uid), ["2.25.23269903", "2.25.23269990"])
        XCTAssertEqual(identifiers.series[0].instances, ["2.25.23269901", "2.25.23269902", "2.25.23269903"])
        let report = await FHIRValidator().validate(study.resource)
        XCTAssertTrue(report.isValid, report.errors.map { $0.path + " " + $0.detail }.joined(separator: "; "))
        let roundTrip = try FHIRResource(xmlData: try study.resource.xmlData())
        XCTAssertEqual(FHIRFixtures.canonical(.object(roundTrip.json)), FHIRFixtures.canonical(.object(study.resource.json)))
        var ordered = study.resource
        ordered.normalizeKeyOrder()
        XCTAssertEqual(Array(ordered.json.keys.prefix(4)), ["resourceType", "identifier", "status", "modality"])
        XCTAssertThrowsError(try FHIRImagingMapper.imagingStudy(from: [])) { XCTAssertEqual($0 as? FHIRImagingMapper.MappingError, .noDatasets) }
        var other = datasets[0]
        other.set(DicomStructuralFixtures.string(.studyInstanceUID, .UI, ["2.25.999"]))
        XCTAssertThrowsError(try FHIRImagingMapper.imagingStudy(from: datasets + [other])) {
            XCTAssertEqual($0 as? FHIRImagingMapper.MappingError, .multipleStudies(["2.25.23269902", "2.25.999"]))
        }
    }

    func test_imagingStudy_preservesStudyAndSeriesTimezoneOffsets() async throws {
        var datasets = try Self.datasets()
        for index in datasets.indices {
            datasets[index].set(DicomDataElement(tag: 0x0008_0201, vr: .SH, value: .strings([index == 0 ? "+0530" : "-0300"])))
            datasets[index].set(DicomStructuralFixtures.string(.seriesDate, .DA, ["20260912"]))
            datasets[index].set(DicomStructuralFixtures.string(.seriesTime, .TM, ["111530"]))
        }
        let study = try FHIRImagingMapper.imagingStudy(from: datasets)
        XCTAssertEqual(study.startedText, "2026-09-12T10:15:00+05:30")
        XCTAssertEqual(study.series.first?.startedText, "2026-09-12T11:15:30-03:00")
        let validation = await FHIRValidator().validate(study.resource)
        XCTAssertTrue(validation.isValid, validation.errors.map(\.detail).joined(separator: "; "))
        for offset in ["", "+1460", "0300", "-1230"] {
            datasets[0].set(DicomDataElement(tag: 0x0008_0201, vr: .SH, value: .strings([offset])))
            let withoutOffset = try FHIRImagingMapper.imagingStudy(from: datasets)
            XCTAssertEqual(withoutOffset.startedText, "2026-09-12", offset)
        }
    }

    func test_patientEndpointReportAndDocumentShells() async throws {
        let datasets = try Self.datasets()
        let patient = FHIRImagingMapper.patient(from: datasets[0], id: "m1")
        XCTAssertEqual(patient.identifiers.first?.value, "M-1")
        XCTAssertEqual(patient.identifiers.first?.json["assigner"]?["display"]?.string, "ISIS")
        XCTAssertEqual(patient.names.first?.family, "Merge")
        XCTAssertEqual(patient.names.first?.given, ["Case"])
        XCTAssertEqual(patient.gender, "female")
        XCTAssertEqual(patient.birthDateText, "1980-01-02")
        let endpoint = FHIRImagingMapper.endpoint(address: "https://pacs.example.test/dicomweb", name: "lab", id: "wado")
        XCTAssertEqual(endpoint.connectionType?.code, "dicom-wado-rs")
        XCTAssertEqual(endpoint.address, "https://pacs.example.test/dicomweb")
        let study = try FHIRImagingMapper.imagingStudy(from: datasets, options: .init(patientReference: "Patient/m1"))
        let report = FHIRImagingMapper.diagnosticReport(for: study, studyReference: "ImagingStudy/s1",
                                                        code: FHIRCodeableConcept(codings: [FHIRCoding(system: "http://loinc.org", code: "24627-2")]),
                                                        issued: "2026-09-12T10:00:00Z", conclusion: "synthetic", id: "r1")
        XCTAssertEqual(report.imagingStudies.first?.reference, "ImagingStudy/s1")
        XCTAssertEqual(report.subject?.reference, "Patient/m1")
        XCTAssertEqual(report.categories.first?.codings.first?.code, "RAD")
        let document = FHIRImagingMapper.documentReference(subject: study.subject, type: FHIRCodeableConcept(text: "Encapsulated CDA"),
                                                           attachment: FHIRAttachment(contentType: "text/xml", url: "Binary/cda1"),
                                                           studyReference: "ImagingStudy/s1", masterIdentifier: "2.25.2363.1", date: "2026-09-12T10:00:00Z", id: "d1")
        XCTAssertEqual(document.masterIdentifier?.value, "urn:oid:2.25.2363.1")
        XCTAssertEqual(document.contents.first?.attachment?.url, "Binary/cda1")
        for resource in [patient.resource, endpoint.resource, report.resource, document.resource] {
            let verdict = await FHIRValidator().validate(resource)
            XCTAssertTrue(verdict.isValid, resource.resourceType + ": " + verdict.errors.map { $0.path + " " + $0.detail }.joined(separator: "; "))
        }
        let anonymous = try FHIRImagingMapper.imagingStudy(from: datasets)
        XCTAssertEqual(anonymous.subject?.identifier?.value, "M-1", "logical reference when no Patient resource is supplied")
        XCTAssertEqual(anonymous.subject?.display, "Merge Case")
    }

    func test_mappedResources_areValidForTheOracle() throws {
        let datasets = try Self.datasets()
        let study = try FHIRImagingMapper.imagingStudy(from: datasets, options: .init(patientReference: "Patient/m1"))
        let patient = FHIRImagingMapper.patient(from: datasets[0], id: "m1")
        let verdicts = try FHIROracleServer.examine([("study", study.resource.jsonData(), "json"), ("patient", patient.resource.jsonData(), "json"),
                                                      ("study-xml", try study.resource.xmlData(), "xml")])
        XCTAssertEqual(verdicts["study"]?["valid"] as? Bool, true, String(describing: verdicts["study"]?["issues"]))
        XCTAssertEqual(verdicts["patient"]?["valid"] as? Bool, true, String(describing: verdicts["patient"]?["issues"]))
        XCTAssertEqual(verdicts["study-xml"]?["valid"] as? Bool, true)
        XCTAssertEqual(verdicts["study-xml"]?["canonicalSHA256"] as? String, verdicts["study"]?["canonicalSHA256"] as? String)
    }
}
