import DicomCore
import XCTest

/// Issue #2823: a revised SR names what it replaces (Predecessor Documents) and, once verified, who verified it;
/// Basic Text SR relationships are constrained by PS3.3 Table A.35.1-2.
final class DicomSRRevisionTests: XCTestCase {
    private let predecessor = DicomKeyObjectReference(
        studyInstanceUID: "2.25.28231", seriesInstanceUID: "2.25.28232",
        referencedSOPClassUID: DicomSRDocument.basicTextSRStorageSOPClassUID, referencedSOPInstanceUID: "2.25.28233")
    private let observer = DicomSRVerifyingObserver(name: "Reader^Ana", organization: "Isis Radiology",
                                                    dateTime: "20260926153000-0300")

    private func document(verificationFlag: String) -> DicomSRDocument {
        DicomSRDocument(
            sopClassUID: DicomSRDocument.basicTextSRStorageSOPClassUID, sopInstanceUID: "2.25.28234",
            completionFlag: "COMPLETE", verificationFlag: verificationFlag,
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: DicomCodedConcept(codeValue: "18782-3", codingSchemeDesignator: "LN",
                                               codeMeaning: "Diagnostic Imaging Report"),
                continuityOfContent: "SEPARATE",
                children: [DicomSRContentItem(relationshipType: "CONTAINS", valueType: "TEXT",
                    conceptName: DicomCodedConcept(codeValue: "121070", codingSchemeDesignator: "DCM",
                                                   codeMeaning: "Findings"),
                    textValue: "No acute findings.")]),
            predecessorDocuments: [predecessor], verifyingObservers: [observer])
    }

    private func part10(_ document: DicomSRDocument) throws -> Data {
        let dataSet = DicomStructuredReportBuilder.dataSet(from: document, studyInstanceUID: "2.25.28231",
                                                           seriesInstanceUID: "2.25.28235", sopInstanceUID: "2.25.28234")
        return try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
            mediaStorageSOPClassUID: DicomSRDocument.basicTextSRStorageSOPClassUID,
            mediaStorageSOPInstanceUID: "2.25.28234"))
    }

    func test_verifiedRevision_roundTripsAndPassesTheIOD() throws {
        let data = try part10(document(verificationFlag: "VERIFIED"))
        let read = try XCTUnwrap(try DCMDecoder(data: data).structuredReport)
        XCTAssertEqual(read.verificationFlag, "VERIFIED")
        XCTAssertEqual(read.verifyingObservers, [observer])
        XCTAssertEqual(read.predecessorDocuments, [predecessor])
        let report = try DicomInstanceValidator.validate(data)
        XCTAssertTrue(report.diagnostics.filter { $0.severity == .error }.isEmpty,
                      "\(report.diagnostics.filter { $0.severity == .error })")
    }

    func test_unverifiedRevision_hasNoVerifyingObserverAndPassesTheIOD() throws {
        let data = try part10(document(verificationFlag: "UNVERIFIED"))
        let decoder = try DCMDecoder(data: data)
        XCTAssertTrue(decoder.dataSet.sequenceItems(for: 0x0040A073).isEmpty)
        XCTAssertEqual(decoder.structuredReport?.predecessorDocuments, [predecessor])
        let report = try DicomInstanceValidator.validate(data)
        XCTAssertTrue(report.diagnostics.filter { $0.severity == .error }.isEmpty,
                      "\(report.diagnostics.filter { $0.severity == .error })")
    }

    func test_basicTextRelationships_followTableA35_1_2() {
        let basic = DicomSRRelationshipConstraints.basicText
        XCTAssertTrue(basic.permits(source: "CONTAINER", relationship: "CONTAINS", target: "TEXT", byReference: false))
        XCTAssertTrue(basic.permits(source: "CONTAINER", relationship: "CONTAINS", target: "IMAGE", byReference: false))
        XCTAssertFalse(basic.permits(source: "CONTAINER", relationship: "CONTAINS", target: "NUM", byReference: false))
        XCTAssertFalse(basic.permits(source: "CONTAINER", relationship: "CONTAINS", target: "TEXT", byReference: true))
        XCTAssertTrue(basic.permits(source: "TEXT", relationship: "INFERRED FROM", target: "IMAGE", byReference: false))
        XCTAssertFalse(basic.permits(source: "CODE", relationship: "INFERRED FROM", target: "IMAGE", byReference: false))
        XCTAssertTrue(basic.permits(source: "PNAME", relationship: "HAS PROPERTIES", target: "DATE", byReference: false))
        XCTAssertFalse(basic.permits(source: "PNAME", relationship: "HAS PROPERTIES", target: "IMAGE", byReference: false))
        XCTAssertTrue(basic.permits(source: "IMAGE", relationship: "HAS ACQ CONTEXT", target: "CODE", byReference: false))
        XCTAssertEqual(DicomSRRelationshipConstraints(rawValue: DicomSRDocument.basicTextSRStorageSOPClassUID), .basicText)
    }
}
