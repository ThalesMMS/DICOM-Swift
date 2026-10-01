import Foundation
import XCTest
@testable import DicomCore

final class DicomStructuredReportWireValidationTests: XCTestCase {
    func test_semanticallySupportedReports_alsoPassValidatedWireRoundTrips() throws {
        for sopClass in [DicomSRDocument.enhancedSRStorageSOPClassUID, DicomSRDocument.comprehensiveSRStorageSOPClassUID,
                         DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID] {
            let document = fixture(sopClass: sopClass)
            XCTAssertTrue(document.semanticValidation.isValid)
            let dataSet = try DicomStructuredReportBuilder.validatedDataSet(from: document,
                studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002", sopInstanceUID: "2.25.23211003")
            // A KOS without an explicit identifier carries the TID 2010 root template its IOD mandates.
            let expectedTemplate = document.templateIdentifier ?? DicomSRProfileConstraints(sopClassUID: sopClass)?.rootTemplateIdentifier
            let template = try XCTUnwrap(dataSet.sequenceItems(for: .contentTemplateSequence).first?.dataSet)
            XCTAssertEqual(template[DicomTag.mappingResource.rawValue]?.vr, .CS)
            XCTAssertEqual(template.string(for: .templateIdentifier), expectedTemplate)
            for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian,
                           .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian] {
                let wire = try DicomDataSetWriter.dataSetData(from: dataSet, transferSyntax: syntax, purpose: .instance)
                let validation = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: syntax)
                XCTAssertEqual(validation.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
                XCTAssertEqual(validation.report[.attributes], .notEvaluated)
                let bytes = try DicomDataSetWriter.part10Data(from: dataSet,
                    options: .init(transferSyntax: syntax, validationPurpose: .instance))
                try export(bytes, name: "report-\(sopClass.split(separator: ".").last ?? "unknown")-\(syntax.rawValue)")
                let decoded = try XCTUnwrap(DCMDecoder(data: bytes).structuredReport)
                XCTAssertTrue(decoded.semanticValidation.isValid)
                XCTAssertEqual(decoded.sopClassUID, sopClass)
                XCTAssertEqual(decoded.templateIdentifier, expectedTemplate)
                XCTAssertEqual(decoded.root.children.map(\.valueType), document.root.children.map(\.valueType))
                XCTAssertEqual(decoded.keyObjectReferences, document.keyObjectReferences)
            }
        }
    }

