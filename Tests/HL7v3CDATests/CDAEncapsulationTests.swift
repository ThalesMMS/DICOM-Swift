import DicomCore
import Foundation
import XCTest
@testable import HL7v3CDA

final class CDAEncapsulationTests: CDATestCase {
    private let patient = CDAEncapsulation.PatientModule(patientName: "Synthetic^Patient", patientID: "SYN-2362")

    func test_exportImport_roundTripIsCanonicallyEqualAndEnvelopeValid() throws {
        let document = try CDAFixtures.document("discharge-summary-structured")
        let series = CDAEncapsulation.SeriesModule(studyInstanceUID: "2.25.2362.10", seriesInstanceUID: "2.25.2362.11", seriesNumber: 1, instanceNumber: 1)
        let data = try CDAEncapsulation.export(document: document, patientModule: patient, seriesModule: series,
                                               options: .init(identity: .explicit, allowMismatch: true))
        let decoder = try DCMDecoder(data: data)
        let encapsulated = try XCTUnwrap(decoder.encapsulatedDocument)
        XCTAssertEqual(encapsulated.kind, .cda)
        XCTAssertEqual(encapsulated.mimeType, "text/xml")
        XCTAssertTrue(DicomEncapsulatedDocumentEnvelopeValidator.validate(encapsulated).isValid)
        let (imported, info) = try CDAEncapsulation.import(part10: data)
        XCTAssertEqual(try CDADocumentSerializer().serialize(imported), try CDADocumentSerializer().serialize(document))
        XCTAssertEqual(info.patientID, "SYN-2362")
        XCTAssertEqual(info.documentTitle, document.title?.text)
        XCTAssertEqual(info.conceptName?.codeValue, document.code?.code)
        XCTAssertTrue(info.validation.isValid)
        XCTAssertEqual(decoder.dataSet.string(for: .studyInstanceUID), "2.25.2362.10")
    }

    func test_identity_requiresExplicitModuleAndRefusesMismatchUnlessAllowed() throws {
        let document = try CDAFixtures.document("ccd-minimal")
        XCTAssertThrowsError(try CDAEncapsulation.export(document: document)) {
            XCTAssertEqual($0 as? CDAEncapsulation.Error, .patientModuleRequired)
        }
        let documentIdentity = try XCTUnwrap(document.recordTargets.first?.patientRole?.ids.first?.extension)
        let mismatch = CDAEncapsulation.PatientModule(patientID: documentIdentity + "-other")
        XCTAssertThrowsError(try CDAEncapsulation.export(document: document, patientModule: mismatch)) {
            XCTAssertEqual($0 as? CDAEncapsulation.Error, .patientIdentityMismatch)
        }
        XCTAssertNoThrow(try CDAEncapsulation.export(document: document, patientModule: mismatch, options: .init(allowMismatch: true)))
        let fromDocument = try CDAEncapsulation.export(document: document, options: .init(identity: .fromDocument))
        XCTAssertEqual(try CDAEncapsulation.import(part10: fromDocument).1.patientID, documentIdentity)
    }

    func test_import_refusesNonCDAPayloadsAndCorruptInput() throws {
        let pdf = try DicomEncapsulatedDocumentBuilder.part10Data(documentData: Data("%PDF-1.4\n%%EOF".utf8),
                                                                  options: .init(kind: .pdf))
        XCTAssertThrowsError(try CDAEncapsulation.import(part10: pdf)) { XCTAssertEqual($0 as? CDAEncapsulation.Error, .notCDA) }
        XCTAssertThrowsError(try CDAEncapsulation.import(part10: Data("not dicom".utf8))) {
            guard case CDAEncapsulation.Error.invalidPart10 = $0 else { return XCTFail("wrong error \($0)") }
        }
        var options = DicomEncapsulatedDocumentBuildOptions(kind: .cda)
        options.mimeType = "text/xml"
        options.hl7InstanceIdentifier = "2.25.2362.99"
        let notCDA = try DicomEncapsulatedDocumentBuilder.part10Data(documentData: Data("<html/>".utf8), options: options)
        XCTAssertThrowsError(try CDAEncapsulation.import(part10: notCDA)) {
            guard case CDAEncapsulation.Error.invalidCDA = $0 else { return XCTFail("wrong error \($0)") }
        }
    }
}
