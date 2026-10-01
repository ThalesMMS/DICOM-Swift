import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the Segmentation and Parametric Map IODs: IOD-specific modules, the
/// A.51-2/A.75-2 functional group usage, segment identification, derivation codes, the pixel
/// module choice (integer, float, double float) and the COLOR_RANGE palette requirements.
final class DicomSegmentationParametricMapCorpusTests: XCTestCase {
    func test_surfaceBuilder_qualifiesAndRejectsRawGeometryViolations() throws {
        typealias W = DicomRTStructureSetBuilder
        let base = DicomGeometryCorpusTests.surfaceDataSet()
        func replacingSurface(_ change: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
            base.setting(W.sequence(0x00660002, [change(base.sequenceItems(for: 0x00660002)[0].dataSet)]))
        }
        let cases: [(String, DicomDataSet, DicomValidationReport.Code?)] = [
            ("surface-cube", base, nil),
            ("surface-finite-invalid", replacingSurface { $0.setting(W.text(0x0066000E, .CS, "MAYBE")) },
                .attributeValueNotAllowed),
            ("surface-manifold-invalid", replacingSurface { $0.setting(W.text(0x00660010, .CS, "MAYBE")) },
                .attributeValueNotAllowed),
            ("surface-processing-required", replacingSurface { $0.setting(W.text(0x00660009, .CS, "YES")) },
                .requiredAttributeMissing),
            ("surface-normals-count", replacingSurface { surface in
                let normals = surface.sequenceItems(for: 0x00660012)[0].dataSet
                    .setting(.init(tag: 0x0066001E, vr: .UL, value: .unsignedIntegers([7])))
                return surface.setting(W.sequence(0x00660012, [normals]))
            }, .attributeValueContradiction),
            ("surface-index-bounds", replacingSurface { surface in
                let primitives = surface.sequenceItems(for: 0x00660013)[0].dataSet
                    .setting(.init(tag: 0x00660041, vr: .OL, value: .unsignedIntegers([1, 2, 9])))
                return surface.setting(W.sequence(0x00660013, [primitives]))
            }, .attributeValueContradiction),
            ("surface-primitives-empty", replacingSurface {
                $0.setting(W.sequence(0x00660013, [DicomDataSet(elements: [])]))
            }, .requiredAttributeMissing),
            ("surface-primitives-empty-list", replacingSurface {
                $0.setting(W.sequence(0x00660013, [DicomDataSet(elements: [
                    .init(tag: 0x00660041, vr: .OL, value: .unsignedIntegers([]))
                ])]))
            }, .requiredAttributeMissing),
            ("surface-count", base.setting(.init(tag: 0x00660001, vr: .UL, value: .unsignedIntegers([2]))),
                .attributeValueContradiction)
        ]
        for (name, dataSet, code) in cases {
            let bytes = try DicomGeometryCorpusTests.bytes(dataSet)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            if let code {
                XCTAssertTrue(report.diagnostics.contains { $0.code == code }, "\(name): \(report.diagnostics)")
                XCTAssertEqual(report.outcome(requiring: requiredLayers), .failed)
            } else {
                XCTAssertEqual(report.outcome(requiring: requiredLayers), .passed, "\(report.diagnostics)")
            }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SEG_PM_CORPUS_DIRECTORY"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try bytes.write(to: output.appendingPathComponent(name + ".dcm"))
                let outcome = report.outcome(requiring: requiredLayers)
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue,
                    "sopClass": DicomSurfaceSegmentation.storageSOPClassUID, "references": false,
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: output.appendingPathComponent(name + ".json"))
            }
        }
    }

    private enum Kind { case segmentation, labelmap, parametricMap }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let shared: [DicomValidationReport.PathComponent] = [.tag(0x52009229), .item(0)]
    private func frame(_ index: Int) -> [DicomValidationReport.PathComponent] { [.tag(0x52009230), .item(index)] }

    func test_originalCorpus_qualifiesSegmentationAndParametricMapAndRejectsViolations() throws {
        let cases: [(String, Kind, (DicomDataSet) -> DicomDataSet, Expectation)] = [
            ("seg-labelmap-8", .labelmap, { $0 }, .passed),
            ("seg-labelmap-16", .labelmap, { self.labelmap($0, bits: 16) }, .passed),
            ("seg-labelmap-palette", .labelmap, { self.labelmapPalette($0) }, .passed),
            ("seg-labelmap-padding", .labelmap, { $0.setting(self.number(0x00280120, 1)) }, .passed),
            ("seg-labelmap-bits-1", .labelmap, { $0.setting(self.number(0x00280100, 1)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280100)])),
            ("seg-labelmap-bits-stored", .labelmap, { $0.setting(self.number(0x00280101, 7)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280101)])),
            ("seg-labelmap-high-bit", .labelmap, { $0.setting(self.number(0x00280102, 8)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280102)])),
            ("seg-labelmap-photometric", .labelmap, { $0.setting(self.text(0x00280004, "MONOCHROME1", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280004)])),
            ("seg-labelmap-overlap-yes", .labelmap, { $0.setting(self.text(0x00620013, "YES", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00620013)])),
            ("seg-labelmap-overlap-missing", .labelmap, { $0.removing(0x00620013) },
             .passed),
            ("seg-labelmap-maximum-fractional", .labelmap, { $0.setting(self.number(0x0062000E, 255)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x0062000E)])),
            ("seg-labelmap-fractional-type", .labelmap, { $0.setting(self.text(0x00620010, "PROBABILITY", .CS)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x00620010)])),
            ("seg-labelmap-padding-range", .labelmap, { $0.setting(self.number(0x00280121, 2)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x00280121)])),
            ("seg-labelmap-segment-identification", .labelmap, { self.replacingFrame($0, 0) { $0.setting(self.segmentIdentification(1)) } },
             .failed(.conditionalAttributeForbidden, frame(0) + [.tag(0x0062000A)])),
            ("seg-labelmap-palette-missing-lut", .labelmap, { $0.setting(self.text(0x00280004, "PALETTE COLOR", .CS)).setting(self.profile()) },
             .failed(.requiredAttributeMissing, [.tag(0x00281101)])),
            ("seg-labelmap-palette-missing-icc", .labelmap, { self.labelmapPalette($0).removing(0x00282000) },
             .failed(.requiredAttributeMissing, [.tag(0x00282000)])),
            ("seg-labelmap-palette-cielab", .labelmap, { dataSet in
                let palette = self.labelmapPalette(dataSet)
                let items = palette[0x00620002]!.sequenceItems.map {
                    $0.dataSet.setting(.init(tag: 0x0062000D, vr: .US, value: .unsignedIntegers([1, 2, 3])))
                }
                return palette.setting(self.sequence(0x00620002, items))
            }, .failed(.conditionalAttributeForbidden, [.tag(0x00620002), .item(0), .tag(0x0062000D)])),
            ("seg-binary", .segmentation, { $0 }, .passed),
            ("seg-fractional", .segmentation, { self.fractional($0) }, .passed),
            ("seg-derived", .segmentation, { self.derived($0) }, .passed),
            // Without Pixel Measures the Pixel Aspect Ratio condition cannot be evidenced (C.7.6.3).
            ("seg-derived-without-frame-of-reference", .segmentation, { self.derived($0, geometry: false).removing(0x00200052).removing(0x00201040) },
             .incomplete(.conditionUndetermined, [.tag(0x00280034)])),
            ("pm-integer", .parametricMap, { $0 }, .passed),
            ("pm-float", .parametricMap, { self.floating($0, double: false) }, .passed),
            ("pm-double", .parametricMap, { self.floating($0, double: true) }, .passed),
            ("pm-color-range", .parametricMap, { self.colorRange($0) }, .passed),
            ("seg-missing-segment-identification", .segmentation, { self.replacingFrame($0, 0) { $0.removing(0x0062000A) } },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x0062000A)])),
            ("seg-unknown-referenced-segment", .segmentation, { self.replacingFrame($0, 0) { $0.setting(self.segmentIdentification(5)) } },
             .failed(.attributeValueContradiction, frame(0) + [.tag(0x0062000A), .item(0), .tag(0x0062000B)])),
            ("seg-segment-numbers-gap", .segmentation, { self.renumberingSecondSegment($0, to: 3) },
             .failed(.attributeValueNotAllowed, [.tag(0x00620002), .item(1), .tag(0x00620004)])),
            ("seg-image-type-original", .segmentation, { $0.setting(self.text(0x00080008, "ORIGINAL\\PRIMARY", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00080008)])),
            ("seg-binary-bits-8", .segmentation, { $0.setting(self.number(0x00280100, 8)).setting(self.number(0x00280101, 8)).setting(self.number(0x00280102, 7)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280100)])),
            ("seg-fractional-missing-maximum", .segmentation, { self.fractional($0).removing(0x0062000E) },
             .failed(.requiredAttributeMissing, [.tag(0x0062000E)])),
            ("seg-pixel-padding", .segmentation, { $0.setting(self.number(0x00280120, 0)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x00280120)])),
            ("seg-no-frame-of-reference-no-derivation", .segmentation, { $0.removing(0x00200052).removing(0x00201040) },
             .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("seg-geometry-without-frame-of-reference", .segmentation, { self.derived($0).removing(0x00200052).removing(0x00201040) },
             .failed(.conditionalAttributeForbidden, shared + [.tag(0x00289110)])),
            ("seg-derivation-without-instance-reference", .segmentation, { self.derived($0).removing(0x00081115) },
             .failed(.requiredAttributeMissing, [.tag(0x00081115)])),
            ("seg-derivation-wrong-code", .segmentation, { self.derived($0, code: "113072") },
             .failed(.attributeValueNotAllowed, frame(0) + [.tag(0x00089124), .item(0), .tag(0x00089215), .item(0), .tag(0x00080100)])),
            ("seg-voi-lut", .segmentation, { $0.setting(self.text(0x00281050, "0", .DS)).setting(self.text(0x00281051, "1", .DS)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x00281050)])),
            ("seg-frame-content-shared", .segmentation, { self.settingShared($0, [self.frameContent([1, 1])]) },
             .failed(.conditionalAttributeForbidden, shared + [.tag(0x00209111)])),
            ("seg-algorithm-name-missing", .segmentation, { self.settingSegmentAlgorithm($0, "AUTOMATIC") },
             .failed(.requiredAttributeMissing, [.tag(0x00620002), .item(0), .tag(0x00620009)])),
            ("pm-missing-real-world-value-mapping", .parametricMap, { self.removingShared($0, 0x00409096) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00409096)])),
            ("pm-rescale-slope-2", .parametricMap, { self.settingShared($0, [self.pixelValueTransformation(slope: "2")]) },
             .failed(.attributeValueNotAllowed, shared + [.tag(0x00289145), .item(0), .tag(0x00281053)])),
            ("pm-missing-frame-voi-lut", .parametricMap, { self.removingShared($0, 0x00289132) },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00289132)])),
            ("pm-float-bits-16", .parametricMap, { self.floating($0, double: false).setting(self.number(0x00280100, 16)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00280100)])),
            ("pm-color-range-without-palette", .parametricMap, { $0.setting(self.text(0x00089205, "COLOR_RANGE", .CS)) },
             .failed(.requiredAttributeMissing, [.tag(0x00281199)])),
            ("pm-mixed-frame-type", .parametricMap, { self.settingShared($0, [self.frameType("DERIVED\\PRIMARY\\MIXED\\NONE")]) },
             .failed(.attributeValueNotAllowed, [.tag(0x52009229), .item(0), .tag(0x00409092), .item(0), .tag(0x00089007)])),
            ("pm-missing-frame-of-reference", .parametricMap, { $0.removing(0x00200052).removing(0x00201040) },
             .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("pm-missing-plane-position", .parametricMap, { self.replacingFrame($0, 0) { $0.removing(0x00209113) } },
             .failed(.requiredAttributeMissing, frame(0) + [.tag(0x00209113)])),
            ("pm-unassigned-shared-per-frame", .parametricMap, { self.replacingFrame($0, 0) { $0.setting(self.sequence(0x00209170, [.init(elements: [])])) } },
             .failed(.conditionalAttributeForbidden, frame(0) + [.tag(0x00209170)])),
            ("pm-image-type-original", .parametricMap, { $0.setting(self.text(0x00080008, "ORIGINAL\\PRIMARY\\VOLUME\\NONE", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00080008)])),
            ("pm-integer-missing-bits-stored", .parametricMap, { $0.removing(0x00280101) },
             .failed(.requiredAttributeMissing, [.tag(0x00280101)])),
            ("pm-derivation-without-instance-reference", .parametricMap, { $0.removing(0x00081115) },
             .failed(.requiredAttributeMissing, [.tag(0x00081115)]))
        ]
        for (name, kind, transform, expectation) in cases {
            let instance = transform(fixture(kind))
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: sop(kind), mediaStorageSOPInstanceUID: "2.25.23259995"))
            let targets = [sourceInstanceUID: target()]
            let report = try DicomInstanceValidator.validate(bytes, targets: targets, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code, let path):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(name): \(report.diagnostics)")
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets, imageConditions: facts), report, name)
            try writeSidecar(name, kind: kind, bytes: bytes, outcome: outcome, references: instance.contains(0x00081115))
        }
    }

    /// The CLI has no target metadata: objects with a Common Instance Reference stay incomplete there.
    private func writeSidecar(_ name: String, kind: Kind, bytes: Data, outcome: DicomValidationReport.Outcome, references: Bool) throws {
        guard let folder = ProcessInfo.processInfo.environment["DICOM_SEG_PM_CORPUS_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
        try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": sop(kind), "references": references,
            "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }

    func test_segmentationBuilder_producesQualifiedInstance() throws {
        let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                                  referencedSOPInstanceUID: "2.25.23259980", referencedFrameNumbers: [],
            derivationCode: DicomSegmentationBuilder.derivationCode, purposeOfReferenceCode: DicomSegmentationBuilder.sourcePurposeCode)
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.23259995", frameOfReferenceUID: "2.25.23259998", segmentationType: .binary, rows: 2, columns: 2,
            referencedSeriesInstanceUIDs: ["2.25.23259981"],
            segments: [.init(number: 1, label: "Liver", algorithmType: "SEMIAUTOMATIC", algorithmName: "Corpus")],
            frames: [
                .init(index: 0, segmentNumber: 1, geometry: .init(frameIndex: 0, imagePositionPatient: .init(0, 0, 0),
                    imageOrientationPatient: .init(row: .init(1, 0, 0), column: .init(0, 1, 0)),
                    pixelMeasures: .init(pixelSpacing: .init(1, 1), sliceThickness: 1, spacingBetweenSlices: nil)),
                    sourceImageReferences: [reference], pixelData: .binary([1, 0, 0, 1])),
                .init(index: 1, segmentNumber: 1, geometry: .init(frameIndex: 1, imagePositionPatient: .init(0, 0, 1),
                    imageOrientationPatient: .init(row: .init(1, 0, 0), column: .init(0, 1, 0)),
                    pixelMeasures: .init(pixelSpacing: .init(1, 1), sliceThickness: 1, spacingBetweenSlices: nil)),
                    sourceImageReferences: [reference], pixelData: .binary([0, 1, 1, 0]))
            ])
        let tissue = DicomCodedConcept(codeValue: "85756007", codingSchemeDesignator: "SCT", codeMeaning: "Tissue")
        let dataSet = DicomSegmentationBuilder.dataSet(from: segmentation, studyInstanceUID: "2.25.23259996",
                                                        seriesInstanceUID: "2.25.23259997",
                                                        options: .init(contentDate: "20260909", contentTime: "120000",
                                                                       defaultPropertyCategory: tissue, defaultPropertyType: tissue))
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID, mediaStorageSOPInstanceUID: "2.25.23259995"))
        let report = try DicomInstanceValidator.validate(bytes, targets: [sourceInstanceUID: target()], imageConditions: facts)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .passed, "\(report.diagnostics)")
        // The builder round-trips its own Frame of Reference and references.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seg-corpus-\(UUID().uuidString).dcm")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let parsed = try XCTUnwrap(DCMDecoder(contentsOf: url).segmentation)
        XCTAssertEqual(parsed.frameOfReferenceUID, "2.25.23259998")
        XCTAssertEqual(parsed.frames.map(\.segmentNumber), [1, 1])
        XCTAssertEqual(parsed.frames[1].sourceImageReferences, [reference])
        try writeSidecar("seg-builder", kind: .segmentation, bytes: bytes, outcome: .passed, references: true)
    }

    func test_missingFirstSegmentNumber_doesNotMisnumberTheSecondSegment() throws {
        let source = fixture(.segmentation)
        var segments = source.sequenceItems(for: 0x00620002).map(\.dataSet)
        segments[0] = segments[0].removing(0x00620004)
        let report = DicomEnhancedImageModules.validate(source.setting(sequence(0x00620002, segments)),
            profile: .segmentation, conditions: facts)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00620002), .item(0), .tag(0x00620004)]
        })
        XCTAssertFalse(report.diagnostics.contains {
            $0.code == .attributeValueNotAllowed && $0.path == [.tag(0x00620002), .item(1), .tag(0x00620004)]
        })
    }

    // MARK: - Fixtures

    private let sourceInstanceUID = "2.25.23259980"

    /// Metadata of the referenced CT instance, keyed by its SOP Instance UID.
    private func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00080018, sourceInstanceUID, .UI),
            text(0x0020000D, "2.25.23259996", .UI), text(0x0020000E, "2.25.23259981", .UI),
            number(0x00280010, 2), number(0x00280011, 2)])
    }

    private func sop(_ kind: Kind) -> String {
        switch kind {
        case .labelmap: return "1.2.840.10008.5.1.4.1.1.66.7"
        case .segmentation: return "1.2.840.10008.5.1.4.1.1.66.4"
        case .parametricMap: return "1.2.840.10008.5.1.4.1.1.30"
        }
    }

    private func fixture(_ kind: Kind) -> DicomDataSet {
        if kind == .labelmap { return labelmap(fixture(.segmentation)) }
        var elements: [DicomDataElement] = [
            text(0x00080016, sop(kind), .UI), text(0x00080018, "2.25.23259995", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "1", .IS), text(0x00200013, "1", .IS),
            text(0x00080023, "20260909", .DA), text(0x00080033, "120000", .TM),
            text(0x00080070, "SYNTHETIC", .LO), text(0x00081090, "MODEL", .LO), text(0x00181000, "1", .LO), text(0x00181020, "1.0", .LO),
            text(0x0020000D, "2.25.23259996", .UI), text(0x0020000E, "2.25.23259997", .UI),
            text(0x00200052, "2.25.23259998", .UI), text(0x00201040, "", .LO),
            text(0x00700080, "CORPUS", .CS), text(0x00700081, "", .LO),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS), number(0x00280010, 2), number(0x00280011, 2),
            text(0x00280008, "2", .IS), text(0x00282110, "00", .CS),
            sequence(0x00209221, [.init(elements: [text(0x00209164, "2.25.23259999", .UI)])])
        ]
        var sharedItem: [DicomDataElement] = [
            sequence(0x00289110, [.init(elements: [text(0x00280030, "1\\1", .DS), text(0x00180050, "1", .DS)])]),
            sequence(0x00209116, [.init(elements: [text(0x00200037, "1\\0\\0\\0\\1\\0", .DS)])])
        ]
        var frames: [DicomDataSet] = []
        switch kind {
        case .segmentation, .labelmap:
            elements += [
                text(0x00080060, "SEG", .CS), text(0x00080008, "DERIVED\\PRIMARY", .CS),
                number(0x00280100, 1), number(0x00280101, 1), number(0x00280102, 0), number(0x00280103, 0),
                text(0x00620001, "BINARY", .CS),
                sequence(0x00620002, [segment(1, "Liver"), segment(2, "Spleen")]),
                sequence(0x00209222, [
                    .init(elements: [text(0x00209164, "2.25.23259999", .UI), pointer(0x00209165, 0x0062000B), pointer(0x00209167, 0x0062000A)]),
                    .init(elements: [text(0x00209164, "2.25.23259999", .UI), pointer(0x00209165, 0x00200032), pointer(0x00209167, 0x00209113)])
                ]),
                // Frame 1 bits 1,0,0,1 and frame 2 bits 0,1,1,0 packed LSB first: 0x69.
                .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([0x69, 0x00])))
            ]
            for index in 1...2 {
                frames.append(.init(elements: [frameContent([UInt(index), 1]), planePosition(index), segmentIdentification(index)]))
            }
        case .parametricMap:
            elements += [
                text(0x00080060, "MR", .CS), text(0x00080008, "DERIVED\\PRIMARY\\VOLUME\\NONE", .CS),
                number(0x00280100, 16), number(0x00280101, 16), number(0x00280102, 15), number(0x00280103, 0),
                text(0x20500020, "IDENTITY", .CS), text(0x00280301, "NO", .CS), text(0x00280302, "NO", .CS), text(0x00189004, "PRODUCT", .CS),
                sequence(0x00400555, []),
                sequence(0x00209222, [
                    .init(elements: [text(0x00209164, "2.25.23259999", .UI), pointer(0x00209165, 0x00200032), pointer(0x00209167, 0x00209113)])
                ]),
                instanceReference(),
                .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 1, count: 16)))
            ]
            sharedItem += [
                pixelValueTransformation(slope: "1"),
                sequence(0x00289132, [.init(elements: [text(0x00281050, "100", .DS), text(0x00281051, "200", .DS)])]),
                realWorldValueMapping(floating: false),
                frameType("DERIVED\\PRIMARY\\VOLUME\\NONE"),
                derivationImage(code: "113072")
            ]
            for index in 1...2 {
                frames.append(.init(elements: [frameContent([UInt(index)]), planePosition(index)]))
            }
        }
        elements.append(sequence(0x52009229, [.init(elements: sharedItem)]))
        elements.append(sequence(0x52009230, frames))
        return .init(elements: elements)
    }

    private func segment(_ number: Int, _ label: String, algorithm: String = "MANUAL") -> DicomDataSet {
        .init(elements: [self.number(0x00620004, UInt(number)), text(0x00620005, label, .LO), text(0x00620008, algorithm, .CS),
                         sequence(0x00620003, [code("85756007", "SCT", "Tissue")]), sequence(0x0062000F, [code("85756007", "SCT", "Tissue")])])
    }

    private func segmentIdentification(_ number: Int) -> DicomDataElement {
        sequence(0x0062000A, [.init(elements: [self.number(0x0062000B, UInt(number))])])
    }

    private func planePosition(_ index: Int) -> DicomDataElement {
        sequence(0x00209113, [.init(elements: [text(0x00200032, "0\\0\\\(index - 1)", .DS)])])
    }

    private func frameContent(_ dimensionValues: [UInt]) -> DicomDataElement {
        sequence(0x00209111, [.init(elements: [.init(tag: 0x00209157, vr: .UL, value: .unsignedIntegers(dimensionValues))])])
    }

    private func frameType(_ value: String) -> DicomDataElement {
        sequence(0x00409092, [.init(elements: [text(0x00089007, value, .CS)])])
    }

    private func pixelValueTransformation(slope: String) -> DicomDataElement {
        sequence(0x00289145, [.init(elements: [text(0x00281052, "0", .DS), text(0x00281053, slope, .DS), text(0x00281054, "US", .LO)])])
    }

    private func realWorldValueMapping(floating: Bool) -> DicomDataElement {
        var item: [DicomDataElement] = [float(0x00409224, 0), float(0x00409225, 1), text(0x00283003, "Stored value", .LO),
                                        text(0x00409210, "SV", .SH), sequence(0x004008EA, [code("1", "UCUM", "no units")])]
        if floating {
            item += [float(0x00409214, 0), float(0x00409213, 1)]
        } else {
            item += [number(0x00409216, 0), number(0x00409211, 65535)]
        }
        return sequence(0x00409096, [.init(elements: item)])
    }

    /// Derivation Image with the Segmentation codes (A.51.5.1) or another derivation code.
    private func derivationImage(code derivation: String, purpose: String = "121322") -> DicomDataElement {
        sequence(0x00089124, [.init(elements: [
            sequence(0x00089215, [code(derivation, "DCM", "Derivation")]),
            sequence(0x00082112, [.init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00081155, "2.25.23259980", .UI),
                sequence(0x0040A170, [code(purpose, "DCM", "Source image for image processing operation")])])])
        ])])
    }

    private func instanceReference() -> DicomDataElement {
        sequence(0x00081115, [.init(elements: [text(0x0020000E, "2.25.23259981", .UI),
            sequence(0x0008114A, [.init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00081155, "2.25.23259980", .UI)])])])])
    }

    /// FRACTIONAL PROBABILITY segmentation with 8-bit samples.
    private func fractional(_ dataSet: DicomDataSet) -> DicomDataSet {
        dataSet.setting(text(0x00620001, "FRACTIONAL", .CS)).setting(text(0x00620010, "PROBABILITY", .CS)).setting(number(0x0062000E, 255))
            .setting(number(0x00280100, 8)).setting(number(0x00280101, 8)).setting(number(0x00280102, 7))
            .setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([255, 0, 0, 255, 0, 128, 128, 0]))))
    }

    /// Frames derived from a CT instance with the Segmentation derivation codes and the instance reference.
    private func derived(_ dataSet: DicomDataSet, code: String = "113076", geometry: Bool = true) -> DicomDataSet {
        var result = dataSet.setting(instanceReference())
        for index in 0..<2 {
            result = replacingFrame(result, index) { frame in
                var item = frame.setting(derivationImage(code: code))
                if !geometry { item = item.removing(0x00209113) }
                return item
            }
        }
        if !geometry {
            result = removingShared(removingShared(result, 0x00289110), 0x00209116)
        }
        return result
    }

    /// Float (OF) or double float (OD) pixels with the matching bit depth and mapping.
    private func floating(_ dataSet: DicomDataSet, double: Bool) -> DicomDataSet {
        var result = dataSet.removing(0x7FE00010).removing(0x00280101).removing(0x00280102).removing(0x00280103)
            .setting(number(0x00280100, double ? 64 : 32))
        result = result.setting(double ? .init(tag: 0x7FE00009, vr: .OD, value: .bytes(Data(repeating: 0, count: 64)))
                                       : .init(tag: 0x7FE00008, vr: .OF, value: .bytes(Data(repeating: 0, count: 32))))
        return settingShared(result, [realWorldValueMapping(floating: true)])
    }

    private func labelmap(_ dataSet: DicomDataSet, bits: Int = 8) -> DicomDataSet {
        var result = dataSet.setting(text(0x00080016, sop(.labelmap), .UI))
            .setting(text(0x00620001, "LABELMAP", .CS)).setting(text(0x00620013, "NO", .CS))
            .setting(number(0x00280100, UInt(bits))).setting(number(0x00280101, UInt(bits)))
            .setting(number(0x00280102, UInt(bits - 1)))
        let second: UInt = bits == 16 ? 300 : 2
        result = result.setting(sequence(0x00620002, [segment(1, "One"), segment(Int(second), "Two")]))
        let values: [UInt16] = [1, UInt16(second), 1, UInt16(second), UInt16(second), 1, UInt16(second), 1]
        let bytes = values.flatMap { value -> [UInt8] in
            bits == 8 ? [UInt8(value)] : [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
        }
        result = result.setting(.init(tag: 0x7FE00010, vr: bits == 8 ? .OB : .OW, value: .bytes(Data(bytes))))
        let dimensions = result[0x00209222]!.sequenceItems.map(\.dataSet).filter {
            $0[0x00209165]?.intValue != 0x0062000B
        }
        result = result.setting(sequence(0x00209222, dimensions))
        for index in 0..<2 {
            result = replacingFrame(result, index) { $0.removing(0x0062000A).setting(self.frameContent([UInt(index + 1)])) }
        }
        return result
    }

    private func labelmapPalette(_ dataSet: DicomDataSet) -> DicomDataSet {
        var result = dataSet.setting(text(0x00280004, "PALETTE COLOR", .CS)).setting(profile())
        for tag in [0x00281101, 0x00281102, 0x00281103] {
            result = result.setting(.init(tag: tag, vr: .US, value: .unsignedIntegers([2, 1, 8])))
        }
        for tag in [0x00281201, 0x00281202, 0x00281203] {
            result = result.setting(.init(tag: tag, vr: .OW, value: .bytes(Data([0, 255]))))
        }
        return result
    }

    /// COLOR_RANGE presentation with a two-entry palette, an ICC profile and the stored value range.
    private func colorRange(_ dataSet: DicomDataSet) -> DicomDataSet {
        var result = dataSet.setting(text(0x00089205, "COLOR_RANGE", .CS)).setting(profile())
        for tag in [0x00281101, 0x00281102, 0x00281103] {
            result = result.setting(.init(tag: tag, vr: .US, value: .unsignedIntegers([2, 0, 8])))
        }
        for tag in [0x00281201, 0x00281202, 0x00281203] {
            result = result.setting(.init(tag: tag, vr: .OW, value: .bytes(Data([0, 255]))))
        }
        return settingShared(result, [sequence(0x00281230, [.init(elements: [float(0x00281231, 0), float(0x00281232, 65535)])])])
    }

    /// Minimal ICC input profile: header, one `desc` tag, sRGB description.
    private func profile() -> DicomDataElement {
        func be(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        var description = Data("desc".utf8) + Data(repeating: 0, count: 4)
        let label = Data("sRGB IEC61966-2.1".utf8) + Data([0])
        description += be(UInt32(label.count)) + label
        while !description.count.isMultiple(of: 4) { description.append(0) }
        var header = Data(repeating: 0, count: 128)
        header.replaceSubrange(8..<12, with: [2, 0x10, 0, 0])
        header.replaceSubrange(12..<16, with: Data("scnr".utf8))
        header.replaceSubrange(16..<20, with: Data("RGB ".utf8))
        header.replaceSubrange(20..<24, with: Data("XYZ ".utf8))
        header.replaceSubrange(36..<40, with: Data("acsp".utf8))
        var bytes = header + be(1) + Data("desc".utf8) + be(144) + be(UInt32(description.count)) + description
        bytes.replaceSubrange(0..<4, with: be(UInt32(bytes.count)))
        if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
        return .init(tag: 0x00282000, vr: .OB, value: .bytes(bytes))
    }

    private func renumberingSecondSegment(_ dataSet: DicomDataSet, to number: Int) -> DicomDataSet {
        var items = (dataSet[0x00620002]?.sequenceItems ?? []).map(\.dataSet)
        items[1].set(self.number(0x00620004, UInt(number)))
        return replacingFrame(dataSet.setting(sequence(0x00620002, items)), 1) { $0.setting(segmentIdentification(number)) }
    }

    private func settingSegmentAlgorithm(_ dataSet: DicomDataSet, _ algorithm: String) -> DicomDataSet {
        var items = (dataSet[0x00620002]?.sequenceItems ?? []).map(\.dataSet)
        items[0].set(text(0x00620008, algorithm, .CS))
        return dataSet.setting(sequence(0x00620002, items))
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

    private func replacingFrame(_ dataSet: DicomDataSet, _ index: Int, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var items = (dataSet[0x52009230]?.sequenceItems ?? []).map(\.dataSet)
        items[index] = transform(items[index])
        return dataSet.setting(sequence(0x52009230, items))
    }

    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }
    private func pointer(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .AT, value: .unsignedIntegers([value])) }
    private func float(_ tag: Int, _ value: Double) -> DicomDataElement { .init(tag: tag, vr: .FD, value: .floats([value])) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