    func test_historicalMappingResourceVR_isRejectedWhenExplicitlyEncoded() throws {
        let dataSet = try DicomStructuredReportBuilder.validatedDataSet(
            from: fixture(sopClass: DicomSRDocument.enhancedSRStorageSOPClassUID),
            studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002", sopInstanceUID: "2.25.23211003")
        let template = try XCTUnwrap(dataSet.sequenceItems(for: .contentTemplateSequence).first?.dataSet)
            .setting(.init(tag: DicomTag.mappingResource.rawValue, vr: .SH, value: .strings(["DCMR"])))
        let historical = dataSet.setting(.init(tag: DicomTag.contentTemplateSequence.rawValue, vr: .SQ,
            value: .sequence([.init(dataSet: template)])))
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian,
                       .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian] {
            let wire = try DicomDataSetWriter.dataSetData(from: historical, transferSyntax: syntax)
            let validation = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: syntax)
            if syntax == .implicitVRLittleEndian {
                // Implicit VR carries no SH marker; the reader correctly obtains CS from the dictionary.
                XCTAssertEqual(validation.report[.vrAndVM], .passed)
            } else {
                XCTAssertEqual(validation.report[.vrAndVM], .failed)
                XCTAssertTrue(validation.report.diagnostics.contains { $0.code == .incompatibleVR
                    && $0.path == [.tag(DicomTag.contentTemplateSequence.rawValue), .item(0), .tag(DicomTag.mappingResource.rawValue)] })
                let bytes = try DicomDataSetWriter.part10Data(from: historical, options: .init(transferSyntax: syntax))
                try export(bytes, name: "historical-sh-\(syntax.rawValue)")
            }
        }
    }

    func test_evidenceReferences_identifyInstancesWhileContentPreservesFrames() throws {
        let document = fixture(sopClass: DicomSRDocument.enhancedSRStorageSOPClassUID)
        let dataSet = DicomStructuredReportBuilder.dataSet(from: document,
            studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002")
        let study = try XCTUnwrap(dataSet.sequenceItems(for: .currentRequestedProcedureEvidenceSequence).first?.dataSet)
        let series = try XCTUnwrap(study.sequenceItems(for: .referencedSeriesSequence).first?.dataSet)
        let evidence = try XCTUnwrap(series.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        XCTAssertFalse(evidence.contains(DicomTag.referencedFrameNumber.rawValue))
        let content = try XCTUnwrap(dataSet.sequenceItems(for: .contentSequence).first?.dataSet)
        XCTAssertEqual(content.sequenceItems(for: .referencedSOPSequence).first?.dataSet.ints(for: .referencedFrameNumber), [1])
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet)).structuredReport)
        XCTAssertEqual(parsed.keyObjectReferences, document.keyObjectReferences)
    }

    func test_keyObjectBuilder_omitsSRVerificationAndCompletionFlags() throws {
        let dataSet = DicomStructuredReportBuilder.dataSet(
            from: fixture(sopClass: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID),
            studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002")
        XCTAssertFalse(dataSet.contains(DicomTag.completionFlag.rawValue))
        XCTAssertFalse(dataSet.contains(DicomTag.verificationFlag.rawValue))
    }

    func test_instanceEvidence_enrichesEachSelectedFrameReferenceWithStudyAndSeries() throws {
        let base = fixture(sopClass: DicomSRDocument.enhancedSRStorageSOPClassUID)
        let original = try XCTUnwrap(base.evidenceReferences.first)
        let unframed = DicomKeyObjectReference(studyInstanceUID: original.studyInstanceUID,
            seriesInstanceUID: original.seriesInstanceUID, referencedSOPClassUID: original.referencedSOPClassUID,
            referencedSOPInstanceUID: original.referencedSOPInstanceUID)
        let expected = [1, 2].map { frame in
            DicomKeyObjectReference(studyInstanceUID: original.studyInstanceUID, seriesInstanceUID: original.seriesInstanceUID,
                referencedSOPClassUID: original.referencedSOPClassUID, referencedSOPInstanceUID: original.referencedSOPInstanceUID,
                referencedFrameNumbers: [frame])
        }
        let document = DicomSRDocument(root: .init(valueType: "CONTAINER", children: expected.map {
            .init(relationshipType: "CONTAINS", valueType: "IMAGE", referencedSOPs: [$0.sourceImageReference])
        }), evidenceReferences: [unframed])
        XCTAssertEqual(document.keyObjectReferences, expected)
    }

    func test_unrepresentedEvidenceFrames_validatedBuilderRejectsWithoutLosingLegacyScope() throws {
        let base = fixture(sopClass: DicomSRDocument.enhancedSRStorageSOPClassUID)
        let document = DicomSRDocument(sopClassUID: base.sopClassUID, modality: base.modality,
            completionFlag: base.completionFlag, verificationFlag: base.verificationFlag,
            templateIdentifier: base.templateIdentifier,
            root: .init(valueType: "CONTAINER", conceptName: base.root.conceptName, continuityOfContent: "SEPARATE"),
            evidenceReferences: base.evidenceReferences)
        XCTAssertTrue(document.semanticValidation.isValid)
        XCTAssertThrowsError(try DicomStructuredReportBuilder.validatedDataSet(from: document,
            studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002")) {
            XCTAssertEqual($0 as? DicomStructuredReportBuildError, .unrepresentedEvidenceFrames(index: 0))
        }
        let legacy = DicomStructuredReportBuilder.dataSet(from: document,
            studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211002")
        let study = try XCTUnwrap(legacy.sequenceItems(for: .currentRequestedProcedureEvidenceSequence).first?.dataSet)
        let series = try XCTUnwrap(study.sequenceItems(for: .referencedSeriesSequence).first?.dataSet)
        let evidence = try XCTUnwrap(series.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        XCTAssertEqual(evidence.ints(for: .referencedFrameNumber), [1])
    }

    private func export(_ bytes: Data, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_SR_VALIDATION_CORPUS_DIRECTORY"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent(name + ".dcm"))
    }

    private func fixture(sopClass: String) -> DicomSRDocument {
        let isKO = sopClass == DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID
        let title = DicomCodedConcept(codeValue: isKO ? "113000" : "126000", codingSchemeDesignator: "DCM",
                                     codeMeaning: isKO ? "Of Interest" : "Imaging Measurement Report")
        let reference = DicomKeyObjectReference(studyInstanceUID: "2.25.23211001", seriesInstanceUID: "2.25.23211004",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1", referencedSOPInstanceUID: "2.25.23211005",
            referencedFrameNumbers: [1])
        let image = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "IMAGE", conceptName: title,
                                     referencedSOPs: [reference.sourceImageReference])
        return DicomSRDocument(sopClassUID: sopClass, sopInstanceUID: "2.25.23211003", modality: isKO ? "KO" : "SR",
            completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", templateIdentifier: isKO ? nil : "1500",
            root: .init(valueType: "CONTAINER", conceptName: title, continuityOfContent: "SEPARATE", children: [image]),
            evidenceReferences: [reference])
    }
}
