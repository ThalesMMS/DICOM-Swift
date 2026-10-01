import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the Enhanced CT, Enhanced MR and Enhanced XA Image IODs: IOD-specific
/// modules, shared/per-frame functional group usage, macro conditions, dimension coherence and
/// frame geometry, evaluated with stated external facts.
final class DicomEnhancedImageCorpusTests: XCTestCase {

    func test_sharedFrameTypeDefect_isReportedOnceAtSharedLocation() throws {
        let source = fixture(.ct)
        let macro = try XCTUnwrap(source[0x52009229]?.sequenceItems.first?.dataSet[0x00189329]?.sequenceItems.first?.dataSet)
            .setting(text(0x00089007, "INVALID\\PRIMARY\\AXIAL\\NONE", .CS))
        let changed = settingShared(source, [sequence(0x00189329, [macro])])
        let report = DicomEnhancedImageModules.validate(changed, profile: .enhancedCT)
        let defects = report.diagnostics.filter { $0.code == .attributeValueNotAllowed && $0.path.last == .tag(0x00089007) }
        XCTAssertEqual(defects.count, 1, "\(defects)")
        XCTAssertEqual(defects.first?.path, shared + [.tag(0x00189329), .item(0), .tag(0x00089007)])
    }

    private enum Kind { case ct, mr, xa }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
        sarCapable: .unsatisfied, gradientOutputCapable: .unsatisfied, operatingModeRegulated: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let shared: [DicomValidationReport.PathComponent] = [.tag(0x52009229), .item(0)]
    private func frame(_ index: Int) -> [DicomValidationReport.PathComponent] { [.tag(0x52009230), .item(index)] }

