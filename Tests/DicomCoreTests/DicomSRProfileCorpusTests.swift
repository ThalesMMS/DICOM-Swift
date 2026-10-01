import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the offered SR SOP Classes (Enhanced SR, Comprehensive SR, Key Object
/// Selection): common document modules, series module, provenance facts, IOD value types,
/// mandated KOS root template and supplied target metadata.
final class DicomSRProfileCorpusTests: XCTestCase {
    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code)
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
        fulfilsRequestedProcedure: .unsatisfied, includesOtherDocumentContent: .unsatisfied, identicalDocumentsStored: .unsatisfied,
        equivalentCDADocument: .unsatisfied, observationTimeDiffers: .unsatisfied, rootTemplateUsed: .satisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let imageUID = "2.25.23212003"

    func test_originalCorpus_qualifiesOfferedSRProfilesWithStatedFactsAndTargets() throws {
        let concept = DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding")
        let text = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: "Synthetic")
        let stripped = "text-without-concept-name"
        let scoord3D = "enhanced-scoord3d"
        let cases: [(String, String, [DicomSRContentItem], [DicomDataElement], DicomCompositeImageModules.Conditions?, Bool, Expectation)] = [
            ("enhanced", "22", [text], [], nil, true, .passed),
            ("comprehensive", "33", [text], [], nil, true, .passed),
            ("kos", "59", [], [], nil, true, .passed),
            ("comprehensive3d", "34", [text], [], nil, true, .passed),
            ("comprehensive3d-scoord3d", "34", [text], [], nil, true, .passed),
            ("enhanced-no-targets", "22", [text], [], nil, false, .incomplete(.referenceTargetUnavailable)),
            ("enhanced-unstated-facts", "22", [text], [], DicomCompositeImageModules.Conditions(), true, .incomplete(.conditionUndetermined)),
            ("kos-missing-template", "59", [], [.init(tag: 0x0040A504, vr: .SQ, value: .sequence([]))], nil, true,
             .failed(.requiredValueEmpty, [.tag(0x0040A504)])),
            ("kos-wrong-template", "59", [], [template("1500")], nil, true,
             .failed(.attributeValueNotAllowed, [.tag(0x0040A504), .item(0), .tag(0x0040DB00)])),
            (scoord3D, "22", [text], [], nil, true,
             .failed(.attributeValueNotAllowed, [.tag(0x0040A730), .item(2), .tag(0x0040A040)])),
            ("series-modality-wrong", "22", [text], [.init(tag: 0x00080060, vr: .CS, value: .strings(["OT"]))], nil, true,
             .failed(.attributeValueNotAllowed, [.tag(0x00080060)])),
            ("missing-manufacturer", "33", [text], [.init(tag: 0x00080070, vr: .LO, value: .strings([]))], nil, true,
             .failed(.requiredAttributeMissing, [.tag(0x00080070)])),
            ("requested-procedure-required", "22", [text], [], DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied,
                nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
                fulfilsRequestedProcedure: .satisfied, includesOtherDocumentContent: .unsatisfied, identicalDocumentsStored: .unsatisfied,
                equivalentCDADocument: .unsatisfied, observationTimeDiffers: .unsatisfied, rootTemplateUsed: .satisfied), true,
             .failed(.requiredAttributeMissing, [.tag(0x0040A370)])),
            (stripped, "22", [text], [], nil, true,
             .failed(.requiredAttributeMissing, [.tag(0x0040A730), .item(1), .tag(0x0040A043)])),
            ("verified-without-observer", "22", [text], [.init(tag: 0x0040A493, vr: .CS, value: .strings(["VERIFIED"]))], nil, true,
             .failed(.requiredAttributeMissing, [.tag(0x0040A073)])),
            ("sync-missing-trigger", "33", [text], [.init(tag: 0x00200200, vr: .UI, value: .strings(["1.2.840.10008.15.1.1"])),
                .init(tag: 0x00181800, vr: .CS, value: .strings(["Y"]))], nil, true,
             .failed(.requiredAttributeMissing, [.tag(0x0018106A)]))
        ]
        for (name, suffix, children, overrides, conditions, withTargets, expectation) in cases {
            var instance = try fixture(suffix: suffix, children: children)
            if name == stripped { instance = removingConceptName(instance, item: 1) }
            if name == scoord3D || name == "comprehensive3d-scoord3d" { instance = appendingSCOORD3D(instance) }
            for element in overrides.filter({ $0.vm.count > 0 || $0.vr == .SQ }) { instance.set(element) }
            for element in overrides where element.vm.count == 0 && element.vr != .SQ { instance = instance.removing(element.tag) }
            let bytes = try DicomDataSetWriter.part10Data(from: instance)
            let targets = withTargets ? [imageUID: target()] : [:]
            let report = try DicomInstanceValidator.validate(bytes, targets: targets, imageConditions: conditions ?? facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, "\(name): \(report.diagnostics)")
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(name): \(report.diagnostics)")
                XCTAssertTrue(report.diagnostics.contains { $0.code == code }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets, imageConditions: conditions ?? facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SR_PROFILE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                let cliOutcome = try DicomInstanceValidator.validate(bytes, imageConditions: facts).outcome(requiring: requiredLayers)
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "needsTargets": withTargets,
                    "sopClass": "1.2.840.10008.5.1.4.1.1.88." + suffix,
                    "exit": cliOutcome == .passed ? 0 : cliOutcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_comprehensive3DProfile_acceptsSCOORD3DAndRejectsAncestorReferences() throws {
        let concept = DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding")
        let item = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: "Synthetic")
        for suffix in ["33", "34"] {
            let instance = appendingSCOORD3D(try fixture(suffix: suffix, children: [item]))
            let bytes = try DicomDataSetWriter.part10Data(from: instance)
            let report = try DicomInstanceValidator.validate(bytes, targets: [imageUID: target()], imageConditions: facts)
            XCTAssertEqual(report.outcome(requiring: requiredLayers), suffix == "34" ? .passed : .failed,
                "\(suffix): \(report.diagnostics)")
            if suffix == "33" {
                XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueNotAllowed &&
                    $0.path == [.tag(0x0040A730), .item(2), .tag(0x0040A040)] })
            }
        }
        var instance = try fixture(suffix: "34", children: [item])
        var items = instance.sequenceItems(for: .contentSequence).map(\.dataSet)
        items[1].set(.init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            text(0x0040A010, "INFERRED FROM", .CS),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1]))
        ]))])))
        instance.set(.init(tag: 0x0040A730, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) })))
        let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: instance),
            targets: [imageUID: target()], imageConditions: facts)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .contentReferenceAncestorForbidden })
        XCTAssertTrue(DicomInstanceValidator.qualifiedProfiles.contains(DicomSRDocument.comprehensive3DSRStorageSOPClassUID))
    }

    private func fixture(suffix: String, children: [DicomSRContentItem]) throws -> DicomDataSet {
        let isKO = suffix == "59"
        let title = DicomCodedConcept(codeValue: isKO ? "113000" : "126000", codingSchemeDesignator: "DCM",
                                     codeMeaning: isKO ? "Of Interest" : "Imaging Measurement Report")
        let purpose = DicomCodedConcept(codeValue: isKO ? "121080" : "260753009", codingSchemeDesignator: isKO ? "DCM" : "SCT",
                                       codeMeaning: isKO ? "Best illustration of finding" : "Source")
        let image = DicomKeyObjectReference(studyInstanceUID: "2.25.23212001", seriesInstanceUID: "2.25.23212002",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1", referencedSOPInstanceUID: imageUID)
        let document = DicomSRDocument(sopClassUID: "1.2.840.10008.5.1.4.1.1.88." + suffix, modality: isKO ? "KO" : "SR",
            completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", templateIdentifier: isKO ? nil : "1500",
            root: .init(valueType: "CONTAINER", conceptName: title, continuityOfContent: "SEPARATE", children: [
                .init(relationshipType: "CONTAINS", valueType: "IMAGE", conceptName: purpose, referencedSOPs: [image.sourceImageReference])
            ] + children), evidenceReferences: [image])
        var result = try DicomStructuredReportBuilder.validatedDataSet(from: document,
            studyInstanceUID: "2.25.23212001", seriesInstanceUID: "2.25.23212004", sopInstanceUID: "2.25.23212005")
        let common: [DicomDataElement] = [
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080070, "SYNTHETIC", .LO), text(0x00080020, "20260908", .DA), text(0x00080030, "120000", .TM),
            text(0x00080050, "", .SH), text(0x00080090, "", .PN), text(0x00200010, "", .SH), text(0x00200011, "1", .IS),
            text(0x00200013, "1", .IS), text(0x00080023, "20260908", .DA), text(0x00080033, "120000", .TM),
            .init(tag: 0x00081111, vr: .SQ, value: .sequence([]))
        ]
        for element in common { result = result.setting(element) }
        // The builder emits the Type 2 attributes empty and the mandated KOS TID 2010 template itself.
        return result
    }

    /// The builder's semantic matrix excludes SCOORD3D, so the IOD value-type case is derived after encoding.
    private func appendingSCOORD3D(_ instance: DicomDataSet) -> DicomDataSet {
        let items = instance.sequenceItems(for: .contentSequence).map(\.dataSet)
        let point = DicomDataSet(elements: [text(0x0040A010, "CONTAINS", .CS), text(0x0040A040, "SCOORD3D", .CS),
            items[1].element(for: 0x0040A043)!, text(0x00700023, "POINT", .CS),
            .init(tag: 0x00700022, vr: .FL, value: .floats([1, 2, 3])), text(0x30060024, "2.25.23212006", .UI)])
        return instance.setting(.init(tag: 0x0040A730, vr: .SQ, value: .sequence((items + [point]).map { .init(dataSet: $0) })))
    }

    /// The builder refuses anonymous items, so the anonymous TEXT case is derived after encoding.
    private func removingConceptName(_ instance: DicomDataSet, item index: Int) -> DicomDataSet {
        var items = instance.sequenceItems(for: .contentSequence).map(\.dataSet)
        items[index] = items[index].removing(0x0040A043)
        return instance.setting(.init(tag: 0x0040A730, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) })))
    }

    /// Actual metadata of the referenced Enhanced CT instance, as the reference resolver needs it.
    private func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2.1", .UI), text(0x00080018, imageUID, .UI),
            text(0x0020000D, "2.25.23212001", .UI), text(0x0020000E, "2.25.23212002", .UI),
            .init(tag: 0x00280008, vr: .IS, value: .strings(["1"])), .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([2]))])
    }

    private func template(_ identifier: String) -> DicomDataElement {
        .init(tag: 0x0040A504, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [text(0x00080105, "DCMR", .CS),
            text(0x0040DB00, identifier, .CS)]))]))
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
}
