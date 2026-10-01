import Foundation
import XCTest
@testable import DicomCore

final class DicomSRDocumentModuleCorpusTests: XCTestCase {
    func test_targetConditionCorpus_composesWireTargetFactsWithExplicitSubsetIntent() throws {
        func group(_ count: UInt) -> DicomDataSet {
            .init(elements: [.init(tag: 0x003A0005, vr: .US, value: .unsignedIntegers([count])),
                             sequence(0x003A0200, Array(repeating: .init(), count: Int(count)))])
        }
        let cases: [(String, [DicomDataElement], DicomAttributeRule.Truth)] = [
            ("dose-absent", [], .undetermined), ("dose-one", [text(0x00280008, "1", .IS)], .satisfied),
            ("dose-three", [text(0x00280008, "3", .IS)], .satisfied), ("dose-zero", [text(0x00280008, "0", .IS)], .undetermined),
            ("wave-absent", [], .undetermined), ("wave-empty", [sequence(0x54000100, [])], .undetermined),
            ("wave-one", [sequence(0x54000100, [group(1)])], .unsatisfied),
            ("wave-two", [sequence(0x54000100, [group(2)])], .satisfied),
            ("wave-two-groups", [sequence(0x54000100, [group(1), group(1)])], .satisfied),
            ("wave-zero", [sequence(0x54000100, [group(0)])], .undetermined),
            ("wave-missing-count", [sequence(0x54000100, [group(1).removing(0x003A0005)])], .undetermined),
            ("wave-missing-definitions", [sequence(0x54000100, [group(1).removing(0x003A0200)])], .undetermined),
            ("wave-conflicting-count", [sequence(0x54000100, [group(2).setting(sequence(0x003A0200, [.init()]))])], .undetermined)
        ]
        let base = try fixture(suffix: "33")
        let original = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let originalPair = try XCTUnwrap(original.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        for (name, geometry, expected) in cases {
            let wave = name.hasPrefix("wave-")
            let uid = "1.2.840.10008.5.1.4.1.1." + (wave ? "9.1.1" : "481.2")
            let pair = originalPair.setting(text(0x00081150, uid, .UI))
            let child = original.setting(text(0x0040A040, wave ? "WAVEFORM" : "IMAGE", .CS)).setting(sequence(0x00081199, [pair]))
            let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [pair])])
            let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
            let source = base.setting(sequence(0x0040A730, [child])).setting(sequence(0x0040A375, [study]))
            var target = target().setting(text(0x00080016, uid, .UI))
            for element in geometry { target = target.setting(element) }
            let sourceRead = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
            let targetRead = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: target, purpose: .instance))
            XCTAssertEqual(sourceRead.report.merging(targetRead.report).outcome(requiring: [.structure, .vrAndVM]), .passed)
            let parsed = try XCTUnwrap(sourceRead.dataSet)
            let references = DicomSRReferenceValidator.validate(parsed, kind: .structuredReport,
                targets: ["2.25.23212003": try XCTUnwrap(targetRead.dataSet)])
            let derived = try XCTUnwrap(references.contentReferenceConditions[[0]])
            XCTAssertEqual(wave ? derived.waveformHasMultipleChannels : derived.isMultiframeImage, expected, name)
            var author = derived
            author.appliesToAllFrames = .unsatisfied
            author.appliesToAllSegments = .unsatisfied
            author.appliesToAllWaveformChannels = .unsatisfied
            let macro = DicomContentReferenceMacro.validate(try XCTUnwrap(parsed.sequenceItems(for: .contentSequence).first?.dataSet),
                kind: wave ? .waveform : .image, conditions: author)
            XCTAssertEqual(macro[.attributes], expected == .undetermined ? .incomplete : expected == .satisfied ? .failed : .passed, name)
            let content = DicomSRContentValidator.validate(parsed, referenceConditions: [[0]: author])
            XCTAssertEqual(content[.attributes], expected == .satisfied ? .failed : .incomplete, name)
            XCTAssertFalse(content.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path.isEmpty })
            XCTAssertEqual(references.report[.references], .passed)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_TARGET_CONDITION_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                for (dataSet, suffix) in [(source, "dcm"), (target, "target.dcm")] {
                    try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                        .write(to: path.appendingPathExtension(suffix))
                }
                try JSONSerialization.data(withJSONObject: ["contentFacts": conditionWitness(derived),
                    "authorIntent": "subset", "attributes": macro[.attributes].rawValue,
                    "contentAttributes": content[.attributes].rawValue, "structureAndVRVM": "passed"])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_sopApplicabilityCorpus_checksEveryCataloguedClassInEachContentRole() throws {
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let original = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        let prefix = "1.2.840.10008.5.1.4.1.1."
        let unknown = [prefix + "2.999", "2.25.23219999"]
        let catalogue = DicomSOPReferenceTraits.entries
        XCTAssertEqual(catalogue.count, 171)
        var cases: [(String, String, Int?, DicomValidationReport.Outcome)] = []
        for uid in catalogue.keys.sorted() + unknown {
            for kind in [DicomContentReferenceMacro.Kind.image, .waveform, .composite] {
                cases.append((kind.rawValue, uid, nil, catalogue[uid].map { $0.kind == kind ? .passed : .failed } ?? .incomplete))
            }
        }
        for suffix in ["11.1", "11.2", "11.3", "11.4", "11.5", "11.8", "11.12", "2", "67",
                       "11.6", "11.7", "11.9", "11.10", "11.11", "9.100.1", "9.100.2"] {
            let uid = prefix + suffix
            cases.append(("IMAGE", uid, 0x00081199, catalogue[uid]?.isSoftcopyPresentationState == true ? .passed : .failed))
        }
        cases += [("IMAGE", prefix + "67", 0x0008114B, .passed), ("IMAGE", prefix + "11.1", 0x0008114B, .failed),
                  ("IMAGE", unknown[0], 0x00081199, .incomplete), ("IMAGE", unknown[1], 0x0008114B, .incomplete)]
        let directory = ProcessInfo.processInfo.environment["DICOM_SR_SOP_CORPUS_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let traits = catalogue.mapValues { ["kind": $0.kind.rawValue, "softcopy": $0.isSoftcopyPresentationState,
                                               "realWorldMap": $0.isRealWorldValueMapping, "multiframe": String(describing: $0.isMultiframeImage),
                                               "segmentation": $0.isSegmentation] as [String: Any] }
            try JSONSerialization.data(withJSONObject: traits, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("catalogue.json"))
        }
        for (index, entry) in cases.enumerated() {
            let (kind, uid, auxiliary, expected) = entry
            let candidate = original.setting(text(0x00081150, uid, .UI))
                .setting(text(0x00081155, auxiliary == nil ? "2.25.23212003" : "2.25.23217007", .UI))
            let pair = auxiliary.map { original.setting(sequence($0, [candidate])) } ?? candidate
            let selected = image.setting(text(0x0040A040, kind, .CS)).setting(sequence(0x00081199, [pair]))
            let evidence = auxiliary == nil ? [candidate] : [original, candidate]
            let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, evidence)])
            let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
            let source = base.setting(sequence(0x0040A730, [selected])).setting(sequence(0x0040A375, [study]))
            var targets = ["2.25.23212003": target().setting(text(0x00080016, auxiliary == nil ? uid : prefix + "2.1", .UI))]
            if auxiliary != nil { targets["2.25.23217007"] = target().setting(text(0x00080016, uid, .UI))
                .setting(text(0x00080018, "2.25.23217007", .UI)) }
            let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            let references = DicomSRReferenceValidator.validate(try XCTUnwrap(read.dataSet), kind: .structuredReport, targets: targets)
            let report = references.report
            XCTAssertEqual(report[.references], expected, "\(kind) \(uid) \(String(describing: auxiliary))")
            XCTAssertEqual(report.diagnostics.map(\.code), expected == .passed ? [] :
                [expected == .failed ? .referenceSOPClassNotAllowed : .referenceRuleUnavailable])
            if let directory {
                let stem = directory.appendingPathComponent("sop-\(index)")
                try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                    .write(to: stem.appendingPathExtension("dcm"))
                for (key, target) in targets {
                    let suffix = key == "2.25.23212003" ? "target" : "companion"
                    try DicomDataSetWriter.part10Data(from: target, options: .init(validationPurpose: .instance))
                        .write(to: stem.appendingPathExtension(suffix + ".dcm"))
                }
                try JSONSerialization.data(withJSONObject: ["references": report[.references].rawValue,
                    "diagnostics": report.diagnostics.map { $0.code.rawValue }, "structureAndVRVM": "passed",
                    "contentFacts": conditionWitness(references.contentReferenceConditions[[0]])])
                    .write(to: stem.appendingPathExtension("json"))
            }
        }
        XCTAssertEqual(cases.count, 539)
    }

    func test_iconCorpus_comparesNativeValuesWithMetadataOmissionAndReferencePaths() throws {
        func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
        func binary(_ tag: Int, _ values: [UInt8], vr: DicomVR = .OB) -> DicomDataElement { .init(tag: tag, vr: vr, value: .bytes(Data(values))) }
        let mono = DicomDataSet(elements: [number(0x00280002, 1), text(0x00280004, "MONOCHROME2", .CS),
            number(0x00280010, 2), number(0x00280011, 2), number(0x00280100, 8), number(0x00280101, 8),
            number(0x00280102, 7), number(0x00280103, 0), binary(0x7FE00010, [0, 17, 129, 255])])
        let bit = mono.setting(number(0x00280010, 1)).setting(number(0x00280011, 9))
            .setting(number(0x00280100, 1)).setting(number(0x00280101, 1)).setting(number(0x00280102, 0))
            .setting(binary(0x7FE00010, [0x55, 0x01]))
        var palette = mono.setting(text(0x00280004, "PALETTE COLOR", .CS)).setting(binary(0x7FE00010, [0, 1, 1, 0]))
        for channel in 1...3 {
            palette = palette.setting(.init(tag: 0x00281100 + channel, vr: .US, value: .unsignedIntegers([2, 0, 8])))
                .setting(binary(0x00281200 + channel, [0, 255], vr: .OW))
        }
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("mono8-valid", mono, .passed), ("mono1-valid", bit, .passed),
            ("mono8-odd-valid", mono.setting(number(0x00280010, 1)).setting(number(0x00280011, 3))
                .setting(binary(0x7FE00010, [7, 19, 201, 0])), .passed),
            ("palette-valid", palette, .passed),
            ("rows-oversize", mono.setting(number(0x00280010, 129)), .failed),
            ("columns-zero", mono.setting(number(0x00280011, 0)), .failed),
            ("rgb-prohibited", mono.setting(text(0x00280004, "RGB", .CS)), .failed),
            ("signed-prohibited", mono.setting(number(0x00280103, 1)), .failed),
            ("bits-prohibited", mono.setting(number(0x00280100, 16)), .failed),
            ("stored-exceeds", bit.setting(number(0x00280101, 8)).setting(number(0x00280102, 7)), .failed),
            ("highbit-wrong", mono.setting(number(0x00280102, 6)), .failed),
            ("planar-prohibited", mono.setting(number(0x00280006, 0)), .failed),
            ("aspect-prohibited", mono.setting(.init(tag: 0x00280034, vr: .IS, value: .strings(["1", "1"]))), .failed),
            ("pixels-missing", mono.removing(0x7FE00010), .failed),
            ("pixels-empty", mono.setting(binary(0x7FE00010, [])), .failed),
            ("pixels-short", mono.setting(binary(0x7FE00010, [0, 17])), .failed),
            ("pixels-long", mono.setting(binary(0x7FE00010, [0, 17, 129, 255, 1, 2])), .failed),
            ("palette-data-short", palette.setting(binary(0x00281202, [], vr: .OW)), .failed),
            ("palette-descriptor-mismatch", palette.setting(.init(tag: 0x00281102, vr: .US, value: .unsignedIntegers([2, 1, 8]))), .failed),
            ("palette-depth-invalid", palette.setting(.init(tag: 0x00281101, vr: .US, value: .unsignedIntegers([2, 0, 12]))), .failed),
            ("palette-data-missing", palette.removing(0x00281202), .failed)
        ]
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let pair = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        for (name, icon, expected) in cases {
            let report = DicomSRIconImageValidator.validate(icon, pixelDataSource: .native)
            XCTAssertEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), expected, name)
            let selected = image.setting(sequence(0x00081199, [pair.setting(sequence(0x00880200, [icon]))]))
            let dataSet = base.setting(sequence(0x0040A730, [selected]))
            let bytes = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
            let read = try DicomEncodedDataSetValidator.validate(bytes)
            XCTAssertEqual(read.report[.structure], .passed, name)
            let parsed = try XCTUnwrap(read.dataSet?.sequenceItems(for: .contentSequence).first?.dataSet
                .sequenceItems(for: .referencedSOPSequence).first?.dataSet.sequenceItems(for: .iconImageSequence).first?.dataSet)
            XCTAssertNil(parsed.element(for: .pixelData))
            let omitted = DicomSRIconImageValidator.validate(parsed, pixelDataSource: .omitted)
            XCTAssertFalse(omitted.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x7FE00010) })
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_ICON_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["icon": expected.rawValue, "structure": "passed",
                    "metadataPixelData": "omitted", "nativePixels": report[.pixelsAndGeometry].rawValue])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_referenceMacroCorpus_checksExternalConditionsAndAccompanyingPairs() throws {
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let pair = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        let cases = ["image-all", "image-subset-missing", "image-subset-selected", "image-all-selected", "image-unknown",
            "segment-subset-missing", "segment-subset-selected", "segment-both", "wave-all", "wave-subset-missing",
            "wave-subset-selected", "wave-all-selected", "wave-unknown",
            "ps-valid", "ps-missing-uid", "ps-empty", "ps-multiple", "rwvm-valid", "rwvm-missing-uid", "rwvm-empty", "rwvm-multiple"]
        let positive: Set<String> = ["image-all", "image-subset-selected", "segment-subset-selected", "wave-all",
            "wave-subset-selected", "ps-valid", "rwvm-valid"]
        for name in cases {
            let isWave = name.hasPrefix("wave-"), isSegment = name.hasPrefix("segment-")
            var facts = DicomContentReferenceMacro.Conditions()
            if !name.hasSuffix("unknown") {
                facts.isMultiframeImage = isWave ? .unsatisfied : .satisfied
                facts.isSegmentation = isSegment ? .satisfied : .unsatisfied
                facts.waveformHasMultipleChannels = isWave ? .satisfied : .unsatisfied
                facts.appliesToAllFrames = name.contains("subset") || name == "segment-both" ? .unsatisfied : .satisfied
                facts.appliesToAllSegments = facts.appliesToAllFrames
                facts.appliesToAllWaveformChannels = facts.appliesToAllFrames
            }
            var reference = pair.setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1." +
                (isWave ? "9.1.1" : isSegment ? "66.4" : "2.1"), .UI))
            var evidence = [reference]
            if name.hasSuffix("selected") || name == "segment-both" {
                let selector: DicomDataElement = isWave ? .init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers([1, 0])) :
                    isSegment ? .init(tag: 0x0062000B, vr: .US, value: .unsignedIntegers([7])) : text(0x00081160, "3", .IS)
                reference = reference.setting(selector)
            }
            if name == "segment-both" { reference = reference.setting(text(0x00081160, "3", .IS)) }
            if name.hasPrefix("ps-") || name.hasPrefix("rwvm-") {
                let auxiliary = pair.setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1." +
                    (name.hasPrefix("ps-") ? "11.1" : "67"), .UI)).setting(text(0x00081155, "2.25.23215007", .UI))
                evidence.append(auxiliary)
                let items: [DicomDataSet] = name.hasSuffix("empty") ? [] : name.hasSuffix("multiple") ? [auxiliary, auxiliary] :
                    [name.hasSuffix("missing-uid") ? auxiliary.removing(0x00081155) : auxiliary]
                reference = reference.setting(sequence(name.hasPrefix("ps-") ? 0x00081199 : 0x0008114B, items))
            }
            let child = image.setting(text(0x0040A040, isWave ? "WAVEFORM" : "IMAGE", .CS))
                .setting(sequence(0x00081199, [reference]))
            let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, evidence)])
            let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
            let dataSet = base.setting(sequence(0x0040A730, [child])).setting(sequence(0x0040A375, [study]))
            let bytes = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
            let read = try DicomEncodedDataSetValidator.validate(bytes, transferSyntax: .explicitVRLittleEndian)
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            let owned = try XCTUnwrap(read.dataSet?.sequenceItems(for: .contentSequence).first?.dataSet)
            let report = DicomContentReferenceMacro.validate(owned, kind: isWave ? .waveform : .image, conditions: facts)
            // An absent selector denotes the whole object, so unstated facts leave nothing required.
            let expected: DicomValidationReport.Outcome = name.hasSuffix("unknown") ? .passed : positive.contains(name) ? .passed : .failed
            XCTAssertEqual(report[.attributes], expected, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_REFERENCE_MACRO_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": expected.rawValue, "structureAndVRVM": "passed",
                    "conditionEvidence": name.hasSuffix("unknown") ? "unknown" :
                        name.contains("subset") || name == "segment-both" ? "multiple-subset" : "multiple-all"])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_selectionCorpus_comparesParsedReferencesWithOwnedTargetMetadata() throws {
        func unsigned(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
        func segment(_ value: UInt) -> DicomDataSet { .init(elements: [unsigned(0x00620004, [value])]) }
        func group(_ count: Int) -> DicomDataSet {
            .init(elements: [unsigned(0x003A0005, [UInt(count)]), sequence(0x003A0200, Array(repeating: .init(), count: count))])
        }
        let frames = target().setting(text(0x00280008, "3", .IS))
        let segments = target().setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.66.4", .UI))
            .setting(sequence(0x00620002, [segment(7), segment(42)]))
        let waveform = target().setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.9.1.1", .UI))
            .setting(sequence(0x54000100, [group(2), group(3)]))
        let cases: [(String, DicomDataElement, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("frame-valid", text(0x00081160, "3", .IS), frames, .passed),
            ("frame-outside", text(0x00081160, "4", .IS), frames, .failed),
            ("frame-zero", text(0x00081160, "0", .IS), frames, .failed),
            ("frame-unknown", text(0x00081160, "1", .IS), target(), .incomplete),
            ("frame-wrong-identity", text(0x00081160, "4", .IS), frames.setting(text(0x00080018, "2.25.999", .UI)), .failed),
            ("segment-valid", unsigned(0x0062000B, [42]), segments, .passed),
            ("segment-missing", unsigned(0x0062000B, [1]), segments, .failed),
            ("segment-unknown", unsigned(0x0062000B, [42]), segments.setting(sequence(0x00620002, [segment(7), .init()])), .incomplete),
            ("segment-duplicate", unsigned(0x0062000B, [7]), segments.setting(sequence(0x00620002, [segment(7), segment(7)])), .failed),
            ("wave-valid", unsigned(0x0040A0B0, [1, 0, 2, 2]), waveform, .passed),
            ("wave-group-outside", unsigned(0x0040A0B0, [3, 1]), waveform, .failed),
            ("wave-channel-outside", unsigned(0x0040A0B0, [1, 3]), waveform, .failed),
            ("wave-unknown", unsigned(0x0040A0B0, [1, 1]), waveform.setting(sequence(0x54000100, [group(2).removing(0x003A0200)])), .incomplete),
            ("wave-count-conflict", unsigned(0x0040A0B0, [1, 1]), waveform.setting(sequence(0x54000100, [group(2).setting(unsigned(0x003A0005, [3]))])), .failed)
        ]
        for (name, selector, metadata, expected) in cases {
            let sopClass = try XCTUnwrap(metadata.string(for: .sopClassUID))
            let pair = DicomDataSet(elements: [text(0x00081150, sopClass, .UI), text(0x00081155, "2.25.23212003", .UI)])
            let base = try fixture(suffix: "33")
            let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
                .setting(text(0x0040A040, name.hasPrefix("wave-") ? "WAVEFORM" : "IMAGE", .CS))
                .setting(sequence(0x00081199, [pair.setting(selector)]))
            let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [pair])])
            let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
            let dataSet = base.setting(sequence(0x0040A730, [image])).setting(sequence(0x0040A375, [study]))
            let sourceBytes = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
            let targetBytes = try DicomDataSetWriter.dataSetData(from: metadata, purpose: .instance)
            let source = try DicomEncodedDataSetValidator.validate(sourceBytes, transferSyntax: .explicitVRLittleEndian)
            let targetRead = try DicomEncodedDataSetValidator.validate(targetBytes, transferSyntax: .explicitVRLittleEndian)
            XCTAssertEqual(source.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            XCTAssertEqual(targetRead.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            let references = DicomSRReferenceValidator.validate(try XCTUnwrap(source.dataSet), kind: .structuredReport,
                targets: ["2.25.23212003": try XCTUnwrap(targetRead.dataSet)])
            XCTAssertEqual(references.report[.references], expected, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_SELECTION_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                for (suffix, value) in [("source.dcm", dataSet), ("target.dcm", metadata)] {
                    try DicomDataSetWriter.part10Data(from: value, options: .init(validationPurpose: .instance))
                        .write(to: path.appendingPathExtension(suffix))
                }
                try JSONSerialization.data(withJSONObject: ["references": references.report[.references].rawValue,
                    "sourceAndTargetWire": "passed", "targetScope": "identity and selection metadata only"])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_relationshipCorpus_composesOriginalPathsAndProfileConstraints() throws {
        let concept = DicomDataSet(elements: [text(0x00080100, "SYNTHETIC", .SH), text(0x00080102, "99LOCAL", .SH),
            text(0x00080104, "Synthetic text", .LO)])
        let value = DicomDataSet(elements: [text(0x0040A040, "TEXT", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [concept]), text(0x0040A160, "SYNTHETIC", .UT)])
        func reference(_ values: [UInt], _ relation: String = "INFERRED FROM") -> DicomDataSet {
            .init(elements: [text(0x0040A010, relation, .CS), .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers(values))])
        }
        func branch(_ child: DicomDataSet) -> DicomDataSet { value.setting(sequence(0x0040A730, [child])) }
        var cases: [(String, String, [DicomDataSet], DicomValidationReport.Outcome)] = []
        for suffix in ["22", "33", "59"] {
            cases += [(suffix + "-baseline", suffix, [value], .passed),
                      (suffix + "-forward", suffix, [branch(reference([1, 2])), value], suffix == "33" ? .passed : .failed)]
        }
        let observation = value.setting(text(0x0040A010, "HAS OBS CONTEXT", .CS))
        let container = value.removing(0x0040A160).setting(text(0x0040A040, "CONTAINER", .CS))
            .setting(text(0x0040A050, "SEPARATE", .CS)).setting(sequence(0x0040A730, [reference([1, 2], "CONTAINS")]))
        cases += [
            ("33-backward", "33", [value, branch(reference([1, 1]))], .passed),
            ("33-missing", "33", [branch(reference([1, 99])), value], .failed),
            ("33-invalid-root", "33", [branch(reference([2])), value], .failed),
            ("33-ancestor", "33", [branch(reference([1]))], .failed),
            ("33-reference-target", "33", [branch(reference([1, 2, 1])), branch(reference([1, 1]))], .failed),
            ("33-reference-contains", "33", [container, value], .failed),
            ("33-invalid-pair", "33", [branch(value.setting(text(0x0040A010, "SELECTED FROM", .CS)))], .failed),
            ("22-observation", "22", [branch(observation)], .failed),
            ("33-observation", "33", [branch(observation)], .passed)
        ]
        for (name, suffix, children, expected) in cases {
            // Keep KOS evidence valid by retaining its original IMAGE as the final content item.
            let base = try fixture(suffix: suffix)
            let originalImage = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
            let dataSet = base.setting(sequence(0x0040A730, children + [originalImage]))
            let bytes = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
            let read = try DicomEncodedDataSetValidator.validate(bytes, transferSyntax: .explicitVRLittleEndian)
            let owned = try XCTUnwrap(read.dataSet)
            let relationships = DicomSRRelationshipValidator.validate(owned)
            let objects = DicomSRReferenceValidator.validate(owned, kind: suffix == "59" ? .keyObjectSelection : .structuredReport,
                targets: ["2.25.23212003": target()])
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            XCTAssertEqual(relationships[.references], expected, name)
            XCTAssertEqual(objects.report[.references], .passed)
            XCTAssertEqual(objects.report.merging(relationships)[.references], expected, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_RELATIONSHIP_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["relationships": relationships[.references].rawValue,
                    "objects": objects.report[.references].rawValue, "structureAndVRVM": "passed"])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_numericMacroCorpus_checksWireAndConditionalRequirements() throws {
        let units = DicomDataSet(elements: [text(0x00080100, "mm", .SH), text(0x00080102, "UCUM", .SH),
            text(0x00080104, "millimeter", .LO)])
        let concept = DicomDataSet(elements: [text(0x00080100, "SYNTHETIC", .SH), text(0x00080102, "99LOCAL", .SH),
            text(0x00080104, "Synthetic measurement", .LO)])
        let qualifier = DicomDataSet(elements: [text(0x00080100, "114007", .SH), text(0x00080102, "DCM", .SH),
            text(0x00080104, "Measurement not attempted", .LO)])
        let value = DicomDataSet(elements: [text(0x0040A30A, "42", .DS), sequence(0x004008EA, [units])])
        let number = DicomDataSet(elements: [text(0x0040A040, "NUM", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [concept]), sequence(0x0040A300, [value])])
        let empty = number.setting(sequence(0x0040A300, []))
        let rational = value.setting(.init(tag: 0x0040A162, vr: .SL, value: .signedIntegers([84])))
            .setting(.init(tag: 0x0040A163, vr: .UL, value: .unsignedIntegers([2])))
        let cases: [(String, DicomDataSet, Bool, DicomValidationReport.Outcome)] = [
            ("baseline", number, false, .passed),
            ("missing-measured", number.removing(0x0040A300), false, .failed),
            ("empty-unqualified", empty, false, .failed),
            ("empty-qualified", empty.setting(sequence(0x0040A301, [qualifier])), false, .passed),
            ("qualifier-with-value", number.setting(sequence(0x0040A301, [qualifier])), false, .failed),
            ("multiple-values", number.setting(sequence(0x0040A300, [value.setting(
                .init(tag: 0x0040A30A, vr: .DS, value: .strings(["1", "2"])))])), false, .failed),
            ("rational-valid", number.setting(sequence(0x0040A300, [rational])), false, .passed),
            ("rational-zero", number.setting(sequence(0x0040A300, [rational.setting(
                .init(tag: 0x0040A163, vr: .UL, value: .unsignedIntegers([0])))])), false, .failed),
            ("rational-missing-denominator", number.setting(sequence(0x0040A300, [rational.removing(0x0040A163)])), false, .failed),
            ("rational-orphan-denominator", number.setting(sequence(0x0040A300, [rational.removing(0x0040A162)])), false, .failed),
            ("float-required-missing", number, true, .failed),
            ("float-required-present", number.setting(sequence(0x0040A300, [value.setting(
                .init(tag: 0x0040A161, vr: .FD, value: .floats([42.000000000000014])))])), true, .passed)
        ]
        for (name, item, needsFloat, expected) in cases {
            let dataSet = try fixture(suffix: "22").removing(0x0040A375).setting(sequence(0x0040A730, [item]))
            let bytes = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
            let decoded = try DicomEncodedDataSetValidator.validate(bytes, transferSyntax: .explicitVRLittleEndian)
            XCTAssertEqual(decoded.report.outcome(requiring: [.structure, .vrAndVM]), .passed)
            let owned = try XCTUnwrap(decoded.dataSet)
            let numeric = try XCTUnwrap(owned.sequenceItems(for: .contentSequence).first?.dataSet)
            let floating: DicomAttributeRule.Truth = needsFloat ? .satisfied : .unsatisfied
            let rules = DicomNumericMeasurementMacro.rules(for: numeric, floatingPointRequired: floating,
                rationalRepresentationRequired: .unsatisfied, versionRequirements: ["UCUM": .unsatisfied, "DCM": .unsatisfied])
            let contract = DicomAttributeValidator.validate(numeric, rules: rules)
            XCTAssertEqual(contract[.attributes], expected, name)
            let content = DicomSRContentValidator.validate(owned, numericPrecisionRequirements: [
                [0]: .init(floatingPoint: floating, rational: .unsatisfied)
            ])
            XCTAssertEqual(content[.attributes], expected == .failed ? .failed : .incomplete, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_NUMERIC_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["numericAttributes": contract[.attributes].rawValue,
                    "combinedAttributes": content[.attributes].rawValue, "floatingPointRequired": needsFloat])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_documentModuleCorpus_composesWireAndAttributeEvidence() throws {
        for suffix in ["22", "33", "59"] {
            let isKO = suffix == "59"
            let kind: DicomSRDocumentModule.Kind = isKO ? .keyObjectSelection : .structuredReport
            let baseline = try fixture(suffix: suffix)
            var cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
                ("baseline", baseline, .passed),
                ("missing-date", baseline.removing(0x00080023), .failed),
                ("missing-evidence", baseline.removing(0x0040A375), .failed)
            ]
            if !isKO {
                let verified = baseline.setting(text(0x0040A493, "VERIFIED", .CS))
                let observer = DicomDataSet(elements: [text(0x0040A075, "SYNTHETIC^VERIFIER", .PN),
                    text(0x0040A027, "TEST", .LO), text(0x0040A030, "20260908120000", .DT), sequence(0x0040A088, [])])
                let complete = verified.setting(sequence(0x0040A073, [observer]))
                cases += [("verified-no-observer", verified, .failed), ("verified-complete", complete, .passed),
                          ("verified-partial", complete.setting(text(0x0040A491, "PARTIAL", .CS)), .failed)]
            }
            for (name, dataSet, expected) in cases {
                let wire = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
                let read = try DicomEncodedDataSetValidator.validate(wire, transferSyntax: .explicitVRLittleEndian)
                let owned = try XCTUnwrap(read.dataSet)
                let references = DicomSRReferenceValidator.validate(owned, kind: kind, targets: ["2.25.23212003": target()])
                let module = DicomSRDocumentModule.validate(owned, kind: kind,
                    conditions: conditions(references.documentConditions, isKO: isKO))
                let content = DicomSRContentValidator.validate(owned)
                let relationships = DicomSRRelationshipValidator.validate(owned)
                let report = read.report.merging(references.report).merging(module).merging(content).merging(relationships)
                XCTAssertEqual(report.outcome(requiring: [.structure, .vrAndVM]), .passed)
                XCTAssertEqual(module[.attributes], expected, "\(suffix)-\(name)")
                XCTAssertEqual(content[.attributes], .incomplete)
                XCTAssertEqual(report[.attributes], expected == .failed ? .failed : .incomplete)
                XCTAssertEqual(report[.operation], .passed)
                let expectedReferences: DicomValidationReport.Outcome = name == "missing-evidence" ? .failed : .passed
                XCTAssertEqual(report[.references], expectedReferences)
                XCTAssertEqual(relationships[.references], .passed)
                let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                if let directory = ProcessInfo.processInfo.environment["DICOM_SR_MODULE_CORPUS_DIRECTORY"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let path = folder.appendingPathComponent("sr-\(suffix)-\(name)")
                    try bytes.write(to: path.appendingPathExtension("dcm"))
                    try JSONSerialization.data(withJSONObject: ["expectedAttributes": expected.rawValue,
                        "actualAttributes": module[.attributes].rawValue, "structureAndVRVM": "passed",
                        "actualReferences": report[.references].rawValue, "contentAttributes": content[.attributes].rawValue,
                        "relationshipReferences": relationships[.references].rawValue,
                        "combinedAttributes": report[.attributes].rawValue, "semanticOperation": report[.operation].rawValue])
                        .write(to: path.appendingPathExtension("json"))
                }
            }
        }
    }

    private func conditionWitness(_ facts: DicomContentReferenceMacro.Conditions?) -> [String: String] {
        guard let facts else { return [:] }
        return ["multiframe": String(describing: facts.isMultiframeImage), "segmentation": String(describing: facts.isSegmentation),
                "multipleChannels": String(describing: facts.waveformHasMultipleChannels), "allFrames": String(describing: facts.appliesToAllFrames),
                "allSegments": String(describing: facts.appliesToAllSegments), "allChannels": String(describing: facts.appliesToAllWaveformChannels)]
    }

    private func conditions(_ graph: DicomSRDocumentModule.Conditions, isKO: Bool) -> DicomSRDocumentModule.Conditions {
        var result = graph
        result.includesOtherDocumentContent = .unsatisfied
        if !isKO { result.identicalDocumentsRequired = .unsatisfied }
        result.requestedProcedureApplies = .unsatisfied
        result.pertinentOtherEvidenceRequired = .unsatisfied
        result.equivalentCDAKnown = .unsatisfied
        return result
    }

    func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2.1", .UI), text(0x00080018, "2.25.23212003", .UI),
            text(0x0020000D, "2.25.23212001", .UI), text(0x0020000E, "2.25.23212002", .UI)])
    }

    func fixture(suffix: String) throws -> DicomDataSet {
        let isKO = suffix == "59"
        let title = DicomCodedConcept(codeValue: isKO ? "113000" : "126000", codingSchemeDesignator: "DCM",
                                     codeMeaning: isKO ? "Of Interest" : "Imaging Measurement Report")
        let image = DicomKeyObjectReference(studyInstanceUID: "2.25.23212001", seriesInstanceUID: "2.25.23212002",
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1", referencedSOPInstanceUID: "2.25.23212003")
        let document = DicomSRDocument(sopClassUID: "1.2.840.10008.5.1.4.1.1.88." + suffix, modality: isKO ? "KO" : "SR",
            completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", templateIdentifier: isKO ? nil : "1500",
            root: .init(valueType: "CONTAINER", conceptName: title, continuityOfContent: "SEPARATE", children: [
                .init(relationshipType: "CONTAINS", valueType: "IMAGE", conceptName: title,
                      referencedSOPs: [image.sourceImageReference])
            ]), evidenceReferences: [image])
        var result = try DicomStructuredReportBuilder.validatedDataSet(from: document,
            studyInstanceUID: "2.25.23212001", seriesInstanceUID: "2.25.23212004", sopInstanceUID: "2.25.23212005")
        let common: [DicomDataElement] = [
            text(0x00100010, "SYNTHETIC^CORPUS", .PN), text(0x00100020, "SYNTHETIC", .LO),
            text(0x00100030, "", .DA), text(0x00100040, "", .CS), text(0x00080070, "SYNTHETIC", .LO),
            text(0x00080020, "20260908", .DA), text(0x00080030, "120000", .TM), text(0x00080050, "", .SH),
            text(0x00080090, "", .PN), text(0x00200010, "", .SH), text(0x00200011, "1", .IS),
            text(0x00200013, "1", .IS), text(0x00080023, "20260908", .DA), text(0x00080033, "120000", .TM),
            sequence(0x00081111, [])
        ]
        for element in common { result = result.setting(element) }
        if !isKO { result = result.setting(sequence(0x0040A372, [])) }
        return result
    }

    func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
