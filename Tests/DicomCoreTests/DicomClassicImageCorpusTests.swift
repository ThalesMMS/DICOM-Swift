import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the classic CT, MR and CR image IODs: Image Plane geometry at the
/// encoded precision, Patient Orientation against direction cosines, Contrast/Bolus,
/// Multi-energy CT with index cross-references, Single-Frame CT Series, CR series/image and
/// Display Shutter, evaluated with stated external facts.
final class DicomClassicImageCorpusTests: XCTestCase {

    func test_multiEnergyDiagnostics_fullAttributeBudgetReservesLimitMarker() {
        let dataSet = multiEnergy(removingDetectors: true, pathSource: 9)
            .setting(text(0x00080008, "DERIVED\\PRIMARY", .CS))
        for maximum in 1...3 {
            let report = DicomMultiEnergyCTModule.validate(dataSet, limits: .init(maximumDiagnostics: maximum))
            XCTAssertLessThanOrEqual(report.diagnostics.count, maximum)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached }, "\(report.diagnostics)")
        }
    }

    private enum Kind { case ct, mr, cr }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
        rescaleUnitsAreHU: .satisfied, cardiacGating: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })

    func test_originalCorpus_qualifiesClassicCTMRCRAndRejectsGeometryAndModuleViolations() throws {
        let oblique = text(0x00200037, "0.70710678\\0.70710678\\0\\-0.70710678\\0.70710678\\0", .DS)
        let cases: [(String, Kind, DicomDataSet, Expectation)] = [
            ("ct", .ct, .init(), .passed),
            ("mr", .mr, .init(), .passed),
            ("cr", .cr, .init(), .passed),
            ("ct-oblique-within-precision", .ct, .init(elements: [oblique, text(0x00200020, "", .CS)]), .passed),
            ("ct-contrast", .ct, .init(elements: [text(0x00180010, "IODINE", .LO),
                sequence(0x00180014, [code("47625008", "SCT", "Intravenous route")])]), .passed),
            ("ct-multi-energy", .ct, multiEnergy(), .passed),
            ("ct-for-presentation", .ct, .init(elements: [text(0x00080068, "FOR PRESENTATION", .CS)]), .passed),
            ("cr-shutter", .cr, shutter(), .passed),
            ("mr-view-code", .mr, .init(elements: [sequence(0x00540220, [code("399033003", "SCT", "frontal")])]), .passed),
            ("ct-orientation-contradiction", .ct, .init(elements: [text(0x00200020, "R\\P", .CS)]),
             .failed(.attributeValueContradiction, [.tag(0x00200020)])),
            ("ct-non-orthogonal", .ct, .init(elements: [text(0x00200037, "1\\0\\0\\0.5\\0.5\\0", .DS)]),
             .failed(.spatialGeometryInvalid, [.tag(0x00200037)])),
            ("ct-oblique-beyond-precision", .ct, .init(elements: [text(0x00200037, "0.72\\0.72\\0\\-0.72\\0.72\\0", .DS)]),
             .failed(.spatialGeometryInvalid, [.tag(0x00200037)])),
            ("ct-contrast-missing-agent", .ct, .init(elements: [sequence(0x00180014, [code("47625008", "SCT", "Intravenous route")])]),
             .failed(.requiredAttributeMissing, [.tag(0x00180010)])),
            ("ct-multi-energy-missing-detector", .ct, multiEnergy(removingDetectors: true),
             .failed(.requiredAttributeMissing, [.tag(0x00189362), .item(0), .tag(0x0018936F)])),
            ("ct-multi-energy-bad-path", .ct, multiEnergy(pathSource: 2),
             .failed(.referenceEvidenceMissing, [.tag(0x00189362), .item(0), .tag(0x00189379), .item(0), .tag(0x00189377)])),
            ("ct-presentation-intent-invalid", .ct, .init(elements: [text(0x00080068, "FOR REVIEW", .CS)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00080068)])),
            ("ct-bits-stored-8", .ct, .init(elements: [number(0x00280101, 8), number(0x00280102, 7)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00280101)])),
            ("mr-ir-missing-inversion", .mr, .init(elements: [text(0x00180020, "IR", .CS)]),
             .failed(.requiredAttributeMissing, [.tag(0x00180082)])),
            ("mr-missing-frame-of-reference", .mr, .init(), .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("cr-photometric-rgb", .cr, .init(elements: [text(0x00280004, "RGB", .CS)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00280004)])),
            ("cr-missing-view-position", .cr, .init(), .failed(.requiredAttributeMissing, [.tag(0x00185101)])),
            ("cr-shutter-missing-edge", .cr, shutter().removing(0x00181608), .failed(.requiredAttributeMissing, [.tag(0x00181608)])),
            ("cr-shutter-duplicate-shape", .cr, shutter().setting(text(0x00181600, "RECTANGULAR\\RECTANGULAR", .CS)),
             .failed(.attributeValueContradiction, [.tag(0x00181600)]))
        ]
        for (name, kind, attributes, expectation) in cases {
            var instance = fixture(kind)
            if name == "mr-missing-frame-of-reference" { instance = instance.removing(0x00200052) }
            if name == "cr-missing-view-position" { instance = instance.removing(0x00185101) }
            for element in attributes.elements { instance.set(element) }
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: sop(kind), mediaStorageSOPInstanceUID: "2.25.23219995"))
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code, let path):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_CLASSIC_IMAGE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": sop(kind),
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_quadrupedOrientationAndUnstatedFacts_stayUndetermined() throws {
        let quadruped = fixture(.ct).setting(text(0x00102210, "QUADRUPED", .CS)).setting(text(0x00200020, "LE\\D", .CS))
            .setting(text(0x00102201, "Canis lupus familiaris", .LO)).setting(text(0x00102292, "", .LO))
            .setting(text(0x00102297, "", .PN)).setting(text(0x00102299, "", .LO))
            .setting(.init(tag: 0x00102293, vr: .SQ, value: .sequence([]))).setting(.init(tag: 0x00102294, vr: .SQ, value: .sequence([])))
        let quadrupedFacts = DicomCompositeImageModules.Conditions(nonHumanPatient: .satisfied, nonBipedalAnatomy: .satisfied,
            pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied, rescaleUnitsAreHU: .satisfied)
        let report = try DicomInstanceValidator.validate(try DicomDataSetWriter.part10Data(from: quadruped), imageConditions: quadrupedFacts)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable && $0.path == [.tag(0x00200020)] })
        XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(report.diagnostics.filter { $0.severity == .error })")
        let unstated = try DicomInstanceValidator.validate(try DicomDataSetWriter.part10Data(from: fixture(.mr)))
        XCTAssertEqual(unstated.outcome(requiring: requiredLayers), .incomplete)
        XCTAssertFalse(unstated.diagnostics.contains { $0.code == .moduleRuleUnavailable })
    }

    private func sop(_ kind: Kind) -> String {
        switch kind {
        case .ct: return "1.2.840.10008.5.1.4.1.1.2"
        case .mr: return "1.2.840.10008.5.1.4.1.1.4"
        case .cr: return "1.2.840.10008.5.1.4.1.1.1"
        }
    }

    private func fixture(_ kind: Kind) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            text(0x00080016, sop(kind), .UI), text(0x00080018, "2.25.23219995", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "", .IS), text(0x00200013, "", .IS), text(0x00080070, "", .LO),
            text(0x0020000D, "2.25.23219996", .UI), text(0x0020000E, "2.25.23219997", .UI),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS), number(0x00280010, 2), number(0x00280011, 2),
            number(0x00280100, 16), number(0x00280101, 12), number(0x00280102, 11), number(0x00280103, 0),
            .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 1, count: 8)))
        ]
        switch kind {
        case .ct, .mr:
            elements += [text(0x00200052, "2.25.23219998", .UI), text(0x00201040, "", .LO), text(0x00280030, "1\\1", .DS),
                text(0x00200037, "1\\0\\0\\0\\1\\0", .DS), text(0x00200032, "0\\0\\0", .DS), text(0x00180050, "", .DS),
                text(0x00185100, "HFS", .CS)]
        case .cr:
            elements += [text(0x00080060, "CR", .CS), text(0x00180015, "CHEST", .CS), text(0x00185101, "PA", .CS),
                text(0x00200020, "L\\F", .CS)]
        }
        if kind == .ct {
            elements += [text(0x00080060, "CT", .CS), text(0x00080008, "ORIGINAL\\PRIMARY\\AXIAL", .CS), text(0x00180060, "", .DS),
                text(0x00200012, "", .IS), text(0x00281052, "-1024", .DS), text(0x00281053, "1", .DS), text(0x00281054, "HU", .LO)]
        }
        if kind == .mr {
            elements += [text(0x00080060, "MR", .CS), text(0x00080008, "ORIGINAL\\PRIMARY", .CS), text(0x00180020, "SE", .CS),
                text(0x00180021, "NONE", .CS), text(0x00180022, "", .CS), text(0x00180023, "2D", .CS), text(0x00180080, "500", .DS),
                text(0x00180081, "10", .DS), text(0x00180091, "1", .IS)]
        }
        return .init(elements: elements)
    }

    private func multiEnergy(removingDetectors: Bool = false, pathSource: UInt = 1) -> DicomDataSet {
        let source = DicomDataSet(elements: [number(0x00189366, 1), text(0x00189367, "S1", .UC), text(0x00189368, "SWITCHING_SOURCE", .CS),
            number(0x0018936B, 1), text(0x00189369, "20260101120000", .DT), text(0x0018936A, "20260101120001", .DT)])
        let detector = DicomDataSet(elements: [number(0x00189370, 1), text(0x00189371, "D1", .UC), text(0x00189372, "INTEGRATING", .CS)])
        let path = DicomDataSet(elements: [number(0x00189376, 1), number(0x00189377, pathSource), number(0x0018937A, 1)])
        let exposure = DicomDataSet(elements: [text(0x00189323, "NONE", .CS), float(0x00189328, 100), float(0x00189330, 200),
            float(0x00189332, 20), text(0x00189345, "", .FD), number(0x00189377, 1)])
        let details = DicomDataSet(elements: [text(0x00180060, "120", .DS), text(0x00181160, "NONE", .SH), text(0x00181190, "1", .DS),
            number(0x00189378, 1)])
        let acquisitionDetails = DicomDataSet(elements: [text(0x00180090, "500", .DS), text(0x00181120, "0", .DS), text(0x00181130, "100", .DS),
            text(0x00181140, "CW", .CS), float(0x00189305, 0.5), float(0x00189306, 0.6), float(0x00189307, 38.4), number(0x00189378, 1)])
        let geometry = DicomDataSet(elements: [text(0x00181110, "1000", .DS), float(0x00189335, 500), number(0x00189378, 1)])
        var acquisition: [DicomDataElement] = [sequence(0x00189365, [source]), sequence(0x00189379, [path]),
            sequence(0x00189321, [exposure]), sequence(0x00189325, [details]), sequence(0x00189304, [acquisitionDetails]),
            sequence(0x00189312, [geometry])]
        if !removingDetectors { acquisition.append(sequence(0x0018936F, [detector])) }
        let mapping = DicomDataSet(elements: [text(0x00283003, "HU", .LO), sequence(0x004008EA, [code("[hnsf'U]", "UCUM", "Hounsfield unit")]),
            text(0x00409210, "L1", .SH), number(0x00409216, 0), number(0x00409211, 4095), float(0x00409224, -1024), float(0x00409225, 1)])
        return .init(elements: [text(0x00189361, "YES", .CS), sequence(0x00189362, [.init(elements: acquisition)]),
            sequence(0x00409096, [mapping])])
    }

    private func shutter() -> DicomDataSet {
        .init(elements: [text(0x00181600, "RECTANGULAR", .CS), .init(tag: 0x00181602, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00181604, vr: .IS, value: .strings(["2"])), .init(tag: 0x00181606, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00181608, vr: .IS, value: .strings(["2"]))])
    }

    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }
    private func float(_ tag: Int, _ value: Double) -> DicomDataElement { .init(tag: tag, vr: .FD, value: .floats([value])) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        if vr == .FD { return .init(tag: tag, vr: .FD, value: .empty) }
        return .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
