import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_temporalCoordinateCorpus_preservesRepresentationConditionsAndCardinality() throws {
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let imagePair = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        let wavePair = imagePair.setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1.9.1.1", .UI))
            .setting(text(0x00081155, "2.25.23220007", .UI))
        let waveform = image.setting(text(0x0040A040, "WAVEFORM", .CS)).setting(text(0x0040A010, "SELECTED FROM", .CS))
            .setting(sequence(0x00081199, [wavePair.setting(.init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers([1, 1, 1, 2])))]))
        let selectedImage = image.setting(text(0x0040A010, "SELECTED FROM", .CS))
        let tags = [0x0040A132, 0x0040A138, 0x0040A13A]
        func value(_ tag: Int, _ count: Int) -> DicomDataElement {
            if tag == 0x0040A132 { return .init(tag: tag, vr: .UL, value: .unsignedIntegers((0..<count).map { UInt($0 + 1) })) }
            return .init(tag: tag, vr: tag == 0x0040A138 ? .DS : .DT,
                         value: .strings((0..<count).map { tag == 0x0040A138 ? "\($0)" : "2026090812000\($0)" }))
        }
        func coordinate(_ range: String, _ tag: Int, _ count: Int) -> DicomDataSet {
            image.removing(0x00081199).setting(text(0x0040A040, "TCOORD", .CS))
                .setting(text(0x0040A130, range, .CS)).setting(value(tag, count))
                .setting(sequence(0x0040A730, [tag == 0x0040A132 ? waveform : selectedImage]))
        }
        var known = DicomTemporalCoordinatesMacro.Conditions()
        known.referencesWaveform = .satisfied
        known.channelsUseSingleMultiplexGroup = .satisfied
        var cases: [(String, DicomDataSet, DicomTemporalCoordinatesMacro.Conditions, DicomValidationReport.Outcome)] = []
        for (range, count, wrongCount) in [("POINT", 1, 2), ("BEGIN", 1, 2), ("END", 1, 2), ("SEGMENT", 2, 1),
                                          ("MULTIPOINT", 3, 1), ("MULTISEGMENT", 4, 3)] {
            for (index, tag) in tags.enumerated() {
                let name = range.lowercased() + "-" + ["samples", "offsets", "dates"][index]
                cases.append((name, coordinate(range, tag, count), known, .passed))
                cases.append((name + "-count", coordinate(range, tag, wrongCount), known, .failed))
            }
        }
        for first in 0..<2 {
            for second in (first + 1)..<3 {
                cases.append(("choice-\(first)-\(second)", coordinate("POINT", tags[first], 1).setting(value(tags[second], 1)), known, .failed))
            }
        }
        let point = coordinate("POINT", 0x0040A138, 1)
        cases.append(("missing-range", point.removing(0x0040A130), known, .failed))
        cases.append(("unknown-range", point.setting(text(0x0040A130, "FUTURE", .CS)), known, .failed))
        for (index, tag) in tags.enumerated() {
            cases.append(("empty-\(index)", coordinate("POINT", tag, 1).setting(.init(tag: tag, vr: value(tag, 1).vr, value: .empty)), known, .failed))
        }
        let samples = coordinate("POINT", 0x0040A132, 1)
        cases.append(("samples-zero", samples.setting(.init(tag: 0x0040A132, vr: .UL, value: .unsignedIntegers([0]))), known, .failed))
        var nonwave = known
        nonwave.referencesWaveform = .unsatisfied
        cases.append(("samples-nonwave", samples.setting(sequence(0x0040A730, [selectedImage])), nonwave, .failed))
        var multigroup = known
        multigroup.channelsUseSingleMultiplexGroup = .unsatisfied
        let multiple = waveform.setting(sequence(0x00081199, [wavePair.setting(.init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers([1, 1, 2, 1])))]))
        cases.append(("samples-multigroup", samples.setting(sequence(0x0040A730, [multiple])), multigroup, .failed))
        cases.append(("samples-unproven", samples, .init(), .incomplete))
        XCTAssertEqual(cases.count, 48)
        for (name, item, caseFacts, expected) in cases {
            var facts = caseFacts
            if !item.contains(0x0040A132) {
                facts.referencesWaveform = .unsatisfied
                facts.channelsUseSingleMultiplexGroup = .undetermined
            }
            let usesWaveform = item.sequenceItems(for: .contentSequence).first?.dataSet.string(for: .valueType) == "WAVEFORM"
            if !usesWaveform { facts.channelsUseSingleMultiplexGroup = .undetermined }
            let pair = usesWaveform ? wavePair : imagePair
            let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [pair])])
            let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
            let source = base.setting(sequence(0x0040A730, [item])).setting(sequence(0x0040A375, [study]))
            let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let decodedItem = try XCTUnwrap(read.dataSet?.sequenceItems(for: .contentSequence).first?.dataSet)
            let report = DicomTemporalCoordinatesMacro.validate(decodedItem, conditions: facts)
            XCTAssertEqual(report[.attributes], expected, name)
            let composed = DicomSRContentValidator.validate(try XCTUnwrap(read.dataSet), temporalConditions: [[0]: facts])
            for diagnostic in report.diagnostics {
                XCTAssertTrue(composed.diagnostics.contains { $0.code == diagnostic.code && $0.severity == diagnostic.severity &&
                    $0.path == [.tag(0x0040A730), .item(0)] + diagnostic.path && $0.requirement == diagnostic.requirement }, name)
            }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_TEMPORAL_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                func truth(_ value: DicomAttributeRule.Truth) -> String {
                    value == .satisfied ? "true" : value == .unsatisfied ? "false" : "unknown"
                }
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                    "diagnostics": report.diagnostics.map { $0.code.rawValue }, "structureAndVRVM": "passed",
                    "referencesWaveform": truth(facts.referencesWaveform), "singleMultiplexGroup": truth(facts.channelsUseSingleMultiplexGroup)])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }
}
