import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the Grayscale, Color, Pseudo-Color and Blending Softcopy Presentation
/// State IODs: module usage, shutters and overlays, layers and graphics, displayed areas, LUTs,
/// the IOD exclusions and the referenced image identity against supplied targets.
final class DicomPresentationStateCorpusTests: XCTestCase {
    func test_buildOptionsKeepUnknownManufacturerEmptyAndSuppliedManufacturer() {
        XCTAssertEqual(DicomPresentationStateBuildOptions().manufacturer, "")
        XCTAssertEqual(DicomPresentationStateBuildOptions(manufacturer: "Known producer").manufacturer, "Known producer")
    }

    private enum Kind { case grayscale, color, pseudoColor, blending }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let imageUID = "2.25.23269980"
    private let seriesUID = "2.25.23269981"

    func test_originalCorpus_qualifiesSoftcopyPresentationStatesAndRejectsViolations() throws {
        let annotation: [DicomValidationReport.PathComponent] = [.tag(0x00700001), .item(0)]
        let cases: [(String, Kind, (DicomDataSet) -> DicomDataSet, Expectation)] = [
            ("gsps", .grayscale, { $0 }, .passed),
            ("gsps-display-shutter", .grayscale, { self.displayShutter($0) }, .passed),
            ("gsps-bitmap-shutter", .grayscale, { self.bitmapShutter($0) }, .passed),
            ("gsps-modality-lut", .grayscale, { $0.setting(self.text(0x00281052, "-1024", .DS)).setting(self.text(0x00281053, "1", .DS)).setting(self.text(0x00281054, "HU", .LO)) }, .passed),
            ("gsps-text-anchor", .grayscale, { self.textObject($0, anchor: true) }, .passed),
            ("gsps-mask", .grayscale, { self.mask($0, averaging: true) }, .passed),
            ("color", .color, { $0 }, .passed),
            ("pseudo-color", .pseudoColor, { $0 }, .passed),
            ("blending", .blending, { $0 }, .passed),
            ("gsps-missing-displayed-area", .grayscale, { $0.removing(0x0070005A) },
             .failed(.requiredAttributeMissing, [.tag(0x0070005A)])),
            ("gsps-annotation-without-layer-module", .grayscale, { $0.removing(0x00700060) },
             .failed(.requiredAttributeMissing, [.tag(0x00700060)])),
            ("gsps-unknown-layer", .grayscale, { self.replacingAnnotation($0) { $0.setting(self.text(0x00700002, "OTHER", .CS)) } },
             .failed(.attributeValueContradiction, annotation + [.tag(0x00700002)])),
            ("gsps-graphic-data-count", .grayscale, { self.replacingGraphic($0) { $0.setting(self.floats(0x00700022, [0, 0, 1])) } },
             .failed(.attributeValueContradiction, annotation + [.tag(0x00700009), .item(0), .tag(0x00700022)])),
            ("gsps-closed-polyline-unfilled", .grayscale, { self.replacingGraphic($0) { $0.setting(self.number(0x00700021, 3)).setting(self.floats(0x00700022, [0, 0, 1, 1, 0, 0])) } },
             .failed(.requiredAttributeMissing, annotation + [.tag(0x00700009), .item(0), .tag(0x00700024)])),
            ("gsps-text-without-anchor-or-box", .grayscale, { self.textObject($0, anchor: false) },
             .failed(.requiredAttributeMissing, annotation + [.tag(0x00700008), .item(0), .tag(0x00700014)])),
            ("gsps-displayed-area-inverted", .grayscale, { self.replacingDisplayedArea($0) { $0.setting(self.signed(0x00700052, [3, 3])) } },
             .failed(.attributeValueContradiction, [.tag(0x0070005A), .item(0), .tag(0x00700053)])),
            ("gsps-true-size-without-spacing", .grayscale, { self.replacingDisplayedArea($0) { $0.setting(self.text(0x00700100, "TRUE SIZE", .CS)) } },
             .failed(.requiredAttributeMissing, [.tag(0x0070005A), .item(0), .tag(0x00700101)])),
            ("gsps-magnify-without-ratio", .grayscale, { self.replacingDisplayedArea($0) { $0.setting(self.text(0x00700100, "MAGNIFY", .CS)) } },
             .failed(.requiredAttributeMissing, [.tag(0x0070005A), .item(0), .tag(0x00700103)])),
            ("gsps-missing-presentation-lut", .grayscale, { $0.removing(0x20500020) },
             .failed(.requiredAttributeMissing, [.tag(0x20500020)])),
            ("gsps-shutter-without-presentation-value", .grayscale, { self.displayShutter($0).removing(0x00181622) },
             .failed(.requiredAttributeMissing, [.tag(0x00181622)])),
            ("gsps-bitmap-shutter-without-overlay", .grayscale, { self.bitmapShutter($0, overlay: false) },
             .failed(.requiredAttributeMissing, [.tag(0x60003000)])),
            ("gsps-overlay-without-activation", .grayscale, { self.bitmapShutter($0).removing(0x60001001) },
             .failed(.requiredAttributeMissing, [.tag(0x60001001)])),
            ("gsps-activation-unknown-layer", .grayscale, { self.bitmapShutter($0).setting(self.text(0x60001001, "OTHER", .CS)) },
             .failed(.attributeValueContradiction, [.tag(0x60001001)])),
            ("gsps-reference-outside-relationship", .grayscale, { self.replacingAnnotation($0) { $0.setting(self.referencedImages(uid: "2.25.23269970")) } },
             .failed(.referenceSelectionInvalid, annotation + [.tag(0x00081140), .item(0), .tag(0x00081155)])),
            ("gsps-modality-lut-both", .grayscale, { $0.setting(self.text(0x00281052, "0", .DS)).setting(self.text(0x00281053, "1", .DS))
                .setting(self.text(0x00281054, "US", .LO)).setting(self.modalityLUTSequence()) },
             .failed(.conditionalAttributeForbidden, [.tag(0x00283000)])),
            ("gsps-rotation-45", .grayscale, { $0.setting(self.number(0x00700042, 45)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00700042)])),
            ("gsps-modality-ot", .grayscale, { $0.setting(self.text(0x00080060, "OT", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00080060)])),
            ("gsps-mask-without-averaging", .grayscale, { self.mask($0, averaging: false) },
             .failed(.requiredAttributeMissing, [.tag(0x00286100), .item(0), .tag(0x00286112)])),
            ("gsps-frame-out-of-range", .grayscale, { self.referencingFrame($0, 3) },
             .failed(.referenceSelectionOutOfRange, [.tag(0x00081115), .item(0), .tag(0x00081140), .item(0), .tag(0x00081160)])),
            ("gsps-sop-class-mismatch", .grayscale, { self.referencingClass($0, "1.2.840.10008.5.1.4.1.1.4") },
             .failed(.referenceIdentityContradiction, [.tag(0x00081115), .item(0), .tag(0x00081140), .item(0), .tag(0x00081150)])),
            ("color-missing-icc", .color, { $0.removing(0x00282000) },
             .failed(.requiredAttributeMissing, [.tag(0x00282000)])),
            ("pseudo-color-missing-palette", .pseudoColor, { $0.removing(0x00281101).removing(0x00281102).removing(0x00281103) },
             .failed(.requiredAttributeMissing, [.tag(0x00281101)])),
            ("pseudo-color-with-presentation-lut", .pseudoColor, { $0.setting(self.text(0x20500020, "IDENTITY", .CS)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x20500020)])),
            ("blending-one-item", .blending, { $0.setting(self.sequence(0x00700402, [self.blendingItem("UNDERLYING")])) },
             .failed(.sequenceItemCountInvalid, [.tag(0x00700402)])),
            ("blending-with-overlay", .blending, { self.overlay($0) },
             .failed(.conditionalAttributeForbidden, [.tag(0x60000010)])),
            ("blending-opacity-2", .blending, { $0.setting(.init(tag: 0x00700403, vr: .FL, value: .floats([2]))) },
             .failed(.attributeValueNotAllowed, [.tag(0x00700403)])),
            ("blending-same-position", .blending, { $0.setting(self.sequence(0x00700402, [self.blendingItem("UNDERLYING"), self.blendingItem("UNDERLYING")])) },
             .failed(.attributeValueContradiction, [.tag(0x00700402), .item(1), .tag(0x00700405)]))
        ]
        for (name, kind, transform, expectation) in cases {
            let instance = transform(fixture(kind))
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: sop(kind), mediaStorageSOPInstanceUID: "2.25.23269995"))
            let targets = [imageUID: target()]
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
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets, imageConditions: facts), report, name)
            try writeSidecar(name, kind: kind, bytes: bytes, outcome: outcome)
        }
    }

    func test_grayscaleBuilder_producesQualifiedInstance() throws {
        let image = DicomPresentationReferencedImage(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2", referencedSOPInstanceUID: imageUID,
                                                     referencedFrameNumbers: [1])
        let bytes = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [.init(seriesInstanceUID: seriesUID, images: [image])],
            graphicAnnotations: [.init(graphicLayer: "MEASUREMENTS", referencedImages: [image], graphicObjects: [
                .init(graphicType: "POLYLINE", graphicData: [0, 0, 1, 1]),
                .init(annotationUnits: "DISPLAY", graphicType: "CIRCLE", graphicData: [0.5, 0.5, 0.75, 0.5], graphicFilled: false)
            ], textObjects: [.init(text: "Corpus", anchorPoint: .init(0.5, 0.5), anchorPointAnnotationUnits: "DISPLAY", anchorPointVisible: true)])],
            options: .init(sopInstanceUID: "2.25.23269995", studyInstanceUID: "2.25.23269996", seriesInstanceUID: "2.25.23269997",
                           seriesNumber: 1, instanceNumber: 1, presentationCreationDate: "20260909", presentationCreationTime: "120000",
                           displayedArea: .init(bottomRight: .init(2, 2)), spatialTransform: .init(isHorizontallyFlipped: false, rotationDegrees: 90),
                           displayTransformProfile: .init(windows: [.init(settings: .init(center: 40, width: 400), explanation: "Corpus", source: .dicom(index: 0))],
                                                          voiLUTs: [], presentationLUTShape: .identity)))
        let report = try DicomInstanceValidator.validate(bytes, targets: [imageUID: target()], imageConditions: facts)
        XCTAssertEqual(report.outcome(requiring: requiredLayers), .passed, "\(report.diagnostics)")
        try writeSidecar("gsps-builder", kind: .grayscale, bytes: bytes, outcome: .passed)
    }

    /// The CLI has no target metadata: every presentation state stays incomplete on its references there.
    private func writeSidecar(_ name: String, kind: Kind, bytes: Data, outcome: DicomValidationReport.Outcome) throws {
        guard let folder = ProcessInfo.processInfo.environment["DICOM_PRESENTATION_STATE_CORPUS_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
        try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": sop(kind),
            "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }

    // MARK: - Fixtures

    private func sop(_ kind: Kind) -> String {
        switch kind {
        case .grayscale: return "1.2.840.10008.5.1.4.1.1.11.1"
        case .color: return "1.2.840.10008.5.1.4.1.1.11.2"
        case .pseudoColor: return "1.2.840.10008.5.1.4.1.1.11.3"
        case .blending: return "1.2.840.10008.5.1.4.1.1.11.4"
        }
    }

    /// Metadata of the referenced two-frame CT instance, keyed by its SOP Instance UID.
    private func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00080018, imageUID, .UI),
            text(0x0020000D, "2.25.23269996", .UI), text(0x0020000E, seriesUID, .UI), text(0x00280008, "2", .IS),
            number(0x00280010, 2), number(0x00280011, 2)])
    }

    private func fixture(_ kind: Kind) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            text(0x00080016, sop(kind), .UI), text(0x00080018, "2.25.23269995", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "1", .IS), text(0x00200013, "1", .IS), text(0x00080060, "PR", .CS),
            text(0x00080070, "SYNTHETIC", .LO), text(0x0020000D, "2.25.23269996", .UI), text(0x0020000E, "2.25.23269997", .UI),
            text(0x00700082, "20260909", .DA), text(0x00700083, "120000", .TM), text(0x00700080, "CORPUS", .CS), text(0x00700081, "", .LO),
            sequence(0x00700060, [.init(elements: [text(0x00700002, "MEASUREMENTS", .CS), text(0x00700062, "1", .IS)])]),
            sequence(0x00700001, [.init(elements: [text(0x00700002, "MEASUREMENTS", .CS), sequence(0x00700009, [graphicObject()])])]),
            sequence(0x0070005A, [displayedArea()]),
            number(0x00700042, 0), text(0x00700041, "N", .CS)
        ]
        switch kind {
        case .grayscale:
            elements += [relationship(), text(0x20500020, "IDENTITY", .CS), softcopyVOI()]
        case .color:
            elements += [relationship(), profile()]
        case .pseudoColor:
            elements += [relationship(), profile(), softcopyVOI()] + palette()
        case .blending:
            elements += [profile(), sequence(0x00700402, [blendingItem("SUPERIMPOSED"), blendingItem("UNDERLYING")]),
                         .init(tag: 0x00700403, vr: .FL, value: .floats([0.5]))] + palette()
        }
        return .init(elements: elements)
    }

    private func relationship() -> DicomDataElement {
        sequence(0x00081115, [.init(elements: [text(0x0020000E, seriesUID, .UI), referencedImages(uid: imageUID)])])
    }

    private func referencedImages(uid: String, sopClass: String = "1.2.840.10008.5.1.4.1.1.2", frames: [Int] = []) -> DicomDataElement {
        var item = [text(0x00081150, sopClass, .UI), text(0x00081155, uid, .UI)]
        if !frames.isEmpty { item.append(text(0x00081160, frames.map(String.init).joined(separator: "\\"), .IS)) }
        return sequence(0x00081140, [.init(elements: item)])
    }

    private func graphicObject() -> DicomDataSet {
        .init(elements: [text(0x00700005, "PIXEL", .CS), number(0x00700020, 2), number(0x00700021, 2),
                         floats(0x00700022, [0, 0, 1, 1]), text(0x00700023, "POLYLINE", .CS)])
    }

    private func displayedArea() -> DicomDataSet {
        .init(elements: [signed(0x00700052, [1, 1]), signed(0x00700053, [2, 2]), text(0x00700100, "SCALE TO FIT", .CS),
                         text(0x00700102, "1\\1", .IS)])
    }

    private func softcopyVOI() -> DicomDataElement {
        sequence(0x00283110, [.init(elements: [text(0x00281050, "40", .DS), text(0x00281051, "400", .DS)])])
    }

    private func modalityLUTSequence() -> DicomDataElement {
        sequence(0x00283000, [.init(elements: [.init(tag: 0x00283002, vr: .US, value: .unsignedIntegers([2, 0, 16])),
            text(0x00283004, "HU", .LO), .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 0, 255, 255])))])])
    }

    private func blendingItem(_ position: String) -> DicomDataSet {
        .init(elements: [text(0x00700405, position, .CS), text(0x0020000D, "2.25.23269996", .UI), relationship(),
                         text(0x00281052, "0", .DS), text(0x00281053, "1", .DS), text(0x00281054, "US", .LO), softcopyVOI()])
    }

    private func palette() -> [DicomDataElement] {
        [0x00281101, 0x00281102, 0x00281103].map { DicomDataElement(tag: $0, vr: .US, value: .unsignedIntegers([2, 0, 16])) }
            + [0x00281201, 0x00281202, 0x00281203].map { DicomDataElement(tag: $0, vr: .OW, value: .bytes(Data([0, 0, 255, 255]))) }
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

    private func displayShutter(_ dataSet: DicomDataSet) -> DicomDataSet {
        dataSet.setting(text(0x00181600, "RECTANGULAR", .CS)).setting(text(0x00181602, "0", .IS)).setting(text(0x00181604, "2", .IS))
            .setting(text(0x00181606, "0", .IS)).setting(text(0x00181608, "2", .IS)).setting(number(0x00181622, 0))
    }

    /// A 2×2 overlay in group 6000 activated in the MEASUREMENTS layer, optionally used as a bitmap shutter.
    private func overlay(_ dataSet: DicomDataSet, activation: Bool = true) -> DicomDataSet {
        var result = dataSet.setting(number(0x60000010, 2)).setting(number(0x60000011, 2)).setting(text(0x60000040, "G", .CS))
            .setting(.init(tag: 0x60000050, vr: .SS, value: .signedIntegers([1, 1]))).setting(number(0x60000100, 1)).setting(number(0x60000102, 0))
            .setting(.init(tag: 0x60003000, vr: .OW, value: .bytes(Data([0x0F, 0x00]))))
        if activation { result = result.setting(text(0x60001001, "MEASUREMENTS", .CS)) }
        return result
    }

    private func bitmapShutter(_ dataSet: DicomDataSet, overlay: Bool = true) -> DicomDataSet {
        let result = overlay ? self.overlay(dataSet) : dataSet
        return result.setting(text(0x00181600, "BITMAP", .CS)).setting(number(0x00181623, 0x6000)).setting(number(0x00181622, 0))
    }

    private func textObject(_ dataSet: DicomDataSet, anchor: Bool) -> DicomDataSet {
        var item = [text(0x00700006, "Corpus", .ST)]
        if anchor { item += [text(0x00700004, "DISPLAY", .CS), floats(0x00700014, [0.5, 0.5]), text(0x00700015, "Y", .CS)] }
        return replacingAnnotation(dataSet) { $0.setting(sequence(0x00700008, [.init(elements: item)])) }
    }

    private func mask(_ dataSet: DicomDataSet, averaging: Bool) -> DicomDataSet {
        var item = [text(0x00286101, "AVG_SUB", .CS), .init(tag: 0x00286110, vr: .US, value: .unsignedIntegers([1, 2]))]
        if averaging { item.append(number(0x00286112, 2)) }
        return dataSet.setting(sequence(0x00286100, [.init(elements: item)])).setting(text(0x00281090, "SUB", .CS))
    }

    private func referencingFrame(_ dataSet: DicomDataSet, _ frame: Int) -> DicomDataSet {
        dataSet.setting(sequence(0x00081115, [.init(elements: [text(0x0020000E, seriesUID, .UI), referencedImages(uid: imageUID, frames: [frame])])]))
    }

    private func referencingClass(_ dataSet: DicomDataSet, _ sopClass: String) -> DicomDataSet {
        dataSet.setting(sequence(0x00081115, [.init(elements: [text(0x0020000E, seriesUID, .UI), referencedImages(uid: imageUID, sopClass: sopClass)])]))
    }

    private func replacingAnnotation(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var items = (dataSet[0x00700001]?.sequenceItems ?? []).map(\.dataSet)
        items[0] = transform(items[0])
        return dataSet.setting(sequence(0x00700001, items))
    }

    private func replacingGraphic(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        replacingAnnotation(dataSet) { annotation in
            var objects = (annotation[0x00700009]?.sequenceItems ?? []).map(\.dataSet)
            objects[0] = transform(objects[0])
            return annotation.setting(sequence(0x00700009, objects))
        }
    }

    private func replacingDisplayedArea(_ dataSet: DicomDataSet, _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var items = (dataSet[0x0070005A]?.sequenceItems ?? []).map(\.dataSet)
        items[0] = transform(items[0])
        return dataSet.setting(sequence(0x0070005A, items))
    }

    private func signed(_ tag: Int, _ values: [Int]) -> DicomDataElement { .init(tag: tag, vr: .SL, value: .signedIntegers(values)) }
    private func floats(_ tag: Int, _ values: [Double]) -> DicomDataElement { .init(tag: tag, vr: .FL, value: .floats(values)) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
