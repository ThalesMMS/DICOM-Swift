import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the RT Dose, RT Structure Set and RT Plan IODs: module usage, the
/// grid-based dose description, structure set and plan coherence, the beam/brachy exclusion and the
/// referenced instances against supplied targets.
final class DicomRTCorpusTests: XCTestCase {
    func test_rtDoseDoesNotApplyGeneralSeriesOnlyConstraints() throws {
        let instance = fixture(.dose).setting(text(0x00200060, "BOTH", .CS))
        let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
            mediaStorageSOPClassUID: sop(.dose), mediaStorageSOPInstanceUID: instanceUID(.dose)))
        let report = try DicomInstanceValidator.validate(bytes, targets: targets(), imageConditions: facts)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .passed, "\(report.diagnostics)")
    }

    func test_structureSetBuilder_producesQualifiedInstance() throws {
        let model = DicomRTStructureSet(sopInstanceUID: "2.25.2346081", label: "PARITY",
            rois: [.init(number: 1, name: "PARITY", referencedFrameOfReferenceUID: "2.25.2346082",
                generationAlgorithm: "MANUAL")], roiContours: [.init(referencedROINumber: 1,
                    contours: [.init(geometricType: "POINT", points: [.zero])])],
            referencedFramesOfReference: [.init(frameOfReferenceUID: "2.25.2346082")])
        let data = DicomRTStructureSetBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let report = try DicomInstanceValidator.validate(DicomGeometryCorpusTests.bytes(data), imageConditions: facts)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .passed, "\(report.diagnostics)")
        let xor = DicomRTStructureSet(rois: model.rois, roiContours: [
            .init(referencedROINumber: 1, contours: [
                .init(geometricType: .closedPlanarXOR, points: [.zero, .init(10, 0, 0), .init(10, 10, 0), .init(0, 10, 0)]),
                .init(geometricType: .closedPlanarXOR, points: [.init(2, 2, 0), .init(3, 2, 0), .init(3, 3, 0), .init(2, 3, 0)])
            ])], referencedFramesOfReference: model.referencedFramesOfReference)
        let xorData = DicomRTStructureSetBuilder.dataSet(from: xor, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let xorReport = try DicomInstanceValidator.validate(DicomGeometryCorpusTests.bytes(xorData), imageConditions: facts)
        XCTAssertEqual(xorReport.outcome(requiring: requiredLayers), .passed, "\(xorReport.diagnostics)")
    }

    private enum Kind { case dose, structureSet, plan }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let planUID = "2.25.23279905", structureSetUID = "2.25.23279903", doseUID = "2.25.23279902", imageUID = "2.25.23279980"
    private let studyUID = "2.25.23279996", imageSeriesUID = "2.25.23279981", frameOfReferenceUID = "2.25.23279998"

    func test_originalCorpus_qualifiesRTDoseStructureSetAndPlanAndRejectsViolations() throws {
        let beam: [DicomValidationReport.PathComponent] = [.tag(0x300A00B0), .item(0)]
        let firstPoint = beam + [.tag(0x300A0111), .item(0)]
        let cases: [(String, Kind, (DicomDataSet) -> DicomDataSet, Expectation)] = [
            ("rtdose-plan", .dose, { $0 }, .passed),
            ("rtdose-beam", .dose, { self.beamDose($0) }, .passed),
            ("rtdose-dvh-only", .dose, { self.dvhOnly($0) }, .passed),
            ("rtstruct", .structureSet, { $0 }, .passed),
            ("rtstruct-approved", .structureSet, { $0.setting(self.text(0x300E0002, "APPROVED", .CS)).setting(self.text(0x300E0004, "20260909", .DA))
                .setting(self.text(0x300E0005, "120000", .TM)).setting(self.text(0x300E0008, "REVIEWER", .PN)) }, .passed),
            ("rtplan-beams", .plan, { $0 }, .passed),
            ("rtplan-brachy", .plan, { self.brachy($0) }, .passed),
            ("rtplan-wedge", .plan, { self.wedged($0, positions: true) }, .passed),
            ("rtdose-missing-dose-units", .dose, { $0.removing(0x30040002) }, .failed(.requiredAttributeMissing, [.tag(0x30040002)])),
            ("rtdose-plan-without-reference", .dose, { $0.removing(0x300C0002) }, .failed(.requiredAttributeMissing, [.tag(0x300C0002)])),
            ("rtdose-beam-without-fraction-group", .dose, { $0.setting(self.text(0x3004000A, "BEAM", .CS)) },
             .failed(.requiredAttributeMissing, [.tag(0x300C0002), .item(0), .tag(0x300C0020)])),
            ("rtdose-offsets-count", .dose, { self.frames($0, 3) }, .failed(.attributeValueContradiction, [.tag(0x3004000C)])),
            ("rtdose-offsets-not-monotonic", .dose, { self.frames($0, 3).setting(self.text(0x3004000C, "0\\2\\1", .DS)) },
             .failed(.attributeValueContradiction, [.tag(0x3004000C)])),
            ("rtdose-bits-12", .dose, { $0.setting(self.number(0x00280100, 12)).setting(self.number(0x00280101, 12)).setting(self.number(0x00280102, 11)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280100)])),
            ("rtdose-missing-frame-of-reference", .dose, { $0.removing(0x00200052).removing(0x00201040) },
             .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("rtdose-multiple-plans-for-plan", .dose, { $0.setting(self.sequence(0x300C0002, [self.reference("1.2.840.10008.5.1.4.1.1.481.5", self.planUID),
                self.reference("1.2.840.10008.5.1.4.1.1.481.5", "2.25.23279906")])) },
             .failed(.sequenceItemCountInvalid, [.tag(0x300C0002)])),
            ("rtdose-modality-wrong", .dose, { $0.setting(self.text(0x00080060, "RTSTRUCT", .CS)) }, .failed(.attributeValueNotAllowed, [.tag(0x00080060)])),
            ("rtdose-grid-without-scaling", .dose, { $0.removing(0x3004000E) }, .failed(.requiredAttributeMissing, [.tag(0x3004000E)])),
            ("rtdose-plan-class-mismatch", .dose, { $0.setting(self.sequence(0x300C0002, [self.reference("1.2.840.10008.5.1.4.1.1.481.3", self.planUID)])) },
             .failed(.referenceIdentityContradiction, [.tag(0x300C0002), .item(0), .tag(0x00081150)])),
            ("rtstruct-contour-points-mismatch", .structureSet, { self.replacingContour($0) { $0.setting(self.text(0x30060046, "4", .IS)) } },
             .failed(.attributeValueContradiction, [.tag(0x30060039), .item(0), .tag(0x30060040), .item(0), .tag(0x30060050)])),
            ("rtstruct-contour-unknown-roi", .structureSet, { self.replacingROIContour($0) { $0.setting(self.text(0x30060084, "9", .IS)) } },
             .failed(.referenceSelectionInvalid, [.tag(0x30060039), .item(0), .tag(0x30060084)])),
            ("rtstruct-duplicate-roi-number", .structureSet, { self.replacingROI($0, 1) { $0.setting(self.text(0x30060022, "1", .IS)) } },
             .failed(.attributeValueContradiction, [.tag(0x30060020), .item(1), .tag(0x30060022)])),
            ("rtstruct-observation-unknown-roi", .structureSet, { self.replacingObservation($0) { $0.setting(self.text(0x30060084, "9", .IS)) } },
             .failed(.referenceSelectionInvalid, [.tag(0x30060080), .item(0), .tag(0x30060084)])),
            ("rtstruct-roi-unknown-frame-of-reference", .structureSet, { self.replacingROI($0, 0) { $0.setting(self.text(0x30060024, "2.25.1", .UI)) } },
             .failed(.attributeValueContradiction, [.tag(0x30060020), .item(0), .tag(0x30060024)])),
            ("rtstruct-geometric-type-wrong", .structureSet, { self.replacingContour($0) { $0.setting(self.text(0x30060042, "CLOSED", .CS)) } },
             .failed(.attributeValueNotAllowed, [.tag(0x30060039), .item(0), .tag(0x30060040), .item(0), .tag(0x30060042)])),
            ("rtstruct-approved-without-reviewer", .structureSet, { $0.setting(self.text(0x300E0002, "APPROVED", .CS)) },
             .failed(.requiredAttributeMissing, [.tag(0x300E0008)])),
            ("rtstruct-image-frame-out-of-range", .structureSet, { self.replacingContour($0) { $0.setting(self.sequence(0x30060016,
                [self.reference("1.2.840.10008.5.1.4.1.1.2", self.imageUID, frames: [3])])) } },
             .failed(.referenceSelectionOutOfRange, [.tag(0x30060039), .item(0), .tag(0x30060040), .item(0), .tag(0x30060016), .item(0), .tag(0x00081160)])),
            ("rtplan-patient-geometry-without-structure-set", .plan, { $0.removing(0x300C0060) }, .failed(.requiredAttributeMissing, [.tag(0x300C0060)])),
            ("rtplan-fraction-beams-without-module", .plan, { $0.removing(0x300A00B0) }, .failed(.requiredAttributeMissing, [.tag(0x300A00B0)])),
            ("rtplan-referenced-beam-unknown", .plan, { self.replacingFractionGroup($0) { $0.setting(self.sequence(0x300C0004, [.init(elements: [self.text(0x300C0006, "7", .IS)])])) } },
             .failed(.referenceSelectionInvalid, [.tag(0x300A0070), .item(0), .tag(0x300C0004), .item(0), .tag(0x300C0006)])),
            ("rtplan-first-control-point-without-gantry", .plan, { self.replacingControlPoint($0, 0) { $0.removing(0x300A011E) } },
             .failed(.requiredAttributeMissing, firstPoint + [.tag(0x300A011E)])),
            ("rtplan-control-point-count", .plan, { self.replacingBeam($0) { $0.setting(self.text(0x300A0110, "3", .IS)) } },
             .failed(.attributeValueContradiction, beam + [.tag(0x300A0110)])),
            ("rtplan-final-meterset-missing", .plan, { self.replacingBeam($0) { $0.removing(0x300A010E) } },
             .failed(.requiredAttributeMissing, beam + [.tag(0x300A010E)])),
            ("rtplan-brachy-with-beams", .plan, { self.brachy($0, keepingBeams: true) }, .failed(.conditionalAttributeForbidden, [.tag(0x300A0200)])),
            ("rtplan-wedges-without-sequence", .plan, { self.replacingBeam($0) { $0.setting(self.text(0x300A00D0, "1", .IS)) } },
             .failed(.requiredAttributeMissing, beam + [.tag(0x300A00D1)])),
            ("rtplan-wedge-without-first-position", .plan, { self.wedged($0, positions: false) },
             .failed(.requiredAttributeMissing, firstPoint + [.tag(0x300A0116)])),
            ("rtplan-prescription-point-without-roi", .plan, { $0.setting(self.sequence(0x300A0010, [.init(elements: [self.text(0x300A0012, "1", .IS),
                self.text(0x300A0014, "POINT", .CS), self.text(0x300A0020, "TARGET", .CS)])])) },
             .failed(.requiredAttributeMissing, [.tag(0x300A0010), .item(0), .tag(0x30060084)])),
            ("rtplan-setup-without-position", .plan, { $0.setting(self.sequence(0x300A0180, [.init(elements: [self.text(0x300A0182, "1", .IS)])])) },
             .failed(.requiredAttributeMissing, [.tag(0x300A0180), .item(0), .tag(0x00185100)])),
            ("rtplan-rejected-without-date", .plan, { $0.setting(self.text(0x300E0002, "REJECTED", .CS)).setting(self.text(0x300E0008, "REVIEWER", .PN))
                .setting(self.text(0x300E0005, "120000", .TM)) },
             .failed(.requiredAttributeMissing, [.tag(0x300E0004)])),
            ("rtplan-rotation-direction-wrong", .plan, { self.replacingControlPoint($0, 0) { $0.setting(self.text(0x300A011F, "CLOCKWISE", .CS)) } },
             .failed(.attributeValueNotAllowed, firstPoint + [.tag(0x300A011F)])),
            ("rtplan-brachy-stepwise-without-step", .plan, { self.replacingChannel(self.brachy($0)) { $0.removing(0x300A02A0) } },
             .failed(.requiredAttributeMissing, [.tag(0x300A0230), .item(0), .tag(0x300A0280), .item(0), .tag(0x300A02A0)])),
            ("rtplan-brachy-final-time-weight-missing", .plan, { self.replacingChannel(self.brachy($0)) { $0.removing(0x300A02C8) } },
             .failed(.requiredAttributeMissing, [.tag(0x300A0230), .item(0), .tag(0x300A0280), .item(0), .tag(0x300A02C8)]))
        ]
        for (name, kind, transform, expectation) in cases {
            let instance = transform(fixture(kind))
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: sop(kind), mediaStorageSOPInstanceUID: instanceUID(kind)))
            let report = try DicomInstanceValidator.validate(bytes, targets: targets(), imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets(), imageConditions: facts), report, name)
            let hasReferences = !["rtdose-plan-without-reference", "rtplan-patient-geometry-without-structure-set"].contains(name)
            let withoutTargets = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            XCTAssertEqual(withoutTargets[.references], hasReferences ? .incomplete : .passed, name)
            XCTAssertEqual(withoutTargets.diagnostics.contains { $0.code == .referenceTargetUnavailable }, hasReferences, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_RT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": sop(kind), "grid": kind == .dose && instance.contains(0x7FE00010),
                    "references": hasReferences,
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_typedBuilders_exportLotA1CorpusAndEngineFacts() throws {
        let doseModels: [(String, DicomRTDoseVolume)] = [
            ("rtdose-absolute-z", DicomRTDoseBuilderTests.dose(offsets: [30, 32])),
            ("rtdose-nonuniform-offsets", DicomRTDoseBuilderTests.dose(offsets: [0, 2, 5])),
            ("rtdose-32bit", DicomRTDoseBuilderTests.dose(bits: 32)),
            ("rtdose-error-signed", DicomRTDoseBuilderTests.dose(signed: true)),
            ("rtdose-relative-normalization", DicomRTDoseBuilderTests.dose(relative: true)),
            ("rtdose-dvh-full", DicomRTDoseBuilderTests.dose(dvhOnly: true)),
            ("rtdose-registered", DicomRTDoseBuilderTests.dose(registered: true))
        ]
        var cases: [(String, DicomDataSet, DicomRTDoseDiagnostic.Code?)] = try doseModels.map {
            ($0.0, try DicomRTDoseBuilder.dataSet(from: $0.1, studyInstanceUID: studyUID, seriesInstanceUID: "2.25.234799"), nil)
        }
        cases.append(("rtplan-full", try DicomRTPlanBuilder.dataSet(from: DicomRTPlanBuilderTests.fullPlan(),
            studyInstanceUID: studyUID, seriesInstanceUID: "2.25.234798"), nil))
        let dvh = try XCTUnwrap(cases.first { $0.0 == "rtdose-dvh-full" }?.1)
        cases.append(("rtdose-dvh-data-count", dvh.setting(sequence(0x30040050,
            [DicomRTDoseBuilderTests.fullDVH().dataSet.setting(text(0x30040058, "0\\1\\2", .DS))])), .dvhDataCountMismatch))
        let signed = try XCTUnwrap(cases.first { $0.0 == "rtdose-error-signed" }?.1)
        cases.append(("rtdose-signed-physical", signed.setting(text(0x30040004, "PHYSICAL", .CS)), .signedNonErrorDose))
        let absolute = try XCTUnwrap(cases.first { $0.0 == "rtdose-absolute-z" }?.1)
        cases.append(("rtdose-absolute-z-oblique", absolute.setting(text(0x00200037, "0.8\\0\\-0.6\\0\\1\\0", .DS)),
                      .absoluteZNonTransverseOrientation))
        var referenceTargets = targets()
        referenceTargets["2.25.234703"] = reference("1.2.840.10008.5.1.4.1.1.66.1", "2.25.234703")
            .setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.66.1", .UI)).setting(text(0x00080018, "2.25.234703", .UI))
        for (name, data, diagnostic) in cases {
            let bytes = try DicomGeometryCorpusTests.bytes(data)
            let report = try DicomInstanceValidator.validate(bytes, targets: referenceTargets, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            // Odd DVH multiplicity and signed PHYSICAL fail raw validation; oblique option b is typed-only.
            XCTAssertEqual(outcome, ["rtdose-signed-physical", "rtdose-dvh-data-count"].contains(name) ? .failed : .passed, "\(name): \(report.diagnostics)")
            let decoder = try DCMDecoder(data: bytes)
            let withoutTargets = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            XCTAssertEqual(withoutTargets[.references], .incomplete, name)
            XCTAssertTrue(withoutTargets.diagnostics.contains { $0.code == .referenceTargetUnavailable }, name)
            var metadata: [String: Any] = ["outcome": outcome.rawValue, "sopClass": data.string(for: 0x00080016)!,
                "grid": data.contains(0x7FE00010), "exit": outcome == .failed ? 1 : 0,
                "references": true,
                "typedOutcome": diagnostic == nil ? "passed" : "failed"]
            if name == "rtplan-full" {
                XCTAssertEqual(decoder.rtPlan, DicomRTPlanBuilderTests.fullPlan())
            } else {
                let parsed = try XCTUnwrap(decoder.rtDose)
                XCTAssertEqual(parsed.diagnostics.map(\.code), diagnostic.map { [$0] } ?? [], name)
                metadata["typedDiagnostics"] = parsed.diagnostics.map { $0.code.rawValue }
                if let expected = doseModels.first(where: { $0.0 == name })?.1 { XCTAssertEqual(parsed, expected) }
                if data.contains(0x7FE00010) {
                    metadata["engineDoseValues"] = parsed.doseValues
                    metadata["engineStoredValues"] = parsed.signedStoredValues?.map(Double.init) ?? parsed.storedValues.map(Double.init)
                    if let position = parsed.imagePositionPatient, let orientation = parsed.imageOrientationPatient,
                       let positions = parsed.gridFrameOffsets.planePositions(imagePosition: position, orientation: orientation) {
                        metadata["enginePlanePositions"] = positions.map { [$0.x, $0.y, $0.z] }
                    }
                }
            }
            if let folder = ProcessInfo.processInfo.environment["DICOM_RT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    // MARK: - Fixtures

    private func sop(_ kind: Kind) -> String {
        switch kind {
        case .dose: return "1.2.840.10008.5.1.4.1.1.481.2"
        case .structureSet: return "1.2.840.10008.5.1.4.1.1.481.3"
        case .plan: return "1.2.840.10008.5.1.4.1.1.481.5"
        }
    }

    private func instanceUID(_ kind: Kind) -> String {
        switch kind {
        case .dose: return doseUID
        case .structureSet: return structureSetUID
        case .plan: return planUID
        }
    }

    /// Metadata of the referenced plan, structure set and two-frame CT image, keyed by SOP Instance UID.
    private func targets() -> [String: DicomDataSet] {
        [planUID: .init(elements: [text(0x00080016, sop(.plan), .UI), text(0x00080018, planUID, .UI), text(0x0020000D, studyUID, .UI)]),
         structureSetUID: .init(elements: [text(0x00080016, sop(.structureSet), .UI), text(0x00080018, structureSetUID, .UI), text(0x0020000D, studyUID, .UI)]),
         imageUID: .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00080018, imageUID, .UI), text(0x0020000D, studyUID, .UI),
                                    text(0x0020000E, imageSeriesUID, .UI), text(0x00280008, "2", .IS)]),
         // The RT Referenced Study reference names the study through the Detached Study Management SOP Class.
         studyUID: .init(elements: [text(0x00080016, "1.2.840.10008.3.1.2.3.1", .UI), text(0x00080018, studyUID, .UI)])]
    }

    private func fixture(_ kind: Kind) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            text(0x00080016, sop(kind), .UI), text(0x00080018, instanceUID(kind), .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "1", .IS), text(0x00080070, "SYNTHETIC", .LO), text(0x00081070, "", .PN),
            text(0x0020000D, studyUID, .UI), text(0x0020000E, "2.25.23279997", .UI)
        ]
        switch kind {
        case .dose:
            elements += [
                text(0x00080060, "RTDOSE", .CS), text(0x00200052, frameOfReferenceUID, .UI), text(0x00201040, "", .LO),
                text(0x00200013, "1", .IS), text(0x00080008, "ORIGINAL\\PRIMARY", .CS),
                number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS), number(0x00280010, 2), number(0x00280011, 2),
                number(0x00280100, 16), number(0x00280101, 16), number(0x00280102, 15), number(0x00280103, 0),
                text(0x00280030, "1\\1", .DS), text(0x00200037, "1\\0\\0\\0\\1\\0", .DS), text(0x00200032, "0\\0\\0", .DS), text(0x00180050, "1", .DS),
                text(0x00280008, "2", .IS), .init(tag: 0x00280009, vr: .AT, value: .unsignedIntegers([0x3004000C])),
                text(0x30040002, "GY", .CS), text(0x30040004, "PHYSICAL", .CS), text(0x3004000A, "PLAN", .CS),
                sequence(0x300C0002, [reference(sop(.plan), planUID)]),
                text(0x3004000C, "0\\1", .DS), text(0x3004000E, "0.01", .DS),
                .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 1, count: 16)))
            ]
        case .structureSet:
            elements += [
                text(0x00080060, "RTSTRUCT", .CS), text(0x30060002, "CORPUS", .SH), text(0x30060008, "", .DA), text(0x30060009, "", .TM),
                sequence(0x30060010, [.init(elements: [text(0x00200052, frameOfReferenceUID, .UI),
                    sequence(0x30060012, [.init(elements: [text(0x00081150, "1.2.840.10008.3.1.2.3.1", .UI), text(0x00081155, studyUID, .UI),
                        sequence(0x30060014, [.init(elements: [text(0x0020000E, imageSeriesUID, .UI),
                            sequence(0x30060016, [reference("1.2.840.10008.5.1.4.1.1.2", imageUID)])])])])])])]),
                sequence(0x30060020, [roi(1, "PTV"), roi(2, "OAR")]),
                sequence(0x30060039, [roiContour(1), roiContour(2)]),
                sequence(0x30060080, [observation(1, roi: 1, "PTV"), observation(2, roi: 2, "ORGAN")])
            ]
        case .plan:
            elements += [
                text(0x00080060, "RTPLAN", .CS), text(0x300A0002, "CORPUS", .SH), text(0x300A0006, "", .DA), text(0x300A0007, "", .TM),
                text(0x300A000C, "PATIENT", .CS), sequence(0x300C0060, [reference(sop(.structureSet), structureSetUID)]),
                sequence(0x300A0070, [.init(elements: [text(0x300A0071, "1", .IS), text(0x300A0078, "30", .IS), text(0x300A0080, "1", .IS),
                    sequence(0x300C0004, [.init(elements: [text(0x300C0006, "1", .IS)])]), text(0x300A00A0, "0", .IS)])]),
                sequence(0x300A00B0, [beam()]),
                text(0x300E0002, "UNAPPROVED", .CS)
            ]
        }
        return .init(elements: elements)
    }

    private func reference(_ sopClass: String, _ instance: String, frames: [Int] = []) -> DicomDataSet {
        var item = [text(0x00081150, sopClass, .UI), text(0x00081155, instance, .UI)]
        if !frames.isEmpty { item.append(text(0x00081160, frames.map(String.init).joined(separator: "\\"), .IS)) }
        return .init(elements: item)
    }

    private func roi(_ number: Int, _ name: String) -> DicomDataSet {
        .init(elements: [text(0x30060022, String(number), .IS), text(0x30060024, frameOfReferenceUID, .UI), text(0x30060026, name, .LO),
                         text(0x30060036, "MANUAL", .CS)])
    }

    private func roiContour(_ number: Int) -> DicomDataSet {
        .init(elements: [text(0x3006002A, "255\\0\\0", .IS), sequence(0x30060040, [.init(elements: [
            sequence(0x30060016, [reference("1.2.840.10008.5.1.4.1.1.2", imageUID)]), text(0x30060042, "CLOSED_PLANAR", .CS),
            text(0x30060046, "3", .IS), text(0x30060050, "0\\0\\0\\1\\0\\0\\0\\1\\0", .DS)])]), text(0x30060084, String(number), .IS)])
    }

    private func observation(_ number: Int, roi: Int, _ type: String) -> DicomDataSet {
        .init(elements: [text(0x30060082, String(number), .IS), text(0x30060084, String(roi), .IS), text(0x300600A4, type, .CS), text(0x300600A6, "", .PN)])
    }

    private func beam() -> DicomDataSet {
        .init(elements: [text(0x300A00C0, "1", .IS), text(0x300A00C4, "STATIC", .CS), text(0x300A00C6, "PHOTON", .CS), text(0x300A00B2, "LINAC", .SH),
            text(0x300A00B3, "MU", .CS), text(0x300A00B4, "1000", .DS),
            sequence(0x300A00B6, [.init(elements: [text(0x300A00B8, "X", .CS), text(0x300A00BC, "1", .IS)])]),
            text(0x300A00D0, "0", .IS), text(0x300A00E0, "0", .IS), text(0x300A00ED, "0", .IS), text(0x300A00F0, "0", .IS),
            text(0x300A010E, "1", .DS), text(0x300A0110, "2", .IS),
            sequence(0x300A0111, [controlPoint(0), .init(elements: [text(0x300A0112, "1", .IS), text(0x300A0134, "1", .DS)])])])
    }

    private func controlPoint(_ index: Int) -> DicomDataSet {
        .init(elements: [text(0x300A0112, String(index), .IS), text(0x300A0134, "0", .DS), text(0x300A0114, "6", .DS),
            sequence(0x300A011A, [.init(elements: [text(0x300A00B8, "X", .CS), text(0x300A011C, "-50\\50", .DS)])]),
            text(0x300A011E, "0", .DS), text(0x300A011F, "NONE", .CS), text(0x300A0120, "0", .DS), text(0x300A0121, "NONE", .CS),
            text(0x300A0122, "0", .DS), text(0x300A0123, "NONE", .CS), text(0x300A0125, "0", .DS), text(0x300A0126, "NONE", .CS),
            text(0x300A0128, "", .DS), text(0x300A0129, "", .DS), text(0x300A012A, "", .DS), text(0x300A012C, "0\\0\\0", .DS)])
    }

    private func beamDose(_ dataSet: DicomDataSet) -> DicomDataSet {
        dataSet.setting(text(0x3004000A, "BEAM", .CS)).setting(sequence(0x300C0002, [.init(elements: [
            text(0x00081150, sop(.plan), .UI), text(0x00081155, planUID, .UI),
            sequence(0x300C0020, [.init(elements: [text(0x300C0022, "1", .IS), sequence(0x300C0004, [.init(elements: [text(0x300C0006, "1", .IS)])])])])])]))
    }

    /// A dose without grid: only the DVH module and the dose description.
    private func dvhOnly(_ dataSet: DicomDataSet) -> DicomDataSet {
        var result = dataSet
        for tag in [0x00200013, 0x00080008, 0x00280002, 0x00280004, 0x00280010, 0x00280011, 0x00280100, 0x00280101, 0x00280102, 0x00280103,
                    0x00280030, 0x00200037, 0x00200032, 0x00180050, 0x00280008, 0x00280009, 0x3004000C, 0x3004000E, 0x7FE00010] {
            result = result.removing(tag)
        }
        return result.setting(sequence(0x300C0060, [reference(sop(.structureSet), structureSetUID)])).setting(sequence(0x30040050, [.init(elements: [
            sequence(0x30040060, [.init(elements: [text(0x30060084, "1", .IS), text(0x30040062, "INCLUDED", .CS)])]),
            text(0x30040001, "CUMULATIVE", .CS), text(0x30040002, "GY", .CS), text(0x30040004, "PHYSICAL", .CS), text(0x30040052, "1", .DS),
            text(0x30040054, "CM3", .CS), text(0x30040056, "2", .IS), text(0x30040058, "0\\1\\1\\0.5", .DS)])]))
    }

    private func frames(_ dataSet: DicomDataSet, _ count: Int) -> DicomDataSet {
        dataSet.setting(text(0x00280008, String(count), .IS))
            .setting(.init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 1, count: 8 * count))))
    }

    /// Brachy application setup replacing (or joining) the beams module.
    private func brachy(_ dataSet: DicomDataSet, keepingBeams: Bool = false) -> DicomDataSet {
        var result = keepingBeams ? dataSet : dataSet.removing(0x300A00B0)
        result = result.setting(sequence(0x300A0070, [.init(elements: [text(0x300A0071, "1", .IS), text(0x300A0078, "1", .IS), text(0x300A0080, "0", .IS),
            text(0x300A00A0, "1", .IS), sequence(0x300C000A, [.init(elements: [text(0x300C000C, "1", .IS)])])])]))
        return result.setting(text(0x300A0200, "INTRACAVITARY", .CS)).setting(text(0x300A0202, "HDR", .CS))
            .setting(sequence(0x300A0206, [.init(elements: [text(0x300A00B2, "AFTERLOADER", .SH)])]))
            .setting(sequence(0x300A0210, [.init(elements: [text(0x300A0212, "1", .IS), text(0x300A0214, "POINT", .CS), text(0x300A0226, "Ir-192", .LO),
                text(0x300A0228, "73.83", .DS), text(0x300A022A, "40000", .DS), text(0x300A022C, "20260909", .DA), text(0x300A022E, "120000", .TM)])]))
            .setting(sequence(0x300A0230, [.init(elements: [text(0x300A0232, "FLETCHER_SUIT", .CS), text(0x300A0234, "1", .IS), text(0x300A0250, "5", .DS),
                sequence(0x300A0280, [channel()])])]))
    }

    private func channel() -> DicomDataSet {
        .init(elements: [text(0x300A0282, "1", .IS), text(0x300A0284, "1200", .DS), text(0x300A0286, "300", .DS), text(0x300A0288, "STEPWISE", .CS),
            text(0x300A02A0, "5", .DS), text(0x300A02A2, "", .IS), text(0x300C000E, "1", .IS), text(0x300A0110, "2", .IS), text(0x300A02C8, "1", .DS),
            sequence(0x300A02D0, [.init(elements: [text(0x300A0112, "0", .IS), text(0x300A02D6, "0", .DS), text(0x300A02D2, "0", .DS)]),
                                  .init(elements: [text(0x300A0112, "1", .IS), text(0x300A02D6, "1", .DS), text(0x300A02D2, "1", .DS)])])])
    }

    /// One wedge with (or without) the wedge position of the first control point.
    private func wedged(_ dataSet: DicomDataSet, positions: Bool) -> DicomDataSet {
        replacingBeam(dataSet) { beam in
            var result = beam.setting(text(0x300A00D0, "1", .IS)).setting(sequence(0x300A00D1, [.init(elements: [text(0x300A00D2, "1", .IS),
                text(0x300A00D3, "STANDARD", .CS), text(0x300A00D5, "45", .IS), text(0x300A00D6, "0.5", .DS), text(0x300A00D8, "0", .DS)])]))
            if positions {
                var points = (result[0x300A0111]?.sequenceItems ?? []).map(\.dataSet)
                points[0] = points[0].setting(sequence(0x300A0116, [.init(elements: [text(0x300C00C0, "1", .IS), text(0x300A0118, "IN", .CS)])]))
                result = result.setting(sequence(0x300A0111, points))
            }
            return result
        }
    }

    private func replacingBeam(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var beams = (dataSet[0x300A00B0]?.sequenceItems ?? []).map(\.dataSet)
        beams[0] = transform(beams[0])
        return dataSet.setting(sequence(0x300A00B0, beams))
    }

    private func replacingControlPoint(_ dataSet: DicomDataSet, _ index: Int, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        replacingBeam(dataSet) { beam in
            var points = (beam[0x300A0111]?.sequenceItems ?? []).map(\.dataSet)
            points[index] = transform(points[index])
            return beam.setting(sequence(0x300A0111, points))
        }
    }

    private func replacingFractionGroup(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var groups = (dataSet[0x300A0070]?.sequenceItems ?? []).map(\.dataSet)
        groups[0] = transform(groups[0])
        return dataSet.setting(sequence(0x300A0070, groups))
    }

    private func replacingChannel(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var setups = (dataSet[0x300A0230]?.sequenceItems ?? []).map(\.dataSet)
        var channels = (setups[0][0x300A0280]?.sequenceItems ?? []).map(\.dataSet)
        channels[0] = transform(channels[0])
        setups[0] = setups[0].setting(sequence(0x300A0280, channels))
        return dataSet.setting(sequence(0x300A0230, setups))
    }

    private func replacingROI(_ dataSet: DicomDataSet, _ index: Int, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var rois = (dataSet[0x30060020]?.sequenceItems ?? []).map(\.dataSet)
        rois[index] = transform(rois[index])
        return dataSet.setting(sequence(0x30060020, rois))
    }

    private func replacingROIContour(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var items = (dataSet[0x30060039]?.sequenceItems ?? []).map(\.dataSet)
        items[0] = transform(items[0])
        return dataSet.setting(sequence(0x30060039, items))
    }

    private func replacingContour(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        replacingROIContour(dataSet) { item in
            var contours = (item[0x30060040]?.sequenceItems ?? []).map(\.dataSet)
            contours[0] = transform(contours[0])
            return item.setting(sequence(0x30060040, contours))
        }
    }

    private func replacingObservation(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var items = (dataSet[0x30060080]?.sequenceItems ?? []).map(\.dataSet)
        items[0] = transform(items[0])
        return dataSet.setting(sequence(0x30060080, items))
    }

    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
