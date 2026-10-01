import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_temporalTargetCorpus_composesActualGroupIdentityAndSampleBounds() throws {
        let cases: [(String, DicomValidationReport.Outcome)] = [
            ("sample-first", .passed), ("sample-last", .passed), ("sample-out", .failed), ("sample-zero", .failed),
            ("channels-zero", .passed), ("channels-missing", .incomplete), ("channels-out", .incomplete),
            ("groups-two", .failed), ("group-missing", .incomplete), ("sample-count-missing", .incomplete),
            ("sample-count-zero", .failed), ("target-missing", .incomplete), ("target-identity", .incomplete),
            ("shared-group", .passed), ("different-groups", .failed), ("unknown-shared-group", .incomplete),
            ("offset-alignment", .incomplete), ("date-alignment", .incomplete)
        ]
        for (name, expected) in cases {
            let fixture = try temporalTargetFixture(name)
            let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: fixture.source, purpose: .instance))
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let source = try XCTUnwrap(read.dataSet)
            var targets: [String: DicomDataSet] = [:]
            for (index, target) in fixture.targets.enumerated() {
                let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: target, purpose: .instance))
                XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
                if name != "target-missing" { targets[index == 0 ? "2.25.23212003" : "2.25.23212006"] = try XCTUnwrap(read.dataSet) }
            }
            let resolved = DicomSRCoordinateReferenceValidator.validate(source, targets: targets)
            let composed = DicomSRContentValidator.validate(source, targets: targets)
            XCTAssertEqual(resolved.report[.pixelsAndGeometry], expected, name)
            XCTAssertEqual(composed[.pixelsAndGeometry], expected, name)
            XCTAssertFalse(composed.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path.isEmpty }, name)
            if expected == .failed || ["target-identity", "channels-out", "group-missing"].contains(name) {
                XCTAssertTrue(composed.diagnostics.contains { $0.code == .semanticProjectionUnavailable &&
                    $0.path == [.tag(0x0040A730), .item(0)] }, name)
                XCTAssertNotEqual(composed[.operation], .passed, name)
            }
            if name == "sample-last" {
                var contrary = DicomTemporalCoordinatesMacro.Conditions()
                contrary.referencesWaveform = .unsatisfied
                let contradiction = DicomSRContentValidator.validate(source, temporalConditions: [[0]: contrary], targets: targets)
                XCTAssertTrue(contradiction.diagnostics.contains { $0.code == .attributeValueContradiction && $0.requirement == .type1C &&
                    $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A132)] })
                let limited = DicomSRContentValidator.validate(source, targets: targets, limits: .init(maximumRuleEvaluations: resolved.evaluations))
                XCTAssertEqual(limited[.pixelsAndGeometry], .incomplete)
                XCTAssertEqual(limited[.operation], .incomplete)
            }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_TEMPORAL_TARGET_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: fixture.source, options: .init(validationPurpose: .instance)).write(to: path.appendingPathExtension("dcm"))
                for (index, target) in fixture.targets.enumerated() {
                    try DicomDataSetWriter.part10Data(from: target, options: .init(validationPurpose: .instance))
                        .write(to: path.appendingPathExtension("target-\(index).dcm"))
                }
                func truth(_ value: DicomAttributeRule.Truth?) -> String { value == .satisfied ? "true" : value == .unsatisfied ? "false" : "unknown" }
                try JSONSerialization.data(withJSONObject: ["structureAndVRVM": "passed", "bounds": expected.rawValue,
                    "references": resolved.report[.references].rawValue, "composedGeometry": composed[.pixelsAndGeometry].rawValue,
                    "referencesWaveform": truth(resolved.temporalConditions[[0]]?.referencesWaveform),
                    "singleGroup": truth(resolved.temporalConditions[[0]]?.channelsUseSingleMultiplexGroup),
                    "diagnostics": resolved.report.diagnostics.map { $0.code.rawValue }]).write(to: path.appendingPathExtension("json"))
            }
        }
    }

    private func temporalTargetFixture(_ name: String) throws -> (source: DicomDataSet, targets: [DicomDataSet]) {
        func number(_ tag: Int, _ values: [UInt], _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .unsignedIntegers(values)) }
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let waveClass = "1.2.840.10008.5.1.4.1.1.9.1.1"
        let original = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet).setting(text(0x00081150, waveClass, .UI))
        let multiple = ["shared-group", "different-groups", "unknown-shared-group"].contains(name)
        let channels: [UInt] = name == "channels-zero" ? [1, 0] : name == "channels-out" ? [1, 3] :
            name == "group-missing" ? [3, 1] : name == "groups-two" ? [1, 1, 2, 1] : [1, 1]
        var selected: [DicomDataSet] = [], targets: [DicomDataSet] = [], evidence: [DicomDataSet] = []
        for index in 0..<(multiple ? 2 : 1) {
            let uid = index == 0 ? "2.25.23212003" : "2.25.23212006"
            let pair = original.setting(text(0x00081155, uid, .UI))
            evidence.append(pair)
            let selection = name == "channels-missing" ? pair : pair.setting(number(0x0040A0B0, channels, .US))
            selected.append(image.setting(text(0x0040A040, "WAVEFORM", .CS)).setting(text(0x0040A010, "SELECTED FROM", .CS)).setting(sequence(0x00081199, [selection])))
            var group = DicomDataSet(elements: [number(0x003A0005, [2], .US), number(0x003A0010, [name == "sample-count-zero" ? 0 : 7], .UL),
                sequence(0x003A0200, [.init(), .init()])])
            if name == "sample-count-missing" { group = group.removing(0x003A0010) }
            if multiple && name != "unknown-shared-group" { group = group.setting(text(0x003A0310, "2.25.2321880" + (name == "different-groups" && index == 1 ? "2" : "1"), .UI)) }
            targets.append(target().setting(text(0x00080016, waveClass, .UI)).setting(text(0x00080018, name == "target-identity" ? "2.25.999" : uid, .UI))
                .setting(sequence(0x54000100, name == "groups-two" ? [group, group] : [group])))
        }
        var temporal = image.removing(0x00081199).setting(text(0x0040A040, "TCOORD", .CS)).setting(text(0x0040A130, "POINT", .CS))
            .setting(number(0x0040A132, [name == "sample-first" ? 1 : name == "sample-zero" ? 0 : name == "sample-out" ? 8 : 7], .UL))
            .setting(sequence(0x0040A730, selected))
        if name == "offset-alignment" { temporal = temporal.removing(0x0040A132).setting(text(0x0040A138, "-1", .DS)) }
        if name == "date-alignment" { temporal = temporal.removing(0x0040A132).setting(text(0x0040A13A, "20260908", .DT)) }
        let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, evidence)])
        let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
        return (base.setting(sequence(0x0040A730, [temporal])).setting(sequence(0x0040A375, [study])), targets)
    }
}