    func test_originalCorpus_qualifiesEnhancedCTMRXAAndRejectsFunctionalGroupViolations() throws {
        let cases: [(String, Kind, (DicomDataSet) -> DicomDataSet, Expectation)] = [
            ("ct", .ct, { $0 }, .passed),
            ("mr", .mr, { $0 }, .passed),
            ("xa", .xa, { $0 }, .passed),
            ("ct-spiral", .ct, { self.spiral($0) }, .passed),
            ("ct-derived", .ct, { self.derived($0) }, .passed),
            ("ct-cardiac", .ct, { self.cardiac($0) }, .passed),
            ("mr-diffusion", .mr, { self.diffusion($0, macro: true) }, .passed),
            ("xa-log-lut", .xa, { self.logarithmicLUT($0) }, .passed),
            ("mr-diffusion-missing-macro", .mr, { self.diffusion($0, macro: false) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00189117)])),
            ("ct-missing-pixel-measures", .ct, { self.removingShared($0, 0x00289110) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00289110)])),
            ("ct-frame-content-shared", .ct, { self.settingShared($0, [self.frameContent(index: 1)]) },
             .failed(.conditionalAttributeForbidden, shared + [.tag(0x00209111)])),
            ("ct-image-type-contradiction", .ct, { $0.setting(self.text(0x00080008, "DERIVED\\PRIMARY\\AXIAL\\NONE", .CS)) },
             .failed(.attributeValueContradiction, [.tag(0x00080008)])),
            ("ct-bits-stored-8", .ct, { $0.setting(self.number(0x00280101, 8)).setting(self.number(0x00280102, 7)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280101)])),
            ("ct-dimension-values-count", .ct, { self.replacingFrame($0, 0, [self.frameContent(index: 1, dimensionValues: [1, 1])]) },
             .failed(.invalidMultiplicity, frame(0) + [.tag(0x00209111), .item(0), .tag(0x00209157)])),
            ("ct-non-orthogonal-orientation", .ct, { self.settingShared($0, [self.sequence(0x00209116,
                [.init(elements: [self.text(0x00200037, "1\\0\\0\\0.5\\0.5\\0", .DS)])])]) },
             .failed(.spatialGeometryInvalid, frame(0) + [.tag(0x00200037)])),
            ("ct-missing-acquisition-type", .ct, { self.removingShared($0, 0x00189301) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00189301)])),
            ("ct-spiral-missing-pitch", .ct, { self.spiral($0, pitch: false) },
             .failed(.requiredAttributeMissing, shared + [.tag(0x00189308), .item(0), .tag(0x00189311)])),
            ("ct-other-iod-macro", .ct, { self.settingShared($0, [self.sequence(0x00189114, [.init(elements: [self.float(0x00189082, 10)])])]) },
             .failed(.conditionalAttributeForbidden, shared + [.tag(0x00189114)])),
            ("ct-multi-energy-without-module", .ct, { $0.setting(self.text(0x00189361, "YES", .CS)) },
             .failed(.requiredAttributeMissing, [.tag(0x00189365)])),
            ("mr-missing-pulse-sequence-name", .mr, { $0.removing(0x00189005) },
             .failed(.requiredAttributeMissing, [.tag(0x00189005)])),
            ("mr-invalid-acquisition-type", .mr, { $0.setting(self.text(0x00180023, "4D", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00180023)])),
            ("xa-missing-collimator", .xa, { self.removingShared($0, 0x00189407) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00189407)])),
            ("xa-carm-relationship-without-frame-of-reference", .xa, { $0.setting(self.text(0x00189474, "YES", .CS)) },
             .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("xa-plane-identification-missing", .xa, { $0.removing(0x00189457) },
             .failed(.requiredAttributeMissing, [.tag(0x00189457)]))
        ]
        for (name, kind, transform, expectation) in cases {
            let instance = transform(fixture(kind))
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: sop(kind), mediaStorageSOPInstanceUID: "2.25.23229995"))
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
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_ENHANCED_IMAGE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": sop(kind),
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_unstatedCapabilityFacts_leaveEnhancedMRIncomplete() throws {
        let bytes = try DicomDataSetWriter.part10Data(from: fixture(.mr))
        let report = try DicomInstanceValidator.validate(bytes, imageConditions: .init(nonHumanPatient: .unsatisfied,
            nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied))
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .incomplete)
        XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(report.diagnostics)")
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined
            && $0.path == shared + [.tag(0x00189112), .item(0), .tag(0x00189239)] }, "\(report.diagnostics)")
    }

    // MARK: - Fixtures

    private func sop(_ kind: Kind) -> String {
        switch kind {
        case .ct: return "1.2.840.10008.5.1.4.1.1.2.1"
        case .mr: return "1.2.840.10008.5.1.4.1.1.4.1"
        case .xa: return "1.2.840.10008.5.1.4.1.1.12.1.1"
        }
    }

    private func fixture(_ kind: Kind) -> DicomDataSet {
        let imageType: String
        switch kind {
        case .ct: imageType = "ORIGINAL\\PRIMARY\\AXIAL\\NONE"
        case .mr: imageType = "ORIGINAL\\PRIMARY\\T1\\NONE"
        case .xa: imageType = "ORIGINAL\\PRIMARY\\SINGLE PLANE\\NONE"
        }
        var elements: [DicomDataElement] = [
            text(0x00080016, sop(kind), .UI), text(0x00080018, "2.25.23229995", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "1", .IS), text(0x00200013, "1", .IS),
            text(0x00080023, "20260908", .DA), text(0x00080033, "120000", .TM), text(0x0008002A, "20260908120000", .DT),
            float(0x00189073, 1),
            text(0x00080070, "SYNTHETIC", .LO), text(0x00081090, "MODEL", .LO), text(0x00181000, "1", .LO), text(0x00181020, "1.0", .LO),
            text(0x0020000D, "2.25.23229996", .UI), text(0x0020000E, "2.25.23229997", .UI),
            text(0x00080008, imageType, .CS), text(0x00189004, "PRODUCT", .CS), text(0x00280301, "NO", .CS),
            text(0x00282110, "00", .CS), text(0x20500020, "IDENTITY", .CS),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS), number(0x00280010, 2), number(0x00280011, 2),
            number(0x00280100, 16), number(0x00280101, 12), number(0x00280102, 11), number(0x00280103, 0),
            text(0x00280008, "2", .IS), sequence(0x00400555, []),
            .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 1, count: 16)))
        ]
        if kind != .xa {
            elements += [text(0x00200052, "2.25.23229998", .UI), text(0x00201040, "", .LO), text(0x00185100, "HFS", .CS),
                text(0x00089205, "MONOCHROME", .CS), text(0x00089206, "VOLUME", .CS), text(0x00089207, "NONE", .CS),
                sequence(0x00209221, [.init(elements: [text(0x00209164, "2.25.23229999", .UI)])]),
                sequence(0x00209222, [.init(elements: [text(0x00209164, "2.25.23229999", .UI),
                    pointer(0x00209165, 0x00209057), pointer(0x00209167, 0x00209111)])])]
        }
        var sharedItem: [DicomDataElement] = [
            sequence(0x00209071, [.init(elements: [text(0x00209072, "U", .CS),
                sequence(0x00082218, [code("51185008", "SCT", "Thoracic structure")])])])
        ]
        // Irradiation Event Identification belongs to the CT and XA functional groups only.
        if kind != .mr { sharedItem.append(sequence(0x00189477, [.init(elements: [text(0x00083010, "2.25.23229990", .UI)])])) }
        switch kind {
        case .ct:
            elements += [text(0x00080060, "CT", .CS)]
            sharedItem += [
                sequence(0x00289110, [.init(elements: [text(0x00280030, "1\\1", .DS), text(0x00180050, "1", .DS)])]),
                sequence(0x00209116, [.init(elements: [text(0x00200037, "1\\0\\0\\0\\1\\0", .DS)])]),
                sequence(0x00189329, [.init(elements: [text(0x00089007, imageType, .CS), text(0x00089205, "MONOCHROME", .CS),
                    text(0x00089206, "VOLUME", .CS), text(0x00089207, "NONE", .CS)])]),
                sequence(0x00289145, [.init(elements: [text(0x00281052, "-1024", .DS), text(0x00281053, "1", .DS), text(0x00281054, "HU", .LO)])]),
                sequence(0x00189301, [.init(elements: [text(0x00189302, "SEQUENCED", .CS), text(0x00189333, "NO", .CS), text(0x00189334, "NO", .CS)])]),
                sequence(0x00189304, [.init(elements: [text(0x00181140, "CW", .CS), float(0x00189305, 1), float(0x00189306, 1),
                    float(0x00189307, 16), text(0x00181130, "100", .DS), text(0x00181120, "0", .DS), text(0x00180090, "500", .DS)])]),
                sequence(0x00189308, [.init(elements: [])]),
                sequence(0x00189326, [.init(elements: [float(0x00189327, 0), floats(0x00189313, [0, 0, 0]), floats(0x00189318, [0, 0, 0])])]),
                sequence(0x00189312, [.init(elements: [text(0x00181110, "1000", .DS), float(0x00189335, 500)])]),
                sequence(0x00189314, [.init(elements: [text(0x00189315, "FILTER_BACK_PROJ", .CS), text(0x00181210, "STANDARD", .SH),
                    text(0x00189316, "BRAIN", .CS), text(0x00181100, "500", .DS), floats(0x00189322, [1, 1]), float(0x00189319, 360),
                    text(0x00189320, "NONE", .SH)])]),
                sequence(0x00189321, [.init(elements: [float(0x00189328, 1000), float(0x00189330, 100), float(0x00189332, 100),
                    text(0x00189323, "NONE", .CS), float(0x00189345, 1)])]),
                sequence(0x00189325, [.init(elements: [text(0x00180060, "120", .DS), text(0x00181190, "1", .DS), text(0x00181160, "NONE", .SH)])])
            ]
        case .mr:
            elements += [text(0x00080060, "MR", .CS), text(0x00189100, "1H", .CS), text(0x00189064, "NONE", .CS),
                text(0x00180087, "1.5", .DS), text(0x00189174, "IEC", .CS), text(0x00089208, "MAGNITUDE", .CS), text(0x00089209, "T1", .CS),
                text(0x00189005, "SE", .SH), text(0x00180023, "2D", .CS), text(0x00189008, "SPIN", .CS), text(0x00189011, "NO", .CS),
                text(0x00189012, "NO", .CS), text(0x00189014, "NO", .CS), text(0x00189015, "NO", .CS), text(0x00189017, "NONE", .CS),
                text(0x00189018, "NO", .CS), text(0x00189024, "NO", .CS), text(0x00189025, "NONE", .CS), text(0x00189029, "NONE", .CS),
                text(0x00189032, "RECTILINEAR", .CS), text(0x00189034, "LINEAR", .CS), text(0x00189033, "SINGLE", .CS), number(0x00189093, 1)]
            sharedItem += [
                sequence(0x00289110, [.init(elements: [text(0x00280030, "1\\1", .DS), text(0x00180050, "1", .DS)])]),
                sequence(0x00209116, [.init(elements: [text(0x00200037, "1\\0\\0\\0\\1\\0", .DS)])]),
                sequence(0x00189226, [.init(elements: [text(0x00089007, imageType, .CS), text(0x00089205, "MONOCHROME", .CS),
                    text(0x00089206, "VOLUME", .CS), text(0x00089207, "NONE", .CS), text(0x00089208, "MAGNITUDE", .CS), text(0x00089209, "T1", .CS)])]),
                sequence(0x00289145, [.init(elements: [text(0x00281052, "0", .DS), text(0x00281053, "1", .DS), text(0x00281054, "US", .LO)])]),
                sequence(0x00189112, [.init(elements: [text(0x00180080, "500", .DS), text(0x00181314, "90", .DS), text(0x00180091, "1", .IS),
                    number(0x00189240, 1), number(0x00189241, 0)])]),
                sequence(0x00189125, [.init(elements: [text(0x00181312, "ROW", .CS), number(0x00189058, 128), number(0x00189231, 128),
                    text(0x00180093, "100", .DS), text(0x00180094, "100", .DS)])]),
                sequence(0x00189114, [.init(elements: [float(0x00189082, 10)])]),
                sequence(0x00189115, [.init(elements: [text(0x00189009, "NO", .CS), text(0x00189010, "NONE", .CS), text(0x00189021, "NO", .CS),
                    text(0x00189026, "NONE", .CS), text(0x00189027, "NONE", .CS), text(0x00189081, "NO", .CS), text(0x00189077, "NO", .CS)])]),
                sequence(0x00189006, [.init(elements: [text(0x00189020, "NONE", .CS), text(0x00189022, "NO", .CS), text(0x00189028, "NONE", .CS),
                    float(0x00189098, 63.8), text(0x00180095, "200", .DS)])]),
                sequence(0x00189042, [.init(elements: [text(0x00181250, "BODY", .SH), text(0x00189041, "", .LO), text(0x00189043, "BODY", .CS),
                    text(0x00189044, "YES", .CS)])]),
                sequence(0x00189049, [.init(elements: [text(0x00181251, "BODY", .SH), text(0x00189050, "", .LO), text(0x00189051, "BODY", .CS)])]),
                sequence(0x00189119, [.init(elements: [text(0x00180083, "1", .DS)])])
            ]
        case .xa:
            elements += [text(0x00080060, "XA", .CS), text(0x00189410, "SINGLE PLANE", .CS), text(0x00189457, "MONOPLANE", .CS),
                text(0x00180060, "80", .DS), text(0x00181155, "GR", .CS), float(0x00189330, 100), float(0x00189328, 10),
                text(0x00181154, "10", .DS), text(0x0018115A, "PULSED", .CS), text(0x00189420, "DIGITAL_DETECTOR", .CS),
                .init(tag: 0x00189426, vr: .FL, value: .empty), text(0x00181508, "CARM", .CS), text(0x00189474, "NO", .CS),
                .init(tag: 0x00189473, vr: .FL, value: .empty), text(0x00187004, "SCINTILLATOR", .CS),
                .init(tag: 0x00189429, vr: .FL, value: .floats([300, 300]))]
            sharedItem += [
                sequence(0x00289443, [.init(elements: [text(0x00089007, imageType, .CS), text(0x00281040, "LIN", .CS),
                    .init(tag: 0x00281041, vr: .SS, value: .signedIntegers([1])), text(0x00181164, "0.2\\0.2", .DS),
                    text(0x00289444, "UNIFORM", .CS), text(0x00289446, "NONE", .CS)])]),
                sequence(0x00289132, [.init(elements: [text(0x00281050, "2048", .DS), text(0x00281051, "4096", .DS)])]),
                sequence(0x00189407, [.init(elements: [text(0x00181700, "RECTANGULAR", .CS), text(0x00181702, "0", .IS), text(0x00181704, "1", .IS),
                    text(0x00181706, "0", .IS), text(0x00181708, "1", .IS)])]),
                sequence(0x00189451, [.init(elements: [])])
            ]
        }
        elements.append(sequence(0x52009229, [.init(elements: sharedItem)]))
        elements.append(sequence(0x52009230, [.init(elements: perFrame(kind, index: 1)), .init(elements: perFrame(kind, index: 2))]))
        return .init(elements: elements)
    }

    private func perFrame(_ kind: Kind, index: Int) -> [DicomDataElement] {
        var items = [frameContent(index: index, dimensionValues: kind == .xa ? nil : [UInt(index)])]
        if kind != .xa {
            items.append(sequence(0x00209113, [.init(elements: [text(0x00200032, "0\\0\\\(index - 1)", .DS)])]))
        }
        return items
    }

    private func frameContent(index: Int, dimensionValues: [UInt]? = [1]) -> DicomDataElement {
        var item: [DicomDataElement] = [text(0x00189151, "20260908120000", .DT), text(0x00189074, "20260908120000", .DT),
            float(0x00189220, 1), text(0x00209056, "1", .SH), .init(tag: 0x00209057, vr: .UL, value: .unsignedIntegers([UInt(index)]))]
        if let dimensionValues { item.append(.init(tag: 0x00209157, vr: .UL, value: .unsignedIntegers(dimensionValues))) }
        return sequence(0x00209111, [.init(elements: item)])
    }

    private func spiral(_ dataSet: DicomDataSet, pitch: Bool = true) -> DicomDataSet {
        var dynamics = [float(0x00189309, 10), float(0x00189310, 10)]
        if pitch { dynamics.append(float(0x00189311, 0.625)) }
        return settingShared(dataSet, [
            sequence(0x00189301, [.init(elements: [text(0x00189302, "SPIRAL", .CS), text(0x00189333, "NO", .CS), text(0x00189334, "NO", .CS)])]),
            sequence(0x00189308, [.init(elements: dynamics)])
        ])
    }

    /// Both frames DERIVED from another instance: the derived frame type, the derivation macro and an
    /// Image Type that summarizes the frames; the acquisition macros stay optional.
    private func derived(_ dataSet: DicomDataSet) -> DicomDataSet {
        let frameType = "DERIVED\\PRIMARY\\AXIAL\\NONE"
        let derivation = sequence(0x00089124, [.init(elements: [
            sequence(0x00089215, [code("113072", "DCM", "Multiplanar reformatting")]),
            sequence(0x00082112, [.init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI), text(0x00081155, "2.25.23229980", .UI),
                sequence(0x0040A170, [code("121322", "DCM", "Source image for image processing operation")])])])
        ])])
        // Image Filter is required for ORIGINAL frames and not permitted otherwise (C.8.15.3.7).
        var result = settingShared(removingShared(dataSet, 0x00189314), [
            sequence(0x00189329, [.init(elements: [text(0x00089007, frameType, .CS), text(0x00089205, "MONOCHROME", .CS),
                text(0x00089206, "VOLUME", .CS), text(0x00089207, "NONE", .CS)])]),
            derivation
        ])
        result = result.setting(text(0x00080008, frameType, .CS))
        return result
    }

    /// Prospective cardiac gating declared at the root with the per-frame trigger macro shared.
    private func cardiac(_ dataSet: DicomDataSet) -> DicomDataSet {
        let root = dataSet.setting(text(0x00189037, "PROSPECTIVE", .CS)).setting(text(0x00189085, "ECG", .CS))
            .setting(float(0x00189070, 800)).setting(text(0x00189169, "NONE", .CS)).setting(text(0x00181081, "700", .IS))
            .setting(text(0x00181082, "900", .IS)).setting(text(0x00181083, "1", .IS)).setting(text(0x00181084, "0", .IS))
        return settingShared(root, [sequence(0x00189118, [.init(elements: [float(0x00209153, 100), float(0x00209252, 100), float(0x00209251, 800)])])])
    }

    /// Diffusion acquisition contrast, with or without the MR Diffusion macro it requires.
    private func diffusion(_ dataSet: DicomDataSet, macro: Bool) -> DicomDataSet {
        var elements = [sequence(0x00189226, [.init(elements: [text(0x00089007, "ORIGINAL\\PRIMARY\\DIFFUSION\\NONE", .CS),
            text(0x00089205, "MONOCHROME", .CS), text(0x00089206, "VOLUME", .CS), text(0x00089207, "NONE", .CS),
            text(0x00089208, "MAGNITUDE", .CS), text(0x00089209, "DIFFUSION", .CS)])])]
        if macro {
            elements.append(sequence(0x00189117, [.init(elements: [float(0x00189087, 1000), text(0x00189075, "ISOTROPIC", .CS)])]))
        }
        return settingShared(dataSet.setting(text(0x00089209, "DIFFUSION", .CS)).setting(text(0x00080008, "ORIGINAL\\PRIMARY\\DIFFUSION\\NONE", .CS)), elements)
    }

    /// LOG pixel intensity relationship, which requires the Pixel Intensity Relationship LUT macro.
    private func logarithmicLUT(_ dataSet: DicomDataSet) -> DicomDataSet {
        let imageType = "ORIGINAL\\PRIMARY\\SINGLE PLANE\\NONE"
        return settingShared(dataSet, [
            sequence(0x00289443, [.init(elements: [text(0x00089007, imageType, .CS), text(0x00281040, "LOG", .CS),
                .init(tag: 0x00281041, vr: .SS, value: .signedIntegers([1])), text(0x00181164, "0.2\\0.2", .DS),
                text(0x00289444, "UNIFORM", .CS), text(0x00289446, "NONE", .CS)])]),
            sequence(0x00289422, [.init(elements: [.init(tag: 0x00283002, vr: .US, value: .unsignedIntegers([2, 0, 16])),
                .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 0, 255, 255]))), text(0x00289474, "TO_LINEAR", .CS)])])
        ])
    }

    private func settingShared(_ dataSet: DicomDataSet, _ elements: [DicomDataElement]) -> DicomDataSet {
        var item = dataSet[0x52009229]?.sequenceItems.first?.dataSet ?? .init()
        for element in elements { item.set(element) }
        return dataSet.setting(sequence(0x52009229, [item]))
    }

    private func removingShared(_ dataSet: DicomDataSet, _ tag: Int) -> DicomDataSet {
        let item = (dataSet[0x52009229]?.sequenceItems.first?.dataSet ?? .init()).removing(tag)
        return dataSet.setting(sequence(0x52009229, [item]))
    }

    private func replacingFrame(_ dataSet: DicomDataSet, _ index: Int, _ elements: [DicomDataElement]) -> DicomDataSet {
        var items = (dataSet[0x52009230]?.sequenceItems ?? []).map(\.dataSet)
        for element in elements { items[index].set(element) }
        return dataSet.setting(sequence(0x52009230, items))
    }

    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }
    private func pointer(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .AT, value: .unsignedIntegers([value])) }
    private func float(_ tag: Int, _ value: Double) -> DicomDataElement { .init(tag: tag, vr: .FD, value: .floats([value])) }
    private func floats(_ tag: Int, _ values: [Double]) -> DicomDataElement { .init(tag: tag, vr: .FD, value: .floats(values)) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
